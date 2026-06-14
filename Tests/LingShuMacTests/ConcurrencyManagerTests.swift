import XCTest
@testable import LingShuMac

final class ConcurrencyManagerTests: XCTestCase {

    func testAdmitsUpToBoundThenQueues() {
        var mgr = LingShuConcurrencyManager(maxConcurrent: 3)
        XCTAssertTrue(mgr.requestAdmission(threadID: "t1"))
        XCTAssertTrue(mgr.requestAdmission(threadID: "t2"))
        XCTAssertTrue(mgr.requestAdmission(threadID: "t3"))
        XCTAssertFalse(mgr.requestAdmission(threadID: "t4"), "第4条超界应排队")
        XCTAssertEqual(mgr.runningCount, 3)
        XCTAssertEqual(mgr.waitingCount, 1)
        XCTAssertTrue(mgr.isWaiting("t4"))
    }

    func testCompleteAdmitsNextWaiting() {
        var mgr = LingShuConcurrencyManager(maxConcurrent: 2)
        mgr.requestAdmission(threadID: "t1")
        mgr.requestAdmission(threadID: "t2")
        XCTAssertFalse(mgr.requestAdmission(threadID: "t3"))   // 排队
        let admitted = mgr.complete(threadID: "t1")
        XCTAssertEqual(admitted, "t3", "释放容量后应自动纳入排队的 t3")
        XCTAssertTrue(mgr.isRunning("t3"))
        XCTAssertEqual(mgr.runningCount, 2)
        XCTAssertEqual(mgr.waitingCount, 0)
    }

    func testPerThreadStateIsIsolated() {
        var mgr = LingShuConcurrencyManager(maxConcurrent: 3)
        mgr.requestAdmission(threadID: "ppt")
        mgr.requestAdmission(threadID: "crawler")
        mgr.updateState(threadID: "ppt") { $0.phase = .executing }
        mgr.updateState(threadID: "crawler") { $0.phase = .reviewing }
        XCTAssertEqual(mgr.state(for: "ppt")?.phase, .executing)
        XCTAssertEqual(mgr.state(for: "crawler")?.phase, .reviewing)
    }

    func testAnyModelInFlightAggregatesPerThread() {
        var mgr = LingShuConcurrencyManager(maxConcurrent: 3)
        mgr.requestAdmission(threadID: "a")
        mgr.requestAdmission(threadID: "b")
        XCTAssertFalse(mgr.anyModelInFlight)
        mgr.setModelInFlight(true, threadID: "a")
        XCTAssertTrue(mgr.anyModelInFlight, "a 在飞 → 聚合为真")
        mgr.setModelInFlight(false, threadID: "a")
        XCTAssertFalse(mgr.anyModelInFlight, "全部落地 → 聚合为假")
    }

    func testDuplicateAdmissionIsIdempotent() {
        var mgr = LingShuConcurrencyManager(maxConcurrent: 3)
        XCTAssertTrue(mgr.requestAdmission(threadID: "t1"))
        XCTAssertTrue(mgr.requestAdmission(threadID: "t1"), "已在跑的线程再申请仍为 true")
        XCTAssertEqual(mgr.runningCount, 1)
    }

    func testCompleteWithoutWaitingReturnsNil() {
        var mgr = LingShuConcurrencyManager(maxConcurrent: 3)
        mgr.requestAdmission(threadID: "t1")
        XCTAssertNil(mgr.complete(threadID: "t1"))
        XCTAssertEqual(mgr.runningCount, 0)
    }
}
