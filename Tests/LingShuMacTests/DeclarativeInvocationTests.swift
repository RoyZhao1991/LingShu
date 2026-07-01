import XCTest
@testable import LingShuMac

/// 声明式调插件识别守卫(纯逻辑):只认 `@别名` → (插件id, 余下输入);自然语句不误命中。
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

    func testNaturalUsePrefixNotMatched() {
        XCTAssertNil(LingShuDeclarativeInvocation.detect("用演示插件 讲一下 /tmp/x.pdf", plugins: plugins))
        XCTAssertNil(LingShuDeclarativeInvocation.detect("调用演示 讲一下 /tmp/x.pdf", plugins: plugins))
        XCTAssertNil(LingShuDeclarativeInvocation.detect("切到演示 讲一下 /tmp/x.pdf", plugins: plugins))
    }

    func testLongestAliasWins() {
        // 「录制技能」(displayName,长)应优先于「录制」(短),rest 不残留「技能」。
        let r = LingShuDeclarativeInvocation.detect("@录制技能 报销", plugins: plugins)
        XCTAssertEqual(r?.id, "record")
        XCTAssertEqual(r?.rest, "报销")
    }

    func testSlashPrefixNotMatched() {
        XCTAssertNil(LingShuDeclarativeInvocation.detect("/present /tmp/a.pdf", plugins: plugins))
    }

    func testNaturalSentenceNotMatched() {
        // 自然语句无显式 @ → 不拦,交常规分诊。
        XCTAssertNil(LingShuDeclarativeInvocation.detect("演示这个文档", plugins: plugins))
        XCTAssertNil(LingShuDeclarativeInvocation.detect("帮我改一下报销单", plugins: plugins))
    }

    /// **@演示 + 附件**:附件路径折进消息时在 `@演示` **之前**(attachmentContextBlock 的「本机路径:…」),
    /// 用户文本只打「@演示」→ 声明在 userText 上识别(rest 为空),路径要从**整条消息**兜底抽到(fullPrompt 兜底)。
    /// 根治用户实测"@演示+附件,路径在消息里却没被认领"。
    func testAtMentionWithAttachmentPathBeforeIt() throws {
        let tmp = NSTemporaryDirectory() + "lingshu-test-\(UUID().uuidString).pptx"
        try "x".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        // ① 声明在 userText("@演示")上识别 → present,segment 为空(后面没路径)
        let chain = LingShuDeclarativeInvocation.detectChain("@演示", plugins: plugins)
        XCTAssertEqual(chain.map(\.id), ["present"])
        XCTAssertEqual(chain.first?.segment, "")
        // ② 路径在 @演示 之前,但从整条消息抽得到(routeDeclarative 的 fullPrompt 兜底走这条)
        let combined = "【文档:x.pptx】\n本机路径:\(tmp)\n大小:1B\n\n用户指令:\n@演示"
        XCTAssertEqual(LingShuState.extractExistingFilePaths(combined), [tmp])
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
