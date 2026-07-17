import XCTest
@testable import LingShuMac

/// Claude(Anthropic /messages)原生工具回合接通(2026-06-28):assistant 的 tool_calls → `tool_use` 块、role=tool 结果 →
/// user 里的 `tool_result` 块,并给 tools/system/最后一条消息打 `cache_control` 缓存断点。守住"Claude 当带工具的 agent 大脑
/// 也走得通 + 全程吃缓存"。见 [[gateway-context-injection]]。
final class AnthropicToolPathTests: XCTestCase {

    private func obj(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// 请求体:工具转 input_schema、tool_use/tool_result 块、缓存断点齐全。
    func testRequestEncodesNativeToolsAndCacheBreakpoints() throws {
        let tools = [LingShuToolDefinition(name: "write_file", description: "写文件",
            properties: [.init(name: "path", type: "string", description: "路径")], required: ["path"])]
        let msgs = [
            LingShuModelMessage(role: "user", content: "建个文件"),
            LingShuModelMessage(role: "assistant", content: "好的",
                toolCalls: [LingShuToolCall(id: "tc1", name: "write_file", arguments: "{\"path\":\"/tmp/a.txt\"}")]),
            LingShuModelMessage(role: "tool", content: "已写入", toolCallID: "tc1")
        ]
        let body = obj(try LingShuModelGateway.anthropicMessagesBody(
            model: "claude-opus-4-8", systemPrompt: "你是灵枢", messages: msgs,
            temperature: 0.3, stream: false, cache: .anthropicExplicit, tools: tools))

        // tools → Anthropic input_schema(非 OpenAI function),最后一个工具打缓存断点
        let toolsArr = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertNotNil(toolsArr[0]["input_schema"])
        XCTAssertNil(toolsArr[0]["function"], "不应残留 OpenAI 形态")
        XCTAssertNotNil(toolsArr[0]["cache_control"], "最后一个工具应打缓存断点(缓存大且稳定的工具集)")

        // system 打缓存断点
        XCTAssertNotNil(try XCTUnwrap(body["system"] as? [[String: Any]]).first?["cache_control"])

        let m = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(m.count, 3)
        // assistant 带 tool_use(input 是对象,非字符串)
        let asst = try XCTUnwrap(m[1]["content"] as? [[String: Any]])
        let toolUse = try XCTUnwrap(asst.first { ($0["type"] as? String) == "tool_use" })
        XCTAssertEqual(toolUse["id"] as? String, "tc1")
        XCTAssertEqual(toolUse["name"] as? String, "write_file")
        XCTAssertEqual((toolUse["input"] as? [String: Any])?["path"] as? String, "/tmp/a.txt")
        // 工具结果合进 user 的 tool_result + 最后一个 block 打缓存断点
        XCTAssertEqual(m[2]["role"] as? String, "user")
        let result = try XCTUnwrap(m[2]["content"] as? [[String: Any]])
        XCTAssertEqual(result[0]["type"] as? String, "tool_result")
        XCTAssertEqual(result[0]["tool_use_id"] as? String, "tc1")
        XCTAssertNotNil(result.last?["cache_control"], "最后一条消息最后一个 block 应打缓存断点")
    }

    func testAnthropicToolInputSchemaPreservesNestedConstraints() throws {
        let schema = #"{"type":"object","properties":{"mode":{"type":"string","enum":["fast","full"]},"items":{"type":"array","items":{"type":"string"}}},"required":["mode","items"]}"#
        let tool = LingShuToolDefinition(
            name: "submit",
            description: "提交",
            properties: [],
            required: ["mode", "items"],
            parametersJSON: schema
        )
        let body = obj(try LingShuModelGateway.anthropicMessagesBody(
            model: "test-model",
            systemPrompt: "",
            messages: [LingShuModelMessage(role: "user", content: "提交")],
            temperature: 0.1,
            stream: false,
            cache: .unsupported,
            tools: [tool]
        ))
        let inputSchema = try XCTUnwrap((body["tools"] as? [[String: Any]])?.first?["input_schema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])

        XCTAssertEqual((properties["mode"] as? [String: Any])?["enum"] as? [String], ["fast", "full"])
        XCTAssertEqual(((properties["items"] as? [String: Any])?["items"] as? [String: Any])?["type"] as? String, "string")
    }

    /// 一轮多个工具结果应合并进**同一条** user 消息(Anthropic 要求)。
    func testConsecutiveToolResultsMergedIntoOneUserMessage() throws {
        let msgs = [
            LingShuModelMessage(role: "assistant", content: "",
                toolCalls: [LingShuToolCall(id: "a", name: "read_file", arguments: "{}"),
                            LingShuToolCall(id: "b", name: "list_directory", arguments: "{}")]),
            LingShuModelMessage(role: "tool", content: "r1", toolCallID: "a"),
            LingShuModelMessage(role: "tool", content: "r2", toolCallID: "b")
        ]
        let body = obj(try LingShuModelGateway.anthropicMessagesBody(
            model: "claude", systemPrompt: "", messages: msgs, temperature: 0.3,
            stream: false, cache: .anthropicExplicit, tools: []))
        let m = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(m.count, 2, "assistant + 一条合并的 user(两个 tool_result)")
        let results = try XCTUnwrap(m[1]["content"] as? [[String: Any]])
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.map { $0["tool_use_id"] as? String }, ["a", "b"])
    }

    /// 响应解析:Anthropic content[] 里的 tool_use → LingShuToolCall(input 对象序列化回 arguments 字符串)。
    func testResponseParsesAnthropicToolUse() {
        let resp = """
        {"id":"msg_1","type":"message","role":"assistant","content":[
          {"type":"text","text":"我来写"},
          {"type":"tool_use","id":"toolu_9","name":"write_file","input":{"path":"/tmp/x.txt","content":"hi"}}
        ]}
        """.data(using: .utf8)!
        let calls = LingShuModelGateway().decodeToolCalls(data: resp)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "toolu_9")
        XCTAssertEqual(calls[0].name, "write_file")
        XCTAssertEqual(calls[0].argumentDictionary["path"], "/tmp/x.txt")
    }

    /// Anthropic usage 的命中率口径:input_tokens 不含 cache_read/creation,总数要加回来,命中率必须 ≤100%(不能算出天文数)。
    func testAnthropicCacheUsageRateNeverExceeds100() {
        // 某轮:1 个新增 token、50000 从缓存读、0 写缓存 → 总输入 50001,命中 50000。
        let usage: [String: Any] = ["input_tokens": 1, "cache_read_input_tokens": 50000, "cache_creation_input_tokens": 0]
        let (prompt, cached) = LingShuPrefixCache.parseCacheUsage(usage)
        XCTAssertEqual(prompt, 50001, "Anthropic 总输入应 = input + cache_read + cache_creation")
        XCTAssertEqual(cached, 50000)
        let snap = LingShuPrefixCacheMeter.Snapshot(calls: 1, totalPrompt: prompt ?? 0, totalCached: cached ?? 0)
        XCTAssertLessThanOrEqual(snap.ratePercent, 100, "命中率不能 >100%")
        XCTAssertEqual(snap.ratePercent, 99)
    }

    /// OpenAI 口径不受影响:prompt_tokens 已是总数,cached 是子集。
    func testOpenAICacheUsageUnaffected() {
        let usage: [String: Any] = ["prompt_tokens": 5000, "prompt_tokens_details": ["cached_tokens": 4000]]
        let (prompt, cached) = LingShuPrefixCache.parseCacheUsage(usage)
        XCTAssertEqual(prompt, 5000)
        XCTAssertEqual(cached, 4000)
    }

    /// 附件直接入脑:user 消息带图片/PDF data URL → Anthropic 原生 image/document 块。
    func testAnthropicEncodesInlineImageAndPdfBlocks() throws {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let pdf = "data:application/pdf;base64,JVBERi0="
        let msgs = [LingShuModelMessage(role: "user", content: "看这两个", toolCalls: nil, toolCallID: nil, imageDataURLs: [png, pdf])]
        let body = obj(try LingShuModelGateway.anthropicMessagesBody(
            model: "claude-sonnet-4-6", systemPrompt: "", messages: msgs, temperature: 0.3,
            stream: false, cache: .anthropicExplicit, tools: []))
        let content = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first { ($0["type"] as? String) == "text" }?["text"] as? String, "看这两个")
        let image = try XCTUnwrap(content.first { ($0["type"] as? String) == "image" })
        XCTAssertEqual((image["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        XCTAssertEqual((image["source"] as? [String: Any])?["data"] as? String, "iVBORw0KGgo=")
        let doc = try XCTUnwrap(content.first { ($0["type"] as? String) == "document" })
        XCTAssertEqual((doc["source"] as? [String: Any])?["media_type"] as? String, "application/pdf")
    }

    /// 多模态能力判断:Claude/GPT-4o/Gemini 算多模态,DeepSeek 不算(开关对它回退 VL)。
    func testVisionCapabilityGate() {
        XCTAssertTrue(LingShuMultimodal.isVisionCapable(provider: "Anthropic Claude", model: "claude-sonnet-4-6"))
        XCTAssertTrue(LingShuMultimodal.isVisionCapable(provider: "OpenAI", model: "gpt-4o"))
        XCTAssertTrue(LingShuMultimodal.isVisionCapable(provider: "Google", model: "gemini-2.5-pro"))
        XCTAssertFalse(LingShuMultimodal.isVisionCapable(provider: "DeepSeek", model: "deepseek-chat"))
    }

    /// **真 bug 回归(2026-06-28)**:子会话把指令放在 `role=system` 消息里、request.systemPrompt 为空时,
    /// Anthropic 必须把 system 消息**收进 system 字段**(不能 filter 掉又用空 systemPrompt → 模型收不到任何指令、客套乱答)。
    func testAnthropicCollectsSystemFromMessagesNotDropped() throws {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: LingShuLanguagePreferenceStore.languageKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: LingShuLanguagePreferenceStore.languageKey) }
            else { defaults.removeObject(forKey: LingShuLanguagePreferenceStore.languageKey) }
        }
        defaults.set(LingShuVoiceLanguage.english.rawValue, forKey: LingShuLanguagePreferenceStore.languageKey)

        let contract = try LingShuModelGateway().makeInvocationContract(
            provider: "Anthropic Claude", model: "claude-sonnet-4-6",
            endpoint: "https://api.anthropic.com/v1", protocolName: "Anthropic", apiKey: "sk-x",
            systemPrompt: "", userPrompt: "", temperature: 0.3, stream: false, continuationToken: nil,
            conversationMessages: [
                LingShuModelMessage(role: "system", content: "只输出一行 JSON,别加客套"),
                LingShuModelMessage(role: "user", content: "听众说:从第二页开始讲解")
            ], tools: [])
        let body = obj(contract.body)
        let sys = body["system"]
        let sysText = (sys as? String) ?? ((sys as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(sysText.hasPrefix("ANSWER IN ENGLISH."), "语言要求必须是 Anthropic system 的第一句话")
        XCTAssertEqual(sysText.components(separatedBy: "ANSWER IN ENGLISH.").count - 1, 1, "语言要求不应重复注入")
        XCTAssertTrue(sysText.contains("只输出一行 JSON"), "system 消息必须进 Anthropic 的 system 字段,不能被丢")
        XCTAssertEqual((body["messages"] as? [[String: Any]])?.count, 1, "system 不该留在 messages 里(走 system 字段)")
    }

    /// 非显式缓存策略时退化为无断点的等价请求体(纯字符串 content)。
    func testNonExplicitCacheDegradesCleanly() throws {
        let body = obj(try LingShuModelGateway.anthropicMessagesBody(
            model: "claude", systemPrompt: "sys", messages: [LingShuModelMessage(role: "user", content: "hi")],
            temperature: 0.3, stream: false, cache: .automatic, tools: []))
        XCTAssertTrue(body["system"] is String, "非显式策略 system 应是纯字符串")
        XCTAssertTrue((try XCTUnwrap(body["messages"] as? [[String: Any]]))[0]["content"] is String)
    }
}
