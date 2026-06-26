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

    func testDetectChainMultiAgent() {
        let agents: [LingShuInvocablePlugin] = [
            .init(id: "codex", displayName: "Codex", aliases: ["codex"], subtitle: "", icon: "", kind: .agent),
            .init(id: "claude", displayName: "Claude", aliases: ["claude"], subtitle: "", icon: "", kind: .agent),
        ]
        let chain = LingShuDeclarativeInvocation.detectChain("@Codex 开发一个清分结算系统 @Claude 进行验收", plugins: agents)
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0].id, "codex")
        XCTAssertEqual(chain[0].segment, "开发一个清分结算系统")
        XCTAssertEqual(chain[1].id, "claude")
        XCTAssertEqual(chain[1].segment, "进行验收")
    }

    func testDetectChainSingle() {
        let chain = LingShuDeclarativeInvocation.detectChain("@演示 /tmp/a.pdf", plugins: plugins)
        XCTAssertEqual(chain.count, 1)
        XCTAssertEqual(chain[0].id, "present")
        XCTAssertEqual(chain[0].segment, "/tmp/a.pdf")
    }

    /// 验收门:agent 输出「没权限/只读」信号识别(声明式调 agent 的授权兜底据此触发)。
    func testAgentOutputLacksPermissionDetection() {
        // 复现 codex 的真实只读反馈。
        XCTAssertTrue(LingShuState.agentOutputLacksPermission("当前环境是只读的，我无法直接在 /Users/example/app 里创建文件。"))
        XCTAssertTrue(LingShuState.agentOutputLacksPermission("Error: read-only file system"))
        XCTAssertTrue(LingShuState.agentOutputLacksPermission("mkdir: permission denied"))
        XCTAssertTrue(LingShuState.agentOutputLacksPermission("没有写入权限,无法创建文件"))
        // 正常成功输出不应误判。
        XCTAssertFalse(LingShuState.agentOutputLacksPermission("已创建 tank.html,浏览器打开即可玩。"))
        XCTAssertFalse(LingShuState.agentOutputLacksPermission("做好了,文件写到 /Users/example/app/tank.html,跑测试全绿。"))
    }


}
