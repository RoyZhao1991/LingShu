import Foundation

/// 通用中枢 P2 真闭环·**防伪完成闸**(纯决策,可单测)。
///
/// 收尾路径上的确定性裁决:模型口头「完成」推不翻结构化事实。综合
/// ① 能力缺口(是否有**未解除的阻断缺口**、是否需用户、是否可自补)
/// ② 能力获取结果([[LingShuCapabilityAcquisition]])
/// ③ 模型是否通过结构化 completion 字段声明未完成 / 待用户 / 部分完成
/// ④ 成功标准达成情况(P3 [[LingShuAcceptance]]:部分达成→partial)
/// 判最终状态:有未解除阻断缺口/结构化未完成/部分达成 → **禁止当成功收尾**;
/// 自补未试→驱动去获取(needsAcquisition);需用户→waitingForUser;部分→partial;尝试了仍卡→blocked。
/// 无任何问题 → `ok`(交还既有验收/收尾流程,不越权强判 verified)。**零领域关键词**(无 if Notion / if PPT)。
enum LingShuCompletionStatus: String, Codable, Sendable, Equatable {
    case ok               // 无缺口、无结构化未完成声明、成功标准未见部分缺失 → 既有流程正常收尾
    case needsAcquisition // 有可自补的阻断缺口且还没尝试 → 应驱动去获取(返工)
    case waitingForUser   // 需用户提供前提(凭据/授权/付费/物理)才能继续
    case partial          // 部分完成(复合任务有的成有的没成)
    case blocked          // 真尝试了仍卡住,无法完成(诚实交还,**非伪完成**)
}

struct LingShuCompletionDecision: Sendable, Equatable {
    var status: LingShuCompletionStatus
    var reason: String
}

struct LingShuCompletionInputs: Sendable, Equatable {
    var hasUnresolvedBlockingGap: Bool      // 有 blocking 且未 resolved 的缺口
    var unresolvedGapNeedsUser: Bool        // 未解除缺口里含需用户类(凭据/授权/付费/物理)
    var unresolvedGapSelfAcquirable: Bool   // 未解除缺口里含可灵枢自补的
    var acquisition: LingShuAcquisitionOutcome
    var modelDeclaredBlocked: Bool          // 模型通过结构化 completion.status 声明未完成/阻断
    var modelDeclaredNeedsUser: Bool        // 模型通过结构化 completion 字段声明需要用户参与
    var modelDeclaredPartial: Bool          // 模型通过结构化 completion.status 声明部分完成
    var someSuccessCriteriaMet: Bool        // 至少一条成功标准确定性达成(P3 met)
    var someSuccessCriteriaUnmet: Bool      // 至少一条成功标准确定性未达成(P3 unmet)

    init(hasUnresolvedBlockingGap: Bool = false,
         unresolvedGapNeedsUser: Bool = false,
         unresolvedGapSelfAcquirable: Bool = false,
         acquisition: LingShuAcquisitionOutcome = .notAttempted,
         modelDeclaredBlocked: Bool = false,
         modelDeclaredNeedsUser: Bool = false,
         modelDeclaredPartial: Bool = false,
         someSuccessCriteriaMet: Bool = false,
         someSuccessCriteriaUnmet: Bool = false) {
        self.hasUnresolvedBlockingGap = hasUnresolvedBlockingGap
        self.unresolvedGapNeedsUser = unresolvedGapNeedsUser
        self.unresolvedGapSelfAcquirable = unresolvedGapSelfAcquirable
        self.acquisition = acquisition
        self.modelDeclaredBlocked = modelDeclaredBlocked
        self.modelDeclaredNeedsUser = modelDeclaredNeedsUser
        self.modelDeclaredPartial = modelDeclaredPartial
        self.someSuccessCriteriaMet = someSuccessCriteriaMet
        self.someSuccessCriteriaUnmet = someSuccessCriteriaUnmet
    }
}

enum LingShuTaskCompletionGate {

    /// **成功标准全部确定性达成 → 投机性 gap 视为已被执行推翻(纯函数,2026-06-30)**。
    /// 给 `computeCompletionDecision` 用:验收依据逐条确定性核验全过(有 met、无 unmet)、且模型没有通过结构字段声明未完成 →
    /// 那条 gap 并没真挡住交付(如 rev.py 三条标准全绿、pytest 跑通,「Python 测试框架」gap 是误报)→ 清掉它,别找用户要授权。
    /// **不在 `decide` 里短路**(那会把"真 needsUser 缺口 + 部分达成 → partial"也误判 ok);只在已知"全绿"的实跑层清。
    nonisolated static func allCriteriaMetResolvesSpeculativeGap(hasCriteria: Bool, someMet: Bool, someUnmet: Bool, modelDeclaredIncomplete: Bool) -> Bool {
        hasCriteria && someMet && !someUnmet && !modelDeclaredIncomplete
    }

    /// 确定性裁决(优先级级联)。
    static func decide(_ i: LingShuCompletionInputs) -> LingShuCompletionDecision {
        // ① 有未解除的阻断缺口 → 绝不当成功收尾。
        if i.hasUnresolvedBlockingGap {
            if i.unresolvedGapNeedsUser || i.acquisition == .needsUser {
                // 复合任务部分已完成 + 部分卡在需用户 → partial 优先(spec 第8条);否则纯 waitingForUser。
                return i.someSuccessCriteriaMet
                    ? .init(status: .partial, reason: "部分目标已完成;另一部分需你提供前提(凭据/授权/付费/物理)才能继续。")
                    : .init(status: .waitingForUser, reason: "有需用户提供的阻断前提(凭据/授权/付费/物理),已主动询问、暂不可完成。")
            }
            switch i.acquisition {
            case .notAttempted:
                if i.unresolvedGapSelfAcquirable {
                    return .init(status: .needsAcquisition, reason: "有可自补的阻断缺口但还没尝试获取——应先连 MCP / 自写组件 / 找技能 / 浏览器去补齐能力。")
                }
                return .init(status: .blocked, reason: "有阻断缺口、既不可自补也未必需用户,无法完成,诚实交还。")
            case .failed, .acquiredUnverified:
                return i.someSuccessCriteriaMet
                    ? .init(status: .partial, reason: "部分目标已完成;缺口能力尝试补齐但未成/未通过最小验证,该部分未完成。")
                    : .init(status: .blocked, reason: "尝试补齐缺口能力但未成/未通过最小验证,任务未完成,诚实交还。")
            case .needsUser:
                return .init(status: .waitingForUser, reason: "补齐该能力必须用户参与,暂不可完成。")
            case .acquiredVerified:
                break   // 缺口已补齐 + 验证通过 → 落到下面按成功标准判
            }
        }
        // ② 无未解除阻断缺口(或已 acquiredVerified):看结构化未完成/部分达成声明。
        if i.modelDeclaredNeedsUser {
            return i.someSuccessCriteriaMet
                ? .init(status: .partial, reason: "部分目标已完成;另一部分需用户提供前提才能继续。")
                : .init(status: .waitingForUser, reason: "模型通过结构化字段声明需要用户参与,暂不可完成。")
        }
        if i.modelDeclaredPartial {
            return .init(status: .partial, reason: "模型通过结构化字段声明部分完成。")
        }
        if i.modelDeclaredBlocked {
            return i.someSuccessCriteriaMet
                ? .init(status: .partial, reason: "模型通过结构化字段声明仍有未完成部分;已完成的部分照常,缺失部分不算完成。")
                : .init(status: .blocked, reason: "模型通过结构化字段声明无法完成/已阻断,禁止当成功收尾。")
        }
        if i.someSuccessCriteriaMet && i.someSuccessCriteriaUnmet {
            return .init(status: .partial, reason: "成功标准部分达成、部分未达成 → 部分完成。")
        }
        return .init(status: .ok, reason: "未见未解除阻断缺口/结构化未完成声明/部分缺失,交既有验收与收尾流程。")
    }
}
