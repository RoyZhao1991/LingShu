import Foundation

/// 主线程(MainActor)卡死看门狗。
///
/// **为什么需要**:灵枢绝大多数状态/UI/agent 收尾都在 MainActor 上。一旦某处在 MainActor 上陷入 CPU 死循环
/// (实测过 `commonParentDir` 跨根路径死循环把主线程顶到 100% CPU),整个 App 的 UI/状态/语音全冻住,
/// 只有不碰 MainActor 的 `/health` 还能答——从外面看就是"卡死"。
///
/// **机制(关键:看门狗自己绝不挂在 MainActor 上)**:一个独立的 `Task.detached` 后台循环,周期性地
/// **竞速** `MainActor.run{}` 与一个超时——健康时 MainActor 子秒级就把闭包跑完(alive);卡死时闭包永远排在
/// 死循环后面跑不到,超时先到(miss)。连续 miss 到阈值 → 记诊断日志 + **强制重启 App**(`open` 自身后 `exit`),
/// 重启后从持久记忆/最近产出物 seed 接续(见下"续作"说明)。带**重启次数上限**防重启循环。
///
/// **续作**:重启后主会话用 `seededDistilledMemory()` + `recentDeliverablesContext()` 恢复上下文,用户说"继续"即可接上;
/// 当前**不重放卡死那一刻正在跑的具体 agent 回合**(全内存,跨重启重建在制品是更大的 Phase 5 工程)——会留一条 marker
/// 让重启后的 App 主动说明"我刚从卡死自动重启,刚才的活儿可能要你说声『继续』"。
final class LingShuMainActorWatchdog: @unchecked Sendable {
    static let shared = LingShuMainActorWatchdog()

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var started = false

    // 可调参数(健康代码下 MainActor 永远子秒级响应,故阈值给得宽,几乎不可能误判)。
    private let probeTimeout: TimeInterval   // 单次探测 MainActor 的超时
    private let pollInterval: TimeInterval   // 两次探测之间的间隔
    private let missesToRecover: Int         // 连续多少次无响应才判定卡死
    private let maxRestartsPerEpisode: Int   // 一个"卡死时段"内最多自动重启几次(防循环)
    private let episodeWindow: TimeInterval  // 超过这段时间没再重启,就把重启计数清零(视为已恢复)

    init(probeTimeout: TimeInterval = 30, pollInterval: TimeInterval = 10,
         missesToRecover: Int = 3, maxRestartsPerEpisode: Int = 3, episodeWindow: TimeInterval = 600) {
        self.probeTimeout = probeTimeout
        self.pollInterval = pollInterval
        self.missesToRecover = missesToRecover
        self.maxRestartsPerEpisode = maxRestartsPerEpisode
        self.episodeWindow = episodeWindow
    }

    // MARK: - 纯判定逻辑(可单测)

    /// 是否应触发重启:连续无响应达阈值,且本"卡死时段"内重启次数未超上限。
    static func shouldRecover(consecutiveMisses: Int, threshold: Int, restartsThisEpisode: Int, maxRestarts: Int) -> Bool {
        consecutiveMisses >= threshold && restartsThisEpisode < maxRestarts
    }

    /// 距上次重启已超过时段窗口 → 视为新时段,计数清零(纯函数可单测)。
    static func restartsAfterDecay(previousCount: Int, lastRestartAt: Date?, now: Date, window: TimeInterval) -> Int {
        guard let lastRestartAt, now.timeIntervalSince(lastRestartAt) <= window else { return 0 }
        return previousCount
    }

    // MARK: - 启动

    /// 启动看门狗(幂等)。`state` 仅用于探测期读取 missionTitle 做诊断,**只在 MainActor 活着时读**。
    func start(state: LingShuState) {
        lock.lock(); defer { lock.unlock() }
        guard !started else { return }
        started = true
        let timeout = probeTimeout, poll = pollInterval, threshold = missesToRecover
        let maxRestarts = maxRestartsPerEpisode, window = episodeWindow
        task = Task.detached(priority: .utility) {
            // 启动即检查:上次是不是看门狗重启来的,是就发一条接续提示。
            Self.announceIfRestartedByWatchdog(state: state)
            var misses = 0
            var lastKnownMission = "(未知)"
            let persisted = Self.loadRestartState()
            var restartsThisEpisode = Self.restartsAfterDecay(previousCount: persisted.count, lastRestartAt: persisted.at, now: Date(), window: window)
            while !Task.isCancelled {
                let probe = await Self.probeMainActor(timeout: timeout, state: state)
                if probe.alive {
                    misses = 0
                    if let m = probe.mission, !m.isEmpty { lastKnownMission = m }
                } else {
                    misses += 1
                    lingShuControlLog("watchdog: 主线程无响应 第\(misses)/\(threshold)次 (上次任务=\(lastKnownMission))")
                    if Self.shouldRecover(consecutiveMisses: misses, threshold: threshold, restartsThisEpisode: restartsThisEpisode, maxRestarts: maxRestarts) {
                        restartsThisEpisode += 1
                        Self.recoverByRestart(restartsThisEpisode: restartsThisEpisode, lastMission: lastKnownMission)
                        return   // exit(0) 已在 recover 内调用,这里兜底
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
            }
        }
    }

    /// 竞速:`MainActor.run{}` vs 超时。MainActor 卡死时 run 永不返回,超时先到 → alive=false。
    private static func probeMainActor(timeout: TimeInterval, state: LingShuState) async -> (alive: Bool, mission: String?) {
        await withTaskGroup(of: (Bool, String?).self) { group in
            group.addTask {
                let mission = await MainActor.run { state.missionTitle }   // MainActor 活着才会返回
                return (true, mission)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return (false, nil)
            }
            let first = await group.next() ?? (false, nil)
            group.cancelAll()
            return first
        }
    }

    // MARK: - 恢复(强制重启)

    private static func recoverByRestart(restartsThisEpisode: Int, lastMission: String) {
        lingShuControlLog("watchdog: ⚠️ 判定主线程卡死,强制重启 App(本时段第 \(restartsThisEpisode) 次)。卡死时任务=\(lastMission)")
        saveRestartState(count: restartsThisEpisode, at: Date(), lastMission: lastMission)
        let appPath = Bundle.main.bundlePath
        // 用一个独立 shell:等本进程退出后再 open 自身(open 对已退出的 app 会拉起新实例)。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; /usr/bin/open \"\(appPath)\""]
        try? p.run()
        Thread.sleep(forTimeInterval: 0.5)   // 给 relauncher 排程的余地
        exit(0)
    }

    // MARK: - 重启状态持久化(防重启循环 + 重启后接续提示)

    private struct RestartState { var count: Int; var at: Date?; var lastMission: String?; var consumed: Bool }

    private static var stateURL: URL {
        let dir = LingShuRuntimeEnvironment.homeDirectory
            .appendingPathComponent("Library/Application Support/LingShu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("watchdog-restart.json")
    }

    private static func loadRestartState() -> (count: Int, at: Date?, mission: String?, consumed: Bool) {
        guard let data = try? Data(contentsOf: stateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (0, nil, nil, true) }
        let count = obj["count"] as? Int ?? 0
        let at = (obj["at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        let mission = obj["lastMission"] as? String
        let consumed = obj["consumed"] as? Bool ?? true
        return (count, at, mission, consumed)
    }

    private static func saveRestartState(count: Int, at: Date, lastMission: String) {
        let obj: [String: Any] = ["count": count, "at": at.timeIntervalSince1970, "lastMission": lastMission, "consumed": false]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: stateURL, options: .atomic) }
    }

    private static func markRestartConsumed() {
        let s = loadRestartState()
        let obj: [String: Any] = ["count": s.count, "at": (s.at ?? Date()).timeIntervalSince1970, "lastMission": s.mission ?? "", "consumed": true]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: stateURL, options: .atomic) }
    }

    /// 启动时:若上次是看门狗重启来的(未消费),主动在对话里说明"我刚从卡死自动重启"。
    private static func announceIfRestartedByWatchdog(state: LingShuState) {
        let s = loadRestartState()
        guard !s.consumed, let at = s.at, Date().timeIntervalSince(at) < 120 else { return }
        markRestartConsumed()
        let mission = s.mission ?? ""
        Task { @MainActor in
            let note = mission.isEmpty
                ? "⚠️ 我刚检测到自己卡住了,已自动重启恢复。如果刚才有没干完的活儿,说一声『继续』我接着做。"
                : "⚠️ 我刚检测到自己卡住了(卡死时在做:\(mission)),已自动重启恢复。需要的话说『继续』我接着做。"
            state.chatMessages.append(.init(speaker: "灵枢", text: note, isUser: false))
            lingShuControlLog("watchdog: 已从卡死自动重启并接续(上次任务=\(mission))")
        }
    }
}
