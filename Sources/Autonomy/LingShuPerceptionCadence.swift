import Foundation

/// 周期感知循环（模块 2）的**纯逻辑**：节流决策 + 系统音频突变分类。
/// 不依赖 UI / State / 系统 API，可离线确定性单测。
///
/// 取向（坑：不是空间问题，是持续 VL 调用的成本/延迟）：VL 单次 1–3s，必须节流——
/// 先用**廉价信号**（前台上下文签名变没变 + 系统音频电平突变）做闸门，再决定要不要花 VL；
/// 大脑在跑回合时让位（它自己会按需 screen_capture）；无任务/未武装时不唤醒大脑，避免持续烧 token。

/// 节流配置（可调，默认值为务实经验值）。
struct LingShuPerceptionCadenceConfig: Equatable, Sendable {
    /// 感知 tick 的最小间隔（心跳每秒触发，内部按此节流）。
    var tickInterval: TimeInterval
    /// 两次 VL 调用之间的**硬下限**（成本天花板）——无论屏幕怎么变，VL 不会比这更密。
    var minVLInterval: TimeInterval
    /// 即使屏幕签名没变，也至少每隔这么久强制刷新一次 VL（抓动态内容 / 同一窗口内的变化）。
    var forcedVLInterval: TimeInterval
    /// 两次「唤醒大脑自主反应」之间的冷却（防环境事件刷屏式唤醒烧钱）。
    var wakeCooldown: TimeInterval

    init(
        tickInterval: TimeInterval = 4,
        minVLInterval: TimeInterval = 9,
        forcedVLInterval: TimeInterval = 45,
        wakeCooldown: TimeInterval = 30
    ) {
        self.tickInterval = tickInterval
        self.minVLInterval = minVLInterval
        self.forcedVLInterval = forcedVLInterval
        self.wakeCooldown = wakeCooldown
    }

    static let `default` = LingShuPerceptionCadenceConfig()
}

/// 系统音频电平的活动态（纯分类：相对阈值判突变，带滞回）。
enum LingShuAudioActivityState: String, Equatable, Sendable {
    case silent   // 安静
    case onset    // 起音（静→响，突变上行）= 值得注意的事件
    case active   // 持续有声
    case offset   // 落音（响→静）
}

/// 系统音频突变检测（纯逻辑，值语义）。
/// 不做 FFT、不识别内容——只回答「声音是不是突然来了 / 停了」，作为唤醒闸门的输入之一。
/// 滞回（on/off 双阈值）避免临界电平反复抖动误报。
struct LingShuAudioActivityDetector: Equatable, Sendable {
    /// 判「有声」的电平阈值（RMS，SCStream Float32 PCM 量纲）。
    var onThreshold: Float
    /// 判「安静」的电平阈值（低于此才算落音）。
    var offThreshold: Float
    private(set) var isActive: Bool

    init(onThreshold: Float = 0.02, offThreshold: Float = 0.008, isActive: Bool = false) {
        self.onThreshold = onThreshold
        self.offThreshold = offThreshold
        self.isActive = isActive
    }

    /// 喂入一帧电平，返回这一刻的活动态（onset/offset 仅在状态翻转的那一帧返回）。
    mutating func ingest(level: Float) -> LingShuAudioActivityState {
        if isActive {
            if level < offThreshold { isActive = false; return .offset }
            return .active
        } else {
            if level > onThreshold { isActive = true; return .onset }
            return .silent
        }
    }
}

/// 一次感知 tick 的输入信号。
struct LingShuPerceptionTickInput: Equatable, Sendable {
    var now: Date
    var lastTickAt: Date
    var lastVLAt: Date
    var lastWakeAt: Date
    /// 廉价闸门：前台上下文签名（app + 窗口标题）相对上次是否变化。
    var screenChanged: Bool
    /// 本 tick 的音频活动态（nil = 无音频源/未启用）。
    var audio: LingShuAudioActivityState?
    /// 大脑当前是否在跑一个回合（在跑就不打断、不重复 VL）。
    var agentBusy: Bool
    /// 是否「武装」自主反应：未武装时只保持 digest 新鲜，不唤醒大脑（省钱 + 安全默认）。
    var autoReactArmed: Bool
}

/// 一次 tick 的决策。
struct LingShuPerceptionTickDecision: Equatable, Sendable {
    /// 这一拍是否真到了 tick 间隔（false = 还没到，直接跳过，连签名都不必算）。
    var due: Bool
    /// 是否花一次 VL 做态势理解。
    var captureVL: Bool
    /// 是否唤醒大脑自主反应（注入观察 → 让它决定要不要动手）。
    var wakeAgent: Bool
    var wakeReason: String?

    static let notDue = LingShuPerceptionTickDecision(due: false, captureVL: false, wakeAgent: false, wakeReason: nil)
}

enum LingShuPerceptionCadencePlanner {
    static func decide(
        _ input: LingShuPerceptionTickInput,
        config: LingShuPerceptionCadenceConfig = .default
    ) -> LingShuPerceptionTickDecision {
        // 节流：还没到 tick 间隔 → 这一拍什么都不做（连廉价签名都省了）。
        guard input.now.timeIntervalSince(input.lastTickAt) >= config.tickInterval - 0.001 else {
            return .notDue
        }
        // 大脑在跑回合：它自己会按需 screen_capture，周期循环让位（不重复花 VL、不打断、不抢着唤醒）。
        guard !input.agentBusy else {
            return .init(due: true, captureVL: false, wakeAgent: false, wakeReason: nil)
        }

        let sinceVL = input.now.timeIntervalSince(input.lastVLAt)
        // VL 闸门：屏幕变了 或 到了强制刷新点；但都不能突破 minVLInterval 硬下限（成本天花板）。
        let wantVL = input.screenChanged || sinceVL >= config.forcedVLInterval
        let captureVL = wantVL && sinceVL >= config.minVLInterval

        // 唤醒闸门：已武装自主反应 + 世界发生了显著变化（系统声音起音 / 前台界面变化）+ 过了冷却。
        // 这里**只判定「世界变了、值得让大脑看一眼」=反射**；要不要行动、做什么由大脑综合评判（wake 后把观察当输入注入会话）。
        let sinceWake = input.now.timeIntervalSince(input.lastWakeAt)
        var wakeAgent = false
        var wakeReason: String?
        if input.autoReactArmed, sinceWake >= config.wakeCooldown {
            if input.audio == .onset {
                wakeAgent = true
                wakeReason = "系统声音突然出现（可能有人开始说话或有提示音）"
            } else if input.screenChanged {
                wakeAgent = true
                wakeReason = "前台应用 / 屏幕界面发生了变化"
            }
        }

        return .init(due: true, captureVL: captureVL, wakeAgent: wakeAgent, wakeReason: wakeReason)
    }
}
