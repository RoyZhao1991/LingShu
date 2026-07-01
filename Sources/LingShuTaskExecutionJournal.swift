import Foundation

enum LingShuTaskExecutionStatus: String, Codable, Equatable, Sendable {
    case queued = "排队中"
    case running = "执行中"
    case answered = "已直接回答"
    case dispatched = "已分派"
    case completed = "已完成"
    case needsRevision = "未达标"
    case blocked = "异常"
    /// 网络/网关中断导致暂停——**非失败**,会话上下文保留,联网后自动续跑。
    case suspended = "已暂停"

    // 通用中枢 P2 真闭环·新增状态(additive,影响执行流/汇总/续接,不只是 UI 装饰)。
    case analyzing = "分析中"             // 前置认知(目标/需求/缺口)进行中
    case acquiringCapability = "补齐能力中" // 正在主动获取缺失能力(连MCP/自写组件/找技能/浏览器)
    case waitingForUser = "待用户"        // 需用户提供前提(凭据/授权/付费/物理)才能继续
    case ready = "就绪"                   // 能力齐备、可执行
    case partial = "部分完成"             // 复合任务部分成、部分未成
    case verified = "已核验"              // 完成且按成功标准核验通过
    case failed = "失败"                  // 真尝试后仍无法完成

    /// 终态(不再自动推进):完成/直答/核验/未达标/失败/部分;阻断与待用户是**可续**的中间停。
    var isTerminal: Bool {
        switch self {
        case .completed, .answered, .verified, .needsRevision, .failed, .partial: return true
        default: return false
        }
    }

    /// 可被「继续」优先恢复的未竟态(spec 第14条:续接优先恢复 blocked/partial/needsRevision/waitingForUser)。
    /// **needsRevision(未达标·评审未通过已交还)同样可续**:「需修正后重验」就是要返工再来,理应能被「继续」恢复(与原 .partial 等价)。
    var isResumableUnfinished: Bool {
        switch self {
        case .blocked, .partial, .needsRevision, .waitingForUser, .suspended, .acquiringCapability: return true
        default: return false
        }
    }
}

enum LingShuTaskExecutionMessageKind: String, Codable, Equatable, Sendable {
    case user
    case core
    case memory
    case router
    case agent
    case model
    case review
    case result
    case warning
}

/// 一条执行消息的**结构化载荷**(对齐 codex 窗口:工具调用/命令输出/文件 diff 渲染成卡片,而非裸文本)。
/// 可空——旧持久化记录无此字段,synthesized Codable 对 Optional 走 decodeIfPresent → nil(向后兼容)。
enum LingShuTaskExecutionDetail: Codable, Equatable, Sendable {
    /// 工具/命令调用:工具名 + 一句话摘要 + 完整参数(供卡片展开)。
    case toolCall(tool: String, summary: String, arguments: String)
    /// 工具/命令结果:工具名 + 成功与否 + 输出(供卡片折叠/展开)。
    case toolResult(tool: String, success: Bool, output: String)
    /// 文件改动:路径 + 新增/修改 + 增删行数 + 统一 diff 文本(供 diff 卡片彩色展开 + 撤销)。
    case fileEdit(path: String, operation: LingShuArtifactOperation, added: Int, removed: Int, diff: String)
}

/// 执行计划的一步(对齐 codex/LOOP 标准:先列计划清单,再逐步执行并更新状态)。
struct LingShuPlanStep: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Equatable, Sendable {
        case pending = "待办"
        case inProgress = "进行中"
        case completed = "已完成"
    }
    var id: String = UUID().uuidString
    var title: String
    var status: Status = .pending

    enum CodingKeys: String, CodingKey { case id, title, status }
    init(id: String = UUID().uuidString, title: String, status: Status = .pending) {
        self.id = id; self.title = title; self.status = status
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        status = (try? c.decode(Status.self, forKey: .status)) ?? .pending
    }
}

struct LingShuTaskExecutionMessage: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var timestamp: Date
    var actor: String
    var role: String
    var kind: LingShuTaskExecutionMessageKind
    var text: String
    /// codex 式渲染的结构化载荷;nil = 纯文本/状态消息,按 kind 渲染。
    var detail: LingShuTaskExecutionDetail?
    /// 文件改动是否已被用户撤销(仅 fileEdit detail 有意义)。
    var undone: Bool?

    init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String,
        detail: LingShuTaskExecutionDetail? = nil,
        undone: Bool? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actor = actor
        self.role = role
        self.kind = kind
        self.text = text
        self.detail = detail
        self.undone = undone
    }
}
// 行级 diff(LCS)已拆为独立模块 → Sources/Support/LingShuLineDiff.swift(纯算法,可单测)。

/// 产出物的文件操作类型(对齐 codex 的「新增/修改」区分)。
enum LingShuArtifactOperation: String, Codable, Equatable, Sendable {
    case created = "新增"
    case modified = "修改"
}

struct LingShuTaskExecutionArtifact: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var location: String
    var producer: String
    var createdAt: Date
    /// 文件操作:新增 or 修改。可空——旧持久化记录无此字段,解码时缺省为 nil(展示按"新增"处理)。
    var operation: LingShuArtifactOperation?

    init(
        id: String = UUID().uuidString,
        title: String,
        location: String,
        producer: String,
        createdAt: Date = Date(),
        operation: LingShuArtifactOperation? = nil
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.producer = producer
        self.createdAt = createdAt
        self.operation = operation
    }
}

/// 代码交付任务的代码改动概览(右侧面板展示)——分支 + **未提交**改动文件;已提交的不统计(porcelain 本就只列未提交)。
struct LingShuCodeChangeSummary: Codable, Equatable, Sendable {
    var repoName: String
    var branch: String
    var files: [Change]
    /// 仓库工作树根的绝对路径——供「审查」面板就地跑 `git diff` 拉真实 hunk(可选:旧记录解码缺省为 nil)。
    var repoWorkingDir: String?

    struct Change: Codable, Equatable, Sendable, Identifiable {
        var id: String { path }
        var status: String   // git porcelain 码:M=改 / A=增 / D=删 / ??=未跟踪 …
        var path: String

        /// 友好中文标签。
        var label: String {
            switch status.trimmingCharacters(in: .whitespaces).uppercased() {
            case "M", "MM", "RM": return "修改"
            case "A", "AM": return "新增"
            case "D": return "删除"
            case "R": return "重命名"
            case "??": return "未跟踪"
            default: return status
            }
        }
    }
}

struct LingShuTaskExecutionRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var prompt: String
    var status: LingShuTaskExecutionStatus
    var summary: String
    var participants: [String]
    var relatedRecordIDs: [String]
    var createdAt: Date
    var updatedAt: Date
    var messages: [LingShuTaskExecutionMessage]
    var artifacts: [LingShuTaskExecutionArtifact]
    /// 执行计划清单(LOOP 标准:先 plan 再逐步执行)。模型经 update_plan 维护,在窗口顶部渲染为 todo。
    var plan: [LingShuPlanStep]
    /// 设计质量分(0–1,PPT 等视觉交付物的过程内审计/最终验收打分)。nil=未评。供 dreaming 进化 DesignKB。
    var designScore: Double?
    /// 设计审计抓到的**失败点/待改进项**(低分页问题)。供 dreaming 从"失败"里学经验。
    var designIssues: [String]
    /// 代码交付任务的代码改动概览(分支 + 未提交文件)。nil=非代码任务/工作目录非 git 仓/无未提交改动。
    var codeChanges: LingShuCodeChangeSummary?

    /// 通用中枢 P1·**结构化目标规格**(typed,随记录持久化跨重启)。入口派生后绑定;
    /// `driveAgentDelivery` 注入执行引导、`verifyAgentDeliverable` 引用成功标准都读它(重启后链路仍拿得到 typed 值)。
    var goalSpec: LingShuGoalSpec?

    /// 通用中枢 P2·**能力缺口分析**(typed,持久化)。执行前评估"能不能做成/缺什么/怎么补",注入执行引导让大脑先补齐再推进。
    var gapAnalysis: LingShuGapAnalysis?

    /// 通用中枢 P3·**验收检查项(成功标准分类后)**(typed,持久化)。验收时惰性分类一次后缓存,避免返工循环重复分类。
    var acceptanceChecks: [LingShuAcceptanceCheck]?

    /// 通用中枢 P3·**全类型验收报告**(typed,持久化)。逐条成功标准的确定性裁决结果,供用户验收时核对。
    var acceptanceReport: LingShuAcceptanceReport?

    /// 通用中枢 P2 真闭环·**能力需求**(typed,持久化)。从 GoalSpec 推导的通用能力需求,查能力图谱判命中/缺口。
    var capabilityRequirements: [LingShuCapabilityRequirement]?

    /// 通用中枢 P2 真闭环·**能力获取尝试**(typed,持久化)。缺口补齐过程:走了哪些路径、成败、最小验证结果,供记忆复用 + 审计。
    var acquisitionAttempts: [LingShuAcquisitionAttempt]?

    /// 通用中枢·能力主动探测观察(typed,持久化)。能力图谱未命中时,探测器会留下发现/置信度/证据,
    /// 后续可转为已验证能力或继续请求授权/驱动。
    var capabilityProbeObservations: [LingShuCapabilityProbeObservation]?

    /// 通用中枢 P2 真闭环·**完成闸裁决**(typed,持久化)。防伪完成的最终结论(ok/partial/waitingForUser/blocked/needsAcquisition)。
    var taskOutcome: LingShuCompletionStatus?

    /// 通用中枢·真实效果验收报告(typed,持久化)。P3 成功标准裁决后,进一步沉淀成可展示/可追溯的现实效果证据链。
    var effectVerificationReport: LingShuEffectVerificationReport?

    /// 一句话**总目标**(模型经 `update_plan` 蒸馏的高度概括,如"构建一个清分结算系统";**不是复述需求**)。
    /// 三级信息架构第 1 级(右侧规划):总目标 → 分步计划(`plan`,抽象里程碑)→ 具体实现(左侧执行对话)。
    /// 空=模型未给(回退用 title)。
    var goal: String = ""

    /// 开发任务判定 → 仅决定任务窗口右侧是否显示「Git 工具」段。
    /// **严格成立条件:已捕获的 git 改动里含真·源码文件**(收尾后 `captureCodeChanges` 扫描)。
    /// 关键:`.md`/文档/`.pptx` 等**非源码**即便在 git 仓里被改、被 `captureCodeChanges` 收进 codeChanges,
    /// 也**不算**开发任务——"读代码写架构总结/PPT"这类非代码流程**绝不出现 Git 工具**(用户反馈 2026-06-15)。
    /// 不再用"codeChanges 非空"或"产出/编辑过源码扩展名"等宽松信号(会把改 .md 的文档任务误判为开发)。
    var isDevelopmentTask: Bool {
        guard let code = codeChanges else { return false }
        return code.files.contains { Self.isSourceCodePath($0.path) }
    }

    /// 真·源码/标记/样式扩展名(紧凑白名单,不含 json/yaml 等配置——避免把 PPT 的 slides.json 误判为开发)。
    static let sourceCodeExtensions: Set<String> = [
        "swift", "py", "js", "mjs", "cjs", "ts", "tsx", "jsx", "go", "rs", "java", "kt",
        "c", "cpp", "cc", "cxx", "h", "hpp", "m", "mm", "rb", "php", "cs", "sh", "bash",
        "sql", "html", "htm", "css", "scss", "less", "vue", "svelte", "gradle"
    ]

    static func isSourceCodePath(_ path: String) -> Bool {
        sourceCodeExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case prompt
        case status
        case summary
        case participants
        case relatedRecordIDs
        case createdAt
        case updatedAt
        case messages
        case artifacts
        case plan
        case designScore
        case designIssues
        case codeChanges
        case goal
        case goalSpec
        case gapAnalysis
        case acceptanceChecks
        case acceptanceReport
        case capabilityRequirements
        case acquisitionAttempts
        case capabilityProbeObservations
        case taskOutcome
        case effectVerificationReport
    }

    init(
        id: String,
        title: String,
        prompt: String,
        status: LingShuTaskExecutionStatus,
        summary: String,
        participants: [String],
        relatedRecordIDs: [String] = [],
        createdAt: Date,
        updatedAt: Date,
        messages: [LingShuTaskExecutionMessage],
        artifacts: [LingShuTaskExecutionArtifact] = [],
        plan: [LingShuPlanStep] = [],
        designScore: Double? = nil,
        designIssues: [String] = [],
        codeChanges: LingShuCodeChangeSummary? = nil,
        goal: String = "",
        goalSpec: LingShuGoalSpec? = nil,
        gapAnalysis: LingShuGapAnalysis? = nil,
        acceptanceChecks: [LingShuAcceptanceCheck]? = nil,
        acceptanceReport: LingShuAcceptanceReport? = nil,
        capabilityRequirements: [LingShuCapabilityRequirement]? = nil,
        acquisitionAttempts: [LingShuAcquisitionAttempt]? = nil,
        capabilityProbeObservations: [LingShuCapabilityProbeObservation]? = nil,
        taskOutcome: LingShuCompletionStatus? = nil,
        effectVerificationReport: LingShuEffectVerificationReport? = nil
    ) {
        self.id = id
        self.goal = goal
        self.goalSpec = goalSpec
        self.gapAnalysis = gapAnalysis
        self.acceptanceChecks = acceptanceChecks
        self.acceptanceReport = acceptanceReport
        self.capabilityRequirements = capabilityRequirements
        self.acquisitionAttempts = acquisitionAttempts
        self.capabilityProbeObservations = capabilityProbeObservations
        self.taskOutcome = taskOutcome
        self.effectVerificationReport = effectVerificationReport
        self.title = title
        self.prompt = prompt
        self.status = status
        self.summary = summary
        self.participants = participants
        self.relatedRecordIDs = relatedRecordIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.artifacts = artifacts
        self.plan = plan
        self.designScore = designScore
        self.designIssues = designIssues
        self.codeChanges = codeChanges
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        prompt = try container.decode(String.self, forKey: .prompt)
        status = try container.decode(LingShuTaskExecutionStatus.self, forKey: .status)
        summary = try container.decode(String.self, forKey: .summary)
        participants = try container.decode([String].self, forKey: .participants)
        relatedRecordIDs = try container.decodeIfPresent([String].self, forKey: .relatedRecordIDs) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        messages = try container.decode([LingShuTaskExecutionMessage].self, forKey: .messages)
        artifacts = try container.decodeIfPresent([LingShuTaskExecutionArtifact].self, forKey: .artifacts) ?? []
        plan = try container.decodeIfPresent([LingShuPlanStep].self, forKey: .plan) ?? []
        designScore = try container.decodeIfPresent(Double.self, forKey: .designScore)
        designIssues = try container.decodeIfPresent([String].self, forKey: .designIssues) ?? []
        codeChanges = try container.decodeIfPresent(LingShuCodeChangeSummary.self, forKey: .codeChanges)
        goal = try container.decodeIfPresent(String.self, forKey: .goal) ?? ""
        goalSpec = try container.decodeIfPresent(LingShuGoalSpec.self, forKey: .goalSpec)
        gapAnalysis = try container.decodeIfPresent(LingShuGapAnalysis.self, forKey: .gapAnalysis)
        acceptanceChecks = try container.decodeIfPresent([LingShuAcceptanceCheck].self, forKey: .acceptanceChecks)
        acceptanceReport = try container.decodeIfPresent(LingShuAcceptanceReport.self, forKey: .acceptanceReport)
        capabilityRequirements = try container.decodeIfPresent([LingShuCapabilityRequirement].self, forKey: .capabilityRequirements)
        acquisitionAttempts = try container.decodeIfPresent([LingShuAcquisitionAttempt].self, forKey: .acquisitionAttempts)
        capabilityProbeObservations = try container.decodeIfPresent([LingShuCapabilityProbeObservation].self, forKey: .capabilityProbeObservations)
        taskOutcome = try container.decodeIfPresent(LingShuCompletionStatus.self, forKey: .taskOutcome)
        effectVerificationReport = try container.decodeIfPresent(LingShuEffectVerificationReport.self, forKey: .effectVerificationReport)
    }

    static func create(prompt: String, now: Date = Date()) -> LingShuTaskExecutionRecord {
        let title = Self.shortTitle(from: prompt)
        return .init(
            id: "task-record-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))",
            title: title,
            prompt: prompt,
            status: .running,
            summary: "灵枢正在判断本轮任务。",
            participants: ["你", "灵枢"],
            relatedRecordIDs: [],
            createdAt: now,
            updatedAt: now,
            messages: [
                .init(timestamp: now, actor: "你", role: "需求方", kind: .user, text: prompt),
                .init(timestamp: now, actor: "灵枢", role: "中枢", kind: .core, text: "收到。我先判断这件事由我直接回答，还是需要调度能力节点。")
            ]
        )
    }

    mutating func append(
        actor: String,
        role: String,
        kind: LingShuTaskExecutionMessageKind,
        text: String,
        detail: LingShuTaskExecutionDetail? = nil,
        now: Date = Date()
    ) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 结构化卡片(detail)即使文本为空也要保留(diff/输出在 detail 里);纯文本消息空了才跳过。
        guard !cleaned.isEmpty || detail != nil else { return }

        if detail == nil,
           messages.last?.actor == actor,
           messages.last?.kind == kind,
           messages.last?.text == cleaned {
            return
        }

        messages.append(.init(timestamp: now, actor: actor, role: role, kind: kind, text: cleaned, detail: detail))
        if !participants.contains(actor) {
            participants.append(actor)
        }
        if messages.count > 140 {
            messages.removeFirst(messages.count - 140)
        }
        updatedAt = now
    }

    mutating func appendArtifact(
        title: String,
        location: String,
        producer: String,
        operation: LingShuArtifactOperation? = nil,
        now: Date = Date()
    ) {
        let cleanedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedLocation.isEmpty else { return }

        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 已登记过同一文件:若这次是"修改"而之前记的是"新增",升级标注为修改(同回合多次写同一文件)。
        if let index = artifacts.firstIndex(where: { $0.location == cleanedLocation }) {
            if operation == .modified, artifacts[index].operation != .modified {
                artifacts[index].operation = .modified
                updatedAt = now
            }
            return
        }

        artifacts.append(.init(
            title: cleanedTitle.isEmpty ? "未命名产出物" : cleanedTitle,
            location: cleanedLocation,
            producer: producer,
            createdAt: now,
            operation: operation
        ))
        updatedAt = now
    }

    mutating func linkRelatedRecord(_ recordID: String, now: Date = Date()) {
        let cleaned = recordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != id, !relatedRecordIDs.contains(cleaned) else { return }
        relatedRecordIDs.append(cleaned)
        updatedAt = now
    }

    mutating func applyRoute(needsAgents: Bool, agents: [String], summary: String, now: Date = Date()) {
        status = needsAgents ? .dispatched : .answered
        self.summary = summary.isEmpty ? (needsAgents ? "本轮已完成能力分派。" : "本轮由灵枢直接回答。") : summary
        participants = Array(Set(participants + agents)).sorted { left, right in
            if left == "你" { return true }
            if right == "你" { return false }
            if left == "灵枢" { return true }
            if right == "灵枢" { return false }
            return left < right
        }
        updatedAt = now
    }

    mutating func finish(status: LingShuTaskExecutionStatus, summary: String, now: Date = Date()) {
        self.status = status
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? self.summary : summary
        updatedAt = now
    }

    private static func shortTitle(from prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 24 else { return trimmed.isEmpty ? "未命名任务" : trimmed }
        return "\(trimmed.prefix(24))..."
    }
}

/// 任务执行日志。写入串行化在 `ioQueue` 上异步完成，调用方不等待编码与落盘；
/// 读取同步穿过同一队列，保证读后写一致。归档记录在内存中缓存，
/// 避免每次保存都重新解码全部归档。
final class LingShuTaskExecutionJournal: @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let archiveStorageKey: String
    private let maxRecords: Int
    private let maxArchivedRecords: Int
    /// 热数据时间窗:最近一个月(参考上下文冷备策略——按时间分热/冷,而不是单纯靠条数)。
    private let hotRetention: TimeInterval
    private let ioQueue = DispatchQueue(label: "lingshu.task-journal.io", qos: .utility)
    private var cachedArchivedRecords: [LingShuTaskExecutionRecord]?

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "lingshu.task-execution.records",
        archiveStorageKey: String = "lingshu.task-execution.records.archive",
        maxRecords: Int = 300,
        maxArchivedRecords: Int = 1000,
        hotRetention: TimeInterval = 30 * 24 * 3600
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.archiveStorageKey = archiveStorageKey
        self.maxRecords = maxRecords
        self.maxArchivedRecords = maxArchivedRecords
        self.hotRetention = hotRetention
    }

    func loadRecords() -> [LingShuTaskExecutionRecord] {
        ioQueue.sync {
            guard let data = defaults.data(forKey: storageKey),
                  let records = try? JSONDecoder().decode([LingShuTaskExecutionRecord].self, from: data) else {
                return []
            }
            return records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxRecords).map { $0 }
        }
    }

    func loadArchivedRecords() -> [LingShuTaskExecutionRecord] {
        ioQueue.sync {
            loadArchivedRecordsCached()
        }
    }

    /// 归一化并保存记录。返回值即保存后的（活跃, 归档）两组数据，
    /// 调用方应直接采用返回值，而不是保存后再从磁盘读回。
    @discardableResult
    func saveRecords(_ records: [LingShuTaskExecutionRecord]) -> (active: [LingShuTaskExecutionRecord], archived: [LingShuTaskExecutionRecord]) {
        ioQueue.sync {
            let sorted = unique(records).sorted { $0.updatedAt > $1.updatedAt }
            // 热 = 最近一个月内的(再设条数上限防爆);超一个月或超上限的转冷备。参考上下文冷备策略。
            let cutoff = Date().addingTimeInterval(-hotRetention)
            let retained = Array(sorted.filter { $0.updatedAt >= cutoff }.prefix(maxRecords))
            let retainedIDs = Set(retained.map(\.id))
            let overflow = sorted.filter { !retainedIDs.contains($0.id) }
            let archived = unique(Array(overflow) + loadArchivedRecordsCached())
                .filter { !retainedIDs.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(maxArchivedRecords)
                .map { $0 }
            cachedArchivedRecords = archived

            ioQueue.async {
                if let data = try? JSONEncoder().encode(retained) {
                    self.defaults.set(data, forKey: self.storageKey)
                }
                if let archiveData = try? JSONEncoder().encode(archived) {
                    self.defaults.set(archiveData, forKey: self.archiveStorageKey)
                }
            }

            return (retained, archived)
        }
    }

    /// 同步落盘队列中所有待写任务。退出前调用。
    func flush() {
        ioQueue.sync {}
    }

    /// 仅允许在 ioQueue 上调用。
    private func loadArchivedRecordsCached() -> [LingShuTaskExecutionRecord] {
        if let cachedArchivedRecords {
            return cachedArchivedRecords
        }
        guard let data = defaults.data(forKey: archiveStorageKey),
              let records = try? JSONDecoder().decode([LingShuTaskExecutionRecord].self, from: data) else {
            cachedArchivedRecords = []
            return []
        }
        let archived = records.sorted { $0.updatedAt > $1.updatedAt }.prefix(maxArchivedRecords).map { $0 }
        cachedArchivedRecords = archived
        return archived
    }

    func upsert(_ record: LingShuTaskExecutionRecord, into records: inout [LingShuTaskExecutionRecord]) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records = unique(records).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func unique(_ records: [LingShuTaskExecutionRecord]) -> [LingShuTaskExecutionRecord] {
        var seen = Set<String>()
        return records.filter { record in
            seen.insert(record.id).inserted
        }
    }
}
