import XCTest
@testable import LingShuMac

/// 统一澄清编排中心：多轮弹窗（逐题呈现、不互相覆盖）与非交互自动定夺。
@MainActor
final class ClarificationCenterTests: XCTestCase {
    func testSingleQuestionPresentsImmediately() {
        let center = LingShuClarificationCenter()
        var presented = 0
        center.submit(kind: "t", taskRecordID: nil, present: { presented += 1 }, autoResolve: {})
        XCTAssertEqual(presented, 1, "队首立即呈现")
        XCTAssertEqual(center.pendingCount, 1)
    }

    func testSecondQuestionQueuesBehindFirst() {
        let center = LingShuClarificationCenter()
        var presentedA = 0, presentedB = 0
        center.submit(kind: "A", taskRecordID: nil, present: { presentedA += 1 }, autoResolve: {})
        center.submit(kind: "B", taskRecordID: nil, present: { presentedB += 1 }, autoResolve: {})
        XCTAssertEqual(presentedA, 1, "第一题已呈现")
        XCTAssertEqual(presentedB, 0, "第二题排队，尚未呈现（不覆盖第一题）")
        XCTAssertEqual(center.pendingCount, 2)
    }

    /// 多轮核心：第一题答完，第二题自动浮现。
    func testResolvingFirstSurfacesSecond() {
        let center = LingShuClarificationCenter()
        var presentedB = 0
        center.submit(kind: "A", taskRecordID: nil, present: {}, autoResolve: {})
        center.submit(kind: "B", taskRecordID: nil, present: { presentedB += 1 }, autoResolve: {})
        XCTAssertEqual(presentedB, 0)
        center.advanceAfterExternalResolution()
        XCTAssertEqual(presentedB, 1, "第一题答完后第二题浮现")
        XCTAssertEqual(center.activeRequest?.kind, "B")
        XCTAssertEqual(center.pendingCount, 1)
    }

    func testResolveActiveRunsResolutionThenAdvances() {
        let center = LingShuClarificationCenter()
        var log: [String] = []
        center.submit(kind: "A", taskRecordID: nil, present: { log.append("present-A") }, autoResolve: {})
        center.submit(kind: "B", taskRecordID: nil, present: { log.append("present-B") }, autoResolve: {})
        center.resolveActive { log.append("resolve-A") }
        XCTAssertEqual(log, ["present-A", "resolve-A", "present-B"], "出队→执行消解→呈现下一题")
        XCTAssertEqual(center.activeRequest?.kind, "B")
    }

    func testDrainsAllInOrderFIFO() {
        let center = LingShuClarificationCenter()
        var order: [String] = []
        for name in ["A", "B", "C"] {
            center.submit(kind: name, taskRecordID: nil, present: { order.append("p-\(name)") }, autoResolve: {})
        }
        XCTAssertEqual(order, ["p-A"])
        center.advanceAfterExternalResolution()
        center.advanceAfterExternalResolution()
        XCTAssertEqual(order, ["p-A", "p-B", "p-C"], "严格按提交顺序逐题浮现")
        center.advanceAfterExternalResolution()
        XCTAssertFalse(center.hasPending, "全部答完后清空")
    }

    func testNonInteractiveAutoResolvesWithoutQueueing() {
        let center = LingShuClarificationCenter()
        center.isNonInteractive = { true }
        var presented = 0, autoResolved = 0
        center.submit(kind: "t", taskRecordID: nil, present: { presented += 1 }, autoResolve: { autoResolved += 1 })
        XCTAssertEqual(presented, 0, "非交互场景不弹卡")
        XCTAssertEqual(autoResolved, 1, "非交互场景自动定夺")
        XCTAssertFalse(center.hasPending, "自动定夺的问题不入队，不阻塞无人值守执行")
    }

    func testReentrantSubmitDuringResolveDoesNotDoublePresent() {
        let center = LingShuClarificationCenter()
        var presentedC = 0
        center.submit(kind: "A", taskRecordID: nil, present: {}, autoResolve: {})
        center.resolveActive {
            center.submit(kind: "C", taskRecordID: nil, present: { presentedC += 1 }, autoResolve: {})
        }
        XCTAssertEqual(presentedC, 1, "消解过程中新提交的问题只呈现一次（幂等，不重复弹卡）")
        XCTAssertEqual(center.activeRequest?.kind, "C")
    }

    func testCancelAllClears() {
        let center = LingShuClarificationCenter()
        center.submit(kind: "A", taskRecordID: nil, present: {}, autoResolve: {})
        center.submit(kind: "B", taskRecordID: nil, present: {}, autoResolve: {})
        center.cancelAll()
        XCTAssertFalse(center.hasPending)
    }
}
