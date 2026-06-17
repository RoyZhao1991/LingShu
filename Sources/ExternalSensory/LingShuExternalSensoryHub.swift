import Foundation
import Combine

/// **外接设备感知中枢（汇聚阶段）**。
///
/// 职责：注册若干独立感知源（每个跑自己的线程）；按用户开关**无缝启用/停用**任一源；把各源吐出的
/// 标准读数汇聚进一个**有界、纯内存、不落盘**的滚动缓冲；驱动下游蒸馏成关键待办；并产出一段紧凑的
/// `situationContribution()` —— 这就是各感知"集中成的一套标准输入"，由 `LingShuSituationContext`
/// 与视觉/听觉一起喂给大模型综合评判。
///
/// 边界：本中枢只**供给事实 + 维护开关/状态**，绝不替大模型决定"该不该提醒/怎么处理"。
/// 隐私 [[perception-data-zero-retention]]：默认全关；读数只在内存、关闭即清空；通知正文不落盘。
@MainActor
final class LingShuExternalSensoryHub: ObservableObject {
    /// 主开关（默认关）。关闭即停所有源、清空缓冲。
    @Published private(set) var masterEnabled = false
    /// 各源最新状态（UI 列表）。
    @Published private(set) var statuses: [String: LingShuExternalSensoryStatus] = [:]
    /// 当前启用的源 ID 集合。
    @Published private(set) var enabledSourceIDs: Set<String> = []
    /// 最近读数（有界，纯内存，最新在前）。
    @Published private(set) var recentReadings: [LingShuExternalSensoryReading] = []
    /// 蒸馏出的关键待办（暴露给 UI + 注入大脑）。
    @Published private(set) var phoneTodos: [LingShuPhoneTodo] = []
    /// 最近一次蒸馏失败/状态说明（UI 可解释）。
    @Published private(set) var lastNote = ""
    /// 待弹出的警告(如蓝牙不可用→自动关闭后告知用户)。UI 用 `.alert(item:)` 消费,展示后置 nil。
    @Published var warning: LingShuExternalSensoryWarning?

    /// 注入的模型驱动蒸馏器（由 State 设置；nil 时用纯启发式兜底）。
    var todoDistiller: (@MainActor @Sendable ([LingShuExternalSensoryReading]) async -> [LingShuPhoneTodo])?

    private let sources: [String: any LingShuExternalSensorySource]
    private let descriptors: [LingShuExternalSensoryDescriptor]
    private var consumers: [String: Task<Void, Never>] = [:]
    private var distillTask: Task<Void, Never>?
    private let maxReadings: Int
    private let masterDefaultsKey = "lingshu.externalSensory.enabled"
    private let enabledDefaultsKey = "lingshu.externalSensory.enabledSources"

    init(sources: [any LingShuExternalSensorySource], maxReadings: Int = 200) {
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.descriptor.id, $0) })
        self.descriptors = sources.map(\.descriptor)
        self.maxReadings = maxReadings
        for descriptor in descriptors {
            statuses[descriptor.id] = .disabled
        }
    }

    /// 默认装配：iPhone 通知桥（ANCS）+ 日历提醒（EventKit）。未来加模块只在这里 append。
    static func makeDefault() -> LingShuExternalSensoryHub {
        LingShuExternalSensoryHub(sources: [
            LingShuANCSSensorySource(),
            LingShuEventKitSensorySource()
        ])
    }

    var availableSources: [LingShuExternalSensoryDescriptor] { descriptors }

    /// 设置对外广播的蓝牙名(i18n:中文「灵枢」/ 英文「Nous」)。转发给所有蓝牙类源。
    func setBluetoothLocalName(_ name: String) {
        for source in sources.values {
            (source as? LingShuANCSSensorySource)?.updateAdvertisedName(name)
        }
    }

    func status(for sourceID: String) -> LingShuExternalSensoryStatus {
        statuses[sourceID] ?? .disabled
    }

    func isEnabled(_ sourceID: String) -> Bool { enabledSourceIDs.contains(sourceID) }

    // MARK: - 开关（无缝切换）

    /// 应用持久化的偏好（启动时调一次）：主开关 + 上次启用的源。
    func restorePersistedPreferences() {
        guard UserDefaults.standard.bool(forKey: masterDefaultsKey) else { return }
        let saved = Set(UserDefaults.standard.stringArray(forKey: enabledDefaultsKey) ?? [])
        setMasterEnabled(true)
        for id in saved where sources[id] != nil { enableSource(id) }
    }

    func setMasterEnabled(_ enabled: Bool) {
        guard enabled != masterEnabled else { return }
        masterEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: masterDefaultsKey)
        if !enabled {
            for id in enabledSourceIDs { stopConsumer(id) }
            enabledSourceIDs.removeAll()
            recentReadings.removeAll()   // 关闭即清空内存（隐私）
            phoneTodos.removeAll()
            for descriptor in descriptors { statuses[descriptor.id] = .disabled }
            persistEnabled()
        }
    }

    func toggleSource(_ sourceID: String) {
        if enabledSourceIDs.contains(sourceID) { disableSource(sourceID) } else { enableSource(sourceID) }
    }

    func enableSource(_ sourceID: String) {
        guard let source = sources[sourceID], !enabledSourceIDs.contains(sourceID) else { return }
        if !masterEnabled { setMasterEnabled(true) }
        enabledSourceIDs.insert(sourceID)
        persistEnabled()
        let stream = source.activate()
        consumers[sourceID] = Task { [weak self] in
            for await signal in stream {
                guard let self else { return }
                await self.handle(signal, from: sourceID)
            }
        }
    }

    /// 重试:停掉再起这条源的线程,重新扫描/连接(用户在 UI 点「重试扫描」)。
    func retrySource(_ sourceID: String) {
        guard let source = sources[sourceID] else { return }
        guard enabledSourceIDs.contains(sourceID) else { enableSource(sourceID); return }
        stopConsumer(sourceID)
        statuses[sourceID] = .connecting
        let stream = source.activate()
        consumers[sourceID] = Task { [weak self] in
            for await signal in stream {
                guard let self else { return }
                await self.handle(signal, from: sourceID)
            }
        }
    }

    func disableSource(_ sourceID: String) {
        guard enabledSourceIDs.contains(sourceID) else { return }
        sources[sourceID]?.deactivate()
        stopConsumer(sourceID)
        enabledSourceIDs.remove(sourceID)
        statuses[sourceID] = .disabled
        // 清掉该源贡献的内存读数。
        recentReadings.removeAll { $0.sourceID == sourceID }
        persistEnabled()
        scheduleDistill()
    }

    private func stopConsumer(_ sourceID: String) {
        consumers[sourceID]?.cancel()
        consumers[sourceID] = nil
        sources[sourceID]?.deactivate()
    }

    private func persistEnabled() {
        UserDefaults.standard.set(Array(enabledSourceIDs), forKey: enabledDefaultsKey)
    }

    // MARK: - 汇聚

    private func handle(_ signal: LingShuExternalSensorySignal, from sourceID: String) {
        switch signal {
        case .status(let status):
            statuses[sourceID] = status
        case .reading(let reading):
            ingest(reading)
        case .notification:
            // 原始通知已在源侧映射为 reading 发出；此处保留扩展点（下游若需原始结构可用）。
            break
        case .fatal(let reason):
            // 依赖能力不可用(如蓝牙关/未授权):弹警告 + 自动关闭本源(开关回到关)。
            let name = sources[sourceID]?.descriptor.displayName ?? "外接设备"
            warning = LingShuExternalSensoryWarning(title: "「\(name)」无法启用", message: reason)
            disableSource(sourceID)
            statuses[sourceID] = .unavailable(reason)
        }
    }

    private func ingest(_ reading: LingShuExternalSensoryReading) {
        recentReadings.insert(reading, at: 0)
        if recentReadings.count > maxReadings {
            recentReadings.removeLast(recentReadings.count - maxReadings)
        }
        scheduleDistill()
    }

    /// 去抖蒸馏：连发读数时不每条都跑模型，攒 1.5s 再蒸馏一次。
    private func scheduleDistill() {
        distillTask?.cancel()
        let snapshot = recentReadings
        distillTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.runDistill(snapshot)
        }
    }

    private func runDistill(_ readings: [LingShuExternalSensoryReading]) async {
        guard !readings.isEmpty else { phoneTodos = []; return }
        if let distiller = todoDistiller {
            let result = await distiller(readings)
            guard !Task.isCancelled else { return }
            phoneTodos = result.isEmpty ? LingShuPhoneTodoDistiller.heuristicDistill(readings) : result
            lastNote = result.isEmpty ? "大脑未蒸馏出待办，按规则兜底" : "已由大脑蒸馏 \(result.count) 条待办"
        } else {
            phoneTodos = LingShuPhoneTodoDistiller.heuristicDistill(readings)
            lastNote = "规则蒸馏 \(phoneTodos.count) 条待办"
        }
    }

    // MARK: - 标准输入贡献（汇聚成给大模型的一句）

    /// 是否有可注入大脑的有效感知（无则别浪费 token）。
    var hasLiveSignals: Bool { masterEnabled && (!phoneTodos.isEmpty || !recentReadings.isEmpty) }

    /// 汇聚成的"一套标准输入"摘要：交给 `LingShuSituationContext` 与视觉/听觉并列注入大脑。
    func situationContribution() -> String? {
        guard hasLiveSignals else { return nil }
        if let todoSummary = LingShuPhoneTodoDistiller.situationSummary(todos: phoneTodos) {
            return todoSummary
        }
        let recent = recentReadings.prefix(3).map { "・\($0.headline)" }.joined(separator: "\n")
        return recent.isEmpty ? nil : "外接设备感知 · 近期信号：\n\(recent)"
    }

    /// 测试/调试注入读数（不经真设备）。
    func ingestForTesting(_ reading: LingShuExternalSensoryReading) { ingest(reading) }
}
