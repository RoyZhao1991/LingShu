import Foundation

/// **硬件设备发现**(M3 引导原语,纯逻辑可单测):枚举本机接入的真实硬件(串口/USB/蓝牙/电源控制器),
/// 并对每个设备标注**有没有对应的驱动组件**(交叉比对已注册的自编传感器源)——这是"发现一个没驱动的新外设"
/// 的那一步,让大脑看清能为哪些硬件自写驱动(author_component component_kind=sensor)。
///
/// 命令执行(`system_profiler`/`ioreg`/`ls /dev`)在 State 工具层做(读取类、无副作用);本类型只做**解析 + 驱动缺口分析**。
enum LingShuDeviceDiscovery {

    struct Device: Equatable, Sendable {
        var kind: String       // serial / usb / bluetooth / power
        var id: String         // 稳定标识(路径 / 地址 / 控制器名)
        var name: String
        var detail: String     // 一句话补充(电量/RSSI/厂商等)
        var connected: Bool
    }

    // MARK: - 解析(纯)

    /// 从 `/dev/cu.*` 路径列表解析串口。过滤系统回环/调试这类**非外设的 OS 伪端口**(客观事实,非设备识别)。
    /// **零品牌/芯片关键词**(撤定制,§4 #9):不再靠 usbserial/ftdi/slab… 猜"这是什么设备"——
    /// 那是定制且永远不通用;串口节点是什么、能不能接,交大脑(classify/probe 时按真实返回判)。
    static func parseSerialPorts(_ devicePaths: [String]) -> [Device] {
        devicePaths.compactMap { path -> Device? in
            let base = (path as NSString).lastPathComponent          // 如 cu.usbserial-1420
            guard base.hasPrefix("cu.") else { return nil }
            let name = String(base.dropFirst(3))
            let lower = name.lowercased()
            // 系统回环/调试控制台不是可喂数据的外设(macOS 通用 OS 端点,非具体设备型号),排除噪声。
            if lower.contains("bluetooth-incoming") || lower.contains("debug-console") { return nil }
            return Device(kind: "serial", id: path, name: name, detail: "串口节点(接的什么设备由大脑探测识别)", connected: true)
        }
    }

    /// 解析 `system_profiler SPUSBDataType -json`(递归 `_items`)。
    static func parseUSB(_ json: Data) -> [Device] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let items = root["SPUSBDataType"] as? [[String: Any]] else { return [] }
        var out: [Device] = []
        func walk(_ nodes: [[String: Any]]) {
            for node in nodes {
                if let name = node["_name"] as? String,
                   node["vendor_id"] != nil || node["product_id"] != nil {   // 真设备(有 VID/PID),跳过 bus 节点
                    let vid = (node["vendor_id"] as? String) ?? ""
                    let pid = (node["product_id"] as? String) ?? ""
                    out.append(Device(kind: "usb", id: "\(vid):\(pid):\(name)", name: name, detail: "USB 设备 \(vid) \(pid)".trimmingCharacters(in: .whitespaces), connected: true))
                }
                if let children = node["_items"] as? [[String: Any]] { walk(children) }
            }
        }
        walk(items)
        return out
    }

    /// 解析 `system_profiler SPBluetoothDataType -json`:已连/未连外设(已连含电量时带出)。
    static func parseBluetooth(_ json: Data) -> [Device] {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        var out: [Device] = []
        func devices(in entries: Any?, connected: Bool) {
            guard let list = entries as? [[String: Any]] else { return }
            for entry in list {
                for (name, value) in entry {
                    let props = value as? [String: Any] ?? [:]
                    let addr = (props["device_address"] as? String) ?? ""
                    var bits: [String] = []
                    if let b = props["device_batteryLevelMain"] as? String { bits.append("电量 \(b)") }
                    if let r = props["device_rssi"] as? String { bits.append("RSSI \(r)") }
                    if let minor = props["device_minorType"] as? String { bits.append(minor) }
                    out.append(Device(kind: "bluetooth", id: addr.isEmpty ? name : addr, name: name,
                                      detail: bits.joined(separator: " · "), connected: connected))
                }
            }
        }
        for section in arr {
            devices(in: section["device_connected"], connected: true)
            devices(in: section["device_not_connected"], connected: false)
        }
        return out
    }

    // MARK: - 驱动缺口分析 + 汇总

    /// 某设备是否已有对应驱动组件(交叉比对已注册自编传感器源 id)。
    /// 启发式:取设备的代表性 token(串口基名 / 蓝牙地址尾段 / kind 关键词),看是否被某源 id 包含。
    static func hasDriver(for device: Device, registeredSourceIDs: Set<String>) -> Bool {
        let ids = registeredSourceIDs.map { $0.lowercased() }
        let tokens = coverageTokens(for: device)
        return ids.contains { id in tokens.contains { !$0.isEmpty && id.contains($0) } }
    }

    /// 驱动匹配用的代表性 token —— **取设备的真实名/标识**(客观事实),**零设备类型关键词**(撤定制,§4 #9:
    /// 不再写死 battery/power/电池… 这类品类词)。蓝牙取地址尾段(无名时的稳定标识),其余取真实名+标识。
    static func coverageTokens(for device: Device) -> [String] {
        var tokens: [String] = []
        let name = device.name.lowercased().replacingOccurrences(of: " ", with: "")
        if !name.isEmpty { tokens.append(name) }
        if device.kind == "bluetooth" {
            tokens.append(String(device.id.replacingOccurrences(of: ":", with: "").suffix(6)).lowercased())
        } else {
            let idToken = (device.id as NSString).lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
            if !idToken.isEmpty { tokens.append(idToken) }
        }
        return tokens.filter { !$0.isEmpty }
    }

    /// 汇总成给大脑的报告:按类列设备 + 标驱动有无 + 引导对没驱动的设备自写驱动。
    static func summarize(_ devices: [Device], registeredSourceIDs: Set<String>) -> String {
        guard !devices.isEmpty else { return "未发现可枚举的外设(串口/USB/蓝牙/电源控制器)。" }
        let kindLabel = ["serial": "串口", "usb": "USB", "bluetooth": "蓝牙", "power": "电源控制器"]
        var lines: [String] = []
        var gaps = 0
        for kind in ["serial", "usb", "bluetooth", "power"] {
            let group = devices.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            lines.append("【\(kindLabel[kind] ?? kind)】")
            for d in group {
                let driven = hasDriver(for: d, registeredSourceIDs: registeredSourceIDs)
                if !driven { gaps += 1 }
                let mark = driven ? "✅有驱动" : "⚠️无驱动组件"
                let conn = d.connected ? "" : "(未连接)"
                let detail = d.detail.isEmpty ? "" : " — \(d.detail)"
                lines.append("  · [\(mark)] \(d.name)\(conn)\(detail)")
            }
        }
        let hint = gaps > 0
            ? "\n发现 \(gaps) 个**没有驱动组件**的设备/控制器。要接入哪个就用 author_component(component_kind=sensor)给它写一个驱动:runner 去读它的真实数据(串口读行 / ioreg 读控制器 / system_profiler 读蓝牙),解析成读数 JSON;上线后数据进感知链,perceive 即可拿到。"
            : "\n所有已枚举设备都已有驱动组件。"
        return lines.joined(separator: "\n") + "\n" + hint
    }
}
