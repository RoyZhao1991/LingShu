import XCTest
@testable import LingShuMac

/// 锁死流式 WAV 头解析：服务端 /stream 回的是 `RIFF ffffffff WAVE fmt … data …`（占位长度）。
final class StreamingWAVHeaderTests: XCTestCase {
    private func streamingHeader() -> [UInt8] {
        var b: [UInt8] = []
        b += Array("RIFF".utf8); b += [0xff,0xff,0xff,0xff]; b += Array("WAVE".utf8)
        b += Array("fmt ".utf8); b += [0x10,0x00,0x00,0x00]          // fmt 块长 16
        b += [0x01,0x00, 0x01,0x00]                                   // PCM, 单声道
        b += [0x80,0x3e,0x00,0x00]                                    // 采样率 16000
        b += [0x00,0x7d,0x00,0x00]                                    // byteRate
        b += [0x02,0x00, 0x10,0x00]                                   // blockAlign, 16-bit
        b += Array("data".utf8); b += [0xff,0xff,0xff,0xff]          // data 占位长度
        return b
    }

    func testLocatesSampleRateAndPCMStart() {
        var bytes = streamingHeader()
        bytes += [0x11,0x22,0x33,0x44]   // 一点 PCM
        let located = LingShuStreamingWAVHeader.locate(in: bytes)
        XCTAssertEqual(located?.sampleRate, 16000)
        XCTAssertEqual(located?.pcmStart, 44)   // 标准 PCM WAV 头 44 字节
    }

    func testReturnsNilWhileHeaderIncomplete() {
        // 只到 "fmt "，还没 data 块 → 等更多字节。
        let partial = Array("RIFF".utf8) + [0xff,0xff,0xff,0xff] + Array("WAVE".utf8) + Array("fmt ".utf8)
        XCTAssertNil(LingShuStreamingWAVHeader.locate(in: partial))
    }
}
