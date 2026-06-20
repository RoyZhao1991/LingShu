import XCTest
@testable import LingShuMac

/// # 知识纪律(陈述非祈使)测试 —— 方案 §3.3 的"知识不退化成框架"红线
///
/// 守住:① 陈述性事实/教训准入 ② 祈使/步骤型被拒 ③ 召回措辞恒为"供参考" ④ 园丁落库前真的过这道闸。
final class KnowledgeDisciplineTests: XCTestCase {

    // MARK: - ① 陈述性事实/教训:准入(方案里给的"知识"正例)

    func testDeclarativeFactsAccepted() {
        // CozyLife 协议事实
        XCTAssertTrue(LingShuKnowledgeDiscipline.isDeclarative(
            "CozyLife 灯走局域网 TCP 5555,JSON+\\r\\n,cmd:3 {attr:[1],data:{1:1}} 开/0 关,DP3 亮度 0-1000,DP4 色温"))
        // HomeKit 独占事实
        XCTAssertTrue(LingShuKnowledgeDiscipline.isDeclarative(
            "HomeKit 配件单控制者独占,已进苹果家庭的第三方连不了"))
        // 教训(陈述事实判断 X≠Y,准入——虽含劝诫意味但不是步骤)
        XCTAssertTrue(LingShuKnowledgeDiscipline.isDeclarative(
            "教训:对'接入设备'类请求,写指南文档≠真接入"))
        // 发现手段事实
        XCTAssertTrue(LingShuKnowledgeDiscipline.isDeclarative(
            "dns-sd -B _services._dns-sd._udp 可枚举本网全部 Bonjour 服务类型"))
    }

    // MARK: - ② 祈使/步骤型:拒入(方案里给的"框架"反例)

    func testImperativeProceduresRejected() {
        // 方案点名的反例:"接入设备时先 X 再 Y"
        assertImperative("接入设备时先发现设备,再判断协议,然后写驱动")
        assertImperative("先打开开关,然后设置亮度到 50%")
        assertImperative("第一步扫描局域网,第二步识别设备")
        assertImperative("步骤1:连接;步骤2:鉴权")
        assertImperative("1. 打开开关\n2. 设置亮度\n3. 调色温")
        assertImperative("请先调用 discover_devices 再调用 peripherals")
        assertImperative("务必在接入前先确认配对码")
    }

    private func assertImperative(_ body: String, file: StaticString = #filePath, line: UInt = #line) {
        if case .declarative = LingShuKnowledgeDiscipline.classify(body) {
            XCTFail("应判为祈使/步骤(框架)被拒:\(body)", file: file, line: line)
        }
    }

    // MARK: - ③ 召回措辞恒为"供参考"

    func testRecallDisclaimerWording() {
        XCTAssertTrue(LingShuKnowledgeDiscipline.recallDisclaimer.contains("供参考"))
        XCTAssertTrue(LingShuKnowledgeDiscipline.recallDisclaimer.contains("自行判断"))
        XCTAssertFalse(LingShuKnowledgeDiscipline.recallDisclaimer.contains("必须"), "召回绝不写成规则/必须")
    }

    // MARK: - ④ 园丁落库前真的过这道闸(集成:祈使候选 → .skip,陈述候选 → .create)

    func testGardenerRejectsImperativeCandidate() {
        let imperative = LingShuMemoryGardener.Candidate(
            kind: .skill, title: "接灯流程", body: "先发现设备,再写驱动,然后上线", source: .inference)
        let action = LingShuMemoryGardener.integrate(imperative, into: [])
        guard case .skip(let why) = action else {
            return XCTFail("祈使/步骤候选应被园丁拒入,实得:\(action)")
        }
        XCTAssertTrue(why.contains("祈使") || why.contains("步骤"))
    }

    func testGardenerAcceptsDeclarativeCandidate() {
        let fact = LingShuMemoryGardener.Candidate(
            kind: .fact, title: "CozyLife 协议", body: "CozyLife 灯走局域网 TCP 5555,JSON 帧", source: .tool)
        let action = LingShuMemoryGardener.integrate(fact, into: [])
        guard case .create = action else {
            return XCTFail("陈述性事实应入库(create),实得:\(action)")
        }
    }

    // MARK: - ⑤ P0② 决策知识种子:每条都须是陈述性(过纪律闸),且全部能真入库

    func testSeedKnowledgeAllDeclarativeAndIngestible() {
        var notes: [LingShuMemoryNote] = []
        for seed in LingShuSeedKnowledge.candidates {
            XCTAssertTrue(LingShuKnowledgeDiscipline.isDeclarative(seed.body), "种子知识必须陈述性:\(seed.title)")
            let action = LingShuMemoryGardener.integrate(seed, into: notes)
            guard case .create(let note) = action else {
                return XCTFail("种子「\(seed.title)」应能入库,实得:\(action)")
            }
            notes.append(note)
        }
        XCTAssertEqual(notes.count, LingShuSeedKnowledge.candidates.count, "全部种子都真入库")
        // 含方案点名的几条关键知识
        XCTAssertTrue(notes.contains { $0.title.contains("CozyLife") })
        XCTAssertTrue(notes.contains { $0.body.contains("写指南文档") || $0.body.contains("说明文档") })
    }
}
