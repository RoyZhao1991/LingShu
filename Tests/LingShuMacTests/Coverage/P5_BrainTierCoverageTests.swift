import XCTest
@testable import LingShuMac

/// 通用中枢 **P5 据当前脑动态调整**全覆盖(100+ case):能力估计(基准主导+运行净分微调+夹紧)+
/// 起步档阈值(带迟滞)+ 旋钮提示(安全红线恒在)+ 复杂度→理想档 + 理想档→可用档降级。纯逻辑无模型。
final class P5_BrainTierCoverageTests: XCTestCase {

    private typealias HP = LingShuHarnessProfile
    private typealias T = LingShuHarnessProfile.Tier
    private typealias BR = LingShuBrainRouter
    private typealias BT = LingShuBrainTier

    func testBrainTier_100Cases() {
        var n = 0
        let acc = 1e-9

        // —— A. capability 公式(20 case)——
        let cap: [(Int?, Int, Double)] = [
            (90, 0, 90), (90, 100, 93), (90, -100, 87), (90, 10, 93), (90, -10, 87),
            (98, 5, 99.5), (50, 0, 50), (0, -100, 0), (0, 0, 0), (100, 100, 100),
            (100, 0, 100), (100, -100, 97), (75, 0, 75), (74, 0, 74), (60, 33, 63),   // bounded 33→10 *0.3=3
            (nil, 0, 50), (nil, 544, 80), (nil, -544, 20), (nil, 30, 80), (nil, -30, 20)
        ]
        for (b, r, e) in cap {
            XCTAssertEqual(HP.capability(benchmark: b, runNetScore: r), e, accuracy: acc, "capability(\(String(describing: b)),\(r))")
            n += 1
        }

        // —— B. tier 阈值:遍历 0...100(101 case,带间隔 75/50)——
        for c in 0...100 {
            let d = Double(c)
            let exp: T = d >= 75 ? .lean : (d >= 50 ? .balanced : .guided)
            XCTAssertEqual(HP.tier(d), exp, "tier(\(c))")
            n += 1
        }
        XCTAssertEqual(HP.tier(74.9), .balanced, "74.9 未到 lean"); n += 1
        XCTAssertEqual(HP.tier(49.9), .guided, "49.9 落 guided"); n += 1
        XCTAssertEqual(HP.tier(75.0), .lean); n += 1
        XCTAssertEqual(HP.tier(50.0), .balanced); n += 1

        // —— C. knobPrefix:安全红线恒在 + 各档关键词 + tag(12 case)——
        for c in [10.0, 60.0, 90.0] {
            let k = HP.knobPrefix(capability: c, tag: "脑力 \(Int(c)) 分")
            XCTAssertTrue(k.contains("安全红线"), "安全红线恒在 @\(c)"); n += 1
            XCTAssertTrue(k.contains("脑力 \(Int(c)) 分"), "tag 注入 @\(c)"); n += 1
            XCTAssertFalse(k.isEmpty); n += 1
        }
        XCTAssertTrue(HP.knobPrefix(capability: 90, tag: "x").contains("放权"), "lean=放权"); n += 1
        XCTAssertTrue(HP.knobPrefix(capability: 60, tag: "x").contains("适度"), "balanced=适度"); n += 1
        XCTAssertTrue(HP.knobPrefix(capability: 10, tag: "x").contains("引导"), "guided=引导"); n += 1

        // —— D. desiredTier 复杂度打分(25 case)——
        func sig(_ k: LingShuGoalKind = .task, c: Int = 0, cr: Int = 0, gap: Bool = false, esc: Int = 0) -> LingShuBrainRoutingSignals {
            .init(kind: k, constraintCount: c, criteriaCount: cr, hasBlockingGap: gap, escalationCount: esc)
        }
        let dt: [(LingShuBrainRoutingSignals, BT, String)] = [
            (sig(.question), .weak, "纯问→0→weak"),
            (sig(.unknown), .weak, "unknown→0→weak"),
            (sig(.interaction), .weak, "互动→1→weak"),
            (sig(.task), .medium, "task→2→medium"),
            (sig(.task, c: 1), .medium, "task+1约束→3→medium"),
            (sig(.task, c: 3, cr: 3), .strong, "task+约束3+标准3→8→strong"),
            (sig(.task, gap: true), .medium, "task+阻断→4→medium"),
            (sig(.task, c: 2, cr: 2), .strong, "2+2+2=6→strong"),
            (sig(.task, esc: 1), .medium, "task+升1→5→medium"),
            (sig(.task, esc: 2), .strong, "task+升2→8→strong"),
            (sig(.question, esc: 2), .strong, "问+升2→6→strong"),
            (sig(.question, esc: 1), .medium, "问+升1→0+3=3→medium"),
            (sig(.task, c: 10), .medium, "约束封顶3→2+3=5→medium"),
            (sig(.task, cr: 10), .medium, "标准封顶3→5→medium"),
            (sig(.task, c: 10, cr: 10), .strong, "都封顶→2+3+3=8→strong"),
            (sig(.interaction, gap: true), .medium, "互动+阻断→3→medium"),
            (sig(.question, gap: true), .medium, "问+阻断→2→medium"),
            (sig(.task, c: 1, cr: 1), .medium, "2+1+1=4→medium"),
            (sig(.task, c: 2, cr: 1, gap: true), .strong, "2+2+1+2=7→strong"),
            (sig(.question, c: 3, cr: 3), .strong, "0+3+3=6→strong"),
            (sig(.question, c: 1), .weak, "0+1=1→weak"),
            (sig(.question, cr: 1), .weak, "0+1=1→weak"),
            (sig(.interaction, c: 1), .medium, "1+1=2→medium"),
            (sig(.task, c: -5), .medium, "负约束当0→2→medium"),
            (sig(.question, esc: -3), .weak, "负升级当0→0→weak")
        ]
        for (s, e, msg) in dt {
            XCTAssertEqual(BR.desiredTier(s), e, msg)
            n += 1
        }

        // —— E. resolve 降级(20 case)——
        let res: [(BT, [BT], BT, String)] = [
            (.strong, [.weak, .medium, .strong], .strong, "理想档可用→用它"),
            (.strong, [.weak, .medium], .medium, "理想缺→降到次高可用"),
            (.strong, [.weak], .weak, "只有弱→弱"),
            (.medium, [.strong], .strong, "只有更强→退用最低可用(=strong)"),
            (.weak, [.medium, .strong], .medium, "理想最弱但只配更强→最低可用"),
            (.weak, [.weak], .weak, "弱可用→弱"),
            (.strong, [], .strong, "空可用→透传理想档"),
            (.medium, [], .medium, "空→透传"),
            (.weak, [], .weak, "空→透传"),
            (.medium, [.weak, .strong], .weak, "≤中只有弱→弱"),
            (.medium, [.weak, .medium], .medium, "≤中取最高=中"),
            (.medium, [.medium], .medium, "正好中"),
            (.strong, [.medium], .medium, "≤强取中"),
            (.strong, [.strong], .strong, "正好强"),
            (.weak, [.strong], .strong, "只配强→退用强"),
            (.medium, [.weak], .weak, "≤中只有弱"),
            (.strong, [.weak, .strong], .strong, "≤强取强"),
            (.weak, [.weak, .medium, .strong], .weak, "≤弱取弱"),
            (.medium, [.weak, .medium, .strong], .medium, "≤中取中"),
            (.strong, [.medium, .strong], .strong, "≤强取强")
        ]
        for (d, av, e, msg) in res {
            XCTAssertEqual(BR.resolve(desired: d, available: av), e, msg)
            n += 1
        }

        // —— F. route 端到端(8 case)——
        XCTAssertEqual(BR.route(sig(.task, c: 3, cr: 3), available: [.weak, .medium]), .medium, "复杂任务但只配弱中→中"); n += 1
        XCTAssertEqual(BR.route(sig(.question), available: [.weak, .medium, .strong]), .weak, "纯问→弱"); n += 1
        XCTAssertEqual(BR.route(sig(.task, esc: 2), available: [.strong]), .strong); n += 1
        XCTAssertEqual(BR.route(sig(.task), available: []), .medium, "空可用→理想档透传"); n += 1
        XCTAssertEqual(BR.route(sig(.question), available: [.strong]), .strong, "弱理想但只配强→退用强"); n += 1
        XCTAssertEqual(BR.route(sig(.task, c: 3, cr: 3, gap: true), available: [.weak, .medium, .strong]), .strong); n += 1
        XCTAssertEqual(BR.route(sig(.interaction), available: [.weak]), .weak); n += 1
        XCTAssertEqual(BT.strong.rank > BT.medium.rank, true); n += 1
        XCTAssertEqual(BT.medium.rank > BT.weak.rank, true); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "P5 覆盖应 ≥100 case,实际 \(n)")
    }
}
