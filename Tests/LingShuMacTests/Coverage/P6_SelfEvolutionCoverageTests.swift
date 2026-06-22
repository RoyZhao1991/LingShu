import XCTest
@testable import LingShuMac

/// 通用中枢 **P6 自我进化 + P6+ 无界自进化(变体注册表/编译核心变体)**全覆盖(100 case):
/// 弱点聚类挖掘 + 有界建议 + 变体注册/切换/回退/删除/活跃 payload + 编译核心组合器解析与组合。纯逻辑无模型。
final class P6_SelfEvolutionCoverageTests: XCTestCase {

    private func exp(_ obj: String, _ outcome: String) -> LingShuGoalExperience {
        LingShuGoalExperience(objective: obj, kind: "task", outcome: outcome, lesson: "L")
    }

    func testSelfEvolution_100Cases() {
        var n = 0

        // —— A. 弱点挖掘 detectPatterns(20 case)——
        let notionFails = [exp("把待办同步到Notion数据库", "失败"), exp("同步今日待办到Notion", "未达标"),
                           exp("把笔记同步到Notion", "部分完成")]
        let p1 = LingShuSelfImprovementMiner.detectPatterns(notionFails)
        XCTAssertEqual(p1.count, 1, "3条Notion失败聚成1簇"); n += 1
        XCTAssertEqual(p1.first?.occurrences, 3); n += 1
        XCTAssertTrue(p1.first?.theme.contains("Notion") ?? false); n += 1
        XCTAssertFalse(p1.first?.sampleLessons.isEmpty ?? true); n += 1
        // 成功的不计
        let withSucc = notionFails + [exp("写斐波那契", "已完成"), exp("查天气", "已核验完成")]
        XCTAssertEqual(LingShuSelfImprovementMiner.detectPatterns(withSucc).count, 1, "成功经验不计入弱点"); n += 1
        // 不足阈值
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns([exp("做PPT", "失败")]).isEmpty, "单条<2不成簇"); n += 1
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns([exp("做PPT", "失败"), exp("查天气", "未达标")]).isEmpty, "互不相似各1次"); n += 1
        // minOccurrences 自定义
        XCTAssertEqual(LingShuSelfImprovementMiner.detectPatterns([exp("做PPT", "失败")], minOccurrences: 1).count, 1, "阈值1→单条也成簇"); n += 1
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns(notionFails, minOccurrences: 4).isEmpty, "阈值4→3条不够"); n += 1
        // 空库
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns([]).isEmpty); n += 1
        // 多簇 + 排序(大簇在前)
        let multi = notionFails + notionFails + [exp("做季度PPT", "失败"), exp("做季度汇报PPT", "未达标")]
        let pm = LingShuSelfImprovementMiner.detectPatterns(multi)
        XCTAssertGreaterThanOrEqual(pm.count, 2, "Notion簇 + PPT簇"); n += 1
        XCTAssertGreaterThanOrEqual(pm[0].occurrences, pm.count >= 2 ? pm[1].occurrences : 0, "大簇排前"); n += 1
        // clusterThreshold 影响
        XCTAssertGreaterThanOrEqual(LingShuSelfImprovementMiner.detectPatterns(notionFails, clusterThreshold: 0.1).count, 1); n += 1
        // 全成功→无弱点
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns([exp("a", "已完成"), exp("b", "已核验完成")]).isEmpty); n += 1
        // 各失败态都算非成功
        for o in ["失败", "未达标", "部分完成"] {
            let pts = LingShuSelfImprovementMiner.detectPatterns([exp("同一个目标X", o), exp("同一个目标X", o)])
            XCTAssertEqual(pts.count, 1, "\(o) 算非成功"); n += 1
        }
        XCTAssertTrue(LingShuSelfImprovementMiner.detectPatterns([exp("X", "已直接回答"), exp("X", "已直接回答")]).isEmpty, "已直接回答=成功不计"); n += 1
        XCTAssertEqual(LingShuSelfImprovementMiner.detectPatterns(notionFails).first?.sampleLessons.count, 3, "样本教训≤3取3"); n += 1

        // —— B. 有界建议 suggestion(6 case)——
        let pat = LingShuImprovementPattern(theme: "同步到Notion", occurrences: 3, sampleLessons: ["缺token", "没共享"])
        let s = LingShuSelfImprovementMiner.suggestion(for: pat)
        XCTAssertTrue(s.contains("沙箱"), "走M1沙箱"); n += 1
        XCTAssertTrue(s.contains("安全门")); n += 1
        XCTAssertTrue(s.contains("批准"), "人批后建"); n += 1
        XCTAssertTrue(s.contains("回滚")); n += 1
        XCTAssertTrue(s.contains("Notion"), "含主题"); n += 1
        XCTAssertTrue(s.contains("3"), "含次数"); n += 1

        // —— C. 模块变体注册表(40 case)——
        var reg = LingShuModuleVariantRegistry()
        // 首注册=活跃基线
        let base = LingShuModuleVariant(slotID: "s", label: "基线", source: "baseline", payload: "B")
        reg.register(base)
        XCTAssertEqual(reg.activeVariant(slotID: "s")?.id, base.id); n += 1
        XCTAssertEqual(reg.activePayload(slotID: "s"), "B"); n += 1
        XCTAssertEqual(reg.variants(slotID: "s").count, 1); n += 1
        // 注册更多(inactive)
        let v2 = LingShuModuleVariant(slotID: "s", label: "v2", source: "authored", payload: "V2")
        let v3 = LingShuModuleVariant(slotID: "s", label: "v3", source: "manual", payload: "V3")
        reg.register(v2); reg.register(v3)
        XCTAssertEqual(reg.activePayload(slotID: "s"), "B", "注册不改活跃"); n += 1
        XCTAssertEqual(reg.variants(slotID: "s").count, 3); n += 1
        // 幂等注册(同 id)
        reg.register(v2)
        XCTAssertEqual(reg.variants(slotID: "s").count, 3, "同id幂等"); n += 1
        // 切换
        XCTAssertTrue(reg.switchActive(slotID: "s", to: v2.id)); n += 1
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V2"); n += 1
        XCTAssertTrue(reg.switchActive(slotID: "s", to: v3.id)); n += 1
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V3"); n += 1
        // 切到未知失败
        XCTAssertFalse(reg.switchActive(slotID: "s", to: "nope")); n += 1
        XCTAssertFalse(reg.switchActive(slotID: "无槽", to: v2.id)); n += 1
        // 切到当前活跃=幂等 true
        XCTAssertTrue(reg.switchActive(slotID: "s", to: v3.id), "切到当前活跃→true"); n += 1
        // 回退(历史栈 v3←v2←base)
        XCTAssertEqual(reg.rollback(slotID: "s"), v2.id, "回退到上一活跃v2"); n += 1
        XCTAssertEqual(reg.activePayload(slotID: "s"), "V2"); n += 1
        XCTAssertEqual(reg.rollback(slotID: "s"), base.id, "再回退到base"); n += 1
        XCTAssertEqual(reg.activePayload(slotID: "s"), "B"); n += 1
        // 历史空→回基线
        XCTAssertEqual(reg.rollback(slotID: "s"), base.id, "历史空→回基线(不崩)"); n += 1
        XCTAssertNil(reg.rollback(slotID: "空槽"), "无槽→nil"); n += 1
        // 删除:基线不可删
        reg.switchActive(slotID: "s", to: v3.id)   // 活跃=v3
        XCTAssertFalse(reg.remove(slotID: "s", variantID: base.id), "基线不可删"); n += 1
        XCTAssertFalse(reg.remove(slotID: "s", variantID: v3.id), "活跃不可删"); n += 1
        XCTAssertTrue(reg.remove(slotID: "s", variantID: v2.id), "非活跃自进化可删"); n += 1
        XCTAssertEqual(reg.variants(slotID: "s").count, 2); n += 1
        XCTAssertFalse(reg.remove(slotID: "s", variantID: "unknown"), "未知id删除失败"); n += 1
        XCTAssertFalse(reg.remove(slotID: "空槽", variantID: v2.id), "无槽删除失败"); n += 1
        // 删后回退仍安全
        XCTAssertNotNil(reg.rollback(slotID: "s")); n += 1
        // 多槽位隔离
        var reg2 = LingShuModuleVariantRegistry()
        reg2.register(.init(slotID: "A", label: "a", source: "baseline", payload: "PA"))
        reg2.register(.init(slotID: "B", label: "b", source: "baseline", payload: "PB"))
        XCTAssertEqual(reg2.activePayload(slotID: "A"), "PA"); n += 1
        XCTAssertEqual(reg2.activePayload(slotID: "B"), "PB"); n += 1
        XCTAssertNil(reg2.activePayload(slotID: "C"), "无槽→nil payload"); n += 1
        XCTAssertEqual(reg2.variants(slotID: "C").count, 0); n += 1
        // activate=true 注册即切活跃 + 记历史
        var reg3 = LingShuModuleVariantRegistry()
        let b3 = LingShuModuleVariant(slotID: "s", label: "base", source: "baseline", payload: "B0")
        let a3 = LingShuModuleVariant(slotID: "s", label: "a", source: "authored", payload: "A0")
        reg3.register(b3); reg3.register(a3, activate: true)
        XCTAssertEqual(reg3.activePayload(slotID: "s"), "A0", "activate→切活跃"); n += 1
        XCTAssertEqual(reg3.rollback(slotID: "s"), b3.id, "回退到记录的base"); n += 1
        // Codable round-trip
        let data = try! JSONEncoder().encode(reg3)
        let back = try! JSONDecoder().decode(LingShuModuleVariantRegistry.self, from: data)
        XCTAssertEqual(back.activePayload(slotID: "s"), reg3.activePayload(slotID: "s"), "Codable 往返"); n += 1
        XCTAssertEqual(back.variants(slotID: "s").count, 2); n += 1
        // 变体 Identifiable / Equatable
        XCTAssertEqual(v2, v2); n += 1
        XCTAssertNotEqual(v2.id, v3.id); n += 1
        // 注册到不同槽不互窜
        var reg4 = LingShuModuleVariantRegistry()
        reg4.register(.init(slotID: "x", label: "x1", source: "baseline", payload: "X1"))
        reg4.register(.init(slotID: "y", label: "y1", source: "baseline", payload: "Y1"))
        reg4.register(.init(slotID: "x", label: "x2", source: "manual", payload: "X2"))
        XCTAssertEqual(reg4.variants(slotID: "x").count, 2); n += 1
        XCTAssertEqual(reg4.variants(slotID: "y").count, 1); n += 1

        // —— D. 编译核心组合器(25 case)——
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve(nil)).key, "append", "默认 append"); n += 1
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("")).key, "append"); n += 1
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("append")).key, "append"); n += 1
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("prepend")).key, "prepend"); n += 1
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("nope")).key, "append", "未知→append"); n += 1
        XCTAssertEqual(type(of: LingShuGuidanceComposers.resolve("  prepend  ")).key, "prepend", "去空白"); n += 1
        XCTAssertEqual(Set(LingShuGuidanceComposers.availableKeys), ["append", "prepend"]); n += 1
        let ap = LingShuGuidanceComposers.resolve("append")
        let pp = LingShuGuidanceComposers.resolve("prepend")
        XCTAssertEqual(ap.compose(experience: "E", strategy: "S"), "E\n\nS"); n += 1
        XCTAssertEqual(pp.compose(experience: "E", strategy: "S"), "S\n\nE"); n += 1
        XCTAssertEqual(ap.compose(experience: "E", strategy: ""), "E", "策略空→只经验"); n += 1
        XCTAssertEqual(ap.compose(experience: "", strategy: "S"), "S", "经验空→只策略"); n += 1
        XCTAssertEqual(pp.compose(experience: "E", strategy: ""), "E"); n += 1
        XCTAssertEqual(pp.compose(experience: "", strategy: "S"), "S"); n += 1
        XCTAssertEqual(ap.compose(experience: "  ", strategy: "  "), "", "都空→空"); n += 1
        XCTAssertEqual(pp.compose(experience: "  ", strategy: "  "), ""); n += 1
        XCTAssertNotEqual(ap.compose(experience: "E", strategy: "S"), pp.compose(experience: "E", strategy: "S"), "两变体顺序不同"); n += 1
        XCTAssertTrue(ap.compose(experience: "E", strategy: "S").hasPrefix("E")); n += 1
        XCTAssertTrue(pp.compose(experience: "E", strategy: "S").hasPrefix("S")); n += 1
        XCTAssertEqual(ap.compose(experience: "多行\n经验", strategy: "策略"), "多行\n经验\n\n策略"); n += 1
        XCTAssertEqual(LingShuGuidanceComposers.all.count, 2, "两个已编译变体"); n += 1
        XCTAssertEqual(LingShuAppendStrategyComposer.key, "append"); n += 1
        XCTAssertEqual(LingShuPrependStrategyComposer.key, "prepend"); n += 1
        XCTAssertEqual(ap.compose(experience: "x", strategy: "y").contains("\n\n"), true, "非空两段用空行分隔"); n += 1
        XCTAssertEqual(ap.compose(experience: "single", strategy: "").contains("\n\n"), false, "单段无分隔"); n += 1

        // —— E. 槽位元信息(6 case)——
        XCTAssertEqual(LingShuModuleSlots.all.count, 4, "4个可进化槽位"); n += 1
        XCTAssertTrue(LingShuModuleSlots.all.contains(LingShuModuleSlots.executionGuidance)); n += 1
        XCTAssertTrue(LingShuModuleSlots.all.contains(LingShuModuleSlots.personaStrategy)); n += 1
        XCTAssertTrue(LingShuModuleSlots.all.contains(LingShuModuleSlots.acquisitionCeiling)); n += 1
        XCTAssertTrue(LingShuModuleSlots.all.contains(LingShuModuleSlots.guidanceAssembly)); n += 1
        XCTAssertFalse(LingShuModuleSlots.label(LingShuModuleSlots.guidanceAssembly).isEmpty); n += 1

        // —— F. 补充:更多变体注册/组合器一致性(12 case)——
        var reg5 = LingShuModuleVariantRegistry()
        for i in 1...5 {
            reg5.register(.init(slotID: "loop", label: "v\(i)", source: i == 1 ? "baseline" : "authored", payload: "P\(i)"))
        }
        XCTAssertEqual(reg5.variants(slotID: "loop").count, 5); n += 1
        XCTAssertEqual(reg5.activePayload(slotID: "loop"), "P1", "首注册=活跃基线"); n += 1
        let ids = reg5.variants(slotID: "loop").map(\.id)
        XCTAssertTrue(reg5.switchActive(slotID: "loop", to: ids[4])); n += 1
        XCTAssertEqual(reg5.activePayload(slotID: "loop"), "P5"); n += 1
        XCTAssertTrue(reg5.switchActive(slotID: "loop", to: ids[2])); n += 1
        XCTAssertEqual(reg5.rollback(slotID: "loop"), ids[4], "回退到上一活跃"); n += 1
        XCTAssertTrue(reg5.remove(slotID: "loop", variantID: ids[1]), "删非活跃非基线"); n += 1
        XCTAssertEqual(reg5.variants(slotID: "loop").count, 4); n += 1
        // 组合器对长文本稳定
        for (e, s) in [("经验A", "策略B"), ("x", "y"), ("线1\n线2", "策")] {
            let out = LingShuGuidanceComposers.resolve("append").compose(experience: e, strategy: s)
            XCTAssertTrue(out.contains(e) && out.contains(s), "append 含两段"); n += 1
        }
        XCTAssertEqual(LingShuGuidanceComposers.availableKeys.count, 2); n += 1

        XCTAssertGreaterThanOrEqual(n, 100, "P6 覆盖应 ≥100 case,实际 \(n)")
    }
}
