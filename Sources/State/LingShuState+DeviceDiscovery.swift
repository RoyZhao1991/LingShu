import Foundation

/// **硬件设备发现四肢**(M3 引导:发现一个没驱动的新外设)。
///
/// 枚举本机真实接入的硬件——串口(`/dev/cu.*`)、USB(`system_profiler SPUSBDataType`)、蓝牙(`SPBluetoothDataType`)、
/// 电源控制器(IOKit `AppleSmartBattery`)——并标出**哪些还没有驱动组件**(交叉比对已注册的自编传感器源)。
/// 这就是可插拔进化闭环的第一步:大脑据此知道"有个 X 设备没驱动",再 `author_component(component_kind=sensor)` 给它写驱动。
/// 命令都是**只读枚举**(无副作用),不走审批门。解析/缺口分析在纯逻辑 `LingShuDeviceDiscovery`。
@MainActor
extension LingShuState {

    func discoverDevicesTool() -> LingShuAgentTool {
        LingShuAgentTool(
            name: "discover_devices",
            description: "枚举本机真实接入的硬件(串口/USB/蓝牙/电源控制器)并标出哪些还没有驱动组件。接外设、想知道'有什么硬件可以接入/读取'时调用;之后对没驱动的设备用 author_component(component_kind=sensor)写一个专用驱动读它的真实数据。",
            parametersJSON: "{\"type\":\"object\",\"properties\":{}}"
        ) { [weak self] _ in
            guard let self else { return "执行环境不可用。" }
            return await self.discoverDevices()
        }
    }

    func discoverDevices() async -> String {
        let registered = Set(externalSensory.availableSources.map(\.id))
        let serial = LingShuDeviceDiscovery.parseSerialPorts(Self.listDevCuPaths())
        let usbJSON = await Self.runReadCommand("/usr/sbin/system_profiler", ["SPUSBDataType", "-json"], timeout: 15)
        let usb = LingShuDeviceDiscovery.parseUSB(Data(usbJSON.utf8))
        let btJSON = await Self.runReadCommand("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"], timeout: 15)
        let bt = LingShuDeviceDiscovery.parseBluetooth(Data(btJSON.utf8))
        let power = await Self.detectPowerControllers()
        let devices = serial + usb + bt + power
        appendTrace(kind: .result, actor: "设备发现", title: "枚举完成",
                    detail: "串口\(serial.count)/USB\(usb.count)/蓝牙\(bt.count)/电源\(power.count)")
        return LingShuDeviceDiscovery.summarize(devices, registeredSourceIDs: registered)
    }

    // MARK: - 只读枚举原语(nonisolated static)

    /// 列 `/dev/cu.*` 路径(串口节点)。
    nonisolated static func listDevCuPaths() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        return names.filter { $0.hasPrefix("cu.") }.map { "/dev/\($0)" }.sorted()
    }

    /// 检测电源控制器(IOKit AppleSmartBattery):装机即作为一个可读硬件控制器列出。
    nonisolated static func detectPowerControllers() async -> [LingShuDeviceDiscovery.Device] {
        let out = await runReadCommand("/usr/sbin/ioreg", ["-rn", "AppleSmartBattery"], timeout: 8)
        guard out.contains("\"BatteryInstalled\" = Yes") else { return [] }
        return [LingShuDeviceDiscovery.Device(
            kind: "power", id: "AppleSmartBattery", name: "电池管理控制器(AppleSmartBattery)",
            detail: "IOKit 电源控制器:温度/电芯电压/循环数/瞬时电流(需驱动解析)", connected: true)]
    }

    /// 跑一条只读命令,取 stdout(软超时杀进程,绝不吊死回合)。失败/超时返回空串。
    nonisolated static func runReadCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do { try process.run() } catch { continuation.resume(returning: ""); return }
                let killer = Task.detached {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    if process.isRunning { process.terminate() }
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                killer.cancel()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
