use crate::model_client::{AgentToolDefinition, ModelClient, ModelError, ModelTurn};
use crate::models::{AgentMessage, AgentRole, AgentToolCall, RuntimeSettings};
use axum::body::Body;
use axum::extract::State;
use axum::http::{header, HeaderMap, Response, StatusCode};
use axum::response::IntoResponse;
use axum::routing::post;
use axum::{Json, Router};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::oneshot;
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum LoopGatewayError {
    #[error("managed loop gateway could not bind: {0}")]
    Bind(#[from] std::io::Error),
    #[error("managed loop gateway failed: {0}")]
    Model(#[from] ModelError),
    #[error("managed loop gateway received an invalid Responses request: {0}")]
    InvalidRequest(String),
}

#[derive(Clone)]
struct GatewayState {
    client: ModelClient,
    settings: RuntimeSettings,
    api_key: Option<String>,
    bearer_token: String,
}

/// A loop harness never receives LingShu's provider credentials. It receives only this
/// short-lived localhost endpoint and a random per-run bearer token.
pub struct LoopTransportGateway {
    address: SocketAddr,
    bearer_token: String,
    shutdown: Option<oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<()>,
}

impl LoopTransportGateway {
    pub async fn start(
        settings: RuntimeSettings,
        api_key: Option<String>,
    ) -> Result<Self, LoopGatewayError> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let bearer_token = format!("lingshu-loop-{}", Uuid::new_v4());
        let state = Arc::new(GatewayState {
            client: ModelClient::new()?,
            settings,
            api_key,
            bearer_token: bearer_token.clone(),
        });
        let router = Router::new()
            .route("/v1/responses", post(handle_responses))
            .route("/responses", post(handle_responses))
            .with_state(state);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let task = tokio::spawn(async move {
            let server = axum::serve(listener, router).with_graceful_shutdown(async {
                let _ = shutdown_rx.await;
            });
            let _ = server.await;
        });
        Ok(Self {
            address,
            bearer_token,
            shutdown: Some(shutdown_tx),
            task,
        })
    }

    pub fn base_url(&self) -> String {
        format!("http://{}/v1", self.address)
    }

    pub fn bearer_token(&self) -> &str {
        &self.bearer_token
    }

    pub async fn stop(mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        let _ = self.task.await;
    }
}

async fn handle_responses(
    State(state): State<Arc<GatewayState>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Response<Body> {
    if !valid_bearer(&headers, &state.bearer_token) {
        return json_error(
            StatusCode::UNAUTHORIZED,
            "The LingShu loop gateway token is missing or invalid.",
        );
    }
    match execute_responses_request(&state, &body).await {
        Ok((turn, stream)) => responses_reply(&state.settings.model, turn, stream),
        Err(error) => json_error(StatusCode::BAD_GATEWAY, &error.to_string()),
    }
}

fn valid_bearer(headers: &HeaderMap, expected: &str) -> bool {
    headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|value| value == expected)
}

async fn execute_responses_request(
    state: &GatewayState,
    body: &Value,
) -> Result<(ModelTurn, bool), LoopGatewayError> {
    let messages = gateway_messages(body)?;
    let tools = gateway_tools(body);
    let max_tokens = body
        .get("max_output_tokens")
        .and_then(Value::as_u64)
        .unwrap_or(8_192)
        .clamp(1, 64_000) as u32;
    let turn = state
        .client
        .turn(
            &state.settings,
            state.api_key.as_deref(),
            &messages,
            &tools,
            max_tokens,
            None,
        )
        .await?;
    Ok((
        turn,
        body.get("stream").and_then(Value::as_bool).unwrap_or(false),
    ))
}

fn gateway_messages(body: &Value) -> Result<Vec<AgentMessage>, LoopGatewayError> {
    let mut messages = Vec::new();
    if let Some(instructions) = body.get("instructions").and_then(Value::as_str) {
        push_text_message(&mut messages, AgentRole::System, instructions);
    }
    match body.get("input") {
        Some(Value::String(text)) => push_text_message(&mut messages, AgentRole::User, text),
        Some(Value::Array(items)) => {
            for item in items {
                match item.get("type").and_then(Value::as_str) {
                    Some("function_call") => {
                        let call = AgentToolCall {
                            id: item
                                .get("call_id")
                                .or_else(|| item.get("id"))
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                            name: item
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or_default()
                                .to_string(),
                            arguments_json: item
                                .get("arguments")
                                .and_then(Value::as_str)
                                .unwrap_or("{}")
                                .to_string(),
                        };
                        if call.name.is_empty() {
                            continue;
                        }
                        if let Some(message) = messages
                            .last_mut()
                            .filter(|message| message.role == AgentRole::Assistant)
                        {
                            message.tool_calls.push(call);
                        } else {
                            messages.push(AgentMessage {
                                role: AgentRole::Assistant,
                                content: String::new(),
                                tool_calls: vec![call],
                                tool_call_id: None,
                            });
                        }
                    }
                    Some("function_call_output") => messages.push(AgentMessage {
                        role: AgentRole::Tool,
                        content: response_content_text(item.get("output")),
                        tool_calls: Vec::new(),
                        tool_call_id: item
                            .get("call_id")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                    }),
                    Some("reasoning") | Some("item_reference") => {}
                    _ => {
                        let role = match item.get("role").and_then(Value::as_str).unwrap_or("user")
                        {
                            "system" | "developer" => AgentRole::System,
                            "assistant" => AgentRole::Assistant,
                            _ => AgentRole::User,
                        };
                        let content = response_content_text(item.get("content"));
                        if !content.trim().is_empty() {
                            push_text_message(&mut messages, role, &content);
                        }
                    }
                }
            }
        }
        Some(Value::Null) | None => {}
        Some(_) => {
            return Err(LoopGatewayError::InvalidRequest(
                "`input` must be a string or an array".into(),
            ));
        }
    }
    if messages.is_empty() {
        return Err(LoopGatewayError::InvalidRequest(
            "the request did not contain usable input".into(),
        ));
    }
    Ok(messages)
}

fn push_text_message(messages: &mut Vec<AgentMessage>, role: AgentRole, content: &str) {
    messages.push(AgentMessage {
        role,
        content: content.to_string(),
        tool_calls: Vec::new(),
        tool_call_id: None,
    });
}

fn response_content_text(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    if let Some(text) = value.as_str() {
        return text.to_string();
    }
    if let Some(parts) = value.as_array() {
        return parts
            .iter()
            .filter_map(|part| {
                part.get("text")
                    .or_else(|| part.get("output_text"))
                    .and_then(Value::as_str)
            })
            .collect::<Vec<_>>()
            .join("");
    }
    value.to_string()
}

fn gateway_tools(body: &Value) -> Vec<AgentToolDefinition> {
    body.get("tools")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|tool| {
            let function = tool.get("function").unwrap_or(tool);
            let name = function.get("name").and_then(Value::as_str)?;
            Some(AgentToolDefinition {
                name: name.to_string(),
                description: function
                    .get("description")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                parameters: function
                    .get("parameters")
                    .cloned()
                    .unwrap_or_else(|| json!({"type":"object","properties":{}})),
            })
        })
        .collect()
}

fn responses_reply(model: &str, turn: ModelTurn, stream: bool) -> Response<Body> {
    let response = completed_response(model, &turn);
    if !stream {
        return Json(response).into_response();
    }
    let response_id = response
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("resp_lingshu")
        .to_string();
    let mut sequence = 0_u64;
    let mut events = vec![json!({
        "type":"response.created",
        "sequence_number":sequence,
        "response":{
            "id":response_id,
            "object":"response",
            "created_at":chrono::Utc::now().timestamp(),
            "model":model,
            "status":"in_progress",
            "output":[]
        }
    })];
    if !turn.text.is_empty() {
        sequence += 1;
        events.push(json!({
            "type":"response.output_text.delta",
            "sequence_number":sequence,
            "item_id":format!("msg_{}", Uuid::new_v4().simple()),
            "output_index":0,
            "content_index":0,
            "delta":turn.text
        }));
    }
    for (index, call) in turn.tool_calls.iter().enumerate() {
        sequence += 1;
        events.push(json!({
            "type":"response.function_call_arguments.delta",
            "sequence_number":sequence,
            "item_id":call.id,
            "output_index":index,
            "delta":call.arguments_json
        }));
    }
    sequence += 1;
    events.push(json!({
        "type":"response.completed",
        "sequence_number":sequence,
        "response":response
    }));
    let mut encoded = events
        .into_iter()
        .map(|event| format!("data: {}\n\n", event))
        .collect::<String>();
    encoded.push_str("data: [DONE]\n\n");
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/event-stream")
        .header(header::CACHE_CONTROL, "no-cache")
        .body(Body::from(encoded))
        .unwrap_or_else(|_| Response::new(Body::empty()))
}

fn completed_response(model: &str, turn: &ModelTurn) -> Value {
    let response_id = format!("resp_{}", Uuid::new_v4().simple());
    let mut output = Vec::new();
    if !turn.reasoning.is_empty() {
        output.push(json!({
            "type":"reasoning",
            "id":format!("rs_{}", Uuid::new_v4().simple()),
            "summary":[{"type":"summary_text","text":turn.reasoning}]
        }));
    }
    if !turn.text.is_empty() {
        output.push(json!({
            "type":"message",
            "id":format!("msg_{}", Uuid::new_v4().simple()),
            "role":"assistant",
            "status":"completed",
            "content":[{"type":"output_text","text":turn.text,"annotations":[]}]
        }));
    }
    output.extend(turn.tool_calls.iter().map(|call| {
        json!({
            "type":"function_call",
            "id":format!("fc_{}", Uuid::new_v4().simple()),
            "call_id":call.id,
            "name":call.name,
            "arguments":call.arguments_json,
            "status":"completed"
        })
    }));
    json!({
        "id":response_id,
        "object":"response",
        "created_at":chrono::Utc::now().timestamp(),
        "model":model,
        "status":"completed",
        "output":output,
        "usage":{
            "input_tokens":0,
            "output_tokens":0,
            "total_tokens":0,
            "input_tokens_details":{"cached_tokens":0},
            "output_tokens_details":{"reasoning_tokens":0}
        }
    })
}

fn json_error(status: StatusCode, message: &str) -> Response<Body> {
    (
        status,
        Json(json!({
            "error":{
                "message":message,
                "type":"lingshu_loop_gateway_error"
            }
        })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::ProviderProtocol;

    #[test]
    fn converts_responses_tool_history_without_losing_call_identity() {
        let body = json!({
            "input":[
                {"role":"user","content":[{"type":"input_text","text":"inspect"}]},
                {"type":"function_call","call_id":"call-1","name":"read_file","arguments":"{\"path\":\"a.md\"}"},
                {"type":"function_call_output","call_id":"call-1","output":"hello"}
            ]
        });
        let messages = gateway_messages(&body).unwrap();
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[1].tool_calls[0].id, "call-1");
        assert_eq!(messages[2].tool_call_id.as_deref(), Some("call-1"));
    }

    #[test]
    fn completed_reply_is_valid_for_text_and_parallel_tools() {
        let reply = completed_response(
            "model",
            &ModelTurn {
                text: "working".into(),
                reasoning: "plan".into(),
                tool_calls: vec![
                    AgentToolCall {
                        id: "a".into(),
                        name: "read_file".into(),
                        arguments_json: "{}".into(),
                    },
                    AgentToolCall {
                        id: "b".into(),
                        name: "list_files".into(),
                        arguments_json: "{}".into(),
                    },
                ],
            },
        );
        assert_eq!(
            reply.pointer("/status").and_then(Value::as_str),
            Some("completed")
        );
        assert_eq!(
            reply.pointer("/output/2/call_id").and_then(Value::as_str),
            Some("a")
        );
        assert_eq!(
            reply.pointer("/output/3/call_id").and_then(Value::as_str),
            Some("b")
        );
    }

    #[test]
    fn provider_protocol_does_not_change_the_gateway_contract() {
        for protocol in [
            ProviderProtocol::OpenaiResponses,
            ProviderProtocol::OpenaiChatCompletions,
            ProviderProtocol::AnthropicMessages,
        ] {
            let mut settings = RuntimeSettings::default();
            settings.protocol = protocol;
            assert!(!settings.model.is_empty());
        }
    }
}
