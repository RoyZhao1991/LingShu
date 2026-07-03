import XCTest
@testable import LingShuMac

/// 通用中枢 **能力闭环 / 防伪完成闸**全覆盖(100 case):
/// 完成闸确定性裁决矩阵 + 结构化 completion 协议 + 获取结果分类 + 缺口阻断语义。纯逻辑无模型。
final class P2_CapabilityGateCoverageTests: XCTestCase {

    private typealias I = LingShuCompletionInputs
    private typealias S = LingShuCompletionStatus

    func testCompletionGateAndCapability_100Cases() {
        var n = 0

        // —— A. 完成闸 decide 矩阵(45 case),(inputs, 预期状态)——
        let cases: [(I, S, String)] = [
            (I(), .ok, "全 false → ok"),
            (I(someSuccessCriteriaMet: true), .ok, "仅 met → ok"),
            (I(someSuccessCriteriaUnmet: true), .ok, "仅 unmet → ok"),
            (I(someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true), .partial, "met+unmet → partial"),
            (I(modelDeclaredBlocked: true), .blocked, "结构化 blocked+无met → blocked"),
            (I(modelDeclaredBlocked: true, someSuccessCriteriaMet: true), .partial, "结构化 blocked+met → partial"),
            // 阻断 + 需用户
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true), .waitingForUser, "阻断+需用户 → 待用户"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, someSuccessCriteriaMet: true), .partial, "阻断+需用户+met → partial"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .needsUser), .waitingForUser, "acquisition=needsUser → 待用户"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .needsUser, someSuccessCriteriaMet: true), .partial, "needsUser+met → partial"),
            // 阻断 + 自补
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .notAttempted), .needsAcquisition, "可自补未试 → 驱动获取"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: false, acquisition: .notAttempted), .blocked, "不可自补未试 → blocked"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .failed), .blocked, "获取失败+无met → blocked"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .failed, someSuccessCriteriaMet: true), .partial, "获取失败+met → partial"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredUnverified), .blocked, "补到未验证+无met → blocked"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredUnverified, someSuccessCriteriaMet: true), .partial, "未验证+met → partial"),
            // 阻断 + acquiredVerified → 落到 ②
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredVerified), .ok, "已验证补齐+无异常 → ok"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredVerified, someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true), .partial, "已验证但met+unmet → partial"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredVerified, modelDeclaredBlocked: true), .blocked, "已验证但结构化 blocked → blocked"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredVerified, modelDeclaredBlocked: true, someSuccessCriteriaMet: true), .partial, "已验证+blocked+met → partial"),
            // 优先级:① 阻断分支压过 ② 结构化 completion/met
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .notAttempted, modelDeclaredBlocked: true), .needsAcquisition, "阻断分支压过结构化 blocked"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, modelDeclaredBlocked: true), .waitingForUser, "需用户压过结构化 blocked"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, unresolvedGapSelfAcquirable: true), .waitingForUser, "需用户优先于自补"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, acquisition: .acquiredVerified), .waitingForUser, "需用户优先于已验证"),
            // 更多无阻断的 ② 组合
            (I(modelDeclaredBlocked: true, someSuccessCriteriaUnmet: true), .blocked, "blocked+unmet(无met) → blocked"),
            (I(someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: false), .ok, "仅met → ok"),
            (I(acquisition: .acquiredVerified), .ok, "无阻断+已验证 → ok"),
            (I(acquisition: .failed), .ok, "无阻断时 acquisition 不影响 → ok"),
            (I(acquisition: .needsUser), .ok, "无阻断时 needsUser 不影响 → ok"),
            (I(unresolvedGapNeedsUser: true), .ok, "无阻断标志时 needsUser 标志被忽略 → ok"),
            (I(unresolvedGapSelfAcquirable: true), .ok, "无阻断时 selfAcq 标志被忽略 → ok"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .acquiredVerified, someSuccessCriteriaMet: true), .ok, "自补已验证+met(无unmet) → ok"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .notAttempted), .blocked, "阻断未试且未标可自补 → blocked"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .failed), .blocked, "自补失败 → blocked"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .failed, someSuccessCriteriaMet: true), .partial, "自补失败+met → partial"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .acquiredUnverified, someSuccessCriteriaMet: true), .partial, "自补未验证+met → partial"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredVerified, someSuccessCriteriaUnmet: true), .ok, "已验证+仅unmet → ok(无met)"),
            (I(modelDeclaredBlocked: false, someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true), .partial, "无blocked+met+unmet → partial"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, acquisition: .notAttempted, someSuccessCriteriaMet: false), .waitingForUser, "需用户+未试 → 待用户"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapNeedsUser: true, acquisition: .failed, someSuccessCriteriaMet: true), .partial, "需用户+失败+met → partial(需用户分支)"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .needsUser, someSuccessCriteriaUnmet: true), .waitingForUser, "acquisition needsUser+unmet(无met) → 待用户"),
            (I(modelDeclaredBlocked: true, someSuccessCriteriaMet: true, someSuccessCriteriaUnmet: true), .partial, "blocked+met+unmet → partial"),
            (I(hasUnresolvedBlockingGap: true, unresolvedGapSelfAcquirable: true, acquisition: .notAttempted, someSuccessCriteriaMet: true), .needsAcquisition, "可自补未试(即便有met)仍先驱动获取"),
            (I(hasUnresolvedBlockingGap: false, modelDeclaredBlocked: false, someSuccessCriteriaMet: false, someSuccessCriteriaUnmet: false), .ok, "干净对话 → ok"),
            (I(hasUnresolvedBlockingGap: true, acquisition: .acquiredVerified, modelDeclaredBlocked: false, someSuccessCriteriaMet: false, someSuccessCriteriaUnmet: false), .ok, "已验证收尾 → ok")
        ]
        for (inp, exp, msg) in cases {
            XCTAssertEqual(LingShuTaskCompletionGate.decide(inp).status, exp, msg)
            n += 1
        }

        // —— B. 完整 JSON completion 协议(20 case)——
        let structuredBlocked = [
            #"{"reply":"暂不可完成","completion":{"status":"blocked","reason":"缺能力"},"OAuth":null}"#,
            #"{"reply":"需要用户","completion":{"status":"waiting_for_user","needs_user":true},"OAuth":null}"#,
            #"{"reply":"部分完成","completion":{"status":"partial","reason":"还有未达成项"},"OAuth":null}"#,
            #"{"reply":"需补能力","completion":{"status":"needs_acquisition","reason":"缺工具"},"OAuth":null}"#,
            #"""
```json
{"reply":"被代码块包住但整段仍是 JSON","completion":{"status":"blocked"},"OAuth":null}
```
"""#
        ]
        for t in structuredBlocked {
            XCTAssertTrue(LingShuStructuredModelOutput.parse(t)?.declaresIncomplete == true, "应从完整 JSON 读出流程字段: \(t)")
            n += 1
        }
        let plainTexts = [
            "我无法接入你的服务", "未授权,做不到", "没有权限访问", "暂不支持这个操作",
            "需要你提供 API Key", "缺少必要的凭据", "我做不了这件事", "尚未连接到该服务",
            "无法同步到日历", "不具备该能力", "暂时无法完成", "无法帮你下单",
            "已完成,文件在 /tmp/a.txt", "PPT 已生成,共 8 页", "OAuth 是授权框架"
        ]
        for t in plainTexts {
            XCTAssertNil(LingShuStructuredModelOutput.parse(t), "普通文本不得驱动流程状态: \(t)")
            n += 1
        }

        // —— C. 获取结果分类 classify(12 case)——
        func sig(_ ru: Bool, _ at: Bool, _ su: Bool, _ ve: Bool) -> LingShuAcquisitionSignals {
            .init(requiresUser: ru, attemptedSelfAcquire: at, acquireSucceeded: su, newCapabilityVerified: ve)
        }
        let clz: [(LingShuAcquisitionSignals, LingShuAcquisitionOutcome)] = [
            (sig(true, false, false, false), .needsUser),
            (sig(true, true, true, true), .needsUser),         // requiresUser 压一切
            (sig(false, false, false, false), .notAttempted),
            (sig(false, false, true, true), .notAttempted),    // 没 attempted 即 notAttempted
            (sig(false, true, true, true), .acquiredVerified),
            (sig(false, true, true, false), .acquiredUnverified),
            (sig(false, true, false, false), .failed),
            (sig(false, true, false, true), .failed),          // 没 succeeded 即 failed
            (sig(true, true, false, false), .needsUser),
            (sig(false, true, true, true), .acquiredVerified),
            (sig(false, true, false, true), .failed),
            (sig(false, false, true, false), .notAttempted)
        ]
        for (s, exp) in clz { XCTAssertEqual(LingShuCapabilityAcquisition.classify(s), exp); n += 1 }
        XCTAssertTrue(LingShuAcquisitionOutcome.acquiredVerified.resolvesGap); n += 1
        XCTAssertFalse(LingShuAcquisitionOutcome.acquiredUnverified.resolvesGap); n += 1
        XCTAssertFalse(LingShuAcquisitionOutcome.failed.resolvesGap); n += 1

        // —— D. 缺口语义:requiresUser / selfAcquirable 按 kind(9)+ 阻断聚合(10)——
        let kinds: [(LingShuGapKind, Bool, Bool)] = [   // (kind, requiresUser, selfAcquirable)
            (.model, false, true), (.tool, false, true), (.knowledge, false, true), (.resource, false, true),
            (.device, true, false), (.permission, true, false), (.funding, true, false), (.humanConfirmation, true, false),
            (.unknown, false, false)
        ]
        for (k, ru, sa) in kinds {
            let g = LingShuCapabilityGap(kind: k, missing: "x", fillPath: "y", blocking: true)
            XCTAssertEqual(g.requiresUser, ru, "requiresUser[\(k.rawValue)]")
            XCTAssertEqual(g.selfAcquirable, sa, "selfAcquirable[\(k.rawValue)]")
            n += 1
        }
        // 阻断聚合:resolved 不再算阻断
        let gapAll = LingShuGapAnalysis(feasibleNow: false, gaps: [
            LingShuCapabilityGap(kind: .permission, missing: "授权", fillPath: "你授权", blocking: true),
            LingShuCapabilityGap(kind: .tool, missing: "工具", fillPath: "自写", blocking: true),
            LingShuCapabilityGap(kind: .knowledge, missing: "资料", fillPath: "查", blocking: false, resolved: false)
        ], note: "")
        XCTAssertTrue(gapAll.hasBlockingGap); n += 1
        XCTAssertEqual(gapAll.blockingGaps.count, 2, "2 个阻断"); n += 1
        XCTAssertTrue(gapAll.blockingNeedsUser, "permission 需用户"); n += 1
        XCTAssertTrue(gapAll.blockingSelfAcquirable, "tool 可自补"); n += 1
        XCTAssertTrue(gapAll.needsUserToUnblock); n += 1
        var resolvedOne = gapAll
        resolvedOne.gaps[0].resolved = true
        XCTAssertEqual(resolvedOne.blockingGaps.count, 1, "解除后剩1阻断"); n += 1
        XCTAssertFalse(resolvedOne.blockingNeedsUser, "需用户缺口已解除"); n += 1
        let noGap = LingShuGapAnalysis(feasibleNow: true, gaps: [], note: "ok")
        XCTAssertFalse(noGap.hasBlockingGap); n += 1
        XCTAssertEqual(noGap.executionGuidance(base: "B"), "B", "无缺口 → 返回 base"); n += 1
        XCTAssertTrue(gapAll.executionGuidance(base: nil).contains("能力缺口"), "有缺口出引导"); n += 1
        XCTAssertTrue(gapAll.executionGuidance(base: nil).contains("ask_user"), "需用户→提示先问"); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "P2 覆盖应 ≥100 case,实际 \(n)")
    }
}
