import XCTest
@testable import LingShuMac

/// 语音"有意义性"判定纯逻辑测试:无意义(语气词/标点/噪声)放弃,真内容(含单字命令)放行。
final class UtteranceMeaningTests: XCTestCase {

    func testMeaninglessDropped() {
        for junk in ["", "  ", "嗯", "啊", "嗯嗯", "嗯，啊", "。。。", "?", "！", "um", "uh", "Hmm", "  oh  ", "呃……"] {
            XCTAssertFalse(LingShuUtteranceMeaning.isMeaningful(junk), "应判无意义: 「\(junk)」")
        }
    }

    func testMeaningfulKept() {
        for ok in ["停", "好", "对", "不", "帮我订个会议室", "灵枢你好", "嗯好的", "今天天气怎么样", "ok", "打开浏览器"] {
            XCTAssertTrue(LingShuUtteranceMeaning.isMeaningful(ok), "应判有意义: 「\(ok)」")
        }
    }

    func testFillerPrefixStillMeaningful() {
        // 语气词开头但含真内容 → 保留。
        XCTAssertTrue(LingShuUtteranceMeaning.isMeaningful("嗯，帮我查一下"))
        XCTAssertTrue(LingShuUtteranceMeaning.isMeaningful("啊对，提醒我五点开会"))
    }
}
