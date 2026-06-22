import XCTest
@testable import LingShuMac

/// SafetyKernel·系统命令裁决经统一权限矩阵的**真值表等价守卫**(2026-06-22)。
/// `LingShuState.shellApprovalDecision` 把原先散在 `requestShellApproval` 的 dev-full / sessionAlways / 非交互 / 风险
/// 判断收口到 `LingShuPermissionMatrix`。本测钉死它与改造前**逐项等价**(改了实现、零行为回归),并守红线。
/// nil = 需交互弹窗;.allowAlways/.deny = 自动裁决。(quarantine 供应链路径在 requestShellApproval 单独处理,不在此函数。)
final class ShellApprovalKernelTests: XCTestCase {

    private func decide(_ fc: Bool, _ dev: Bool, _ sa: Bool, _ ni: Bool) -> LingShuShellApprovalDecision? {
        LingShuState.shellApprovalDecision(forceConfirm: fc, devFullAccess: dev, sessionAlwaysAllowed: sa, nonInteractive: ni)
    }

    /// 开发者全权 override:一律自动放行(保留用户拍板的现有行为)。
    func testDevFullAlwaysAllows() {
        for fc in [false, true] { for sa in [false, true] { for ni in [false, true] {
            XCTAssertEqual(decide(fc, true, sa, ni), .allowAlways, "dev-full 应放行 (fc=\(fc) sa=\(sa) ni=\(ni))")
        }}}
    }

    /// dev-full=false 的完整真值表(对齐改造前 requestShellApproval 的逐分支行为)。
    func testNonDevFullTruthTableMatchesLegacy() {
        // (forceConfirm, sessionAlways, nonInteractive) → 期望
        func expect(_ fc: Bool, _ sa: Bool, _ ni: Bool, _ want: LingShuShellApprovalDecision?, _ msg: String) {
            XCTAssertEqual(decide(fc, false, sa, ni), want, "\(msg) (fc=\(fc) sa=\(sa) ni=\(ni))")
        }
        // 普通命令(medium)
        expect(false, false, false, nil,          "标准+无授权+有人 → 弹窗")
        expect(false, false, true,  .deny,         "标准+无授权+无人值守 → 安全拒")
        expect(false, true,  false, .allowAlways,  "完全授权+有人 → 放行")
        expect(false, true,  true,  .allowAlways,  "完全授权+无人值守 → 放行(原 line46 先于 line47)")
        // 系统级敏感命令(critical/forceConfirm)——红线:即使完全授权也不自动放行
        expect(true,  false, false, nil,           "系统敏感+有人 → 强制弹窗")
        expect(true,  false, true,  .deny,         "系统敏感+无人值守 → 拒")
        expect(true,  true,  false, nil,           "系统敏感即使完全授权+有人 → 仍弹窗(红线)")
        expect(true,  true,  true,  .deny,         "系统敏感+无人值守 → 拒(红线)")
    }

    /// 红线:无人值守(autonomous)下系统级敏感命令绝不自动放行=直拒;有人在则强制弹窗(绝不自动放行)。
    func testCriticalNeverAutoAllowed() {
        XCTAssertEqual(decide(true, false, true,  true),  .deny, "无人值守+完全授权 → 仍拒")
        XCTAssertEqual(decide(true, false, false, true),  .deny, "无人值守+无授权 → 拒")
        XCTAssertEqual(decide(true, false, true,  false), nil,   "有人+完全授权 → 强制弹窗(不自动放行)")
        XCTAssertEqual(decide(true, false, false, false), nil,   "有人+无授权 → 强制弹窗")
    }
}
