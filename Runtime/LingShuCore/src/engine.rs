use crate::artifacts::{materialize_artifacts, ArtifactError};
use crate::contract::{kernel_contract, PlatformCapabilities};
use crate::models::*;
use crate::preview::{preview_file, PreviewKind};
use crate::providers::provider_catalog;
use crate::store::{RuntimeStore, StoreError};
use reqwest::{Client, StatusCode};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::sync::Mutex;
use uuid::Uuid;

const CONTEXT_MESSAGE_LIMIT: usize = 80;
const GOAL_ATTEMPTS: usize = 3;
const MODEL_REQUEST_ATTEMPTS: usize = 3;

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("no API token is configured for {0}")]
    MissingApiKey(String),
    #[error("unsupported runtime platform: {0}")]
    UnsupportedPlatform(String),
    #[error("model request failed: {0}")]
    Request(#[from] reqwest::Error),
    #[error("model returned HTTP {status}: {message}")]
    ModelHttp { status: StatusCode, message: String },
    #[error("model response did not contain text")]
    EmptyModelResponse,
    #[error("model response did not match the required JSON contract: {0}")]
    InvalidModelJson(String),
    #[error("task was not found: {0}")]
    MissingTask(Uuid),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Artifact(#[from] ArtifactError),
}

#[derive(Clone)]
pub struct RuntimeKernel {
    store: RuntimeStore,
    platform: String,
    capabilities: PlatformCapabilities,
    client: ModelClient,
    queue_guard: Arc<Mutex<()>>,
}

impl RuntimeKernel {
    pub fn new(store: RuntimeStore, platform: impl Into<String>) -> Result<Self, EngineError> {
        let platform = platform.into();
        let capabilities = kernel_contract()
            .platform_capabilities
            .get(&platform)
            .cloned()
            .ok_or_else(|| EngineError::UnsupportedPlatform(platform.clone()))?;
        Ok(Self {
            store,
            platform,
            capabilities,
            client: ModelClient::new()?,
            queue_guard: Arc::new(Mutex::new(())),
        })
    }

    pub fn store(&self) -> &RuntimeStore {
        &self.store
    }

    pub async fn snapshot(&self, provider_configured: bool) -> RuntimeSnapshot {
        self.store
            .snapshot(
                &self.platform,
                self.capabilities.clone(),
                provider_configured,
            )
            .await
    }

    pub async fn validate_provider(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
    ) -> Result<String, EngineError> {
        ensure_key(settings, api_key)?;
        self.client
            .complete(
                settings,
                api_key,
                "You are a connectivity probe. Reply with exactly: OK",
                "Reply with exactly: OK",
                32,
            )
            .await
    }

    pub async fn submit(
        &self,
        prompt: String,
        attachment_paths: Vec<PathBuf>,
    ) -> Result<SubmitReceipt, EngineError> {
        Ok(self.store.enqueue(prompt, attachment_paths).await?)
    }

    /// Drains the shared single-main-task queue. Calling this concurrently is safe; only one
    /// invocation owns the queue and every shell observes the same persisted state transitions.
    pub async fn run_queue(&self, api_key: Option<String>) -> Result<usize, EngineError> {
        let _guard = self.queue_guard.lock().await;
        let mut completed = 0;
        while let Some(thread_id) = self.store.next_queued_id().await {
            if !self.store.claim(thread_id).await? {
                break;
            }
            match self.execute(thread_id, api_key.as_deref()).await {
                Ok(()) => completed += 1,
                Err(error) => {
                    let locale = self.store.settings().await.locale;
                    let message = localized_failure(locale, &error);
                    self.store
                        .fail(thread_id, message, error.to_string())
                        .await?;
                }
            }
        }
        Ok(completed)
    }

    pub async fn cancel(&self, thread_id: Uuid) -> Result<bool, EngineError> {
        Ok(self.store.cancel(thread_id).await?)
    }

    async fn execute(&self, thread_id: Uuid, api_key: Option<&str>) -> Result<(), EngineError> {
        let task = self
            .store
            .task(thread_id)
            .await
            .ok_or(EngineError::MissingTask(thread_id))?;
        let settings = self.store.settings().await;
        ensure_key(&settings, api_key)?;
        let history = self
            .store
            .conversation_context(thread_id, CONTEXT_MESSAGE_LIMIT)
            .await;
        let attachment_context = attachment_context(&task.attachment_paths);
        let goal = self
            .generate_goal(
                &settings,
                api_key,
                &history,
                &task.prompt,
                &attachment_context,
            )
            .await?;
        self.store.set_goal(thread_id, goal.clone()).await?;

        if self
            .store
            .task(thread_id)
            .await
            .map(|task| task.status == TaskStatus::Cancelled)
            .unwrap_or(true)
        {
            return Ok(());
        }

        let completion = self
            .produce_completion(
                &settings,
                api_key,
                &history,
                &task.prompt,
                &attachment_context,
                &goal,
            )
            .await?;
        if self
            .store
            .task(thread_id)
            .await
            .map(|task| task.status == TaskStatus::Cancelled)
            .unwrap_or(true)
        {
            return Ok(());
        }
        let artifacts = materialize_artifacts(&settings.workspace, &completion.artifacts)?;
        self.store
            .complete(thread_id, completion.reply, artifacts)
            .await?;
        Ok(())
    }

    async fn generate_goal(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        history: &[ChatMessage],
        prompt: &str,
        attachment_context: &str,
    ) -> Result<GoalSpec, EngineError> {
        let history = format_history(history);
        let system = format!(
            "{}\nYou are LingShu's shared cross-platform goal compiler. Produce one complete GoalSpec as a single JSON object and no prose. Never silently invent missing references. Use the full conversation to resolve references, including older turns. Windows computer control and realtime perception are unavailable; do not promise those capabilities. Required fields and enum values:\n{}",
            settings.locale.language_directive(),
            goal_schema_instruction(),
        );
        let user = format!(
            "Full conversation context:\n{history}\n\nCurrent user input:\n{prompt}\n\nAttachments:\n{attachment_context}\n\nCompile the current input into the required GoalSpec."
        );
        let mut failures = Vec::new();
        for attempt in 1..=GOAL_ATTEMPTS {
            let attempt_user = format!(
                "Independent generation attempt {attempt}/{GOAL_ATTEMPTS}. Do not repair or reuse another attempt.\n\n{user}"
            );
            match self
                .client
                .complete(settings, api_key, &system, &attempt_user, 2_400)
                .await
            {
                Ok(response) => match decode_json::<GoalSpec>(&response) {
                    Ok(goal) if goal.is_ready() => return Ok(goal),
                    Ok(_) => failures.push(format!("attempt {attempt}: incomplete GoalSpec")),
                    Err(error) => failures.push(format!("attempt {attempt}: {error}")),
                },
                Err(error) => failures.push(format!("attempt {attempt}: {error}")),
            }
        }
        Err(EngineError::InvalidModelJson(failures.join("; ")))
    }

    async fn produce_completion(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        history: &[ChatMessage],
        prompt: &str,
        attachment_context: &str,
        goal: &GoalSpec,
    ) -> Result<TaskCompletion, EngineError> {
        let goal_json = serde_json::to_string_pretty(goal)
            .map_err(|error| EngineError::InvalidModelJson(error.to_string()))?;
        let system = format!(
            "{}\nYou are LingShu, an open-model desktop agent running on Windows through the shared LingShu runtime kernel. Fulfil the accepted GoalSpec faithfully. You may answer and create registered artifacts, but this Windows build does not expose computer control or realtime perception. Return exactly one JSON object with this shape and no prose outside it:\n{{\"reply\":\"user-facing Markdown\",\"artifacts\":[{{\"title\":\"...\",\"file_name\":\"...\",\"kind\":\"markdown|text|json|html|docx|pptx\",\"content\":\"full document body\",\"slides\":[{{\"title\":\"...\",\"bullets\":[\"...\"],\"notes\":\"...\"}}]}}]}}\nFor pptx, put slide content in slides. For docx and text formats, put the complete content in content. For chat replies, return an empty artifacts array. Do not claim a file exists unless you include it in artifacts.",
            settings.locale.language_directive(),
        );
        let user = format!(
            "Accepted GoalSpec:\n{goal_json}\n\nConversation context:\n{}\n\nCurrent request:\n{prompt}\n\nAttachments:\n{attachment_context}",
            format_history(history),
        );
        let response = self
            .client
            .complete(settings, api_key, &system, &user, 12_000)
            .await?;
        let completion = decode_json::<TaskCompletion>(&response)?;
        if completion.reply.trim().is_empty() {
            return Err(EngineError::InvalidModelJson("reply is empty".into()));
        }
        Ok(completion)
    }
}

#[derive(Clone)]
struct ModelClient {
    client: Client,
}

impl ModelClient {
    fn new() -> Result<Self, reqwest::Error> {
        Ok(Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(20))
                .timeout(Duration::from_secs(180))
                .user_agent("LingShu-Runtime/1.1")
                .build()?,
        })
    }

    async fn complete(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        system: &str,
        user: &str,
        max_tokens: u32,
    ) -> Result<String, EngineError> {
        for attempt in 0..MODEL_REQUEST_ATTEMPTS {
            let request = match settings.protocol {
                ProviderProtocol::OpenaiChatCompletions => {
                    let url = endpoint_with_suffix(&settings.endpoint, "chat/completions");
                    let mut request = self.client.post(url).json(&json!({
                        "model": settings.model,
                        "messages": [
                            {"role": "system", "content": system},
                            {"role": "user", "content": user}
                        ],
                        "max_tokens": max_tokens,
                        "stream": false
                    }));
                    if let Some(key) = api_key.filter(|key| !key.trim().is_empty()) {
                        request = request.bearer_auth(key);
                    }
                    request
                }
                ProviderProtocol::AnthropicMessages => {
                    let url = endpoint_with_suffix(&settings.endpoint, "messages");
                    let mut request = self
                        .client
                        .post(url)
                        .header("anthropic-version", "2023-06-01")
                        .json(&json!({
                            "model": settings.model,
                            "system": system,
                            "messages": [{"role": "user", "content": user}],
                            "max_tokens": max_tokens
                        }));
                    if let Some(key) = api_key.filter(|key| !key.trim().is_empty()) {
                        request = request.header("x-api-key", key);
                    }
                    request
                }
            };

            let response = match request.send().await {
                Ok(response) => response,
                Err(error) if attempt + 1 < MODEL_REQUEST_ATTEMPTS => {
                    tokio::time::sleep(retry_delay(attempt)).await;
                    let _ = error;
                    continue;
                }
                Err(error) => return Err(error.into()),
            };
            let status = response.status();
            let text = response.text().await?;
            let body = serde_json::from_str::<Value>(&text)
                .unwrap_or_else(|_| json!({"message": truncate(&text, 2_000)}));
            if !status.is_success() {
                if transient_status(status) && attempt + 1 < MODEL_REQUEST_ATTEMPTS {
                    tokio::time::sleep(retry_delay(attempt)).await;
                    continue;
                }
                return Err(http_error(status, &body));
            }
            return match settings.protocol {
                ProviderProtocol::OpenaiChatCompletions => {
                    extract_openai_text(&body).ok_or(EngineError::EmptyModelResponse)
                }
                ProviderProtocol::AnthropicMessages => body
                    .get("content")
                    .and_then(Value::as_array)
                    .and_then(|blocks| {
                        blocks
                            .iter()
                            .find_map(|block| block.get("text").and_then(Value::as_str))
                    })
                    .map(str::to_string)
                    .ok_or(EngineError::EmptyModelResponse),
            };
        }
        unreachable!("model request loop always returns on its final attempt")
    }
}

fn transient_status(status: StatusCode) -> bool {
    matches!(status.as_u16(), 408 | 409 | 425 | 429) || status.is_server_error()
}

fn retry_delay(attempt: usize) -> Duration {
    Duration::from_millis(800 * (1_u64 << attempt.min(3)))
}

fn ensure_key(settings: &RuntimeSettings, api_key: Option<&str>) -> Result<(), EngineError> {
    let requires_key = provider_catalog()
        .iter()
        .find(|provider| provider.id == settings.provider_id)
        .map(|provider| provider.requires_api_key)
        .unwrap_or(true);
    if requires_key && api_key.map(str::trim).unwrap_or_default().is_empty() {
        return Err(EngineError::MissingApiKey(settings.provider_name.clone()));
    }
    Ok(())
}

fn endpoint_with_suffix(endpoint: &str, suffix: &str) -> String {
    let trimmed = endpoint.trim_end_matches('/');
    if trimmed.ends_with(suffix) {
        trimmed.to_string()
    } else {
        format!("{trimmed}/{suffix}")
    }
}

fn http_error(status: StatusCode, body: &Value) -> EngineError {
    let message = body
        .pointer("/error/message")
        .and_then(Value::as_str)
        .or_else(|| body.get("message").and_then(Value::as_str))
        .unwrap_or("unknown provider error")
        .to_string();
    EngineError::ModelHttp { status, message }
}

fn extract_openai_text(body: &Value) -> Option<String> {
    let content = body.pointer("/choices/0/message/content")?;
    if let Some(text) = content.as_str() {
        return Some(text.to_string());
    }
    content
        .as_array()
        .map(|parts| {
            parts
                .iter()
                .filter_map(|part| {
                    part.get("text").and_then(|value| {
                        value.as_str().map(str::to_string).or_else(|| {
                            value
                                .get("value")
                                .and_then(Value::as_str)
                                .map(str::to_string)
                        })
                    })
                })
                .collect::<Vec<_>>()
                .join("")
        })
        .filter(|text| !text.is_empty())
}

fn decode_json<T: serde::de::DeserializeOwned>(raw: &str) -> Result<T, EngineError> {
    let candidate = json_candidate(raw)
        .ok_or_else(|| EngineError::InvalidModelJson("no JSON object found".into()))?;
    serde_json::from_str(candidate)
        .map_err(|error| EngineError::InvalidModelJson(error.to_string()))
}

fn json_candidate(raw: &str) -> Option<&str> {
    let trimmed = raw.trim();
    if trimmed.starts_with('{') && trimmed.ends_with('}') {
        return Some(trimmed);
    }
    let start = trimmed.find('{')?;
    let mut depth = 0_u32;
    let mut in_string = false;
    let mut escaped = false;
    for (offset, character) in trimmed[start..].char_indices() {
        if in_string {
            if escaped {
                escaped = false;
            } else if character == '\\' {
                escaped = true;
            } else if character == '"' {
                in_string = false;
            }
            continue;
        }
        match character {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return Some(&trimmed[start..start + offset + character.len_utf8()]);
                }
            }
            _ => {}
        }
    }
    None
}

fn format_history(messages: &[ChatMessage]) -> String {
    if messages.is_empty() {
        return "(no prior conversation)".into();
    }
    messages
        .iter()
        .map(|message| {
            let role = match message.role {
                MessageRole::User => "USER",
                MessageRole::Assistant => "ASSISTANT",
                MessageRole::System => "SYSTEM",
            };
            format!("[{role}] {}", message.text)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn attachment_context(paths: &[PathBuf]) -> String {
    if paths.is_empty() {
        return "(none)".into();
    }
    paths
        .iter()
        .map(|path| match preview_file(path) {
            Ok(preview) => {
                let body = match preview.kind {
                    PreviewKind::Image | PreviewKind::Pdf => {
                        "Binary media is available for in-app preview; no text was extracted."
                            .into()
                    }
                    _ => truncate(&preview.content, 24_000),
                };
                format!(
                    "FILE: {}\nPATH: {}\nTYPE: {:?}\nCONTENT:\n{}",
                    preview.name, preview.path, preview.kind, body
                )
            }
            Err(error) => format!("FILE: {}\nUNREADABLE: {error}", path.display()),
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_string();
    }
    value.chars().take(max_chars).collect::<String>() + "\n[truncated]"
}

fn goal_schema_instruction() -> &'static str {
    r#"{
  "objective": "string",
  "kind": "task|interaction|question",
  "output_mode": "chat_reply|artifact|visible_interaction|external_action",
  "reference_scope": "current_input|default_anchor|candidate_background|visible_context|task_thread|memory",
  "reference_evidence": ["string"],
  "reference_explicit": true,
  "reference_confidence": "high|medium|low",
  "constraints": ["string"],
  "boundaries": ["string"],
  "risks": ["string"],
  "success_criteria": ["string"],
  "open_questions": ["string"]
}"#
}

fn localized_failure(locale: AppLocale, error: &EngineError) -> String {
    match locale {
        AppLocale::ZhCn => format!("本轮未能完成：{error}。任务没有使用默认目标降级执行，请检查模型通道后重试。"),
        AppLocale::En => format!("This run could not be completed: {error}. LingShu did not fall back to a fabricated default goal; check the model channel and retry."),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_balanced_json_without_leaking_surrounding_text() {
        let raw = "preface ```json\n{\"reply\":\"ok\",\"artifacts\":[]}\n``` tail";
        let completion: TaskCompletion = decode_json(raw).unwrap();
        assert_eq!(completion.reply, "ok");
    }

    #[test]
    fn endpoint_suffix_is_not_duplicated() {
        assert_eq!(
            endpoint_with_suffix("https://example.test/v1", "chat/completions"),
            "https://example.test/v1/chat/completions"
        );
        assert_eq!(
            endpoint_with_suffix(
                "https://example.test/v1/chat/completions",
                "chat/completions"
            ),
            "https://example.test/v1/chat/completions"
        );
    }

    #[test]
    fn language_directive_is_first_in_runtime_prompts() {
        assert!(AppLocale::En
            .language_directive()
            .starts_with("Highest priority"));
        assert!(AppLocale::ZhCn
            .language_directive()
            .starts_with("最高优先级"));
    }
}
