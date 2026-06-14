import XCTest
@testable import LingShuMac

/// 自进化 PPT 模块 · DesignKB 设计知识库:定位、种子数据齐备、版式/配色注册表可读。
final class DesignKBTests: XCTestCase {
    func testDesignKBResolvesAndHasGenerator() {
        XCTAssertNotNil(LingShuDesignKB.directoryURL(), "应能定位 DesignKB(包内或开发源码树)")
        XCTAssertNotNil(LingShuDesignKB.generatorPath, "DesignKB 应带 generator.py")
    }

    func testLayoutAndPaletteRegistriesPopulated() {
        let layouts = LingShuDesignKB.layoutIDs()
        let palettes = LingShuDesignKB.paletteIDs()
        // 关键版式原型必须齐备(封面/章节/要点/图文/数字/图表/收尾)。
        XCTAssertTrue(Set(layouts).isSuperset(of: ["cover", "section", "bullets", "image-right", "bignumber", "chart", "closing"]),
                      "版式原型库应覆盖核心版式,实得:\(layouts)")
        XCTAssertGreaterThanOrEqual(palettes.count, 4, "配色库应有多套专业配色,实得:\(palettes)")
        XCTAssertNotNil(LingShuDesignKB.rubricText(), "应带设计质量评审 rubric")
    }
}
