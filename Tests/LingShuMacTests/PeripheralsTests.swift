import XCTest
@testable import LingShuMac

/// # 统一外设 + 大脑识别/归类测试(所有东西都是外设;别名/能力/归一/接入路由大脑判,壳不硬编码)
final class PeripheralsTests: XCTestCase {

    private func cls(access: String, integratable: Bool, canonical: String = "", alias: String = "", deviceType: String = "", caps: [String] = []) -> LingShuPeripheralClassification {
        .init(canonical: canonical, alias: alias, what: "w", deviceType: deviceType, capabilities: caps, access: access, integratable: integratable, note: "n")
    }

    func testAutoAdoptableNeedsIntegratableAndOpenAccess() {
        XCTAssertTrue(cls(access: "open_local", integratable: true).autoAdoptable)
        XCTAssertTrue(cls(access: "airplay", integratable: true).autoAdoptable)
        XCTAssertFalse(cls(access: "open_local", integratable: false).autoAdoptable, "不可接入 → 不自动")
        XCTAssertFalse(cls(access: "homekit", integratable: true).autoAdoptable)
        XCTAssertFalse(cls(access: "needs_code", integratable: true).autoAdoptable)
    }

    func testDisplayNameUsesAliasAndGroupUsesDeviceType() {
        var p = LingShuPeripheral(id: "net/CozyLife_IST0", name: "CozyLife_IST0", transport: .network, raw: "_hap._tcp", statusLine: "s", builtinActions: [], classification: nil)
        XCTAssertEqual(p.displayName, "CozyLife_IST0", "未识别用原始名")
        XCTAssertEqual(p.displayGroup, LingShuPeripheralTransport.network.placeholderGroup.zh)
        XCTAssertFalse(p.isControllable, "未接入不算可控(不再用大脑乐观猜测)")
        p.classification = cls(access: "open_local", integratable: true, canonical: "light-bedside", alias: "床头灯", deviceType: "灯", caps: ["开关","亮度"])
        XCTAssertEqual(p.displayName, "床头灯", "识别后显示语义别名")
        XCTAssertEqual(p.displayGroup, "灯")
        XCTAssertEqual(p.canonicalKey, "light-bedside")
        XCTAssertFalse(p.isControllable, "可接入≠已接入,仍不可控")
        p.integrated = true
        XCTAssertTrue(p.isControllable, "真接入后才可控")
    }

    func testCanonicalMergesMultiChannel() {
        // 同一音箱多通道 → 大脑给相同 canonical → 合并键相同(壳据此合并成一台)。
        let a = LingShuPeripheral(id: "net/卧室", name: "卧室", transport: .network, raw: "_airplay._tcp", statusLine: "", builtinActions: [], classification: cls(access: "airplay", integratable: true, canonical: "speaker-bedroom"))
        let b = LingShuPeripheral(id: "net/卧室", name: "卧室", transport: .network, raw: "_raop._tcp", statusLine: "", builtinActions: [], classification: cls(access: "airplay", integratable: true, canonical: "speaker-bedroom"))
        XCTAssertEqual(a.canonicalKey, b.canonicalKey, "多通道同一 canonical → 归一")
    }

    func testParseBrainClassifications() {
        let json = """
        [{"id":"net/卧室","canonical":"speaker-bedroom","alias":"卧室音箱","what":"HomePod","deviceType":"音箱","capabilities":["音频输出","音频输入"],"access":"airplay","integratable":true,"note":"pyatv"},
         {"id":"net/CozyLife_IST0","canonical":"light-bedside","alias":"床头灯","what":"CozyLife灯","deviceType":"灯","capabilities":["开关","亮度","色温"],"access":"open_local","integratable":true,"note":"本地协议可自写"}]
        """
        let map = LingShuState.parsePeripheralClassifications(json)
        XCTAssertEqual(map.count, 2)
        XCTAssertEqual(map["net/CozyLife_IST0"]?.alias, "床头灯")
        XCTAssertEqual(map["net/CozyLife_IST0"]?.deviceType, "灯")
        XCTAssertEqual(map["net/CozyLife_IST0"]?.capabilities, ["开关","亮度","色温"])
        XCTAssertTrue(map["net/CozyLife_IST0"]?.autoAdoptable ?? false)
        XCTAssertEqual(map["net/卧室"]?.capabilities.count, 2, "多能力(输入+输出)折在一台")
    }

    func testParseRejectsGarbage() {
        XCTAssertTrue(LingShuState.parsePeripheralClassifications("没有 JSON").isEmpty)
    }

    /// §4 #4:已接入由**大脑判**(integrated:true),取代壳里 actuator_target↔名称子串匹配。
    func testParseIntegratedPeripheralIDs() {
        let json = """
        [{"id":"net/CozyLife_IST0","alias":"床头灯","integratable":true,"integrated":true},
         {"id":"net/卧室","alias":"卧室音箱","integratable":true,"integrated":false},
         {"id":"bt/mouse","alias":"鼠标","integratable":false}]
        """
        let ids = LingShuState.parseIntegratedPeripheralIDs(json)
        XCTAssertEqual(ids, ["net/CozyLife_IST0"], "只收大脑判 integrated:true 的;缺字段=未接入")
        XCTAssertTrue(LingShuState.parseIntegratedPeripheralIDs("垃圾").isEmpty)
    }
}
