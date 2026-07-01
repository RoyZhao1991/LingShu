import SwiftUI
import AppKit

extension StepState {
    var icon: String {
        switch self {
        case .waiting: "circle"
        case .running: "bolt.fill"
        case .done: "checkmark"
        }
    }

    var color: Color {
        switch self {
        case .waiting: Color.lingFaint
        case .running: .orange
        case .done: .green
        }
    }
}

extension AgentRuntimeMode {
    var icon: String {
        switch self {
        case .dormant: "pause.circle"
        case .planning: "doc.text.magnifyingglass"
        case .working: "bolt.fill"
        case .supervising: "eye"
        case .correcting: "wrench.adjustable"
        case .verifying: "checklist.checked"
        }
    }

    var color: Color {
        switch self {
        case .dormant: Color.lingFaint
        case .planning: .indigo
        case .working: .orange
        case .supervising: .teal
        case .correcting: .red
        case .verifying: .green
        }
    }
}

extension MissionRuntimePhase {
    var icon: String {
        switch self {
        case .idle: "pause.circle"
        case .planning: "doc.text.magnifyingglass"
        case .executing: "cpu"
        case .supervising: "eye"
        case .correcting: "exclamationmark.triangle"
        case .verifying: "checklist.checked"
        case .delivering: "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .idle: Color.lingFaint
        case .planning: .indigo
        case .executing: .orange
        case .supervising: .teal
        case .correcting: .red
        case .verifying: .green
        case .delivering: .brown
        }
    }
}

extension TaskRuntimeStage {
    var icon: String {
        switch self {
        case .dormant: "pause.circle"
        case .intake: "tray.and.arrow.down"
        case .memory: "brain"
        case .planning: "list.bullet.rectangle"
        case .permission: "lock.shield"
        case .executing: "hammer"
        case .monitoring: "waveform.path.ecg"
        case .checking: "checklist.checked"
        case .review: "checkmark.seal"
        case .delivering: "shippingbox"
        case .blocked: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .dormant: Color.lingFaint
        case .intake: .cyan
        case .memory: .purple
        case .planning: .indigo
        case .permission: .orange
        case .executing: .lingHolo
        case .monitoring: .teal
        case .checking: .green
        case .review: .green
        case .delivering: .brown
        case .blocked: .red
        }
    }
}

extension String {
    var eventColor: Color {
        switch self {
        case "ok": .green
        case "info": .teal
        case "medium": .orange
        case "high": .red
        default: Color.lingFaint
        }
    }
}

extension LingShuTraceKind {
    var icon: String {
        switch self {
        case .system: "sparkles"
        case .route: "arrow.triangle.branch"
        case .runtime: "hammer"
        case .model: "brain.head.profile"
        case .agent: "person.3.sequence"
        case .tool: "terminal"
        case .warning: "exclamationmark.triangle"
        case .result: "checkmark.seal"
        }
    }

    var color: Color {
        switch self {
        case .system: Color.lingHolo
        case .route: .cyan
        case .runtime: .orange
        case .model: .indigo
        case .agent: .orange
        case .tool: .green
        case .warning: .red
        case .result: .teal
        }
    }
}

extension LingShuTaskExecutionStatus {
    var color: Color {
        switch self {
        case .queued: .purple
        case .running: .lingHolo
        case .answered: .cyan
        case .dispatched: .orange
        case .completed: .green
        case .needsRevision: .orange
        case .blocked: .red
        case .suspended: .yellow   // 网络中断暂停:黄色(区别于红色"异常"——它会自动续)
        // 通用中枢 P2 真闭环·新增状态配色。
        case .analyzing: .purple
        case .acquiringCapability: .lingHolo
        case .waitingForUser: .yellow   // 等用户提供前提(凭据/授权…),非失败
        case .ready: .cyan
        case .partial: .orange          // 部分完成:橙色提示"没全成"
        case .verified: .green
        case .failed: .red
        }
    }
}

extension LingShuTaskExecutionMessageKind {
    var icon: String {
        switch self {
        case .user: "person.fill"
        case .core: "sparkles"
        case .memory: "memorychip"
        case .router: "arrow.triangle.branch"
        case .agent: "person.3.sequence"
        case .model: "brain.head.profile"
        case .review: "checkmark.seal"
        case .result: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .user: .lingHolo
        case .core: .cyan
        case .memory: .purple
        case .router: .teal
        case .agent: .orange
        case .model: .indigo
        case .review: .green
        case .result: .green
        case .warning: .red
        }
    }
}

extension Date {
    var taskRecordDisplayTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(18)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.07))
            }
    }
}

extension Color {
    /// **跟随系统外观自动适配**(浅色/深色,2026-06-29)。SwiftUI `Color` 经 `NSColor` 的 dynamicProvider 按当前外观实时解析,
    /// 无需在每个视图读 colorScheme。给一对 (light, dark) sRGB,系统切外观即自动换。
    static func lingAdaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    /// 主背景:深=近黑 / 浅=**柔和纸白(非刺眼纯白)**。浅色取 Linear/Vercel 风冷调纸白,给内容呼吸。
    static let lingVoid = lingAdaptive(light: (0.969, 0.973, 0.980), dark: (0.018, 0.026, 0.032))
    /// **主前景基色(文字/图标/描边/微表面):深=白 / 浅=近黑冷石板(#1A1D21)**——取代散落的 `Color.lingFg.opacity(X)`。
    /// @0.9=锐利正文、@0.6=次级、@0.4=弱、@0.08~0.12=细描边/微表面,半透明语义两侧都成立。
    static let lingFg = lingAdaptive(light: (0.102, 0.114, 0.129), dark: (1, 1, 1))
    /// 强调色(全息青):深=亮青霓虹 / 浅=**teal-600 深青(#0D9488)**——亮青在浅底发飘,浅色须加深加沉。
    static let lingHolo = lingAdaptive(light: (0.051, 0.580, 0.533), dark: (0.22, 0.94, 0.86))
    /// 次强调(蓝):浅=精炼蓝 #2563EB(blue-600)。
    static let lingHoloAlt = lingAdaptive(light: (0.146, 0.388, 0.922), dark: (0.25, 0.55, 1.0))

    /// **画布(主窗口底):深=深空 / 浅=比表面更深一档的柔灰**。关键设计点——浅色用灰画布,
    /// 才能让白色工具条/卡片"浮起来"形成三级层次(画布灰 < 面 lingVoid近白 < 工具条 lingBar纯白),不再是一张死板大白纸。
    static let lingCanvas = lingAdaptive(light: (0.914, 0.922, 0.937), dark: (0.018, 0.026, 0.032))
    /// **工具条/导航条表面(顶栏 + 底部输入坞):深=半透明暗条(透出辉光) / 浅=纯白上浮**。配阴影+分隔线=明确的 chrome 区。
    static let lingBar = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.6)
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    })
    /// 画布底部压暗渐变:深色为文字可读性压暗;浅色几乎不压(否则浅底发灰发脏)。
    static let lingCanvasVignette = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.015)
    })
    /// 底部输入坞表面:**深=透明(维持原悬浮观感,零回归)/ 浅=纯白上浮 compose 卡**(配阴影浮于灰画布)。
    static let lingDockSurface = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.clear
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    })
    /// 数字人 mini 光球的核心盘(背景):深=半透明黑(发光核底) / 浅=**柔光薄荷**(白顶栏上是柔和浅球,核心青环看得见,不再是刺眼黑盘)。
    static let lingOrbCore = Color(nsColor: NSColor(name: nil) { ap in
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.68)
            : NSColor(srgbRed: 0.918, green: 0.973, blue: 0.961, alpha: 1.0)
    })
    /// 光球**中心核/种子点**高亮:深=白热核(亮在暗底) / 浅=**深青核**(亮在浅底)。
    /// 原来直接用 `lingFg`(深白/浅黑)→浅色下核心变成黑点,中心圈被吞;改成跟随的青/白核,两侧都"亮"。
    static let lingOrbSeed = lingAdaptive(light: (0.039, 0.420, 0.380), dark: (1, 1, 1))

    static let lingBackground = Color(red: 0.945, green: 0.955, blue: 0.955)
    static let lingPanel = Color(red: 0.968, green: 0.974, blue: 0.972)
    static let lingSidebar = Color(red: 0.105, green: 0.125, blue: 0.128)
    static let lingInk = Color(red: 0.075, green: 0.105, blue: 0.11)
    static let lingMuted = Color(red: 0.36, green: 0.42, blue: 0.43)
    static let lingFaint = Color(red: 0.58, green: 0.63, blue: 0.64)
    static let lingAccent = Color(red: 0.0, green: 0.48, blue: 0.45)
}
