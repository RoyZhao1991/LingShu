import Foundation

enum LingShuCapabilityRole: String, CaseIterable, Equatable {
    case planning = "规划"
    case review = "审议"
    case dispatch = "调度"
    case design = "设计"
    case execution = "执行"
    case monitoring = "监控"
    case verification = "验证"
    case memory = "记忆"
    case safety = "安全"
    case knowledge = "知识"
    case routing = "路由"

    var defaultMode: AgentRuntimeMode {
        switch self {
        case .planning, .memory, .knowledge, .routing:
            return .planning
        case .review, .verification, .safety:
            return .verifying
        case .dispatch, .design, .execution:
            return .working
        case .monitoring:
            return .supervising
        }
    }

    var defaultCadence: String {
        switch self {
        case .design, .execution, .review, .monitoring, .safety:
            return "实时"
        case .verification:
            return "提交后"
        default:
            return "本轮"
        }
    }

    var description: String {
        switch self {
        case .planning:
            return "理解目标、形成任务草案、执行计划和能力分派建议"
        case .review:
            return "审核风险、事实、权限和边界，必要时封驳"
        case .dispatch:
            return "把已批准计划分配给内部或外部能力节点并汇总结果"
        case .design:
            return "把需求转为叙事结构、视觉方案、版式规范和 PPT/演示交付物"
        case .execution:
            return "在授权范围内产出代码、文档、动作或工具结果"
        case .monitoring:
            return "跟踪心跳、进度、偏差、资源和运行状态"
        case .verification:
            return "检查产物、验证结果、回归风险和验收证据"
        case .memory:
            return "检索主线程记忆、执行记忆和冷备摘要"
        case .safety:
            return "审查权限、合规、数据和高风险操作"
        case .knowledge:
            return "检索、整理、引用和沉淀知识库内容"
        case .routing:
            return "发现 agent、路由消息、同步状态和回传产物"
        }
    }

    static var promptChoiceList: String {
        allCases.map(\.rawValue).joined(separator: "|")
    }

    static var orderedNames: [String] {
        allCases.map(\.rawValue)
    }

    static var promptCatalog: String {
        allCases.map { "- \($0.rawValue)：\($0.description)" }.joined(separator: "\n")
    }

    static func normalize(_ rawName: String) -> LingShuCapabilityRole? {
        let raw = rawName
            .replacingOccurrences(of: "智能体", with: "")
            .replacingOccurrences(of: "专家", with: "")
            .replacingOccurrences(of: "Agent", with: "")
            .replacingOccurrences(of: "agent", with: "")
            .replacingOccurrences(of: "节点", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if raw.isEmpty { return nil }

        if let exact = allCases.first(where: { $0.rawValue.lowercased() == raw }) {
            return exact
        }

        let aliases: [(LingShuCapabilityRole, [String])] = [
            (.review, ["审议", "审核", "审查", "风险", "合规", "封驳"]),
            (.planning, ["规划", "计划", "草案", "需求", "目标", "业务", "项目", "推进", "里程碑", "架构", "技术方案", "方案"]),
            (.dispatch, ["调度", "分派", "编排", "派发", "协调", "落地"]),
            (.design, ["设计", "设计部", "设计交付", "ppt", "幻灯片", "演示文稿", "演示页", "汇报材料", "汇报页", "deck", "presentation", "slide", "版式", "排版", "视觉方案", "视觉设计", "美化"]),
            (.execution, ["执行", "开发", "实现", "代码", "脚本", "函数", "程序", "爬虫", "demo", "补丁", "集成", "工具"]),
            (.monitoring, ["监控", "监工", "巡检", "心跳", "进度", "运维", "部署", "运行", "稳定"]),
            (.verification, ["验证", "测试", "验收", "质量", "回归", "review", "检查"]),
            (.memory, ["记忆", "历史", "线程", "冷备", "恢复", "上下文"]),
            (.safety, ["安全", "权限", "高风险", "越权", "隐私"]),
            (.knowledge, ["知识", "资料", "检索", "研究", "引用", "文档"]),
            (.routing, ["路由", "发现", "协议", "a2a", "mcp", "外部"])
        ]

        return aliases.first { _, words in
            words.contains { raw.contains($0) }
        }?.0
    }

    static func orderIndex(for name: String) -> Int {
        guard let role = normalize(name),
              let index = allCases.firstIndex(of: role) else {
            return allCases.count
        }
        return index
    }
}
