use crate::models::{AgentMessage, AgentRole, AgentToolCall, ProviderProtocol, RuntimeSettings};
use futures_util::StreamExt;
use reqwest::{Client, Response, StatusCode};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::time::Duration;
use thiserror::Error;
use tokio::sync::mpsc;

const REQUEST_ATTEMPTS: usize = 3;

#[derive(Debug, Error)]
pub enum ModelError {
    #[error("model request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("model returned HTTP {status}: {message}")]
    Http { status: StatusCode, message: String },
    #[error("model response did not contain text or tool calls")]
    Empty,
    #[error("model stream was malformed: {0}")]
    Malformed(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ModelDelta {
    Text(String),
    Reasoning(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: Value,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ModelTurn {
    pub text: String,
    pub reasoning: String,
    pub tool_calls: Vec<AgentToolCall>,
}

#[derive(Debug, Clone, Default)]
struct PartialToolCall {
    id: String,
    name: String,
    arguments: String,
}

#[derive(Clone)]
pub struct ModelClient {
    client: Client,
}

impl ModelClient {
    pub fn new() -> Result<Self, ModelError> {
        Ok(Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(20))
                .timeout(Duration::from_secs(300))
                .user_agent("LingShu-Runtime/1.2")
                .build()?,
        })
    }

    pub async fn complete(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        system: &str,
        user: &str,
        max_tokens: u32,
    ) -> Result<String, ModelError> {
        let messages = vec![
            AgentMessage {
                role: AgentRole::System,
                content: system.into(),
                tool_calls: Vec::new(),
                tool_call_id: None,
            },
            AgentMessage {
                role: AgentRole::User,
                content: user.into(),
                tool_calls: Vec::new(),
                tool_call_id: None,
            },
        ];
        let response = self
            .send_with_retry(settings, api_key, &messages, &[], max_tokens, false)
            .await?;
        let status = response.status();
        let text = response.text().await?;
        let body = serde_json::from_str::<Value>(&text)
            .unwrap_or_else(|_| json!({"message": truncate(&text, 2_000)}));
        if !status.is_success() {
            return Err(http_error(status, &body));
        }
        let turn = parse_non_stream_turn(settings.protocol.clone(), &body)?;
        if turn.text.trim().is_empty() {
            Err(ModelError::Empty)
        } else {
            Ok(turn.text)
        }
    }

    pub async fn turn(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        messages: &[AgentMessage],
        tools: &[AgentToolDefinition],
        max_tokens: u32,
        delta_tx: Option<mpsc::UnboundedSender<ModelDelta>>,
    ) -> Result<ModelTurn, ModelError> {
        let response = self
            .send_with_retry(settings, api_key, messages, tools, max_tokens, true)
            .await?;
        let status = response.status();
        if !status.is_success() {
            let text = response.text().await?;
            let body = serde_json::from_str::<Value>(&text)
                .unwrap_or_else(|_| json!({"message": truncate(&text, 2_000)}));
            return Err(http_error(status, &body));
        }
        let is_event_stream = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.to_ascii_lowercase().contains("text/event-stream"));
        if !is_event_stream {
            let body = response.json::<Value>().await?;
            let turn = parse_non_stream_turn(settings.protocol.clone(), &body)?;
            emit_completed_deltas(&turn, delta_tx.as_ref());
            return Ok(turn);
        }
        parse_event_stream(settings.protocol.clone(), response, delta_tx).await
    }

    async fn send_with_retry(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        messages: &[AgentMessage],
        tools: &[AgentToolDefinition],
        max_tokens: u32,
        stream: bool,
    ) -> Result<Response, ModelError> {
        for attempt in 0..REQUEST_ATTEMPTS {
            let request = self.request(settings, api_key, messages, tools, max_tokens, stream);
            let response = match request.send().await {
                Ok(response) => response,
                Err(error) if attempt + 1 < REQUEST_ATTEMPTS => {
                    tokio::time::sleep(retry_delay(attempt)).await;
                    let _ = error;
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            if transient_status(response.status()) && attempt + 1 < REQUEST_ATTEMPTS {
                tokio::time::sleep(retry_delay(attempt)).await;
                continue;
            }
            return Ok(response);
        }
        unreachable!("request loop returns on its final attempt")
    }

    fn request(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        messages: &[AgentMessage],
        tools: &[AgentToolDefinition],
        max_tokens: u32,
        stream: bool,
    ) -> reqwest::RequestBuilder {
        match settings.protocol {
            ProviderProtocol::OpenaiChatCompletions => {
                let mut body = Map::new();
                body.insert("model".into(), json!(settings.model));
                body.insert("messages".into(), openai_messages(messages));
                body.insert("max_tokens".into(), json!(max_tokens));
                body.insert("stream".into(), json!(stream));
                if !tools.is_empty() {
                    body.insert("tools".into(), openai_tools(tools));
                    body.insert("tool_choice".into(), json!("auto"));
                }
                let mut request = self
                    .client
                    .post(endpoint_with_suffix(&settings.endpoint, "chat/completions"))
                    .json(&Value::Object(body));
                if let Some(key) = api_key.filter(|key| !key.trim().is_empty()) {
                    request = request.bearer_auth(key);
                }
                request
            }
            ProviderProtocol::AnthropicMessages => {
                let (system, messages) = anthropic_messages(messages);
                let mut body = Map::new();
                body.insert("model".into(), json!(settings.model));
                body.insert("system".into(), json!(system));
                body.insert("messages".into(), messages);
                body.insert("max_tokens".into(), json!(max_tokens));
                body.insert("stream".into(), json!(stream));
                if !tools.is_empty() {
                    body.insert("tools".into(), anthropic_tools(tools));
                }
                let mut request = self
                    .client
                    .post(endpoint_with_suffix(&settings.endpoint, "messages"))
                    .header("anthropic-version", "2023-06-01")
                    .json(&Value::Object(body));
                if let Some(key) = api_key.filter(|key| !key.trim().is_empty()) {
                    request = request.header("x-api-key", key);
                }
                request
            }
        }
    }
}

fn openai_messages(messages: &[AgentMessage]) -> Value {
    Value::Array(
        messages
            .iter()
            .map(|message| match message.role {
                AgentRole::Assistant if !message.tool_calls.is_empty() => json!({
                    "role": "assistant",
                    "content": if message.content.is_empty() { Value::Null } else { json!(message.content) },
                    "tool_calls": message.tool_calls.iter().map(|call| json!({
                        "id": call.id,
                        "type": "function",
                        "function": {"name": call.name, "arguments": call.arguments_json}
                    })).collect::<Vec<_>>()
                }),
                AgentRole::Tool => json!({
                    "role": "tool",
                    "tool_call_id": message.tool_call_id,
                    "content": message.content,
                }),
                _ => json!({
                    "role": match message.role {
                        AgentRole::System => "system",
                        AgentRole::User => "user",
                        AgentRole::Assistant => "assistant",
                        AgentRole::Tool => "tool",
                    },
                    "content": message.content,
                }),
            })
            .collect(),
    )
}

fn anthropic_messages(messages: &[AgentMessage]) -> (String, Value) {
    let system = messages
        .iter()
        .filter(|message| message.role == AgentRole::System)
        .map(|message| message.content.clone())
        .collect::<Vec<_>>()
        .join("\n\n");
    let mut converted = Vec::new();
    for message in messages
        .iter()
        .filter(|message| message.role != AgentRole::System)
    {
        match message.role {
            AgentRole::Assistant if !message.tool_calls.is_empty() => {
                let mut blocks = Vec::new();
                if !message.content.is_empty() {
                    blocks.push(json!({"type":"text", "text": message.content}));
                }
                blocks.extend(message.tool_calls.iter().map(|call| {
                    json!({
                        "type": "tool_use",
                        "id": call.id,
                        "name": call.name,
                        "input": serde_json::from_str::<Value>(&call.arguments_json).unwrap_or_else(|_| json!({}))
                    })
                }));
                converted.push(json!({"role":"assistant", "content":blocks}));
            }
            AgentRole::Tool => converted.push(json!({
                "role":"user",
                "content":[{"type":"tool_result", "tool_use_id":message.tool_call_id, "content":message.content}]
            })),
            AgentRole::Assistant => converted.push(json!({"role":"assistant", "content":message.content})),
            AgentRole::User => converted.push(json!({"role":"user", "content":message.content})),
            AgentRole::System => {}
        }
    }
    (system, Value::Array(converted))
}

fn openai_tools(tools: &[AgentToolDefinition]) -> Value {
    json!(tools
        .iter()
        .map(|tool| json!({
            "type":"function",
            "function":{"name":tool.name, "description":tool.description, "parameters":tool.parameters}
        }))
        .collect::<Vec<_>>())
}

fn anthropic_tools(tools: &[AgentToolDefinition]) -> Value {
    json!(tools
        .iter()
        .map(|tool| json!({
            "name":tool.name, "description":tool.description, "input_schema":tool.parameters
        }))
        .collect::<Vec<_>>())
}

async fn parse_event_stream(
    protocol: ProviderProtocol,
    response: Response,
    delta_tx: Option<mpsc::UnboundedSender<ModelDelta>>,
) -> Result<ModelTurn, ModelError> {
    let mut stream = response.bytes_stream();
    let mut pending = String::new();
    let mut turn = ModelTurn::default();
    let mut tools = BTreeMap::<usize, PartialToolCall>::new();
    while let Some(chunk) = stream.next().await {
        let bytes = chunk?;
        pending.push_str(&String::from_utf8_lossy(&bytes));
        pending = pending.replace("\r\n", "\n");
        while let Some(boundary) = pending.find("\n\n") {
            let frame = pending[..boundary].to_string();
            pending.drain(..boundary + 2);
            for data in frame
                .lines()
                .filter_map(|line| line.strip_prefix("data:"))
                .map(str::trim)
            {
                if data.is_empty() || data == "[DONE]" {
                    continue;
                }
                let value = serde_json::from_str::<Value>(data)
                    .map_err(|error| ModelError::Malformed(error.to_string()))?;
                match protocol {
                    ProviderProtocol::OpenaiChatCompletions => {
                        apply_openai_stream_chunk(&value, &mut turn, &mut tools, delta_tx.as_ref())
                    }
                    ProviderProtocol::AnthropicMessages => apply_anthropic_stream_chunk(
                        &value,
                        &mut turn,
                        &mut tools,
                        delta_tx.as_ref(),
                    ),
                }
            }
        }
    }
    turn.tool_calls = finalize_tool_calls(tools);
    if turn.text.trim().is_empty() && turn.tool_calls.is_empty() {
        Err(ModelError::Empty)
    } else {
        Ok(turn)
    }
}

fn apply_openai_stream_chunk(
    value: &Value,
    turn: &mut ModelTurn,
    tools: &mut BTreeMap<usize, PartialToolCall>,
    delta_tx: Option<&mpsc::UnboundedSender<ModelDelta>>,
) {
    let Some(delta) = value.pointer("/choices/0/delta") else {
        return;
    };
    if let Some(text) = text_value(delta.get("content")) {
        turn.text.push_str(&text);
        emit(delta_tx, ModelDelta::Text(text));
    }
    for key in ["reasoning_content", "reasoning", "thinking"] {
        if let Some(reasoning) = text_value(delta.get(key)) {
            turn.reasoning.push_str(&reasoning);
            emit(delta_tx, ModelDelta::Reasoning(reasoning));
        }
    }
    if let Some(calls) = delta.get("tool_calls").and_then(Value::as_array) {
        for call in calls {
            let index = call.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
            let partial = tools.entry(index).or_default();
            if let Some(id) = call.get("id").and_then(Value::as_str) {
                partial.id.push_str(id);
            }
            if let Some(name) = call.pointer("/function/name").and_then(Value::as_str) {
                partial.name.push_str(name);
            }
            if let Some(arguments) = call.pointer("/function/arguments").and_then(Value::as_str) {
                partial.arguments.push_str(arguments);
            }
        }
    }
}

fn apply_anthropic_stream_chunk(
    value: &Value,
    turn: &mut ModelTurn,
    tools: &mut BTreeMap<usize, PartialToolCall>,
    delta_tx: Option<&mpsc::UnboundedSender<ModelDelta>>,
) {
    let index = value.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
    match value.get("type").and_then(Value::as_str) {
        Some("content_block_start") => {
            let block = value.get("content_block").unwrap_or(&Value::Null);
            match block.get("type").and_then(Value::as_str) {
                Some("tool_use") => {
                    let partial = tools.entry(index).or_default();
                    partial.id = block
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .into();
                    partial.name = block
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .into();
                    if let Some(input) = block.get("input").filter(|input| !input.is_null()) {
                        partial.arguments = input.to_string();
                    }
                }
                Some("text") => {
                    if let Some(text) = block.get("text").and_then(Value::as_str) {
                        turn.text.push_str(text);
                        emit(delta_tx, ModelDelta::Text(text.into()));
                    }
                }
                _ => {}
            }
        }
        Some("content_block_delta") => {
            let delta = value.get("delta").unwrap_or(&Value::Null);
            match delta.get("type").and_then(Value::as_str) {
                Some("text_delta") => {
                    if let Some(text) = delta.get("text").and_then(Value::as_str) {
                        turn.text.push_str(text);
                        emit(delta_tx, ModelDelta::Text(text.into()));
                    }
                }
                Some("thinking_delta") => {
                    if let Some(text) = delta.get("thinking").and_then(Value::as_str) {
                        turn.reasoning.push_str(text);
                        emit(delta_tx, ModelDelta::Reasoning(text.into()));
                    }
                }
                Some("input_json_delta") => {
                    if let Some(fragment) = delta.get("partial_json").and_then(Value::as_str) {
                        tools.entry(index).or_default().arguments.push_str(fragment);
                    }
                }
                _ => {}
            }
        }
        _ => {}
    }
}

fn parse_non_stream_turn(
    protocol: ProviderProtocol,
    body: &Value,
) -> Result<ModelTurn, ModelError> {
    let mut turn = ModelTurn::default();
    match protocol {
        ProviderProtocol::OpenaiChatCompletions => {
            let message = body
                .pointer("/choices/0/message")
                .ok_or(ModelError::Empty)?;
            turn.text = text_value(message.get("content")).unwrap_or_default();
            turn.reasoning = ["reasoning_content", "reasoning", "thinking"]
                .into_iter()
                .find_map(|key| text_value(message.get(key)))
                .unwrap_or_default();
            if let Some(calls) = message.get("tool_calls").and_then(Value::as_array) {
                turn.tool_calls = calls
                    .iter()
                    .map(|call| AgentToolCall {
                        id: call
                            .get("id")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .into(),
                        name: call
                            .pointer("/function/name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .into(),
                        arguments_json: call
                            .pointer("/function/arguments")
                            .and_then(Value::as_str)
                            .unwrap_or("{}")
                            .into(),
                    })
                    .filter(|call| !call.name.is_empty())
                    .collect();
            }
        }
        ProviderProtocol::AnthropicMessages => {
            if let Some(blocks) = body.get("content").and_then(Value::as_array) {
                for block in blocks {
                    match block.get("type").and_then(Value::as_str) {
                        Some("text") => turn.text.push_str(
                            block
                                .get("text")
                                .and_then(Value::as_str)
                                .unwrap_or_default(),
                        ),
                        Some("thinking") => turn.reasoning.push_str(
                            block
                                .get("thinking")
                                .and_then(Value::as_str)
                                .unwrap_or_default(),
                        ),
                        Some("tool_use") => turn.tool_calls.push(AgentToolCall {
                            id: block
                                .get("id")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .into(),
                            name: block
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .into(),
                            arguments_json: block
                                .get("input")
                                .cloned()
                                .unwrap_or_else(|| json!({}))
                                .to_string(),
                        }),
                        _ => {}
                    }
                }
            }
        }
    }
    if turn.text.trim().is_empty() && turn.tool_calls.is_empty() {
        Err(ModelError::Empty)
    } else {
        Ok(turn)
    }
}

fn finalize_tool_calls(tools: BTreeMap<usize, PartialToolCall>) -> Vec<AgentToolCall> {
    tools
        .into_values()
        .filter(|tool| !tool.name.is_empty())
        .map(|tool| AgentToolCall {
            id: if tool.id.is_empty() {
                uuid::Uuid::new_v4().to_string()
            } else {
                tool.id
            },
            name: tool.name,
            arguments_json: if tool.arguments.trim().is_empty() {
                "{}".into()
            } else {
                tool.arguments
            },
        })
        .collect()
}

fn text_value(value: Option<&Value>) -> Option<String> {
    let value = value?;
    if let Some(text) = value.as_str() {
        return Some(text.into());
    }
    value.as_array().map(|parts| {
        parts
            .iter()
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("")
    })
}

fn emit(sender: Option<&mpsc::UnboundedSender<ModelDelta>>, delta: ModelDelta) {
    if let Some(sender) = sender {
        let _ = sender.send(delta);
    }
}

fn emit_completed_deltas(turn: &ModelTurn, sender: Option<&mpsc::UnboundedSender<ModelDelta>>) {
    if !turn.reasoning.is_empty() {
        emit(sender, ModelDelta::Reasoning(turn.reasoning.clone()));
    }
    if !turn.text.is_empty() {
        emit(sender, ModelDelta::Text(turn.text.clone()));
    }
}

fn transient_status(status: StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 409 | 425 | 429) || status.is_server_error()
}

fn retry_delay(attempt: usize) -> Duration {
    Duration::from_millis(800 * (1_u64 << attempt.min(3)))
}

fn endpoint_with_suffix(endpoint: &str, suffix: &str) -> String {
    let trimmed = endpoint.trim_end_matches('/');
    if trimmed.ends_with(suffix) {
        trimmed.to_string()
    } else {
        format!("{trimmed}/{suffix}")
    }
}

fn http_error(status: StatusCode, body: &Value) -> ModelError {
    let message = body
        .pointer("/error/message")
        .and_then(Value::as_str)
        .or_else(|| body.get("message").and_then(Value::as_str))
        .unwrap_or("unknown provider error")
        .to_string();
    ModelError::Http { status, message }
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        value.to_string()
    } else {
        value.chars().take(max_chars).collect::<String>() + "\n[truncated]"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_openai_tool_turn() {
        let body = json!({"choices":[{"message":{"content":null,"reasoning_content":"plan","tool_calls":[{"id":"c1","type":"function","function":{"name":"read_file","arguments":"{\"path\":\"a.md\"}"}}]}}]});
        let turn = parse_non_stream_turn(ProviderProtocol::OpenaiChatCompletions, &body).unwrap();
        assert_eq!(turn.reasoning, "plan");
        assert_eq!(turn.tool_calls[0].name, "read_file");
    }

    #[test]
    fn converts_tool_history_for_anthropic() {
        let messages = vec![
            AgentMessage {
                role: AgentRole::Assistant,
                content: String::new(),
                tool_calls: vec![AgentToolCall {
                    id: "c1".into(),
                    name: "read_file".into(),
                    arguments_json: "{}".into(),
                }],
                tool_call_id: None,
            },
            AgentMessage {
                role: AgentRole::Tool,
                content: "ok".into(),
                tool_calls: Vec::new(),
                tool_call_id: Some("c1".into()),
            },
        ];
        let (_, value) = anthropic_messages(&messages);
        assert_eq!(
            value.pointer("/0/content/0/type").and_then(Value::as_str),
            Some("tool_use")
        );
        assert_eq!(
            value.pointer("/1/content/0/type").and_then(Value::as_str),
            Some("tool_result")
        );
    }
}
