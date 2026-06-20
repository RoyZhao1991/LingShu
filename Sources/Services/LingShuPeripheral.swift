import Foundation

/// **统一外设模型**:灵枢眼里"所有东西都是外设"——网络设备(mDNS)、串口、USB、蓝牙、电源控制器、
/// 已接入的传感器/执行器组件,统一成一条 `LingShuPeripheral`,进**一个已连接外设列表**。
/// **分类/分组不在壳里硬编码,由大脑在连接时判定**(`classification`,nil = 待大脑归类);壳只给原始事实。
///
/// 传输方式是客观事实(怎么连上的),可由壳确定;但"这是灯/音箱/插座/传感器、走哪条接入路"是判断,交大脑。
enum LingShuPeripheralTransport: String, Sendable, Equatable, CaseIterable {
    case network    // 局域网 mDNS 服务
    case serial     // 串口 /dev/cu.*
    case usb
    case bluetooth
    case power      // IOKit 电源控制器
    case sensor     // 已接入的感知源
    case component  // 已自编上线的工具/执行器组件
    case local      // 本机可控(音量…)

    /// 仅用于大脑归类前的**即时占位分组**(客观传输标签,非决策);大脑归类后被 `classification.group` 覆盖。
    var placeholderGroup: (zh: String, en: String) {
        switch self {
        case .network: ("网络设备(待归类)", "Network")
        case .serial: ("串口设备", "Serial")
        case .usb: ("USB 设备", "USB")
        case .bluetooth: ("蓝牙设备", "Bluetooth")
        case .power: ("电源/硬件控制器", "Power")
        case .sensor: ("感知源", "Sensors")
        case .component: ("自编组件", "Components")
        case .local: ("本机可控", "Local")
        }
    }
}

/// 大脑给一台外设的判定(连接时自动产出 / 探测后更新)。`access` 取受限词表保接入路由确定;其余是大脑的语义判断。
/// **灵枢是 AI 不是工具**:这里承载的是大脑"看懂了这是什么、有什么用、什么能力、能不能接入",而非一个死徽章。
struct LingShuPeripheralClassification: Equatable, Sendable {
    var canonical: String       // **归一键**:同一物理设备的多通道/多广播归到同一个键(合并去重)
    var alias: String           // **语义别名**:这到底是什么(如"床头灯""客厅音箱"),取代产品代号
    var what: String            // 用途/说明(大脑看懂后的一句话)
    var deviceType: String      // 设备类型分组(灯/音箱/鼠标/电脑/手机/传感器/网络服务…)
    var capabilities: [String]  // 能力清单(开关/亮度/色温/音频输出/音频输入…)——多通道折这里,不拆成多设备
    var access: String          // 受限词表:open_local / airplay / homekit / matter / needs_code / unknown
    var integratable: Bool      // 大脑判:能不能接入(让灵枢能控/能读)
    var note: String            // 怎么接 / 能否自写驱动

    /// 灵枢能否全自动接入(开放协议/airplay,无需人工给码/改本体)。
    var autoAdoptable: Bool { integratable && ["open_local", "airplay"].contains(access.lowercased()) }
}

struct LingShuPeripheral: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var transport: LingShuPeripheralTransport
    /// 给大脑读的原始事实(服务类型/路径/厂商/地址…),用于归类。
    var raw: String
    var statusLine: String
    /// 本机可控的内建动作(如 ["mute","vol_down","vol_up"]);非本机为空。
    var builtinActions: [String]
    /// 大脑判定(nil = 待探测/归类)。
    var classification: LingShuPeripheralClassification?
    /// **已真接入**(壳判:有 author 的驱动组件指向它 / 本机内建)——接入后才"可控/可对话控制"。
    var integrated: Bool = false

    /// 展示名:大脑别名优先(取代产品代号),否则原始名。
    var displayName: String {
        if let a = classification?.alias.trimmingCharacters(in: .whitespaces), !a.isEmpty { return a }
        return name
    }
    /// 展示分组:大脑判的设备类型优先,否则用传输占位。
    var displayGroup: String {
        if let d = classification?.deviceType.trimmingCharacters(in: .whitespaces), !d.isEmpty { return d }
        return transport.placeholderGroup.zh
    }
    /// 合并键:同一物理设备的多通道归一(大脑给的 canonical 优先,否则各自独立)。
    var canonicalKey: String {
        if let c = classification?.canonical.trimmingCharacters(in: .whitespaces), !c.isEmpty { return c }
        return id
    }
    /// 真能控?= 已接入(有真驱动)或本机内建动作。**不再用大脑的乐观猜测当"可控"。**
    var isControllable: Bool { integrated || !builtinActions.isEmpty }
}
