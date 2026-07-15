import Foundation

/// Agent Loop 的策略层:把"是否可并行、是否算进展、是否脚手架、是否需要大参数分块纠偏"集中到一处。
///
/// 这里的输入是模型已经发出的结构化 tool_call 和工具元数据,不是用户自然语言。业务语义仍交给主脑判断。
enum LingShuAgentLoopPolicy {
    static func tool(named name: String, in tools: [LingShuAgentTool]) -> LingShuAgentTool? {
        tools.first { $0.name == name }
    }

    static func metadata(for name: String, in tools: [LingShuAgentTool]) -> LingShuToolMetadata {
        tool(named: name, in: tools)?.metadata ?? .inferred(name: name, parametersJSON: "{}")
    }

    static func requiredParams(for name: String, in tools: [LingShuAgentTool]) -> Set<String> {
        LingShuAgentSession.requiredParams(for: name, in: tools)
    }

    static func isMutatingProgress(_ call: LingShuAgentToolCall, tools: [LingShuAgentTool]) -> Bool {
        metadata(for: call.name, in: tools).isMutatingProgress
    }

    static func isOptionalScaffold(_ name: String, tools: [LingShuAgentTool]) -> Bool {
        metadata(for: name, in: tools).isOptionalScaffold
    }

    static func isLargePayloadSensitive(_ call: LingShuAgentToolCall, tools: [LingShuAgentTool]) -> Bool {
        metadata(for: call.name, in: tools).isLargePayloadSensitive
    }

    static func firstRequiredPayloadField(for call: LingShuAgentToolCall, tools: [LingShuAgentTool]) -> String {
        let required = requiredParams(for: call.name, in: tools)
        for preferred in ["content", "command", "patch"] where required.contains(preferred) {
            return preferred
        }
        return required.sorted().first ?? "参数"
    }

    static func argumentValidationError(for call: LingShuAgentToolCall, tools: [LingShuAgentTool]) -> String? {
        guard let tool = tool(named: call.name, in: tools) else { return nil }
        guard let object = parseArguments(call.argumentsJSON) else {
            return "参数不是合法 JSON 对象。请按工具 schema 重新给出结构化参数。"
        }
        if let missing = missingRequiredParam(for: call, tools: tools) {
            return "缺少必需参数 `\(missing)`。请按工具 schema 补齐后再调用。"
        }
        if metadata(for: call.name, in: tools).effect == .execute,
           let command = object["command"] as? String,
           let reason = shellCommandContractError(command) {
            return reason
        }
        _ = tool
        return nil
    }

    static func missingRequiredParam(for call: LingShuAgentToolCall, tools: [LingShuAgentTool]) -> String? {
        guard let object = parseArguments(call.argumentsJSON),
              let tool = tool(named: call.name, in: tools) else { return nil }
        let propertySchemas = parameterPropertySchemas(tool.parametersJSON)
        return requiredParams(for: call.name, in: tools).sorted().first { field in
            requiredValueIsInvalid(object[field], schema: propertySchemas[field])
        }
    }

    static func normalizedToolSignature(for call: LingShuAgentToolCall, tools: [LingShuAgentTool]) -> String {
        if missingRequiredParam(for: call, tools: tools) != nil {
            return "\(call.name)#MALFORMED"
        }
        if argumentValidationError(for: call, tools: tools) != nil {
            return "\(call.name)#INVALID_ARGUMENTS"
        }
        return LingShuAgentSession.normalizedToolSignature(
            name: call.name,
            argsJSON: call.argumentsJSON,
            required: requiredParams(for: call.name, in: tools)
        )
    }

    static func invalidArgumentsSteer(_ errors: [(tool: String, reason: String)]) -> String {
        let lines = errors.map { "- \($0.tool): \($0.reason)" }.joined(separator: "\n")
        return """
        【系统纠偏】本轮工具调用参数没有满足工具契约,已被宿主拦截,没有执行真实动作。
        \(lines)
        请重新思考目标:如果要写入/修改内容,优先使用 write_file 或 edit_file;如果确实要执行系统命令,只把能在 shell 中运行的命令放进 command 字段,不要把说明文字、约束、正文或 Markdown 片段塞进 command。
        """
    }

    static func largePayloadSteer(toolName: String, field: String) -> String {
        "【系统纠偏】你调用「\(toolName)」时 `\(field)` 一直空着到达——这通常不是漏填,而是这次要传的内容太大、被通道截断丢了。不要继续把整块内容塞进一次调用;唯一出路是分块写小段:先写第一小段,再多次追加后续小段。若可用 shell,可用 `cat > 目标文件 << 'EOF' ... EOF` 写第一段,再用 `cat >> 目标文件 << 'EOF' ... EOF` 追加;每条命令只带一小块文本,全部写完后再运行/校验。"
    }

    static func malformedRequiredParamsSteer(toolName: String) -> String {
        "【系统纠偏】你连续多次调用「\(toolName)」都缺少工具声明的必需参数。请先读取该工具 schema,补齐必需字段后重新调用;如果某个写入/编辑工具反复失败,换用等价工具或更小步骤完成真实目标。"
    }

    static func optionalScaffoldSteer(toolName: String) -> String {
        "【系统纠偏】「\(toolName)」只是可选脚手架,不是任务目标本身。跳过这一步,直接推进用户真正要的交付物或答复。"
    }

    static func overValidationSteer() -> String {
        "【系统纠偏】你已经连续很多步只在测试/查看,没有再产生新的交付变更。若目标已经达成,请直接给出最终交付文本:完成了什么、产出物在哪里、如何打开/运行;不要继续重复验证空转。"
    }

    static func readOnlyStallSteer(turns: Int) -> String {
        "【系统提醒】你已经连续 \(turns) 步只在读取/查看,还没有形成产出。若信息足够,请立即动手产出;若这是纯问答,请直接回答;若缺关键前提,请明确提出需要用户补充什么。"
    }

    private static func parseArguments(_ argsJSON: String) -> [String: Any]? {
        guard let data = argsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func requiredValueIsInvalid(_ value: Any?, schema: [String: Any]?) -> Bool {
        guard let value else { return true }
        if value is NSNull { return true }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any], let minimum = schema?["minItems"] as? NSNumber {
            return array.count < minimum.intValue
        }
        if let dict = value as? [String: Any], let minimum = schema?["minProperties"] as? NSNumber {
            return dict.count < minimum.intValue
        }
        return false
    }

    private static func parameterPropertySchemas(_ parametersJSON: String) -> [String: [String: Any]] {
        guard let data = parametersJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = root["properties"] as? [String: Any] else { return [:] }
        return properties.reduce(into: [:]) { result, item in
            if let schema = item.value as? [String: Any] {
                result[item.key] = schema
            }
        }
    }

    private static func shellCommandContractError(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "run_command.command 为空。" }
        guard let first = firstShellWord(trimmed) else { return nil }
        let lower = first.lowercased()
        if shellWordsThatCanStartACommand.contains(lower) { return nil }
        if first.contains("/") || first.hasPrefix("~") { return nil }
        if first.contains("="), !first.hasPrefix("=") { return nil }
        if first.unicodeScalars.contains(where: { scalar in
            (0x3400...0x9FFF).contains(Int(scalar.value)) || invalidBareCommandScalars.contains(scalar)
        }) {
            return "run_command.command 看起来不是可执行 shell 命令,首个命令词为 `\(first)`。"
        }
        return nil
    }

    private static func firstShellWord(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let controlPrefixes = ["(", "{", "[[", "if ", "for ", "while ", "until ", "case ", "function ", "time "]
        if controlPrefixes.contains(where: { trimmed.hasPrefix($0) }) { return nil }
        var token = ""
        var quote: Character?
        for ch in trimmed {
            if let q = quote {
                if ch == q { quote = nil }
                token.append(ch)
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                token.append(ch)
                continue
            }
            if ch.isWhitespace || ch == ";" || ch == "|" || ch == "&" {
                break
            }
            token.append(ch)
        }
        return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : token
    }

    private static let shellWordsThatCanStartACommand: Set<String> = [
        "alias", "autoload", "bg", "break", "builtin", "bye", "cd", "command", "continue",
        "dirs", "disable", "disown", "echo", "emulate", "enable", "eval", "exec", "exit",
        "export", "false", "fc", "fg", "functions", "getln", "getopts", "hash", "history",
        "jobs", "kill", "let", "limit", "local", "logout", "popd", "print", "printf", "pushd",
        "pwd", "read", "readonly", "rehash", "return", "set", "shift", "source", "test",
        "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unfunction",
        "unhash", "unlimit", "unset", "unsetopt", "wait", "whence", "where", "which", "zcompile",
        "zformat", "zmodload", "zparseopts", "zstyle"
    ]

    private static let invalidBareCommandScalars = CharacterSet(charactersIn: "*?`“”‘’：，。；、【】《》")
}

enum LingShuAgentLoopTraceKind: String, Sendable, Equatable {
    case model
    case route
    case runtime
    case tool
    case warning
    case result
}

struct LingShuAgentLoopTraceEvent: Sendable, Equatable {
    let kind: LingShuAgentLoopTraceKind
    let actor: String
    let title: String
    let detail: String
}
