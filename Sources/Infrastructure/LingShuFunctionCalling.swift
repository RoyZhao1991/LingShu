import Foundation

/// 原生 function-calling 的工具定义。完整参数 Schema 在所有受支持协议间原样复用。
///
/// 取代脆弱的文本 `【工具】{json}` 协议：把工具以结构化 schema 随请求下发，模型用 `tool_calls`
/// 结构化字段返回调用——不再从自由文本里正则抠 JSON，坏命令/坏 JSON 大幅减少。
struct LingShuToolDefinition: Equatable, Sendable {
    var name: String
    var description: String
    /// 参数属性：名字 → (JSON 类型, 说明)。
    var properties: [Property]
    var required: [String]
    /// Agent 工具提供的完整 JSON Schema。存在时优先透传 enum/items/嵌套对象等约束；
    /// 旧调用方没有提供时，继续由 properties + required 生成兼容 Schema。
    var parametersJSON: String?

    struct Property: Equatable, Sendable {
        var name: String
        var type: String
        var description: String
    }

    init(
        name: String,
        description: String,
        properties: [Property],
        required: [String],
        parametersJSON: String? = nil
    ) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
        self.parametersJSON = parametersJSON
    }

    func parameterSchemaObject() -> [String: Any] {
        if let parametersJSON,
           let data = parametersJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        var props: [String: Any] = [:]
        for property in properties {
            props[property.name] = ["type": property.type, "description": property.description]
        }
        return [
            "type": "object",
            "properties": props,
            "required": required
        ]
    }

    /// 编码成 OpenAI `tools` 数组里的一项。
    func wireObject() -> [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameterSchemaObject()
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
            description: "读文本文件,带行号返回(供精确编辑定位)。大文件用 offset/limit 分段读全。",
            properties: [
                .init(name: "path", type: "string", description: "要读取文件的绝对路径"),
                .init(name: "offset", type: "string", description: "(可选)起始行号,1 起,默认 1"),
                .init(name: "limit", type: "string", description: "(可选)读多少行,默认 1200")
            ],
            required: ["path"]
        ),
        .init(
            name: "write_file",
            description: "把完整内容写入文件(只能写工作目录内)。**新建文件或整体重写用它;改已有大文件的局部用 edit_file。**",
            properties: [
                .init(name: "path", type: "string", description: "目标文件绝对路径，必须在工作目录内"),
                .init(name: "content", type: "string", description: "要写入的完整文本内容")
            ],
            required: ["path", "content"]
        ),
        .init(
            name: "edit_file",
            description: "精确编辑已有文件:把**唯一匹配**的 old_string 替换成 new_string,不重写整文件(改大代码首选)。old_string 要与文件逐字符一致(含缩进);不唯一就多带上下文或分次改。先 read_file 看准再编辑。",
            properties: [
                .init(name: "path", type: "string", description: "要编辑文件绝对路径,必须在工作目录内"),
                .init(name: "old_string", type: "string", description: "被替换的原文(需在文件中唯一、逐字符一致)"),
                .init(name: "new_string", type: "string", description: "替换后的新文本")
            ],
            required: ["path", "old_string", "new_string"]
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
