import Foundation

/// 语义任务拆分(Layer ①)的数据模型。
///
/// 解决「一句话里含多个任务,可能相关也可能无关」:把整句拆成 N 个独立任务意图,
/// 相关的归同一分组(可进同线程),无关的分到不同组(各起线程)。每个意图带续接线索,
/// 供路由层(Layer ②)对历史记录做多匹配。
struct LingShuTaskSegmentIntent: Identifiable, Equatable, Sendable {
    let id: String
    /// 该任务的独立、自足指令文本(已从原句剥离出来)。
    var text: String
    /// 相关性分组键:同 group 视为相关任务,可并入同一线程顺序推进。
    var group: String
    /// 是真任务还是闲聊/寒暄片段。
    var isTask: Bool
    /// 可能续接的历史线索(如"昨天那个爬虫"),交给路由层做多匹配;nil 表示无续接线索。
    var resumeHint: String?

    init(
        id: String = "intent-\(UUID().uuidString.prefix(8))",
        text: String,
        group: String = "g1",
        isTask: Bool = true,
        resumeHint: String? = nil
    ) {
        self.id = id
        self.text = text
        self.group = group
        self.isTask = isTask
        self.resumeHint = resumeHint
    }
}

struct LingShuTaskSegmentation: Equatable, Sendable {
    var intents: [LingShuTaskSegmentIntent]
    /// 来源:heuristic(快路)或 model(模型驱动)。
    var source: String

    /// 真任务意图。
    var taskIntents: [LingShuTaskSegmentIntent] {
        intents.filter { $0.isTask }
    }

    /// 是否多任务(>1 个真任务意图)。
    var isMultiTask: Bool {
        taskIntents.count > 1
    }

    /// 相关性分组后的任务簇:每簇 = 一条可独立推进的线程的候选输入。
    var taskGroups: [[LingShuTaskSegmentIntent]] {
        var order: [String] = []
        var buckets: [String: [LingShuTaskSegmentIntent]] = [:]
        for intent in taskIntents {
            if buckets[intent.group] == nil { order.append(intent.group) }
            buckets[intent.group, default: []].append(intent)
        }
        return order.map { buckets[$0] ?? [] }
    }

    static func single(_ text: String, isTask: Bool, source: String) -> LingShuTaskSegmentation {
        .init(intents: [LingShuTaskSegmentIntent(text: text, group: "g1", isTask: isTask)], source: source)
    }
}
