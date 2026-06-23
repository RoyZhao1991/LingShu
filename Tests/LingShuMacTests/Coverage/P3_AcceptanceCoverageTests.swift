import XCTest
@testable import LingShuMac

/// 通用中枢 **P3 全类型验收**全覆盖(100 case):criterion 分类归一 + 逐条确定性裁决(met/unmet/unverifiable)+
/// 报告聚合(硬门返工)+ 分类器容错解析(1-1 对齐 / 漏多项回退 / 非 JSON 回退)。纯逻辑无模型。
final class P3_AcceptanceCoverageTests: XCTestCase {

    private typealias K = LingShuCriterionKind
    private typealias St = LingShuCheckStatus

    func testAcceptance_100Cases() {
        var n = 0

        // —— A. parseKind 归一(25 case)——
        let kindMap: [(String, K)] = [
            ("file_exists", .fileExists), ("fileexists", .fileExists), ("file-exists", .fileExists), ("FILE_EXISTS", .fileExists),
            ("command_succeeds", .commandSucceeds), ("commandsucceeds", .commandSucceeds), ("command", .commandSucceeds),
            ("test", .commandSucceeds), ("build", .commandSucceeds), ("Command-Succeeds", .commandSucceeds),
            ("device_effect", .deviceEffect), ("deviceeffect", .deviceEffect), ("device", .deviceEffect),
            ("environment_change", .environmentChange), ("environment", .environmentChange), ("env", .environmentChange),
            ("user_confirmation", .userConfirmation), ("user", .userConfirmation),
            ("content_quality", .contentQuality), ("content", .contentQuality), ("quality", .contentQuality),
            ("乱七八糟", .contentQuality), ("", .contentQuality), ("unknown", .contentQuality), ("  test  ", .commandSucceeds)
        ]
        for (raw, exp) in kindMap {
            XCTAssertEqual(LingShuAcceptancePlanner.parseKind(raw), exp, "parseKind(\(raw))")
            n += 1
        }
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind(nil), .contentQuality, "nil → contentQuality"); n += 1

        // —— B. make() 逐条裁决(30 case)——
        func chk(_ k: K, _ probe: String?) -> LingShuAcceptanceCheck { .init(kind: k, criterion: "c-\(k.rawValue)", probe: probe) }
        func verdict(_ k: K, probe: String?, exists: Bool = false, cmd: Bool? = nil) -> St {
            let r = LingShuAcceptanceReport.make(checks: [chk(k, probe)],
                                                 fileExists: { _ in exists },
                                                 commandSucceeded: { _ in cmd })
            return r.verdicts[0].status
        }
        // fileExists
        XCTAssertEqual(verdict(.fileExists, probe: "/tmp/a.txt", exists: true), .met); n += 1
        XCTAssertEqual(verdict(.fileExists, probe: "/tmp/a.txt", exists: false), .unmet); n += 1
        XCTAssertEqual(verdict(.fileExists, probe: "", exists: true), .unverifiable, "空探针→unverifiable"); n += 1
        XCTAssertEqual(verdict(.fileExists, probe: nil, exists: true), .unverifiable, "无探针→unverifiable"); n += 1
        XCTAssertEqual(verdict(.fileExists, probe: "report.pdf", exists: true), .met); n += 1
        XCTAssertEqual(verdict(.fileExists, probe: "*.pptx", exists: false), .unmet); n += 1
        // commandSucceeds 三态
        XCTAssertEqual(verdict(.commandSucceeds, probe: "swift test", cmd: true), .met); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: "swift test", cmd: false), .unmet); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: "pytest", cmd: nil), .unverifiable, "无匹配命令→unverifiable"); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: "", cmd: true), .unverifiable, "空探针→unverifiable"); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: nil, cmd: true), .unverifiable); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: "npm test", cmd: true), .met); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: "go test", cmd: false), .unmet); n += 1
        // 非确定性类型恒 unverifiable(绝不幻觉为达成)
        for k in [K.deviceEffect, .environmentChange, .userConfirmation, .contentQuality, .unknown] {
            XCTAssertEqual(verdict(k, probe: nil), .unverifiable, "\(k.rawValue) 恒 unverifiable"); n += 1
            XCTAssertEqual(verdict(k, probe: "有探针也无视"), .unverifiable, "\(k.rawValue) 即便给探针仍 unverifiable"); n += 1
        }
        // 证据文本非空
        let evR = LingShuAcceptanceReport.make(checks: [chk(.fileExists, "/x")], fileExists: { _ in true }, commandSucceeded: { _ in nil })
        XCTAssertFalse(evR.verdicts[0].evidence.isEmpty, "met 带证据"); n += 1
        XCTAssertEqual(evR.verdicts[0].criterion, "c-fileExists", "criterion 原样"); n += 1
        XCTAssertEqual(evR.verdicts[0].kind, .fileExists); n += 1
        XCTAssertEqual(verdict(.fileExists, probe: "/tmp/missing", exists: false), .unmet); n += 1
        XCTAssertEqual(verdict(.commandSucceeds, probe: "make", cmd: true), .met); n += 1

        // —— C. 报告聚合 / 硬门(15 case)——
        let mixed = LingShuAcceptanceReport.make(checks: [
            chk(.fileExists, "/exists"), chk(.fileExists, "/missing"),
            chk(.commandSucceeds, "swift test"), chk(.contentQuality, nil)
        ], fileExists: { $0 == "/exists" }, commandSucceeded: { $0 == "swift test" ? true : nil })
        XCTAssertTrue(mixed.hasDeterministicFailure, "有 unmet → 硬门"); n += 1
        XCTAssertEqual(mixed.deterministicFailures.count, 1); n += 1
        XCTAssertEqual(mixed.deterministicallyMet.count, 2, "fileExists met + command met"); n += 1
        XCTAssertEqual(mixed.unverifiable.count, 1, "contentQuality"); n += 1
        XCTAssertFalse(mixed.isEmpty); n += 1
        XCTAssertFalse(mixed.deterministicFailureReason.isEmpty); n += 1
        XCTAssertTrue(mixed.summary.contains("✅") && mixed.summary.contains("❌")); n += 1
        XCTAssertTrue(mixed.verifierBlock.contains("未达成") || mixed.verifierBlock.contains("达成")); n += 1
        let allMet = LingShuAcceptanceReport.make(checks: [chk(.fileExists, "/a"), chk(.commandSucceeds, "t")],
                                                  fileExists: { _ in true }, commandSucceeded: { _ in true })
        XCTAssertFalse(allMet.hasDeterministicFailure, "全 met → 不返工"); n += 1
        XCTAssertEqual(allMet.deterministicallyMet.count, 2); n += 1
        let allUnver = LingShuAcceptanceReport.make(checks: [chk(.contentQuality, nil), chk(.deviceEffect, nil)],
                                                    fileExists: { _ in false }, commandSucceeded: { _ in nil })
        XCTAssertFalse(allUnver.hasDeterministicFailure, "全 unverifiable → 不硬门"); n += 1
        XCTAssertEqual(allUnver.unverifiable.count, 2); n += 1
        let empty = LingShuAcceptanceReport(verdicts: [], note: "")
        XCTAssertTrue(empty.isEmpty); n += 1
        XCTAssertFalse(empty.hasDeterministicFailure); n += 1
        XCTAssertTrue(empty.verifierBlock.isEmpty, "无 verdict → 空 verifierBlock"); n += 1

        // —— D. 分类器容错解析(30 case)——
        // D1: 1-1 对齐(数量一致 → 用原标准覆盖 criterion,保留 kind/probe)
        let crit = ["生成 report.pdf", "swift test 全绿", "内容准确"]
        let json3 = """
        [{"criterion":"生成报告文件","kind":"file_exists","probe":"report.pdf"},
         {"criterion":"测试通过","kind":"command_succeeds","probe":"swift test"},
         {"criterion":"内容好","kind":"content_quality","probe":""}]
        """
        let p3 = LingShuAcceptancePlanner.parse(json3, fallbackCriteria: crit)
        XCTAssertEqual(p3.count, 3); n += 1
        XCTAssertEqual(p3[0].criterion, "生成 report.pdf", "原标准覆盖"); n += 1
        XCTAssertEqual(p3[0].kind, .fileExists); n += 1
        XCTAssertEqual(p3[0].probe, "report.pdf"); n += 1
        XCTAssertEqual(p3[1].kind, .commandSucceeds); n += 1
        XCTAssertEqual(p3[1].probe, "swift test"); n += 1
        XCTAssertEqual(p3[2].kind, .contentQuality); n += 1
        XCTAssertNil(p3[2].probe, "空 probe → nil"); n += 1
        // D2: 非 JSON / 空 → 本地启发式回退:不丢条目,且保留文件/命令硬证据。
        for bad in ["不是JSON", "", "   ", "{对象不是数组}", "没有方括号"] {
            let pf = LingShuAcceptancePlanner.parse(bad, fallbackCriteria: crit)
            XCTAssertEqual(pf.count, 3, "回退保全部条目: \(bad)"); n += 1
            XCTAssertEqual(pf[0].kind, .fileExists, "回退仍识别文件硬证据"); n += 1
            XCTAssertEqual(pf[1].kind, .commandSucceeds, "回退仍识别命令硬证据"); n += 1
            XCTAssertEqual(pf[2].kind, .contentQuality, "无硬证据才交主观评审"); n += 1
        }
        // D3: 空 fallback + 有解析 → 用解析
        let pe = LingShuAcceptancePlanner.parse("[{\"criterion\":\"x\",\"kind\":\"file_exists\",\"probe\":\"x.txt\"}]", fallbackCriteria: [])
        XCTAssertEqual(pe.count, 1); n += 1
        XCTAssertEqual(pe[0].kind, .fileExists); n += 1
        // D4: 数量不匹配 → 按原文匹配,未匹配走本地启发式。
        let jsonMismatch = "[{\"criterion\":\"swift test 全绿\",\"kind\":\"command_succeeds\",\"probe\":\"swift test\"}]"
        let pm = LingShuAcceptancePlanner.parse(jsonMismatch, fallbackCriteria: crit)
        XCTAssertEqual(pm.count, 3, "不丢条目"); n += 1
        XCTAssertEqual(pm.first { $0.criterion == "swift test 全绿" }?.kind, .commandSucceeds, "匹配上的用其分类"); n += 1
        XCTAssertEqual(pm.first { $0.criterion == "生成 report.pdf" }?.kind, .fileExists, "未匹配但含文件线索→本地硬证据"); n += 1
        // D5: criterion 空的项被跳过 → 回退
        let pSkip = LingShuAcceptancePlanner.parse("[{\"criterion\":\"\",\"kind\":\"file_exists\"}]", fallbackCriteria: ["唯一标准"])
        XCTAssertEqual(pSkip.count, 1); n += 1
        XCTAssertEqual(pSkip[0].kind, .contentQuality, "空 criterion 被跳→回退"); n += 1
        // D6: fallback 里空串被清理
        let pClean = LingShuAcceptancePlanner.parse("非json", fallbackCriteria: ["a", "", "  ", "b"])
        XCTAssertEqual(pClean.count, 2, "空标准被清理"); n += 1
        XCTAssertEqual(pClean.map(\.criterion), ["a", "b"]); n += 1

        // —— E. 补充:多条 fileExists/command 混合裁决(10 case)——
        for path in ["/a", "/b", "/c", "/d"] {
            XCTAssertEqual(verdict(.fileExists, probe: path, exists: true), .met, "存在: \(path)"); n += 1
        }
        for c in ["pytest -q", "swift build", "make all"] {
            XCTAssertEqual(verdict(.commandSucceeds, probe: c, cmd: true), .met, "命令成功: \(c)"); n += 1
        }
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("FILE-EXISTS"), .fileExists); n += 1
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("ENV"), .environmentChange); n += 1
        XCTAssertEqual(LingShuAcceptancePlanner.parseKind("Quality"), .contentQuality); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "P3 覆盖应 ≥100 case,实际 \(n)")
    }
}
