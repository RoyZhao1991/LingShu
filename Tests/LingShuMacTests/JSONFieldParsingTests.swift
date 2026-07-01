import XCTest
@testable import LingShuMac

/// `LingShuState.jsonField` 守卫:大模型常把 page/index/lines/on 这类字段出成 **JSON 数字/布尔**
/// (`{"page":4}` 而非 `{"page":"4"}`),解析器必须照取成字符串——否则 `Int(jsonField(...))` 全线静默回退默认值。
/// 根因实测:演示中"从第四页开始演示",大脑出 `{"intent":"seek","page":4}`,旧 `as? String` 把 page 读成 nil → 误追问页号。
final class JSONFieldParsingTests: XCTestCase {

    func testParsesStringField() {
        XCTAssertEqual(LingShuState.jsonField("{\"page\":\"4\"}", "page"), "4")
    }

    /// **核心回归**:数字字段(大脑被要求"出阿拉伯整数"时必然出数字)也要能取到。
    func testParsesIntegerNumberField() {
        XCTAssertEqual(LingShuState.jsonField("{\"intent\":\"seek\",\"page\":4}", "page"), "4")
        XCTAssertEqual(Int(LingShuState.jsonField("{\"page\":4}", "page") ?? ""), 4, "Int(...) 链路读得出 4")
    }

    func testParsesDecimalNumberField() {
        XCTAssertEqual(LingShuState.jsonField("{\"v\":4.5}", "v"), "4.5")
    }

    /// 布尔回 "true"/"false"(不是 "1"/"0")——`on` 这类开关调用方据此判定。
    func testParsesBooleanFieldAsWord() {
        XCTAssertEqual(LingShuState.jsonField("{\"on\":true}", "on"), "true")
        XCTAssertEqual(LingShuState.jsonField("{\"on\":false}", "on"), "false")
    }

    func testMissingOrNonScalarReturnsNil() {
        XCTAssertNil(LingShuState.jsonField("{\"page\":4}", "missing"))
        XCTAssertNil(LingShuState.jsonField("{\"obj\":{\"a\":1}}", "obj"), "对象不是标量 → nil")
        XCTAssertNil(LingShuState.jsonField("{\"arr\":[1,2]}", "arr"), "数组不是标量 → nil")
        XCTAssertNil(LingShuState.jsonField("不是JSON", "page"))
    }
}
