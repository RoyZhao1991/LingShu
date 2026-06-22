import XCTest
@testable import LingShuMac

/// 完全版 #5·统一权限求值器守卫:**安全红线恒成立**(供应链/紧急停止/不可逆)+ 各模式裁决合理。
final class PermissionMatrixTests: XCTestCase {
    typealias M = LingShuPermissionMatrix

    func testRedLinesNeverRelaxed() {
        // 供应链(未审代码):任何模式都拒。
        for mode in [LingShuRunMode.developerFull, .autonomous, .standard, .readOnly, .presentation] {
            XCTAssertEqual(M.decide(domain: .supplyChain, risk: .low, mode: mode, durablyAllowed: true), .deny,
                           "供应链恒拒(\(mode))")
        }
        // 紧急停止:全拒,连只读也拒。
        XCTAssertEqual(M.decide(domain: .file, risk: .readonly, mode: .emergencyStop), .deny)
        // 不可逆/系统级 critical:无人值守=拒,有人在=先确认,绝不自动放行。
        XCTAssertEqual(M.decide(domain: .systemControl, risk: .critical, mode: .autonomous, durablyAllowed: true), .deny)
        XCTAssertEqual(M.decide(domain: .systemControl, risk: .critical, mode: .developerFull, durablyAllowed: true), .askUser)
    }

    func testReadonlyAlwaysAllowed() {
        for mode in [LingShuRunMode.standard, .autonomous, .developerFull, .presentation] {
            XCTAssertEqual(M.decide(domain: .file, risk: .readonly, mode: mode), .allow)
        }
        // 只读模式下非只读风险一律拒。
        XCTAssertEqual(M.decide(domain: .file, risk: .low, mode: .readOnly), .deny)
    }

    func testDeveloperFull() {
        XCTAssertEqual(M.decide(domain: .terminal, risk: .medium, mode: .developerFull), .allow, "dev全权:中风险放行")
        XCTAssertEqual(M.decide(domain: .network, risk: .high, mode: .developerFull), .askUser, "高风险仍先确认")
        XCTAssertEqual(M.decide(domain: .network, risk: .high, mode: .developerFull, durablyAllowed: true), .allow, "已持久授权则放行")
    }

    func testAutonomousUnattended() {
        XCTAssertEqual(M.decide(domain: .file, risk: .low, mode: .autonomous), .allow)
        XCTAssertEqual(M.decide(domain: .terminal, risk: .medium, mode: .autonomous), .askUser, "无人值守中风险先确认")
        XCTAssertEqual(M.decide(domain: .network, risk: .high, mode: .autonomous), .deny, "无人值守高风险拒")
    }

    func testStandardAndPresentation() {
        XCTAssertEqual(M.decide(domain: .file, risk: .low, mode: .standard), .allow)
        XCTAssertEqual(M.decide(domain: .terminal, risk: .medium, mode: .standard), .askUser)
        XCTAssertEqual(M.decide(domain: .file, risk: .low, mode: .presentation), .allow)
        XCTAssertEqual(M.decide(domain: .systemControl, risk: .medium, mode: .presentation), .askUser, "演示中别乱动")
    }
}
