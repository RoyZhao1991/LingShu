import XCTest
@testable import LingShuMac

/// 各通道账号余额查询的按厂商适配(2026-06-28 用户要的"余额显示口子")。守住:支持的厂商解析正确、不支持的不显示、请求构造带 Bearer。
final class ChannelBalanceTests: XCTestCase {

    func testDeepSeekParse() {
        let data = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"110.50","granted_balance":"0.00","topped_up_balance":"110.50"}]}"#.data(using: .utf8)!
        let r = LingShuChannelBalance.parse(provider: "DeepSeek", data: data)
        XCTAssertEqual(r?.display, "¥110.50")
        XCTAssertEqual(r?.available, true)
    }

    func testDeepSeekZeroBalanceNotAvailable() {
        let data = #"{"is_available":false,"balance_infos":[{"currency":"USD","total_balance":"0.00"}]}"#.data(using: .utf8)!
        let r = LingShuChannelBalance.parse(provider: "DeepSeek", data: data)
        XCTAssertEqual(r?.display, "$0.00")
        XCTAssertEqual(r?.available, false)
    }

    func testOpenRouterRemaining() {
        let data = #"{"data":{"label":"sk-or","usage":0.5,"limit":10,"limit_remaining":9.5,"is_free_tier":false}}"#.data(using: .utf8)!
        let r = LingShuChannelBalance.parse(provider: "OpenRouter", data: data)
        XCTAssertEqual(r?.display, "$9.50 剩余")
        XCTAssertEqual(r?.available, true)
    }

    func testOpenRouterUnlimited() {
        let data = #"{"data":{"usage":2.5,"limit":null,"limit_remaining":null}}"#.data(using: .utf8)!
        let r = LingShuChannelBalance.parse(provider: "OpenRouter", data: data)
        XCTAssertEqual(r?.display, "已用 $2.50 · 无限额")
        XCTAssertEqual(r?.available, true)
    }

    func testUnsupportedProviderNoBalance() {
        XCTAssertFalse(LingShuChannelBalance.isSupported(provider: "Anthropic Claude"))
        XCTAssertFalse(LingShuChannelBalance.isSupported(provider: "MiniMax 官方"))
        XCTAssertNil(LingShuChannelBalance.request(provider: "Anthropic Claude", apiKey: "k"))
        XCTAssertTrue(LingShuChannelBalance.isSupported(provider: "DeepSeek"))
    }

    func testRequestHasBearerAndCorrectURL() {
        let req = LingShuChannelBalance.request(provider: "DeepSeek", apiKey: "sk-x")
        XCTAssertEqual(req?.url?.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(req?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
        XCTAssertNil(LingShuChannelBalance.request(provider: "DeepSeek", apiKey: "  "), "空 key 不构造请求")
    }
}
