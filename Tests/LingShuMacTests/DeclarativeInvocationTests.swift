import XCTest
@testable import LingShuMac

/// 声明式调插件识别守卫(纯逻辑):`@别名`/`用别名[插件]`/`/别名` → (插件id, 余下输入);自然语句不误命中。
final class DeclarativeInvocationTests: XCTestCase {

    private let plugins: [LingShuInvocablePlugin] = [
        .init(id: "present", displayName: "演示与答疑", aliases: ["演示", "讲解", "present"], subtitle: "", icon: ""),
        .init(id: "record", displayName: "录制技能", aliases: ["录制", "记录技能"], subtitle: "", icon: ""),
    ]

    func testAtPrefix() {
        let r = LingShuDeclarativeInvocation.detect("@演示 /tmp/a.pdf", plugins: plugins)
        XCTAssertEqual(r?.id, "present")
        XCTAssertEqual(r?.rest, "/tmp/a.pdf")
    }

    func testUsePrefix() {
        XCTAssertEqual(LingShuDeclarativeInvocation.detect("用演示插件 讲一下 /tmp/x.pdf", plugins: plugins)?.id, "present")
        XCTAssertEqual(LingShuDeclarativeInvocation.detect("用演示插件 讲一下 /tmp/x.pdf", plugins: plugins)?.rest, "讲一下 /tmp/x.pdf")
    }

    func testLongestAliasWins() {
        // 「录制技能」(displayName,长)应优先于「录制」(短),rest 不残留「技能」。
        let r = LingShuDeclarativeInvocation.detect("用录制技能 报销", plugins: plugins)
        XCTAssertEqual(r?.id, "record")
        XCTAssertEqual(r?.rest, "报销")
    }

    func testSlashPrefix() {
        XCTAssertEqual(LingShuDeclarativeInvocation.detect("/present /tmp/a.pdf", plugins: plugins)?.id, "present")
    }

    func testNaturalSentenceNotMatched() {
        // 自然语句无显式声明前缀 → 不拦(交常规分诊/关键词路由)。
        XCTAssertNil(LingShuDeclarativeInvocation.detect("演示这个文档", plugins: plugins))
        XCTAssertNil(LingShuDeclarativeInvocation.detect("帮我改一下报销单", plugins: plugins))
    }
}
