import Foundation

/// 控制面模型调用角色:只负责"判断/分类/验收/收尾措辞"这类短思考。
/// 与任务执行面分离:控制面默认短 timeout + 单次尝试,防止目标解析/缺口分析卡住整条输入。
enum LingShuControlPlaneRole: String, Sendable {
    case triage = "分诊"
    case goalSpec = "目标认知"
    case gapAnalysis = "能力评估"
    case capabilityRequirement = "能力需求"
    case acceptancePlanner = "验收分类"
    case deliveryReview = "交付评审"
    case deliveryComposer = "交付播报"

    var timeoutSeconds: TimeInterval {
        switch self {
        case .triage: return 6
        case .goalSpec, .capabilityRequirement, .acceptancePlanner: return 8
        case .gapAnalysis: return 10
        // 验收要处理大产物正文 + VL 看图审版式,18s 对 40KB+ 的 HTML/代码太短(健康模型也被拖超时 → 误判通道故障)。
        // 抬到 90s(配合正文截断),既不超时也不空等。
        case .deliveryReview: return 90
        case .deliveryComposer: return 8
        }
    }

    var defaultSignals: LingShuBrainRoutingSignals {
        switch self {
        case .triage:
            return .init(kind: .question)
        case .goalSpec, .capabilityRequirement:
            return .init(kind: .task, criteriaCount: 1)
        case .gapAnalysis:
            return .init(kind: .task, criteriaCount: 1, hasBlockingGap: true)
        case .acceptancePlanner:
            return .init(kind: .task, criteriaCount: 2)
        case .deliveryReview:
            return .init(kind: .task, constraintCount: 2, criteriaCount: 3)
        case .deliveryComposer:
            return .init(kind: .interaction, criteriaCount: 1)
        }
    }
}

@MainActor
extension LingShuState {

    /// 控制面模型调用统一走当前启用主脑。
    /// 使用短 timeout + 单次尝试,避免控制面拖慢/卡死任务入口。
    /// `timeoutOverride`:某些控制面活儿延迟容忍不同(如**看图生成讲稿**要给多模态脑发整页图、远超分类器的 8s)——
    /// 演示前预生成讲稿不卡用户,给足超时;分类器仍用 role 自己的短超时(用户在飞等)。
    func controlPlaneModelAdapter(_ role: LingShuControlPlaneRole, taskRecordID: String? = nil, timeoutOverride: TimeInterval? = nil) -> LingShuGatewayAgentModel {
        _ = taskRecordID
        // 当前产品形态不支持多脑协同:所有控制面判断也统一走当前启用主脑。
        // role 只保留 timeout/profile 语义,不再触发强/中/弱脑切换。
        return makeAgentModelAdapter(timeout: timeoutOverride ?? role.timeoutSeconds, maxAttempts: 1)
    }
}
