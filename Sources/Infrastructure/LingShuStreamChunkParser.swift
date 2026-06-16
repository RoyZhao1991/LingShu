import Foundation

/// 流式增量(SSE 行)解析 —— **协议层适配,独立成模块**。
///
/// 不同厂商的流式事件结构不同,这里按**协议**(由 provider/protocol 推导出的 `requestFormat`)收敛成独立解析器,
/// 各处(`streamAgent` / 旧流式路径)共用同一套,不再各写一份、也不会像之前那样按下葫芦起了瓢:
///  - **OpenAI chat/completions**(DeepSeek / MiniMax / Kimi / 通义 / 数据网关):`choices[0].delta.{content, reasoning_content, tool_calls}` + 末块 `usage`;
///  - **OpenAI Responses**:`response.output_text.delta`;
///  - **Anthropic Messages**:`content_block_delta`(text / input_json_delta)+ `message_delta`(usage)。
///
/// **分层**:本模块只做"原始 SSE 行 → 结构化协议增量";模型层的**思维链分离**(MiniMax M3 内联 `<think>` /
/// DeepSeek-R 的 `reasoning_content`)交给 [LingShuModelReplyAdapter](LingShuModelReplyAdapter.swift)(按模型适配)——
/// 两层各管一件事、各自可单测、按需扩展。

/// 一段工具调用增量(OpenAI 风格按 index 累积:首块给 id/name,其后拼 arguments 片段)。
struct LingShuStreamToolCallDelta {
    var index: Int
    var id: String?
    var name: String?
    var argumentsFragment: String?
}

/// 一行 SSE 解析出的结构化协议增量。
struct LingShuStreamChunk {
    var contentDelta: String = ""        // 用户可见正文增量(保留换行/空白——纯 "\n" 块绝不能丢)
    var reasoningDelta: String = ""      // 协议级思维链字段(如 DeepSeek-R `reasoning_content`),不进正文气泡
    var toolCallDeltas: [LingShuStreamToolCallDelta] = []
    var usage: [String: Any]?            // 末块用量(含前缀缓存命中),用 stream_options.include_usage 才有
    var done: Bool = false               // 流结束标记([DONE] / message_stop)
    var hasPayload: Bool { !contentDelta.isEmpty || !reasoningDelta.isEmpty || !toolCallDeltas.isEmpty || usage != nil || done }
}

/// 协议层流式解析器:一行 SSE → 结构化增量。返回 nil = 非数据行/无关行(跳过)。
protocol LingShuStreamChunkParsing {
    func parse(line: String) -> LingShuStreamChunk?
}

enum LingShuStreamChunkParsers {
    /// 按请求格式(已由 provider/protocol 推导)选协议解析器——换模型自动选对。
    static func parser(for format: LingShuModelGatewayRequestFormat) -> LingShuStreamChunkParsing {
        switch format {
        case .anthropicMessages: return LingShuAnthropicStreamChunkParser()
        case .responses: return LingShuResponsesStreamChunkParser()
        case .chatCompletions, .codexBridge, .hostAdapter: return LingShuOpenAIChatStreamChunkParser()
        }
    }

    /// 剥 SSE 行的 `data:` 前缀,返回 JSON 负载或 `[DONE]`。
    static func ssePayload(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:") {
            return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func jsonObject(_ payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// OpenAI chat/completions 流式(DeepSeek / MiniMax / Kimi / 通义 / 数据网关 …)。
struct LingShuOpenAIChatStreamChunkParser: LingShuStreamChunkParsing {
    func parse(line: String) -> LingShuStreamChunk? {
        let payload = LingShuStreamChunkParsers.ssePayload(line)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" { return LingShuStreamChunk(done: true) }
        guard let object = LingShuStreamChunkParsers.jsonObject(payload) else { return nil }

        var chunk = LingShuStreamChunk()
        if let usage = object["usage"] as? [String: Any] { chunk.usage = usage }
        if let choices = object["choices"] as? [[String: Any]], let delta = choices.first?["delta"] as? [String: Any] {
            // **保留换行/空白**:只过滤真正的空串("");纯 "\n" 是有效正文,绝不能丢(否则 markdown 结构塌)。
            if let content = delta["content"] as? String, !content.isEmpty { chunk.contentDelta = content }
            if let reasoning = delta["reasoning_content"] as? String, !reasoning.isEmpty { chunk.reasoningDelta = reasoning }
            if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                for tc in toolCalls {
                    var d = LingShuStreamToolCallDelta(index: (tc["index"] as? Int) ?? 0)
                    d.id = tc["id"] as? String
                    if let function = tc["function"] as? [String: Any] {
                        d.name = function["name"] as? String
                        d.argumentsFragment = function["arguments"] as? String
                    }
                    chunk.toolCallDeltas.append(d)
                }
            }
        }
        return chunk.hasPayload ? chunk : nil
    }
}

/// OpenAI Responses 流式:文本走 `response.output_text.delta`(工具/其它事件待 Responses agent 工具循环接入时再补)。
struct LingShuResponsesStreamChunkParser: LingShuStreamChunkParsing {
    func parse(line: String) -> LingShuStreamChunk? {
        let payload = LingShuStreamChunkParsers.ssePayload(line)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" { return LingShuStreamChunk(done: true) }
        guard let object = LingShuStreamChunkParsers.jsonObject(payload) else { return nil }

        var chunk = LingShuStreamChunk()
        if let type = object["type"] as? String, type == "response.output_text.delta",
           let delta = object["delta"] as? String, !delta.isEmpty {
            chunk.contentDelta = delta
        }
        if let response = object["response"] as? [String: Any], let usage = response["usage"] as? [String: Any] {
            chunk.usage = usage
        } else if let usage = object["usage"] as? [String: Any] {
            chunk.usage = usage
        }
        return chunk.hasPayload ? chunk : nil
    }
}

/// Anthropic Messages 流式:`content_block_delta`(text_delta=正文 / input_json_delta=工具参数)+ `message_delta`(usage)+ `message_stop`。
struct LingShuAnthropicStreamChunkParser: LingShuStreamChunkParsing {
    func parse(line: String) -> LingShuStreamChunk? {
        let payload = LingShuStreamChunkParsers.ssePayload(line)
        guard !payload.isEmpty else { return nil }
        if payload == "[DONE]" { return LingShuStreamChunk(done: true) }
        guard let object = LingShuStreamChunkParsers.jsonObject(payload), let type = object["type"] as? String else { return nil }

        var chunk = LingShuStreamChunk()
        switch type {
        case "content_block_delta":
            if let delta = object["delta"] as? [String: Any] {
                if let text = delta["text"] as? String, !text.isEmpty { chunk.contentDelta = text }
                if let partial = delta["partial_json"] as? String, !partial.isEmpty {
                    chunk.toolCallDeltas = [LingShuStreamToolCallDelta(index: (object["index"] as? Int) ?? 0, argumentsFragment: partial)]
                }
            }
        case "message_delta":
            if let usage = object["usage"] as? [String: Any] { chunk.usage = usage }
        case "message_stop":
            chunk.done = true
        default:
            break
        }
        return chunk.hasPayload ? chunk : nil
    }
}
