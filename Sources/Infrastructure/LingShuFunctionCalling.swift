import Foundation

/// 原生 function-calling 的工具定义（OpenAI `tools` 格式，MiniMax M3 / GLM 等 chat/completions 端点通用）。
///
/// 取代脆弱的文本 `【工具】{json}` 协议：把工具以结构化 schema 随请求下发，模型用 `tool_calls`
/// 结构化字段返回调用——不再从自由文本里正则抠 JSON，坏命令/坏 JSON 大幅减少。
struct LingShuToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    /// 参数属性：名字 → (JSON 类型, 说明)。
    var properties: [Property]
    var required: [String]

    struct Property: Equatable, Sendable {
        var name: String
        var type: String
        var description: String
    }

    /// 编码成 OpenAI `tools` 数组里的一项。
    func wireObject() -> [String: Any] {
        var props: [String: Any] = [:]
        for property in properties {
            props[property.name] = ["type": property.type, "description": property.description]
        }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": props,
                    "required": required
                ]
            ]
        ]
    }
}

/// 模型返回的一次工具调用（从 `choices[0].message.tool_calls` 解析）。
struct LingShuToolCall: Equatable, Codable, Sendable {
    /// 供应商给的调用 id；回传工具结果时用 `tool_call_id` 对应。
    var id: String
    var name: String
    /// 参数 JSON 字符串（OpenAI 原样给字符串，可能需要二次解析）。
    var arguments: String

    /// 解析 arguments JSON 成 [String: String]（与现有 LingShuToolRequest.arguments 对齐）。
    var argumentDictionary: [String: String] {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [String: String]()) { result, pair in
            if let string = pair.value as? String {
                result[pair.key] = string
            } else {
                result[pair.key] = String(describing: pair.value)
            }
        }
    }
}

enum LingShuFunctionCallingCatalog {
    /// 五个内建工具的结构化 schema（与 LingShuLocalToolExecutor 一一对应）。
    static let builtin: [LingShuToolDefinition] = [
        .init(
            name: "read_file",
            description: "读取文本文件的前 8KB。",
            properties: [.init(name: "path", type: "string", description: "要读取文件的绝对路径")],
            required: ["path"]
        ),
        .init(
            name: "write_file",
            description: "把内容写入文件（只能写在工作目录内）。",
            properties: [
                .init(name: "path", type: "string", description: "目标文件绝对路径，必须在工作目录内"),
                .init(name: "content", type: "string", description: "要写入的完整文本内容")
            ],
            required: ["path", "content"]
        ),
        .init(
            name: "list_directory",
            description: "列出目录内容。",
            properties: [.init(name: "path", type: "string", description: "要列出目录的绝对路径")],
            required: ["path"]
        ),
        .init(
            name: "fetch_url",
            description: "GET 抓取网页/接口文本（前 8KB）。",
            properties: [.init(name: "url", type: "string", description: "http/https URL")],
            required: ["url"]
        ),
        .init(
            name: "run_command",
            description: "在工作目录执行 shell 命令。高风险动作，会请用户授权后执行。",
            properties: [.init(name: "command", type: "string", description: "要执行的 shell 命令，注意命令与参数间留空格")],
            required: ["command"]
        )
    ]

    /// 外部 MCP 工具转成 function 定义（参数统一收一个自由 JSON 对象 arguments）。
    static func definition(forMCPTool name: String, description: String) -> LingShuToolDefinition {
        .init(
            name: name,
            description: String(description.prefix(160)),
            properties: [.init(name: "arguments_json", type: "string", description: "该工具的参数，JSON 对象字符串")],
            required: []
        )
    }
}
