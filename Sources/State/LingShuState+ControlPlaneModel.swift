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

    /// P5 补齐:控制面也走脑路由,不再直连当前单脑。
    /// 未配置多档模型时仍落回当前模型,但使用短 timeout + 单次尝试,避免控制面拖慢/卡死任务入口。
    func controlPlaneModelAdapter(_ role: LingShuControlPlaneRole, taskRecordID: String? = nil) -> LingShuGatewayAgentModel {
        let signals: LingShuBrainRoutingSignals
        if let taskRecordID {
            signals = brainRoutingSignals(taskRecordID: taskRecordID)
        } else {
            signals = role.defaultSignals
        }
        let tier = LingShuBrainRouter.route(signals, available: availableBrainTiers())
        return tierModelAdapter(tier, timeout: role.timeoutSeconds, maxAttempts: 1)
    }
}
