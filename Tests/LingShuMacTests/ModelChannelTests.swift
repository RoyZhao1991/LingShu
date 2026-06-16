import XCTest
@testable import LingShuMac

/// 类型化能力通道:通道 key 规则 + 校验状态可持久化(Codable 往返)。
/// 校验逻辑本身(ping/测试图)是真实网络调用,不进离线单测;这里保通道身份与状态序列化稳定。
final class ModelChannelTests: XCTestCase {

    func testChannelKeysAreStable() {
        XCTAssertEqual(LingShuState.brainChannelKey("DeepSeek"), "brain:DeepSeek")
        XCTAssertEqual(LingShuState.ttsChannelKey("datanet-speaker-tts"), "tts:datanet-speaker-tts")
        XCTAssertEqual(LingShuState.visionChannelKey, "vision:datanet")
        XCTAssertEqual(LingShuState.videoChannelKey, "video:datanet")
        XCTAssertEqual(LingShuState.asrLocalChannelKey, "asr:local")
    }

    func testValidationStateCodableRoundTrips() throws {
        let now = Date()
        let map: [String: LingShuChannelValidation] = [
            LingShuState.brainChannelKey("DeepSeek"): .init(ok: true, detail: "校验通过 · 模型有回复", at: now),
            LingShuState.visionChannelKey: .init(ok: false, detail: "VL 调用失败", at: now)
        ]
        let data = try JSONEncoder().encode(map)
        let decoded = try JSONDecoder().decode([String: LingShuChannelValidation].self, from: data)
        XCTAssertEqual(decoded[LingShuState.brainChannelKey("DeepSeek")]?.ok, true)
        XCTAssertEqual(decoded[LingShuState.visionChannelKey]?.ok, false)
        XCTAssertEqual(decoded[LingShuState.visionChannelKey]?.detail, "VL 调用失败")
    }
}
