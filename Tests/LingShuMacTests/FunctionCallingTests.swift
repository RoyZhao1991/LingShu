import XCTest
@testable import LingShuMac

final class FunctionCallingTests: XCTestCase {
    private let gateway = LingShuModelGateway()

    private func body(forTools tools: [LingShuToolDefinition]) throws -> [String: Any] {
        let contract = try gateway.makeInvocationContract(
            provider: "MiniMax",
            model: "MiniMax-M3",
            endpoint: "https://api.minimax.chat/v1",
            protocolName: "OpenAI 兼容",
            apiKey: "sk-test",
            systemPrompt: "你是灵枢。",
            userPrompt: "跑一下 hello.py",
            temperature: 0.6,
            stream: false,
            tools: tools
        )
        return try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
    }

    // MARK: - 请求体

    func testToolsEncodedIntoChatCompletionsBody() throws {
        let object = try body(forTools: LingShuFunctionCallingCatalog.builtin)
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 6)   // read/write/edit/list/fetch/run

        let functions = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertTrue(functions.contains("run_command"))
        XCTAssertTrue(functions.contains("write_file"))
        XCTAssertTrue(functions.contains("edit_file"))   // 精确编辑四肢(改大代码)

        let runCommand = try XCTUnwrap(tools.first {
            (($0["function"] as? [String: Any])?["name"] as? String) == "run_command"
        })
        let function = try XCTUnwrap(runCommand["function"] as? [String: Any])
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        let required = try XCTUnwrap(parameters["required"] as? [String])
        XCTAssertEqual(required, ["command"])
        XCTAssertEqual(runCommand["type"] as? String, "function")
    }

    func testNonToolBodyStaysCleanWithoutToolKeys() throws {
        let object = try body(forTools: [])
        XCTAssertNil(object["tools"], "无工具请求不应带 tools 字段")
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        // 普通消息只有 role/content，不应混入 tool_calls / tool_call_id。
        for message in messages {
            XCTAssertNil(message["tool_calls"])
            XCTAssertNil(message["tool_call_id"])
        }
    }

    func testToolRoundtripMessagesSerializeToolCallsAndResults() throws {
        let assistant = LingShuModelMessage(
            role: "assistant",
            content: "",
            toolCalls: [.init(id: "call_1", name: "run_command", arguments: "{\"command\":\"python3 hello.py\"}")]
        )
        let toolResult = LingShuModelMessage(role: "tool", content: "✓ run_command：2026", toolCallID: "call_1")

        let contract = try gateway.makeInvocationContract(
            provider: "MiniMax",
            model: "MiniMax-M3",
            endpoint: "https://api.minimax.chat/v1",
            protocolName: "OpenAI 兼容",
            apiKey: "sk-test",
            systemPrompt: "你是灵枢。",
            userPrompt: "",
            temperature: 0.6,
            stream: false,
            conversationMessages: [
                .init(role: "system", content: "你是灵枢。"),
                .init(role: "user", content: "跑一下 hello.py"),
                assistant,
                toolResult
            ],
            tools: LingShuFunctionCallingCatalog.builtin
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: contract.body) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])

        // 空正文的 assistant tool_calls 消息必须保留（不能被空正文过滤掉）。
        let assistantWire = try XCTUnwrap(messages.first { ($0["tool_calls"] as? [[String: Any]]) != nil })
        let calls = try XCTUnwrap(assistantWire["tool_calls"] as? [[String: Any]])
        XCTAssertEqual((calls.first?["function"] as? [String: Any])?["name"] as? String, "run_command")
        XCTAssertEqual(calls.first?["id"] as? String, "call_1")

        let toolWire = try XCTUnwrap(messages.first { $0["tool_call_id"] as? String == "call_1" })
        XCTAssertEqual(toolWire["role"] as? String, "tool")
    }

    // MARK: - 响应解析

    func testDecodeToolCallsFromResponse() throws {
        let json = """
        {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
          {"id":"call_abc","type":"function","function":{"name":"run_command","arguments":"{\\"command\\":\\"ls -l\\"}"}}
        ]}}]}
        """
        let calls = gateway.decodeToolCalls(data: Data(json.utf8))
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "run_command")
        XCTAssertEqual(calls.first?.id, "call_abc")
        XCTAssertEqual(calls.first?.argumentDictionary["command"], "ls -l")
    }

    func testDecodeToolCallsEmptyForPlainTextResponse() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"好的，已完成。"}}]}"#
        XCTAssertTrue(gateway.decodeToolCalls(data: Data(json.utf8)).isEmpty)
    }

    func testToolCallArgumentDictionaryHandlesNonStringValues() {
        let call = LingShuToolCall(id: "x", name: "demo", arguments: "{\"path\":\"/tmp/a\",\"limit\":8}")
        XCTAssertEqual(call.argumentDictionary["path"], "/tmp/a")
        XCTAssertEqual(call.argumentDictionary["limit"], "8")
    }
}
