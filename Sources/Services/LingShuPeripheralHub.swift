import Foundation
import Network
import Combine
import AppKit

/// **统一外设中枢**(本体):一个「已连接外设」列表,汇聚所有来源——
/// 网络(mDNS,本类原生扫)+ 串口/USB/蓝牙/电源/传感器/自编组件(壳侧 `setExternalPeripherals` 灌入)+ 本机可控。
/// **不在这里硬编码分类**:每台外设的 group/category/接入路由大脑判(`applyClassifications`);本类只给客观事实 + 控本机。
@MainActor
final class LingShuPeripheralHub: ObservableObject {
    @Published private(set) var peripherals: [LingShuPeripheral] = []
    @Published private(set) var scanning = false
    @Published private(set) var localVolume = 0
    @Published var hint = ""

    /// 要浏览的家居/设备 Bonjour 服务类型(客观清单,非分类决策;Info.plist 的 NSBonjourServices 要同步)。
    static let browsedServiceTypes = [
        "_hap._tcp", "_airplay._tcp", "_raop._tcp", "_matter._tcp", "_matterc._udp",
        "_hue._tcp", "_shelly._tcp", "_http._tcp", "_googlecast._tcp", "_miio._udp", "_companion-link._tcp"
    ]

    private var browsers: [NWBrowser] = []
    private var networkByType: [String: [LingShuPeripheral]] = [:]
    private var scanGraceTask: Task<Void, Never>?
    private var externalPeripherals: [LingShuPeripheral] = []   // 壳侧灌入(串口/USB/蓝牙/电源/传感器/组件)
    private var classifications: [String: LingShuPeripheralClassification] = [:]
    private var integratedIDs: Set<String> = []

    /// 本机可控外设(始终在列)。
    private var localDevices: [LingShuPeripheral] {
        [LingShuPeripheral(
            id: "local.volume", name: "本机 · 系统音量", transport: .local,
            raw: "macOS 系统输出音量(osascript)", statusLine: "当前音量 \(localVolume)%",
            builtinActions: ["mute", "vol_down", "vol_up"], classification: nil)]
    }

    /// 待大脑归类的外设(本机/已归类的除外)。
    var unclassified: [LingShuPeripheral] { peripherals.filter { $0.classification == nil && $0.transport != .local } }

    // MARK: - 壳侧汇入 + 大脑归类

    /// 壳把非网络外设(串口/USB/蓝牙/电源/传感器/组件)灌进来。
    func setExternalPeripherals(_ list: [LingShuPeripheral]) { externalPeripherals = list; rebuild() }

    /// 应用大脑的分类/分组结果(按 id)。
    func applyClassifications(_ map: [String: LingShuPeripheralClassification]) {
        for (k, v) in map { classifications[k] = v }
        rebuild()
    }

    /// 标记已真接入的外设 id(有真驱动 → 可对话控制)。
    func setIntegrated(_ ids: Set<String>) { integratedIDs.formUnion(ids); rebuild() }

    // MARK: - 扫描(网络 mDNS)

    func startScan() {
        guard !scanning else { return }
        scanning = true; hint = ""; networkByType = [:]; rebuild()
        for type in Self.browsedServiceTypes {
            let browser = NWBrowser(for: .bonjour(type: type, domain: "local."), using: NWParameters())
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                Task { @MainActor in self?.handleNetwork(type: type, results: results) }
            }
            // 不在单个浏览器 .failed 时报"受限"——某些(如 UDP)服务类型本就会 failed,会误报;真受限由下面的宽限期零结果判定。
            browser.start(queue: .global(qos: .utility))
            browsers.append(browser)
        }
        Task { @MainActor in await refreshVolume() }
        // 宽限期收尾:6s 后停"发现中";**只有真没扫到任何网络设备**才提示(扫到了=没受限)。
        scanGraceTask?.cancel()
        scanGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self else { return }
            self.scanning = false
            let netCount = self.networkByType.values.reduce(0) { $0 + $1.count }
            self.hint = netCount > 0 ? "" : "局域网未发现设备。若设备没出现,确认已允许灵枢访问「本地网络」(系统设置 → 隐私与安全 → 本地网络)。"
        }
    }

    func stopScan() { scanGraceTask?.cancel(); for b in browsers { b.cancel() }; browsers = []; scanning = false }

    private func handleNetwork(type: String, results: Set<NWBrowser.Result>) {
        var devs: [LingShuPeripheral] = []
        for r in results {
            guard case let .service(name, stype, _, _) = r.endpoint else { continue }
            devs.append(LingShuPeripheral(
                id: "net/\(name)", name: name, transport: .network,
                raw: "mDNS 服务类型 \(stype)", statusLine: "局域网服务 \(stype)",
                builtinActions: [], classification: nil))
        }
        networkByType[type] = devs
        if !devs.isEmpty { hint = "" }   // 扫到网络设备 = 本地网络没被挡,清掉任何"受限"提示
        rebuild()
    }

    private func rebuild() {
        var merged: [String: LingShuPeripheral] = [:]
        func add(_ p: LingShuPeripheral) {
            var x = p
            if let c = classifications[p.id] { x.classification = c }
            if integratedIDs.contains(p.id) { x.integrated = true }
            merged[x.id] = x
        }
        localDevices.forEach(add)
        externalPeripherals.forEach(add)
        networkByType.values.flatMap { $0 }.forEach(add)
        peripherals = merged.values.sorted {
            $0.displayGroup == $1.displayGroup ? $0.name < $1.name : $0.displayGroup < $1.displayGroup
        }
    }

    // MARK: - 本机控制

    func refreshVolume() async {
        let out = await Self.run("/usr/bin/osascript", ["-e", "output volume of (get volume settings)"])
        if let v = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) { localVolume = v; rebuild() }
    }

    @discardableResult
    func controlLocal(_ id: String, _ action: String) async -> String {
        guard id == "local.volume" else { return "未知本机外设:\(id)" }
        var v = localVolume
        switch action {
        case "vol_up": v = min(100, v + 10)
        case "vol_down": v = max(0, v - 10)
        case "mute": v = 0
        default: if let n = Int(action) { v = max(0, min(100, n)) } else { return "未知动作:\(action)" }
        }
        _ = await Self.run("/usr/bin/osascript", ["-e", "set volume output volume \(v)"])
        await refreshVolume()
        return "已把本机音量设为 \(localVolume)%"
    }

    /// 一键直达 macOS「本地网络」隐私设置页(实际开关受 Apple 安全限制只能用户点,这是允许的最接近"一键解除")。
    static func openLocalNetworkSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated static func run(_ executable: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            Task.detached {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
                let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: ""); return }
                let killer = Task.detached { try? await Task.sleep(nanoseconds: 8_000_000_000); if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit(); killer.cancel()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
        }
    }
}
