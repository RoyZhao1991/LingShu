use crate::artifacts::{materialize_artifacts, ArtifactError};
use crate::contract::{kernel_contract, PlatformCapabilities};
use crate::model_client::{AgentToolDefinition, ModelClient, ModelDelta, ModelError, ModelTurn};
use crate::models::*;
use crate::plugins::{PluginError, PluginRegistry};
use crate::preview::{preview_file, PreviewKind};
use crate::providers::provider_catalog;
use crate::store::{RuntimeStore, StoreError};
use chrono::{DateTime, Utc};
use futures_util::future::join_all;
use serde::Deserialize;
use serde_json::{json, Value};
use std::future::Future;
use std::path::{Component, Path, PathBuf};
use std::pin::Pin;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use tokio::sync::{mpsc, Mutex};
use uuid::Uuid;

const CONTEXT_MESSAGE_LIMIT: usize = 80;
const GOAL_ATTEMPTS: usize = 3;
const MAX_AGENT_TURNS: usize = 40;
const MAX_CHILD_DEPTH: u8 = 3;
const STUCK_REPEAT_THRESHOLD: usize = 5;
const MAX_RUNTIME_CONTRACT_CORRECTIONS: usize = 2;
const MIN_GOAL_TIMEOUT_SECONDS: u64 = 30;
const MAX_GOAL_TIMEOUT_SECONDS: [u64; GOAL_ATTEMPTS] = [75, 120, 180];

#[derive(Debug, Error)]
pub enum EngineError {
    #[error("no API token is configured for {0}")]
    MissingApiKey(String),
    #[error("unsupported runtime platform: {0}")]
    UnsupportedPlatform(String),
    #[error(transparent)]
    Model(#[from] ModelError),
    #[error("model response did not match the required JSON contract: {0}")]
    InvalidModelJson(String),
    #[error("{phase} timed out after {seconds} seconds")]
    ModelTimeout { phase: String, seconds: u64 },
    #[error("task was not found: {0}")]
    MissingTask(Uuid),
    #[error("task execution was cancelled")]
    Cancelled,
    #[error("local operation failed: {0}")]
    LocalOperation(String),
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Artifact(#[from] ArtifactError),
    #[error(transparent)]
    Plugin(#[from] PluginError),
}

#[derive(Clone)]
pub struct RuntimeKernel {
    store: RuntimeStore,
    platform: String,
    capabilities: PlatformCapabilities,
    client: ModelClient,
    plugins: PluginRegistry,
    queue_guard: Arc<Mutex<()>>,
}

#[derive(Debug)]
enum SessionOutcome {
    Completed {
        text: String,
        messages: Vec<AgentMessage>,
    },
    Blocked,
    Cancelled,
}

#[derive(Debug)]
struct ToolExecution {
    call: AgentToolCall,
    output: String,
    network_command: bool,
    command_succeeded: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct PlanArguments {
    #[serde(default)]
    items: Vec<PlanItemArguments>,
}

#[derive(Debug, Deserialize)]
struct PlanItemArguments {
    title: String,
    #[serde(default)]
    detail: String,
    #[serde(default)]
    status: String,
}

#[derive(Debug, Deserialize)]
struct PathArguments {
    path: String,
}

#[derive(Debug, Deserialize)]
struct ListArguments {
    #[serde(default)]
    path: String,
    #[serde(default)]
    recursive: bool,
}

#[derive(Debug, Deserialize)]
struct WriteArguments {
    path: String,
    content: String,
}

#[derive(Debug, Deserialize)]
struct CommandArguments {
    command: String,
    #[serde(default)]
    timeout_seconds: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct SpawnArguments {
    objective: String,
    #[serde(default)]
    role: String,
}

#[derive(Debug, Deserialize)]
struct AskArguments {
    prompt: String,
}

#[derive(Debug, Deserialize)]
struct VerificationResult {
    passed: bool,
    summary: String,
    #[serde(default)]
    findings: Vec<String>,
}

impl RuntimeKernel {
    pub fn new(store: RuntimeStore, platform: impl Into<String>) -> Result<Self, EngineError> {
        Self::new_with_resources(store, platform, None)
    }

    pub fn new_with_resources(
        store: RuntimeStore,
        platform: impl Into<String>,
        resource_root: Option<PathBuf>,
    ) -> Result<Self, EngineError> {
        let platform = platform.into();
        let capabilities = kernel_contract()
            .platform_capabilities
            .get(&platform)
            .cloned()
            .ok_or_else(|| EngineError::UnsupportedPlatform(platform.clone()))?;
        let plugins = PluginRegistry::new(store.data_dir(), resource_root, platform.clone())?;
        Ok(Self {
            store,
            platform,
            capabilities,
            client: ModelClient::new()?,
            plugins,
            queue_guard: Arc::new(Mutex::new(())),
        })
    }

    pub fn store(&self) -> &RuntimeStore {
        &self.store
    }

    pub fn plugins(&self) -> &PluginRegistry {
        &self.plugins
    }

    pub async fn snapshot(&self, provider_configured: bool) -> RuntimeSnapshot {
        let mut snapshot = self
            .store
            .snapshot(
                &self.platform,
                self.capabilities.clone(),
                provider_configured,
            )
            .await;
        snapshot.plugins = self.plugins.list();
        snapshot
    }

    pub async fn validate_provider(
        &self,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
    ) -> Result<String, EngineError> {
        ensure_key(settings, api_key)?;
        Ok(self
            .client
            .complete(
                settings,
                api_key,
                "You are a connectivity probe. Reply with exactly: OK",
                "Reply with exactly: OK",
                32,
            )
            .await?)
    }

    pub async fn submit(
        &self,
        prompt: String,
        attachment_paths: Vec<PathBuf>,
    ) -> Result<SubmitReceipt, EngineError> {
        Ok(self.store.enqueue(prompt, attachment_paths).await?)
    }

    /// Only the foreground/main queue is serialized. `spawn_task` sessions use independent
    /// persisted contexts and may run concurrently without mutating the main conversation.
    pub async fn run_queue(&self, api_key: Option<String>) -> Result<usize, EngineError> {
        let _guard = self.queue_guard.lock().await;
        let mut completed = 0;
        while let Some(thread_id) = self.store.next_queued_id().await {
            if !self.store.claim(thread_id).await? {
                break;
            }
            match self.execute(thread_id, api_key.as_deref()).await {
                Ok(()) => completed += 1,
                Err(EngineError::Cancelled) => {}
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

    pub async fn resume(
        &self,
        thread_id: Uuid,
        answer: String,
        api_key: Option<String>,
    ) -> Result<bool, EngineError> {
        let Some(task) = self.store.prepare_resume(thread_id, answer).await? else {
            return Ok(false);
        };
        let settings = self.store.settings().await;
        ensure_key(&settings, api_key.as_deref())?;
        let Some(goal) = task.goal_spec.clone() else {
            return Err(EngineError::InvalidModelJson(
                "blocked task has no GoalSpec".into(),
            ));
        };
        self.store
            .append_event(
                thread_id,
                RuntimeEventKind::HumanInteraction,
                RuntimeEventState::Completed,
                "User",
                localized(&settings.locale, "继续执行", "Resume"),
                localized(
                    &settings.locale,
                    "已收到人的输入，从原会话位置继续。",
                    "Human input received; resuming the same session.",
                ),
            )
            .await?;
        let outcome = self
            .run_agent_session(task, goal.clone(), settings.clone(), api_key.clone(), None)
            .await?;
        let outcome = match outcome {
            SessionOutcome::Completed { text, messages }
                if should_run_checker(&goal, &self.store.task(thread_id).await) =>
            {
                self.verify_and_revise(thread_id, goal, settings, api_key, text, messages)
                    .await?
            }
            other => other,
        };
        self.finish_session_outcome(thread_id, outcome).await?;
        Ok(true)
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
                thread_id,
                &settings,
                api_key,
                &history,
                &task.prompt,
                &attachment_context,
            )
            .await?;
        self.store.set_goal(thread_id, goal.clone()).await?;
        self.store
            .append_event(
                thread_id,
                RuntimeEventKind::Plan,
                RuntimeEventState::Completed,
                "GoalSpec",
                localized(&settings.locale, "核心目标已确认", "Goal accepted"),
                goal.objective.clone(),
            )
            .await?;
        if self.store.task_is_cancelled(thread_id).await {
            return Err(EngineError::Cancelled);
        }

        let plugin_context = self.plugins.prompt_context(settings.locale);
        let messages = initial_session_messages(
            &settings,
            RuntimeAuthorityContext {
                platform: &self.platform,
                capabilities: &self.capabilities,
                plugin_context: &plugin_context,
            },
            &history,
            &task.prompt,
            &attachment_context,
            &goal,
            task.depth,
        )?;
        self.store
            .set_session_messages(thread_id, messages.clone())
            .await?;
        self.store
            .set_assistant_text(thread_id, String::new(), MessageState::Thinking)
            .await?;
        let mut task = self
            .store
            .task(thread_id)
            .await
            .ok_or(EngineError::MissingTask(thread_id))?;
        task.session_messages = messages;
        let outcome = self
            .run_agent_session(
                task,
                goal.clone(),
                settings.clone(),
                api_key.map(str::to_string),
                None,
            )
            .await?;
        let outcome = match outcome {
            SessionOutcome::Completed { text, messages }
                if should_run_checker(&goal, &self.store.task(thread_id).await) =>
            {
                self.verify_and_revise(
                    thread_id,
                    goal,
                    settings,
                    api_key.map(str::to_string),
                    text,
                    messages,
                )
                .await?
            }
            other => other,
        };
        self.finish_session_outcome(thread_id, outcome).await
    }

    async fn finish_session_outcome(
        &self,
        thread_id: Uuid,
        outcome: SessionOutcome,
    ) -> Result<(), EngineError> {
        match outcome {
            SessionOutcome::Completed { text, messages } => {
                self.store.set_session_messages(thread_id, messages).await?;
                let artifacts = self
                    .store
                    .task(thread_id)
                    .await
                    .map(|task| task.artifacts)
                    .unwrap_or_default();
                self.store
                    .complete(thread_id, text.clone(), artifacts)
                    .await?;
                self.store
                    .append_event(
                        thread_id,
                        RuntimeEventKind::Result,
                        RuntimeEventState::Completed,
                        "LingShu",
                        localized(&self.store.settings().await.locale, "任务完成", "Completed"),
                        truncate(&text, 1_200),
                    )
                    .await?;
            }
            SessionOutcome::Blocked => {}
            SessionOutcome::Cancelled => return Err(EngineError::Cancelled),
        }
        Ok(())
    }

    fn run_agent_session<'a>(
        &'a self,
        task: TaskRecord,
        goal: GoalSpec,
        settings: RuntimeSettings,
        api_key: Option<String>,
        correction: Option<String>,
    ) -> Pin<Box<dyn Future<Output = Result<SessionOutcome, EngineError>> + Send + 'a>> {
        Box::pin(async move {
            let mut messages = task.session_messages.clone();
            let mut active_permission = settings.execution_permission_mode;
            let (mut executed_tools, mut failed_network_command) = session_tool_evidence(&messages);
            let mut runtime_contract_corrections = 0_usize;
            if let Some(correction) = correction {
                messages.push(AgentMessage {
                    role: AgentRole::User,
                    content: format!(
                        "{}\n{}",
                        localized(
                            &settings.locale,
                            "【独立验收反馈，最高优先级】不要宣告完成；修复以下问题后重新交付。",
                            "[Independent checker feedback, highest priority] Do not declare completion; fix these issues and deliver again."
                        ),
                        correction
                    ),
                    tool_calls: Vec::new(),
                    tool_call_id: None,
                });
            }
            let mut signatures: Vec<String> = Vec::new();
            let mut last_text = String::new();
            for turn_index in 1..=MAX_AGENT_TURNS {
                if self.store.task_is_cancelled(task.id).await {
                    return Ok(SessionOutcome::Cancelled);
                }
                let latest_permission = self.store.settings().await.execution_permission_mode;
                if latest_permission != active_permission {
                    active_permission = latest_permission;
                    messages.push(runtime_authority_message(
                        &settings,
                        &self.platform,
                        &self.capabilities,
                        active_permission,
                    ));
                    self.store
                        .append_event(
                            task.id,
                            RuntimeEventKind::Status,
                            RuntimeEventState::Completed,
                            "Runtime",
                            localized(
                                &settings.locale,
                                "执行权限已更新",
                                "Execution permission updated",
                            ),
                            format!("permission_mode={}", active_permission.as_str()),
                        )
                        .await?;
                }
                let mut definitions = tool_definitions(task.depth, active_permission);
                definitions.extend(plugin_tool_definitions(
                    &self.plugins.enabled_tools(),
                    settings.locale,
                ));
                let mut turn_settings = settings.clone();
                turn_settings.execution_permission_mode = active_permission;
                self.store
                    .set_session_messages(task.id, messages.clone())
                    .await?;
                self.store
                    .set_assistant_text(
                        task.id,
                        localized(&settings.locale, "思考中…", "Thinking…").into(),
                        MessageState::Thinking,
                    )
                    .await?;
                let turn = self
                    .stream_model_turn(
                        task.id,
                        turn_index,
                        &turn_settings,
                        api_key.as_deref(),
                        &messages,
                        &definitions,
                    )
                    .await?;
                if !turn.text.trim().is_empty() {
                    last_text = turn.text.clone();
                }
                if turn.tool_calls.is_empty() {
                    let final_text = if turn.text.trim().is_empty() {
                        last_text.clone()
                    } else {
                        turn.text.clone()
                    };
                    if final_text.trim().is_empty() {
                        return Err(EngineError::InvalidModelJson(
                            "agent ended without a user-facing response".into(),
                        ));
                    }
                    let latest_permission = self.store.settings().await.execution_permission_mode;
                    if latest_permission != active_permission {
                        active_permission = latest_permission;
                        messages.push(AgentMessage {
                            role: AgentRole::Assistant,
                            content: final_text,
                            tool_calls: Vec::new(),
                            tool_call_id: None,
                        });
                        messages.push(runtime_authority_message(
                            &settings,
                            &self.platform,
                            &self.capabilities,
                            active_permission,
                        ));
                        continue;
                    }
                    if let Some(issue) = completion_contract_issue(
                        &goal,
                        &final_text,
                        active_permission,
                        executed_tools,
                        failed_network_command,
                    ) {
                        if runtime_contract_corrections >= MAX_RUNTIME_CONTRACT_CORRECTIONS {
                            return Err(EngineError::LocalOperation(format!(
                                "model repeatedly contradicted the runtime contract: {issue}"
                            )));
                        }
                        runtime_contract_corrections += 1;
                        messages.push(AgentMessage {
                            role: AgentRole::Assistant,
                            content: final_text,
                            tool_calls: Vec::new(),
                            tool_call_id: None,
                        });
                        messages.push(runtime_contract_correction_message(
                            &settings,
                            &self.platform,
                            &self.capabilities,
                            active_permission,
                            issue,
                        ));
                        self.store
                            .append_event(
                                task.id,
                                RuntimeEventKind::Warning,
                                RuntimeEventState::Completed,
                                "Runtime",
                                localized(
                                    &settings.locale,
                                    "运行时契约自纠",
                                    "Runtime contract correction",
                                ),
                                issue.to_string(),
                            )
                            .await?;
                        continue;
                    }
                    messages.push(AgentMessage {
                        role: AgentRole::Assistant,
                        content: final_text.clone(),
                        tool_calls: Vec::new(),
                        tool_call_id: None,
                    });
                    self.store
                        .set_session_messages(task.id, messages.clone())
                        .await?;
                    return Ok(SessionOutcome::Completed {
                        text: final_text,
                        messages,
                    });
                }

                let signature = tool_signature(&turn.tool_calls);
                signatures.push(signature.clone());
                if signatures.len() >= STUCK_REPEAT_THRESHOLD
                    && signatures
                        .iter()
                        .rev()
                        .take(STUCK_REPEAT_THRESHOLD)
                        .all(|candidate| candidate == &signature)
                {
                    return Err(EngineError::LocalOperation(format!(
                        "agent repeated the same tool plan {STUCK_REPEAT_THRESHOLD} times: {signature}"
                    )));
                }
                messages.push(AgentMessage {
                    role: AgentRole::Assistant,
                    content: turn.text,
                    tool_calls: turn.tool_calls.clone(),
                    tool_call_id: None,
                });
                self.store
                    .set_session_messages(task.id, messages.clone())
                    .await?;

                if let Some(blocking) = turn.tool_calls.iter().find(|call| call.name == "ask_user")
                {
                    let args = serde_json::from_str::<AskArguments>(&blocking.arguments_json)
                        .map_err(|error| EngineError::InvalidModelJson(error.to_string()))?;
                    self.store
                        .set_needs_user_action(
                            task.id,
                            Some(blocking.id.clone()),
                            args.prompt.clone(),
                        )
                        .await?;
                    self.store
                        .append_event(
                            task.id,
                            RuntimeEventKind::HumanInteraction,
                            RuntimeEventState::Blocked,
                            "LingShu",
                            localized(&settings.locale, "等待你的操作", "Your action is required"),
                            args.prompt,
                        )
                        .await?;
                    return Ok(SessionOutcome::Blocked);
                }

                let executions = join_all(turn.tool_calls.into_iter().map(|call| {
                    self.execute_tool(
                        task.clone(),
                        goal.clone(),
                        settings.clone(),
                        api_key.clone(),
                        call,
                    )
                }))
                .await;
                for execution in executions {
                    let execution = execution?;
                    executed_tools += 1;
                    if execution.network_command && execution.command_succeeded == Some(false) {
                        failed_network_command = true;
                    }
                    messages.push(AgentMessage {
                        role: AgentRole::Tool,
                        content: execution.output,
                        tool_calls: Vec::new(),
                        tool_call_id: Some(execution.call.id),
                    });
                }
                self.store
                    .set_session_messages(task.id, messages.clone())
                    .await?;
            }
            Err(EngineError::LocalOperation(format!(
                "agent reached the {MAX_AGENT_TURNS}-turn safety ceiling"
            )))
        })
    }

    async fn stream_model_turn(
        &self,
        task_id: Uuid,
        turn_index: usize,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        messages: &[AgentMessage],
        definitions: &[AgentToolDefinition],
    ) -> Result<ModelTurn, EngineError> {
        let model_event = self
            .store
            .append_event(
                task_id,
                RuntimeEventKind::Model,
                RuntimeEventState::Running,
                settings.model.clone(),
                localized(
                    &settings.locale,
                    &format!("模型回合 {turn_index}"),
                    &format!("Model turn {turn_index}"),
                ),
                String::new(),
            )
            .await?;
        let (delta_tx, mut delta_rx) = mpsc::unbounded_channel();
        let client = self.client.clone();
        let settings_owned = settings.clone();
        let api_key_owned = api_key.map(str::to_string);
        let messages_owned = messages.to_vec();
        let definitions_owned = definitions.to_vec();
        let model_handle = tokio::spawn(async move {
            client
                .turn(
                    &settings_owned,
                    api_key_owned.as_deref(),
                    &messages_owned,
                    &definitions_owned,
                    12_000,
                    Some(delta_tx),
                )
                .await
        });
        let mut reasoning_event: Option<Uuid> = None;
        let mut visible_started = false;
        while let Some(delta) = delta_rx.recv().await {
            match delta {
                ModelDelta::Reasoning(text) => {
                    let event_id = match reasoning_event {
                        Some(id) => id,
                        None => {
                            let event = self
                                .store
                                .append_event(
                                    task_id,
                                    RuntimeEventKind::Reasoning,
                                    RuntimeEventState::Running,
                                    settings.model.clone(),
                                    localized(&settings.locale, "推理摘要", "Reasoning summary"),
                                    String::new(),
                                )
                                .await?;
                            reasoning_event = Some(event.id);
                            event.id
                        }
                    };
                    self.store.append_event_detail_live(event_id, &text).await;
                }
                ModelDelta::Text(text) => {
                    if !visible_started {
                        self.store
                            .set_assistant_text(task_id, String::new(), MessageState::Thinking)
                            .await?;
                        visible_started = true;
                    }
                    self.store
                        .append_event_detail_live(model_event.id, &text)
                        .await;
                    self.store.append_assistant_delta_live(task_id, &text).await;
                }
            }
        }
        let turn_result = match model_handle.await {
            Ok(result) => result.map_err(EngineError::from),
            Err(error) => Err(EngineError::LocalOperation(error.to_string())),
        };
        let turn = match turn_result {
            Ok(turn) => turn,
            Err(error) => {
                if let Some(event_id) = reasoning_event {
                    self.store
                        .finish_event(event_id, RuntimeEventState::Failed, Some(error.to_string()))
                        .await?;
                }
                self.store
                    .finish_event(
                        model_event.id,
                        RuntimeEventState::Failed,
                        Some(error.to_string()),
                    )
                    .await?;
                return Err(error);
            }
        };
        if let Some(event_id) = reasoning_event {
            self.store
                .finish_event(event_id, RuntimeEventState::Completed, None)
                .await?;
        }
        let detail = if !turn.text.trim().is_empty() {
            turn.text.clone()
        } else {
            format!(
                "{}: {}",
                localized(&settings.locale, "请求工具", "Requested tools"),
                turn.tool_calls
                    .iter()
                    .map(|call| call.name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        };
        self.store
            .finish_event(model_event.id, RuntimeEventState::Completed, Some(detail))
            .await?;
        if !turn.tool_calls.is_empty() {
            self.store
                .set_assistant_text(
                    task_id,
                    localized(&settings.locale, "执行中…", "Working…").into(),
                    MessageState::Thinking,
                )
                .await?;
        }
        self.store.flush().await?;
        Ok(turn)
    }

    async fn execute_tool(
        &self,
        task: TaskRecord,
        goal: GoalSpec,
        settings: RuntimeSettings,
        api_key: Option<String>,
        call: AgentToolCall,
    ) -> Result<ToolExecution, EngineError> {
        let network_command = call.name == "run_command"
            && serde_json::from_str::<CommandArguments>(&call.arguments_json)
                .ok()
                .is_some_and(|args| command_uses_network(&args.command));
        let event = self
            .store
            .append_event(
                task.id,
                if call.name == "spawn_task" {
                    RuntimeEventKind::Delegation
                } else if call.name == "update_plan" {
                    RuntimeEventKind::Plan
                } else {
                    RuntimeEventKind::Tool
                },
                RuntimeEventState::Running,
                task.participant_name.clone(),
                tool_title(&settings.locale, &call.name),
                truncate(&call.arguments_json, 1_200),
            )
            .await?;
        let result = match call.name.as_str() {
            "inspect_runtime" => {
                let latest = self.store.settings().await;
                runtime_authority_payload(
                    &latest,
                    &self.platform,
                    &self.capabilities,
                    latest.execution_permission_mode,
                )
                .to_string()
            }
            "update_plan" => {
                let args = parse_arguments::<PlanArguments>(&call)?;
                let items = args
                    .items
                    .into_iter()
                    .map(|item| {
                        let status = match item.status.as_str() {
                            "completed" => TaskStatus::Completed,
                            "in_progress" | "running" => TaskStatus::Running,
                            _ => TaskStatus::Queued,
                        };
                        (item.title, item.detail, status)
                    })
                    .collect::<Vec<_>>();
                self.store.update_plan(task.id, items).await?;
                json!({"ok":true,"message":"plan updated"}).to_string()
            }
            "read_file" => {
                let args = parse_arguments::<PathArguments>(&call)?;
                let path =
                    resolve_read_path(&settings.workspace, &task.attachment_paths, &args.path)?;
                let preview = preview_file(&path)
                    .map_err(|error| EngineError::LocalOperation(error.to_string()))?;
                let extracted_text = if preview.kind == PreviewKind::Unsupported {
                    tokio::fs::read_to_string(&path).await.ok()
                } else {
                    readable_preview_text(&preview)
                };
                match extracted_text {
                    Some(content) => json!({
                        "ok":true,
                        "path":path,
                        "kind":preview.kind,
                        "content":truncate(&content, 80_000),
                        "section_count":preview.sections.len()
                    })
                    .to_string(),
                    None if preview.kind == PreviewKind::Pdf => json!({
                        "ok":false,
                        "path":path,
                        "kind":"pdf",
                        "error":"The PDF has no extractable embedded text. OCR is required.",
                        "missing_capability":"document_ocr",
                        "recovery":"Inspect available tools and local software first. If OCR installation is required, ask for that exact installation approval and continue after approval; do not stop at 'no plugin'."
                    })
                    .to_string(),
                    None => json!({
                        "ok":false,
                        "path":path,
                        "kind":preview.kind,
                        "error":"This binary file has no locally extractable text.",
                        "missing_capability":"binary_document_understanding",
                        "recovery":"Inspect available tools and compose a safe fallback. Ask the user only for an unavoidable installation, credential, authorization, or physical action."
                    })
                    .to_string(),
                }
            }
            "list_files" => {
                let args = parse_arguments::<ListArguments>(&call)?;
                let path = resolve_workspace_path(&settings.workspace, &args.path)?;
                let entries = list_paths(&path, args.recursive, 500)?;
                json!({"path":path,"entries":entries}).to_string()
            }
            "write_file" => {
                let args = parse_arguments::<WriteArguments>(&call)?;
                let path = resolve_workspace_path(&settings.workspace, &args.path)?;
                if let Some(parent) = path.parent() {
                    tokio::fs::create_dir_all(parent)
                        .await
                        .map_err(|error| EngineError::LocalOperation(error.to_string()))?;
                }
                let mut file = tokio::fs::File::create(&path)
                    .await
                    .map_err(|error| EngineError::LocalOperation(error.to_string()))?;
                file.write_all(args.content.as_bytes())
                    .await
                    .map_err(|error| EngineError::LocalOperation(error.to_string()))?;
                json!({"ok":true,"path":path,"bytes":args.content.len()}).to_string()
            }
            "create_artifact" => {
                let spec = parse_arguments::<ArtifactSpec>(&call)?;
                let records = materialize_artifacts(&settings.workspace, &[spec])?;
                self.store.add_artifacts(task.id, records.clone()).await?;
                json!({"ok":true,"artifacts":records}).to_string()
            }
            "register_artifact" => {
                let args = parse_arguments::<PathArguments>(&call)?;
                let path = resolve_workspace_path(&settings.workspace, &args.path)?;
                let record = artifact_record_for_path(&path)?;
                self.store
                    .add_artifacts(task.id, vec![record.clone()])
                    .await?;
                json!({"ok":true,"artifact":record}).to_string()
            }
            "run_command" => {
                let args = parse_arguments::<CommandArguments>(&call)?;
                let latest_permission = self.store.settings().await.execution_permission_mode;
                run_local_command(
                    &settings.workspace,
                    &args.command,
                    args.timeout_seconds,
                    latest_permission,
                )
                .await?
            }
            "spawn_task" => {
                let args = parse_arguments::<SpawnArguments>(&call)?;
                if task.depth >= MAX_CHILD_DEPTH {
                    json!({"ok":false,"error":"maximum child task depth reached"}).to_string()
                } else {
                    self.run_child_task(&task, &goal, &settings, api_key, args.objective, args.role)
                        .await?
                }
            }
            other
                if self
                    .plugins
                    .enabled_tools()
                    .iter()
                    .any(|tool| tool.exposed_name == other) =>
            {
                let arguments =
                    serde_json::from_str::<Value>(&call.arguments_json).map_err(|error| {
                        EngineError::InvalidModelJson(format!("{} arguments: {error}", call.name))
                    })?;
                let latest_permission = self.store.settings().await.execution_permission_mode;
                let execution = self
                    .plugins
                    .execute(other, arguments, &settings.workspace, latest_permission)
                    .await?;
                let mut records = Vec::new();
                for path in execution.artifact_paths {
                    records.push(artifact_record_for_path(&path)?);
                }
                if !records.is_empty() {
                    self.store.add_artifacts(task.id, records).await?;
                }
                execution.output
            }
            other => json!({"ok":false,"error":format!("unknown tool: {other}")}).to_string(),
        };
        self.store
            .finish_event(
                event.id,
                RuntimeEventState::Completed,
                Some(truncate(&result, 2_400)),
            )
            .await?;
        let command_succeeded = (call.name == "run_command")
            .then(|| {
                serde_json::from_str::<Value>(&result)
                    .ok()
                    .and_then(|value| value.get("ok").and_then(Value::as_bool))
            })
            .flatten();
        Ok(ToolExecution {
            call,
            output: result,
            network_command,
            command_succeeded,
        })
    }

    async fn run_child_task(
        &self,
        parent: &TaskRecord,
        parent_goal: &GoalSpec,
        settings: &RuntimeSettings,
        api_key: Option<String>,
        objective: String,
        requested_role: String,
    ) -> Result<String, EngineError> {
        let participant = if requested_role.trim().is_empty() {
            localized(&settings.locale, "能力执行者", "Worker").to_string()
        } else {
            requested_role
        };
        let child_id = self
            .store
            .create_child_task(
                parent.id,
                objective.clone(),
                TaskRole::Worker,
                participant.clone(),
                TaskOrigin::Subtask,
            )
            .await?;
        self.store
            .append_event(
                parent.id,
                RuntimeEventKind::Delegation,
                RuntimeEventState::Completed,
                "LingShu",
                localized(&settings.locale, "已派发子任务", "Child task dispatched"),
                format!("{participant}: {objective}"),
            )
            .await?;
        let result: Result<String, EngineError> = async {
            let child_history = vec![ChatMessage {
                id: Uuid::new_v4(),
                role: MessageRole::System,
                text: format!(
                    "Parent GoalSpec: {}",
                    serde_json::to_string(parent_goal).unwrap_or_default()
                ),
                created_at: Utc::now(),
                state: MessageState::Complete,
                thread_id: Some(parent.id),
                attachment_paths: Vec::new(),
            }];
            let goal = self
                .generate_goal(
                    child_id,
                    settings,
                    api_key.as_deref(),
                    &child_history,
                    &objective,
                    "(none)",
                )
                .await?;
            self.store.set_goal(child_id, goal.clone()).await?;
            let child = self
                .store
                .task(child_id)
                .await
                .ok_or(EngineError::MissingTask(child_id))?;
            let plugin_context = self.plugins.prompt_context(settings.locale);
            let messages = initial_session_messages(
                settings,
                RuntimeAuthorityContext {
                    platform: &self.platform,
                    capabilities: &self.capabilities,
                    plugin_context: &plugin_context,
                },
                &child_history,
                &objective,
                "(none)",
                &goal,
                child.depth,
            )?;
            self.store
                .set_session_messages(child_id, messages.clone())
                .await?;
            let mut child = child;
            child.session_messages = messages;
            match self
                .run_agent_session(child, goal, settings.clone(), api_key, None)
                .await?
            {
                SessionOutcome::Completed { text, messages } => {
                    self.store.set_session_messages(child_id, messages).await?;
                    let artifacts = self
                        .store
                        .task(child_id)
                        .await
                        .map(|task| task.artifacts)
                        .unwrap_or_default();
                    self.store
                        .complete(child_id, text.clone(), artifacts.clone())
                        .await?;
                    if !artifacts.is_empty() {
                        self.store
                            .add_artifacts(parent.id, artifacts.clone())
                            .await?;
                    }
                    self.store
                        .append_event(
                            child_id,
                            RuntimeEventKind::Result,
                            RuntimeEventState::Completed,
                            participant.clone(),
                            localized(&settings.locale, "子任务完成", "Child task completed"),
                            truncate(&text, 1_200),
                        )
                        .await?;
                    Ok(json!({
                        "ok":true,
                        "child_task_id":child_id,
                        "summary":text,
                        "artifacts":artifacts.iter().map(|item| item.path.clone()).collect::<Vec<_>>()
                    })
                    .to_string())
                }
                SessionOutcome::Blocked => Ok(json!({
                    "ok":false,
                    "child_task_id":child_id,
                    "needs_user_action":self.store.task(child_id).await.and_then(|task| task.pending_question)
                })
                .to_string()),
                SessionOutcome::Cancelled => Ok(json!({"ok":false,"child_task_id":child_id,"cancelled":true}).to_string()),
            }
        }
        .await;
        match result {
            Ok(output) => Ok(output),
            Err(error) => {
                let detail = error.to_string();
                self.store
                    .fail(
                        child_id,
                        localized(
                            &settings.locale,
                            "子任务未能完成，主线程可根据错误调整方案。",
                            "The child task could not complete; the main session can adapt to the error.",
                        )
                        .into(),
                        detail.clone(),
                    )
                    .await?;
                self.store
                    .append_event(
                        child_id,
                        RuntimeEventKind::Result,
                        RuntimeEventState::Failed,
                        participant,
                        localized(&settings.locale, "子任务失败", "Child task failed"),
                        detail.clone(),
                    )
                    .await?;
                Ok(json!({"ok":false,"child_task_id":child_id,"error":detail}).to_string())
            }
        }
    }

    async fn verify_and_revise(
        &self,
        thread_id: Uuid,
        goal: GoalSpec,
        settings: RuntimeSettings,
        api_key: Option<String>,
        mut final_text: String,
        mut messages: Vec<AgentMessage>,
    ) -> Result<SessionOutcome, EngineError> {
        for review_round in 1..=2 {
            let verification = self
                .run_checker(
                    thread_id,
                    &goal,
                    &settings,
                    api_key.as_deref(),
                    &final_text,
                    review_round,
                )
                .await?;
            if verification.passed {
                return Ok(SessionOutcome::Completed {
                    text: final_text,
                    messages,
                });
            }
            if review_round == 2 {
                return Err(EngineError::LocalOperation(format!(
                    "independent checker still rejected the delivery: {}",
                    verification.findings.join("; ")
                )));
            }
            let correction = format!(
                "{}\n{}",
                verification.summary,
                verification.findings.join("\n")
            );
            let mut task = self
                .store
                .task(thread_id)
                .await
                .ok_or(EngineError::MissingTask(thread_id))?;
            task.session_messages = messages;
            match self
                .run_agent_session(
                    task,
                    goal.clone(),
                    settings.clone(),
                    api_key.clone(),
                    Some(correction),
                )
                .await?
            {
                SessionOutcome::Completed {
                    text,
                    messages: next,
                } => {
                    final_text = text;
                    messages = next;
                }
                other => return Ok(other),
            }
        }
        unreachable!()
    }

    async fn run_checker(
        &self,
        parent_id: Uuid,
        goal: &GoalSpec,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        final_text: &str,
        round: usize,
    ) -> Result<VerificationResult, EngineError> {
        let checker_id = self
            .store
            .create_child_task(
                parent_id,
                format!("Independent verification round {round}"),
                TaskRole::Checker,
                localized(&settings.locale, "独立审查员", "Independent checker").into(),
                TaskOrigin::Verification,
            )
            .await?;
        self.store.set_goal(checker_id, goal.clone()).await?;
        let task = self
            .store
            .task(parent_id)
            .await
            .ok_or(EngineError::MissingTask(parent_id))?;
        let artifacts = task
            .artifacts
            .iter()
            .map(|artifact| match preview_file(&artifact.path) {
                Ok(preview) => format!(
                    "ARTIFACT {} ({})\n{}",
                    artifact.path.display(),
                    artifact.kind,
                    truncate(&preview.content, 30_000)
                ),
                Err(error) => format!("ARTIFACT {} unreadable: {error}", artifact.path.display()),
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        let system = format!(
            "{}\nYou are an independent checker. Verify the delivery against every GoalSpec success criterion and the actual registered artifact content. Return one JSON object only: {{\"passed\":true|false,\"summary\":\"...\",\"findings\":[\"...\"]}}. Do not pass claims that lack observable evidence.",
            settings.locale.language_directive()
        );
        let user = format!(
            "GoalSpec:\n{}\n\nMaker final response:\n{}\n\nRegistered artifacts:\n{}",
            serde_json::to_string_pretty(goal).unwrap_or_default(),
            final_text,
            if artifacts.is_empty() {
                "(none)"
            } else {
                &artifacts
            }
        );
        let event = self
            .store
            .append_event(
                checker_id,
                RuntimeEventKind::Model,
                RuntimeEventState::Running,
                settings.model.clone(),
                localized(&settings.locale, "独立验收", "Independent verification"),
                String::new(),
            )
            .await?;
        let result = match self
            .client
            .complete(settings, api_key, &system, &user, 2_000)
            .await
            .map_err(EngineError::from)
            .and_then(|raw| decode_json::<VerificationResult>(&raw))
        {
            Ok(result) => result,
            Err(error) => {
                self.store
                    .finish_event(event.id, RuntimeEventState::Failed, Some(error.to_string()))
                    .await?;
                self.store
                    .fail(
                        checker_id,
                        localized(
                            &settings.locale,
                            "独立验收未能完成。",
                            "Independent verification could not complete.",
                        )
                        .into(),
                        error.to_string(),
                    )
                    .await?;
                return Err(error);
            }
        };
        self.store
            .finish_event(
                event.id,
                if result.passed {
                    RuntimeEventState::Completed
                } else {
                    RuntimeEventState::Failed
                },
                Some(format!(
                    "{}\n{}",
                    result.summary,
                    result.findings.join("\n")
                )),
            )
            .await?;
        self.store
            .complete(checker_id, result.summary.clone(), Vec::new())
            .await?;
        Ok(result)
    }

    async fn generate_goal(
        &self,
        task_id: Uuid,
        settings: &RuntimeSettings,
        api_key: Option<&str>,
        history: &[ChatMessage],
        prompt: &str,
        attachment_context: &str,
    ) -> Result<GoalSpec, EngineError> {
        let event = self
            .store
            .append_event(
                task_id,
                RuntimeEventKind::Model,
                RuntimeEventState::Running,
                settings.model.clone(),
                localized(&settings.locale, "理解目标", "Understanding the goal"),
                localized(
                    &settings.locale,
                    "正在把当前输入编译为可执行目标。",
                    "Compiling the current input into an executable goal.",
                ),
            )
            .await?;
        let history = format_history(history);
        let system = format!(
            "{}\nYou are LingShu's shared cross-platform goal compiler. Produce one complete GoalSpec as a single JSON object and no prose. Never silently invent missing references. Use the full conversation to resolve references, including older turns. Platform-specific unavailable capabilities must be listed as boundaries, not used to change the user's intent. Required fields and enum values:\n{}",
            settings.locale.language_directive(),
            goal_schema_instruction(),
        );
        let base_user = format!(
            "Full conversation context:\n{history}\n\nCurrent user input:\n{prompt}\n\nAttachments:\n{attachment_context}\n\nCompile the current input into the required GoalSpec."
        );
        let mut previous_raw = String::new();
        let mut previous_issue = String::new();
        for attempt in 1..=GOAL_ATTEMPTS {
            let timeout_seconds = goal_timeout_seconds(&base_user, attempt);
            let user = if attempt == 1 {
                base_user.clone()
            } else {
                format!(
                    "The previous GoalSpec was invalid. Repair it; do not restart or change the user's intent.\nValidation issue: {previous_issue}\nPrevious output:\n{previous_raw}\n\nOriginal request:\n{base_user}"
                )
            };
            let generation = tokio::time::timeout(
                Duration::from_secs(timeout_seconds),
                self.client
                    .complete(settings, api_key, &system, &user, 1_600),
            )
            .await
            .map_err(|_| EngineError::ModelTimeout {
                phase: format!("GoalSpec generation attempt {attempt}"),
                seconds: timeout_seconds,
            });
            match generation {
                Ok(result) => match result {
                    Ok(raw) => match decode_json::<GoalSpec>(&raw) {
                        Ok(goal) if goal.is_ready() => {
                            self.store
                                .finish_event(
                                    event.id,
                                    RuntimeEventState::Completed,
                                    Some(format!("{} ({attempt}/{GOAL_ATTEMPTS})", goal.objective)),
                                )
                                .await?;
                            return Ok(goal);
                        }
                        Ok(_) => {
                            previous_issue = "GoalSpec is structurally valid but incomplete".into();
                            previous_raw = raw;
                        }
                        Err(error) => {
                            previous_issue = error.to_string();
                            previous_raw = raw;
                        }
                    },
                    Err(error) => {
                        previous_issue = error.to_string();
                        previous_raw.clear();
                    }
                },
                Err(error) => {
                    previous_issue = error.to_string();
                    previous_raw.clear();
                }
            }
            self.store
                .append_event(
                    task_id,
                    RuntimeEventKind::Warning,
                    RuntimeEventState::Running,
                    "GoalSpec",
                    localized(&settings.locale, "目标结构需要修复", "Goal repair required"),
                    format!("{attempt}/{GOAL_ATTEMPTS}: {previous_issue}"),
                )
                .await?;
        }
        self.store
            .finish_event(
                event.id,
                RuntimeEventState::Failed,
                Some(previous_issue.clone()),
            )
            .await?;
        Err(EngineError::InvalidModelJson(previous_issue))
    }
}

fn runtime_authority_payload(
    settings: &RuntimeSettings,
    platform: &str,
    capabilities: &PlatformCapabilities,
    permission_mode: ExecutionPermissionMode,
) -> Value {
    json!({
        "source": "lingshu_runtime_store",
        "authoritative": true,
        "platform": platform,
        "execution_permission_mode": permission_mode.as_str(),
        "local_command": "available",
        "network_authorization": if permission_mode == ExecutionPermissionMode::FullAccess {
            "allowed"
        } else {
            "requires_full_access"
        },
        "network_reachability": "not_probed",
        "lingshu_process_sandbox": if permission_mode == ExecutionPermissionMode::FullAccess {
            "not_applied"
        } else {
            "workspace_and_network_guard"
        },
        "workspace": settings.workspace,
        "capabilities": capabilities,
        "rule": "Authorization is a runtime fact. Reachability or command failure must be established by a real tool result, never guessed from model identity or conversation history."
    })
}

fn runtime_authority_message(
    settings: &RuntimeSettings,
    platform: &str,
    capabilities: &PlatformCapabilities,
    permission_mode: ExecutionPermissionMode,
) -> AgentMessage {
    AgentMessage {
        role: AgentRole::System,
        content: format!(
            "{}\nAuthoritative LingShu runtime state update:\n{}",
            permission_mode.prompt_directive(settings.locale),
            serde_json::to_string_pretty(&runtime_authority_payload(
                settings,
                platform,
                capabilities,
                permission_mode,
            ))
            .unwrap_or_else(|_| "{}".into())
        ),
        tool_calls: Vec::new(),
        tool_call_id: None,
    }
}

fn runtime_contract_correction_message(
    settings: &RuntimeSettings,
    platform: &str,
    capabilities: &PlatformCapabilities,
    permission_mode: ExecutionPermissionMode,
    issue: &str,
) -> AgentMessage {
    let instruction = localized(
        &settings.locale,
        "【运行时事实纠正，最高优先级】上一版回复与宿主运行时事实冲突，不能交付。不要重复无证据的限制结论。先调用 inspect_runtime；若问题涉及命令、联网、安装或目录访问，再调用 run_command 做真实验证，然后仅依据工具结果重新回答。",
        "[Runtime fact correction, highest priority] The previous draft conflicts with trusted host runtime facts and cannot be delivered. Do not repeat an unsupported limitation claim. Call inspect_runtime first; when the request involves commands, networking, installation, or filesystem access, use run_command for a real probe, then answer only from tool evidence.",
    );
    AgentMessage {
        role: AgentRole::System,
        content: format!(
            "{instruction}\nContract issue: {issue}\n{}",
            serde_json::to_string_pretty(&runtime_authority_payload(
                settings,
                platform,
                capabilities,
                permission_mode,
            ))
            .unwrap_or_else(|_| "{}".into())
        ),
        tool_calls: Vec::new(),
        tool_call_id: None,
    }
}

fn completion_contract_issue(
    goal: &GoalSpec,
    final_text: &str,
    permission_mode: ExecutionPermissionMode,
    executed_tools: usize,
    failed_network_command: bool,
) -> Option<&'static str> {
    if executed_tools == 0
        && matches!(
            goal.output_mode,
            OutputMode::Artifact | OutputMode::VisibleInteraction | OutputMode::ExternalAction
        )
    {
        return Some("an action or deliverable was declared without any tool evidence");
    }
    if permission_mode != ExecutionPermissionMode::FullAccess {
        return None;
    }
    if contains_unsupported_sandbox_claim(final_text) {
        return Some(
            "the response claimed a LingShu/platform sandbox limitation while full_access is active",
        );
    }
    if !failed_network_command && contains_unverified_network_claim(final_text) {
        return Some(
            "the response claimed network unavailability without a failed network command",
        );
    }
    None
}

fn session_tool_evidence(messages: &[AgentMessage]) -> (usize, bool) {
    let executed_tools = messages
        .iter()
        .filter(|message| message.role == AgentRole::Tool)
        .count();
    let failed_network_command = messages.iter().any(|message| {
        if message.role != AgentRole::Tool {
            return false;
        }
        let Some(call_id) = message.tool_call_id.as_deref() else {
            return false;
        };
        let Some(call) = messages
            .iter()
            .flat_map(|candidate| candidate.tool_calls.iter())
            .find(|call| call.id == call_id && call.name == "run_command")
        else {
            return false;
        };
        let is_network = serde_json::from_str::<CommandArguments>(&call.arguments_json)
            .ok()
            .is_some_and(|args| command_uses_network(&args.command));
        let failed = serde_json::from_str::<Value>(&message.content)
            .ok()
            .and_then(|value| value.get("ok").and_then(Value::as_bool))
            == Some(false);
        is_network && failed
    });
    (executed_tools, failed_network_command)
}

fn contains_unsupported_sandbox_claim(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        "被关在沙箱",
        "沙箱限制",
        "沙箱环境阻止",
        "平台层面的硬性限制",
        "平台限制无法",
        "无法修改沙箱",
        "不能修改沙箱",
        "出站防火墙",
        "容器网关",
        "sandbox prevents",
        "sandbox blocks",
        "sandboxed environment",
        "platform limitation",
        "platform restriction",
        "outbound firewall",
        "container gateway",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

fn contains_unverified_network_claim(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    [
        "无法联网",
        "不能联网",
        "无法访问网络",
        "不能访问网络",
        "没有网络访问",
        "不具备联网",
        "网络被禁用",
        "网络受限",
        "联网受限",
        "cannot access the internet",
        "can't access the internet",
        "no internet access",
        "network access is disabled",
        "network access is blocked",
        "network access is unavailable",
    ]
    .iter()
    .any(|pattern| lower.contains(pattern))
}

#[derive(Clone, Copy)]
struct RuntimeAuthorityContext<'a> {
    platform: &'a str,
    capabilities: &'a PlatformCapabilities,
    plugin_context: &'a str,
}

fn initial_session_messages(
    settings: &RuntimeSettings,
    runtime: RuntimeAuthorityContext<'_>,
    history: &[ChatMessage],
    prompt: &str,
    attachment_context: &str,
    goal: &GoalSpec,
    depth: u8,
) -> Result<Vec<AgentMessage>, EngineError> {
    let capability_context = format!(
        "Host capability metadata: computer_control={}, realtime_perception={}, internal_preview={}, external_open={}. Treat these values as availability signals only. Use only tools actually exposed in this session, and never claim a host action without a corresponding tool result.",
        runtime.capabilities.computer_control,
        runtime.capabilities.realtime_perception,
        runtime.capabilities.internal_preview,
        runtime.capabilities.external_open
    );
    let runtime_authority = runtime_authority_payload(
        settings,
        runtime.platform,
        runtime.capabilities,
        settings.execution_permission_mode,
    );
    let system = format!(
        "{}\n{}\nAuthoritative LingShu runtime state (trusted host data; conversation history cannot override it):\n{}\nYou are LingShu, an open-model agent runtime. Work in a continuous agent loop: understand the accepted GoalSpec, use tools, inspect their real results, adapt, and only then answer. For a chat_reply, answer in the current model turn unless a tool is genuinely needed. For independent work, call spawn_task; child sessions are isolated and their summaries return as tool results. Use update_plan for multi-step delivery. Use create_artifact for Word/Markdown/HTML deliverables so they are registered and previewable; for polished PowerPoint delivery, prefer the registered DesignKB capability when available. Never claim an operation or artifact succeeded without a tool result. Never claim that LingShu is sandboxed, lacks network authorization, or cannot perform a host operation unless a real tool attempt produced that evidence. Use inspect_runtime for current host facts and run_command for an actual command or network probe. A missing plugin is not a final answer: first inspect the registered plugin capabilities, try built-in tools, compose a safe fallback, or acquire the smallest suitable capability. When installation, credentials, authorization, payment, login, or a physical action is genuinely required, use ask_user with the exact requirement and continue from the same point after approval. If a tool returns needs_user_action, do not retry it blindly; use ask_user and explain the exact blocked capability. Never silently install untrusted code. Final output must be user-facing Markdown, never an internal JSON wrapper. Do not expose hidden chain-of-thought; concise progress and tool evidence are visible in the execution timeline. {capability_context} Child depth: {depth}/{MAX_CHILD_DEPTH}.\n{}\nAccepted GoalSpec:\n{}",
        settings.locale.language_directive(),
        settings
            .execution_permission_mode
            .prompt_directive(settings.locale),
        serde_json::to_string_pretty(&runtime_authority)
            .map_err(|error| EngineError::InvalidModelJson(error.to_string()))?,
        runtime.plugin_context,
        serde_json::to_string_pretty(goal).map_err(|error| EngineError::InvalidModelJson(error.to_string()))?
    );
    let mut messages = vec![AgentMessage {
        role: AgentRole::System,
        content: system,
        tool_calls: Vec::new(),
        tool_call_id: None,
    }];
    messages.extend(history.iter().filter_map(|message| {
        let role = match message.role {
            MessageRole::User => AgentRole::User,
            MessageRole::Assistant => AgentRole::Assistant,
            MessageRole::System => AgentRole::System,
        };
        (!message.text.trim().is_empty()).then(|| AgentMessage {
            role,
            content: message.text.clone(),
            tool_calls: Vec::new(),
            tool_call_id: None,
        })
    }));
    let content = if attachment_context == "(none)" {
        prompt.to_string()
    } else {
        format!("{prompt}\n\nAttached context:\n{attachment_context}")
    };
    messages.push(AgentMessage {
        role: AgentRole::User,
        content,
        tool_calls: Vec::new(),
        tool_call_id: None,
    });
    Ok(messages)
}

fn tool_definitions(
    depth: u8,
    permission_mode: ExecutionPermissionMode,
) -> Vec<AgentToolDefinition> {
    let command_description = match permission_mode {
        ExecutionPermissionMode::Sandbox => {
            "Run a local command with the Workspace as working directory. Network access and writes outside the Workspace require user authorization; a blocked result contains needs_user_action. This is terminal execution, not computer UI control."
        }
        ExecutionPermissionMode::FullAccess => {
            "Run a local command with the Workspace as working directory. Full access is already authorized for local commands, network access, dependency installation, and paths outside the Workspace. This is terminal execution, not computer UI control."
        }
    };
    let mut tools = vec![
        tool("inspect_runtime", "Read authoritative live host facts: platform, current execution permission, command availability, network authorization, Workspace, and platform capabilities. Use this instead of guessing that LingShu is sandboxed or offline.", json!({"type":"object","properties":{}})),
        tool("update_plan", "Create or update the visible execution plan. Keep exactly one item in_progress.", json!({"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"detail":{"type":"string"},"status":{"type":"string","enum":["pending","in_progress","completed"]}},"required":["title","status"]}}},"required":["items"]})),
        tool("read_file", "Read text and extract embedded text from PDF, DOCX, and PPTX files in the Workspace or current task attachments. Text PDFs need no plugin. A scanned PDF returns a structured OCR capability gap so you can recover instead of stopping.", json!({"type":"object","properties":{"path":{"type":"string"}},"required":["path"]})),
        tool("list_files", "List files under LingShu's Workspace.", json!({"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}}})),
        tool("write_file", "Write a UTF-8 text file inside LingShu's Workspace. Use create_artifact for Office deliverables.", json!({"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]})),
        tool("create_artifact", "Create and register a previewable Markdown, text, JSON, HTML, Word (.docx), or PowerPoint (.pptx) artifact.", json!({"type":"object","properties":{"title":{"type":"string"},"file_name":{"type":"string"},"kind":{"type":"string","enum":["markdown","text","json","html","docx","pptx"]},"content":{"type":"string"},"slides":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"bullets":{"type":"array","items":{"type":"string"}},"notes":{"type":"string"}},"required":["title"]}}},"required":["title","file_name","kind"]})),
        tool("register_artifact", "Register an existing Workspace file as a task artifact after verifying it exists.", json!({"type":"object","properties":{"path":{"type":"string"}},"required":["path"]})),
        tool("run_command", command_description, json!({"type":"object","properties":{"command":{"type":"string"},"timeout_seconds":{"type":"integer","minimum":1,"maximum":300}},"required":["command"]})),
        tool("ask_user", "Pause this exact session when human input, authorization, login, scanning, or a physical action is required.", json!({"type":"object","properties":{"prompt":{"type":"string"}},"required":["prompt"]})),
    ];
    if depth < MAX_CHILD_DEPTH {
        tools.push(tool("spawn_task", "Dispatch independent work to an isolated child agent session. Multiple calls in one turn run concurrently and return summaries to this session.", json!({"type":"object","properties":{"objective":{"type":"string"},"role":{"type":"string"}},"required":["objective"]})));
    }
    tools
}

fn plugin_tool_definitions(
    tools: &[PluginToolRecord],
    locale: AppLocale,
) -> Vec<AgentToolDefinition> {
    tools
        .iter()
        .map(|plugin_tool| {
            let description =
                if locale == AppLocale::ZhCn && !plugin_tool.description_zh.trim().is_empty() {
                    &plugin_tool.description_zh
                } else {
                    &plugin_tool.description
                };
            tool(
                &plugin_tool.exposed_name,
                description,
                plugin_tool.parameters.clone(),
            )
        })
        .collect()
}

fn tool(name: &str, description: &str, parameters: Value) -> AgentToolDefinition {
    AgentToolDefinition {
        name: name.into(),
        description: description.into(),
        parameters,
    }
}

fn parse_arguments<T: for<'de> Deserialize<'de>>(call: &AgentToolCall) -> Result<T, EngineError> {
    serde_json::from_str(&call.arguments_json)
        .map_err(|error| EngineError::InvalidModelJson(format!("{} arguments: {error}", call.name)))
}

fn resolve_workspace_path(workspace: &Path, raw: &str) -> Result<PathBuf, EngineError> {
    let workspace = normalize_path(workspace);
    let candidate = if raw.trim().is_empty() {
        workspace.clone()
    } else {
        let raw = PathBuf::from(raw);
        let joined = if raw.is_absolute() {
            raw
        } else {
            workspace.join(raw)
        };
        normalize_path(&joined)
    };
    if !candidate.starts_with(&workspace) {
        return Err(EngineError::LocalOperation(format!(
            "path is outside the Workspace: {}",
            candidate.display()
        )));
    }
    Ok(candidate)
}

fn resolve_read_path(
    workspace: &Path,
    attachments: &[PathBuf],
    raw: &str,
) -> Result<PathBuf, EngineError> {
    if let Ok(path) = resolve_workspace_path(workspace, raw) {
        return Ok(path);
    }
    let candidate = normalize_path(Path::new(raw));
    if attachments
        .iter()
        .any(|attachment| normalize_path(attachment) == candidate)
    {
        Ok(candidate)
    } else {
        Err(EngineError::LocalOperation(format!(
            "read access is limited to Workspace and current attachments: {}",
            candidate.display()
        )))
    }
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn list_paths(root: &Path, recursive: bool, limit: usize) -> Result<Vec<String>, EngineError> {
    let mut result = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let entries = std::fs::read_dir(&directory)
            .map_err(|error| EngineError::LocalOperation(error.to_string()))?;
        for entry in entries {
            let entry = entry.map_err(|error| EngineError::LocalOperation(error.to_string()))?;
            let path = entry.path();
            result.push(path.display().to_string());
            if result.len() >= limit {
                return Ok(result);
            }
            if recursive && path.is_dir() {
                pending.push(path);
            }
        }
        if !recursive {
            break;
        }
    }
    result.sort();
    Ok(result)
}

async fn run_local_command(
    workspace: &Path,
    command: &str,
    timeout_seconds: Option<u64>,
    permission_mode: ExecutionPermissionMode,
) -> Result<String, EngineError> {
    if permission_mode == ExecutionPermissionMode::Sandbox {
        if let Some((capability, reason)) = sandbox_permission_requirement(command) {
            return Ok(json!({
                "ok": false,
                "needs_user_action": true,
                "permission_mode": permission_mode.as_str(),
                "required_capability": capability,
                "reason": reason,
                "recovery": "Ask the user to switch this session to Full Access, then resume from the same task checkpoint."
            })
            .to_string());
        }
    }
    let timeout_seconds = timeout_seconds.unwrap_or(120).clamp(1, 300);
    #[cfg(target_os = "windows")]
    let mut process = {
        let mut process = tokio::process::Command::new("powershell.exe");
        process.args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            command,
        ]);
        process
    };
    #[cfg(not(target_os = "windows"))]
    let mut process = {
        let mut process = tokio::process::Command::new("/bin/zsh");
        process.args(["-lc", command]);
        process
    };
    process
        .current_dir(workspace)
        .env(
            "LINGSHU_EXECUTION_PERMISSION_MODE",
            permission_mode.as_str(),
        )
        .env(
            "LINGSHU_NETWORK_ACCESS",
            if permission_mode == ExecutionPermissionMode::FullAccess {
                "allowed"
            } else {
                "restricted"
            },
        )
        .env("LINGSHU_WORKSPACE", workspace)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = tokio::time::timeout(Duration::from_secs(timeout_seconds), process.output())
        .await
        .map_err(|_| {
            EngineError::LocalOperation(format!("command timed out after {timeout_seconds}s"))
        })?
        .map_err(|error| EngineError::LocalOperation(error.to_string()))?;
    Ok(json!({
        "ok":output.status.success(),
        "permission_mode":permission_mode.as_str(),
        "network_authorization":if permission_mode == ExecutionPermissionMode::FullAccess {"allowed"} else {"requires_full_access"},
        "runtime_sandbox_applied":permission_mode == ExecutionPermissionMode::Sandbox,
        "exit_code":output.status.code(),
        "stdout":truncate(&String::from_utf8_lossy(&output.stdout), 40_000),
        "stderr":truncate(&String::from_utf8_lossy(&output.stderr), 20_000)
    })
    .to_string())
}

fn sandbox_permission_requirement(command: &str) -> Option<(&'static str, &'static str)> {
    let lower = command.to_ascii_lowercase();
    if command_uses_network(&lower) {
        return Some((
            "network",
            "Sandbox mode does not authorize network access for local commands.",
        ));
    }

    let outside_workspace_markers = [
        "../",
        "..\\",
        "~/",
        "$home",
        "${home}",
        "%userprofile%",
        "$env:userprofile",
    ];
    if outside_workspace_markers
        .iter()
        .any(|marker| lower.contains(marker))
    {
        return Some((
            "filesystem_outside_workspace",
            "Sandbox mode does not authorize filesystem access outside the Workspace.",
        ));
    }
    None
}

fn command_uses_network(command: &str) -> bool {
    let lower = command.to_ascii_lowercase();
    [
        "http://",
        "https://",
        "ftp://",
        "curl ",
        "wget ",
        "invoke-webrequest",
        "invoke-restmethod",
        "start-bitstransfer",
        "git clone",
        "git fetch",
        "git pull",
        "npm install",
        "pnpm install",
        "yarn install",
        "pip install",
        "pip3 install",
        "cargo install",
        "ssh ",
        "scp ",
    ]
    .iter()
    .any(|marker| lower.contains(marker))
}

fn artifact_record_for_path(path: &Path) -> Result<ArtifactRecord, EngineError> {
    if !path.is_file() {
        return Err(EngineError::LocalOperation(format!(
            "artifact does not exist: {}",
            path.display()
        )));
    }
    let metadata =
        std::fs::metadata(path).map_err(|error| EngineError::LocalOperation(error.to_string()))?;
    let modified_at = metadata
        .modified()
        .ok()
        .map(DateTime::<Utc>::from)
        .unwrap_or_else(Utc::now);
    Ok(ArtifactRecord {
        id: Uuid::new_v4(),
        title: path
            .file_name()
            .and_then(|value| value.to_str())
            .unwrap_or("Artifact")
            .into(),
        path: path.to_path_buf(),
        kind: path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("file")
            .to_ascii_lowercase(),
        size_bytes: metadata.len(),
        modified_at,
    })
}

fn should_run_checker(goal: &GoalSpec, task: &Option<TaskRecord>) -> bool {
    matches!(goal.output_mode, OutputMode::Artifact)
        || task.as_ref().is_some_and(|task| !task.artifacts.is_empty())
}

fn tool_signature(calls: &[AgentToolCall]) -> String {
    calls
        .iter()
        .map(|call| format!("{}:{}", call.name, call.arguments_json))
        .collect::<Vec<_>>()
        .join("|")
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
                    PreviewKind::Image => {
                        "Binary image is available for in-app preview; no local text was extracted."
                            .into()
                    }
                    PreviewKind::Pdf => readable_preview_text(&preview)
                        .map(|text| truncate(&text, 24_000))
                        .unwrap_or_else(|| {
                            "The PDF is previewable but has no embedded text; OCR capability is required."
                                .into()
                        }),
                    _ => readable_preview_text(&preview)
                        .map(|text| truncate(&text, 24_000))
                        .unwrap_or_else(|| {
                            "Binary media is available for in-app preview; no local text was extracted."
                                .into()
                        }),
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

fn readable_preview_text(preview: &crate::preview::PreviewPayload) -> Option<String> {
    let text = match preview.kind {
        PreviewKind::Pdf => preview
            .sections
            .iter()
            .enumerate()
            .map(|(index, page)| format!("[Page {}]\n{}", index + 1, page))
            .collect::<Vec<_>>()
            .join("\n\n"),
        PreviewKind::Document
        | PreviewKind::Presentation
        | PreviewKind::Text
        | PreviewKind::Markdown
        | PreviewKind::Code
        | PreviewKind::Html => preview.content.clone(),
        PreviewKind::Image | PreviewKind::Unsupported => return None,
    };
    (!text.trim().is_empty()).then_some(text)
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        value.to_string()
    } else {
        value.chars().take(max_chars).collect::<String>() + "\n[truncated]"
    }
}

/// Keep GoalSpec generation bounded without branching on provider or model names. The budget is
/// derived only from request size and increases for repair attempts, matching the macOS policy.
fn goal_timeout_seconds(payload: &str, attempt: usize) -> u64 {
    let estimated_tokens = payload.chars().count().div_ceil(4) as u64 + 800;
    let first = (20 + estimated_tokens.div_ceil(400))
        .clamp(MIN_GOAL_TIMEOUT_SECONDS, MAX_GOAL_TIMEOUT_SECONDS[0]);
    match attempt {
        1 => first,
        2 => (first.saturating_mul(135).div_ceil(100))
            .max(first + 15)
            .min(MAX_GOAL_TIMEOUT_SECONDS[1]),
        _ => (first.saturating_mul(180).div_ceil(100))
            .max(first + 35)
            .min(MAX_GOAL_TIMEOUT_SECONDS[2]),
    }
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

fn localized_failure(locale: AppLocale, error: &EngineError) -> String {
    match locale {
        AppLocale::ZhCn => format!("本轮未能完成：{error}。会话和执行记录已保留，可以修正或重试。"),
        AppLocale::En => format!("This run could not be completed: {error}. The session and execution trace were preserved for correction or retry."),
    }
}

fn localized<'a>(locale: &AppLocale, zh: &'a str, en: &'a str) -> &'a str {
    match locale {
        AppLocale::ZhCn => zh,
        AppLocale::En => en,
    }
}

fn tool_title(locale: &AppLocale, name: &str) -> String {
    let (zh, en) = match name {
        "update_plan" => ("更新执行计划", "Update plan"),
        "read_file" => ("读取文件", "Read file"),
        "list_files" => ("查看工作区", "List Workspace"),
        "write_file" => ("写入文件", "Write file"),
        "create_artifact" => ("创建产出物", "Create artifact"),
        "register_artifact" => ("登记产出物", "Register artifact"),
        "run_command" => ("运行命令", "Run command"),
        "spawn_task" => ("派发子任务", "Dispatch child task"),
        "create_designed_presentation" => (
            "使用 DesignKB 生成演示文稿",
            "Create presentation with DesignKB",
        ),
        other => return other.to_string(),
    };
    localized(locale, zh, en).into()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Map;
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{Arc as StdArc, Mutex as StdMutex};
    use std::thread::{self, JoinHandle};
    use std::time::Instant;
    use tempfile::tempdir;

    type MockResponder = dyn Fn(&Value, usize) -> Value + Send + Sync + 'static;

    fn mock_provider(
        expected_requests: usize,
        responder: impl Fn(&Value, usize) -> Value + Send + Sync + 'static,
    ) -> (String, StdArc<StdMutex<Vec<Value>>>, JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let requests = StdArc::new(StdMutex::new(Vec::new()));
        let captured = requests.clone();
        let responder: StdArc<MockResponder> = StdArc::new(responder);
        let handle = thread::spawn(move || {
            let started = Instant::now();
            let mut handlers = Vec::new();
            while handlers.len() < expected_requests && started.elapsed() < Duration::from_secs(8) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        let captured = captured.clone();
                        let responder = responder.clone();
                        let index = handlers.len();
                        handlers.push(thread::spawn(move || {
                            let request = read_request_json(&mut stream);
                            captured.lock().unwrap().push(request.clone());
                            let response = responder(&request, index);
                            let body = serde_json::to_vec(&response).unwrap();
                            let headers = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                                body.len()
                            );
                            stream.write_all(headers.as_bytes()).unwrap();
                            stream.write_all(&body).unwrap();
                            stream.flush().unwrap();
                        }));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("mock provider accept failed: {error}"),
                }
            }
            for handler in handlers {
                handler.join().unwrap();
            }
        });
        (endpoint, requests, handle)
    }

    fn read_request_json(stream: &mut TcpStream) -> Value {
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut chunk = [0_u8; 4_096];
        let header_end = loop {
            let read = stream.read(&mut chunk).unwrap();
            assert!(read > 0, "request ended before its headers");
            bytes.extend_from_slice(&chunk[..read]);
            if let Some(position) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
                break position + 4;
            }
        };
        let headers = String::from_utf8_lossy(&bytes[..header_end]);
        let content_length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        while bytes.len() - header_end < content_length {
            let read = stream.read(&mut chunk).unwrap();
            assert!(read > 0, "request ended before its body");
            bytes.extend_from_slice(&chunk[..read]);
        }
        serde_json::from_slice(&bytes[header_end..header_end + content_length]).unwrap()
    }

    fn openai_response(content: Option<String>, reasoning: Option<&str>, calls: Value) -> Value {
        let mut message = Map::new();
        message.insert("content".into(), content.map_or(Value::Null, Value::String));
        if let Some(reasoning) = reasoning {
            message.insert("reasoning_content".into(), json!(reasoning));
        }
        if !calls.is_null() {
            message.insert("tool_calls".into(), calls);
        }
        json!({"choices":[{"message":Value::Object(message)}]})
    }

    fn goal_response(objective: &str, kind: &str, output_mode: &str) -> Value {
        let success_criteria = if kind == "question" {
            json!([])
        } else {
            json!(["The requested outcome is completed and reported"])
        };
        openai_response(
            Some(
                json!({
                    "objective": objective,
                    "kind": kind,
                    "output_mode": output_mode,
                    "reference_scope": "current_input",
                    "reference_evidence": [objective],
                    "reference_explicit": true,
                    "reference_confidence": "high",
                    "constraints": [],
                    "boundaries": [],
                    "risks": [],
                    "success_criteria": success_criteria,
                    "open_questions": []
                })
                .to_string(),
            ),
            None,
            Value::Null,
        )
    }

    async fn test_kernel_for_platform(
        endpoint: String,
        platform: &str,
    ) -> (tempfile::TempDir, RuntimeStore, RuntimeKernel) {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let mut settings = store.settings().await;
        settings.locale = AppLocale::En;
        settings.provider_id = "custom-compatible".into();
        settings.provider_name = "Mock provider".into();
        settings.protocol = ProviderProtocol::OpenaiChatCompletions;
        settings.endpoint = endpoint;
        settings.model = "mock-agent".into();
        settings.workspace = directory.path().join("Workspace");
        settings.first_run_complete = true;
        store.update_settings(settings).await.unwrap();
        let kernel = RuntimeKernel::new(store.clone(), platform).unwrap();
        (directory, store, kernel)
    }

    async fn test_kernel(endpoint: String) -> (tempfile::TempDir, RuntimeStore, RuntimeKernel) {
        test_kernel_for_platform(endpoint, "windows").await
    }

    fn local_command_test_timeout_seconds() -> u64 {
        if cfg!(target_os = "windows") {
            30
        } else {
            10
        }
    }

    fn runtime_contract_test_timeout() -> Duration {
        Duration::from_secs(if cfg!(target_os = "windows") { 45 } else { 5 })
    }

    #[test]
    fn extracts_balanced_json_without_leaking_surrounding_text() {
        let raw = "preface ```json\n{\"passed\":true,\"summary\":\"ok\",\"findings\":[]}\n``` tail";
        let result: VerificationResult = decode_json(raw).unwrap();
        assert!(result.passed);
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

    #[test]
    fn workspace_path_rejects_parent_escape() {
        let workspace = Path::new("/tmp/lingshu-workspace");
        assert!(resolve_workspace_path(workspace, "../secret.txt").is_err());
        assert!(resolve_workspace_path(workspace, "reports/result.md").is_ok());
    }

    #[tokio::test]
    async fn sandbox_blocks_parent_write_but_full_access_propagates_to_the_process() {
        let root = tempdir().unwrap();
        let workspace = root.path().join("Workspace");
        std::fs::create_dir_all(&workspace).unwrap();
        let marker = root.path().join("Outside").join("permission.txt");

        #[cfg(target_os = "windows")]
        let command = r#"New-Item -ItemType Directory -Force ..\Outside | Out-Null; "$env:LINGSHU_EXECUTION_PERMISSION_MODE`:$env:LINGSHU_NETWORK_ACCESS" | Set-Content -NoNewline ..\Outside\permission.txt"#;
        #[cfg(not(target_os = "windows"))]
        let command = r#"mkdir -p ../Outside && printf '%s:%s' "$LINGSHU_EXECUTION_PERMISSION_MODE" "$LINGSHU_NETWORK_ACCESS" > ../Outside/permission.txt"#;

        let blocked = run_local_command(
            &workspace,
            command,
            Some(local_command_test_timeout_seconds()),
            ExecutionPermissionMode::Sandbox,
        )
        .await
        .unwrap();
        let blocked: Value = serde_json::from_str(&blocked).unwrap();
        assert_eq!(blocked["needs_user_action"], true);
        assert_eq!(
            blocked["required_capability"],
            "filesystem_outside_workspace"
        );
        assert!(!marker.exists());

        let allowed = run_local_command(
            &workspace,
            command,
            Some(local_command_test_timeout_seconds()),
            ExecutionPermissionMode::FullAccess,
        )
        .await
        .unwrap();
        let allowed: Value = serde_json::from_str(&allowed).unwrap();
        assert_eq!(allowed["ok"], true);
        assert_eq!(allowed["permission_mode"], "full_access");
        assert_eq!(
            std::fs::read_to_string(marker).unwrap(),
            "full_access:allowed"
        );
    }

    #[cfg(any(target_os = "windows", target_os = "macos"))]
    #[tokio::test]
    async fn full_access_permits_a_real_local_network_request() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let started = Instant::now();
            while started.elapsed() < Duration::from_secs(local_command_test_timeout_seconds()) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(Duration::from_secs(2)))
                            .unwrap();
                        let mut request = Vec::new();
                        let mut chunk = [0_u8; 1_024];
                        while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                            let read = stream.read(&mut chunk).unwrap();
                            assert!(read > 0, "request ended before its headers");
                            request.extend_from_slice(&chunk[..read]);
                        }
                        let response = b"HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: close\r\n\r\npermission-ok";
                        stream.write_all(response).unwrap();
                        stream.flush().unwrap();
                        return true;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => return false,
                }
            }
            false
        });
        let workspace = tempdir().unwrap();
        let marker = workspace.path().join("network-permission.txt");

        #[cfg(target_os = "windows")]
        let command = format!(
            "$client = [System.Net.Sockets.TcpClient]::new('{host}', {port}); \
             $stream = $client.GetStream(); \
             $request = [System.Text.Encoding]::ASCII.GetBytes(\"GET / HTTP/1.1`r`nHost: {host}`r`nConnection: close`r`n`r`n\"); \
             $stream.Write($request, 0, $request.Length); \
             $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::ASCII); \
             $response = $reader.ReadToEnd(); \
             if (-not $response.Contains('permission-ok')) {{ exit 1 }}; \
             [System.IO.File]::WriteAllText((Join-Path (Get-Location) 'network-permission.txt'), \
             'permission-ok', [System.Text.Encoding]::ASCII); \
             $client.Dispose()",
            host = address.ip(),
            port = address.port()
        );
        #[cfg(target_os = "macos")]
        let command = format!("/usr/bin/curl -fsS 'http://{address}' > network-permission.txt");

        let output = run_local_command(
            workspace.path(),
            &command,
            Some(local_command_test_timeout_seconds()),
            ExecutionPermissionMode::FullAccess,
        )
        .await
        .unwrap();
        let output: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(output["ok"], true);
        assert_eq!(output["permission_mode"], "full_access");
        assert_eq!(std::fs::read_to_string(marker).unwrap(), "permission-ok");
        assert!(server.join().unwrap());
    }

    #[tokio::test]
    async fn sandbox_reports_network_authorization_instead_of_platform_unavailability() {
        let workspace = tempdir().unwrap();
        let output = run_local_command(
            workspace.path(),
            "curl https://example.com",
            Some(10),
            ExecutionPermissionMode::Sandbox,
        )
        .await
        .unwrap();
        let output: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(output["needs_user_action"], true);
        assert_eq!(output["required_capability"], "network");
        assert!(output["recovery"].as_str().unwrap().contains("Full Access"));
    }

    #[test]
    fn simple_questions_keep_the_full_agent_contract_without_forcing_tools() {
        let goal = GoalSpec {
            objective: "Introduce LingShu".into(),
            kind: GoalKind::Question,
            output_mode: OutputMode::ChatReply,
            reference_scope: ReferenceScope::CurrentInput,
            reference_evidence: vec!["Who are you?".into()],
            reference_explicit: true,
            reference_confidence: ReferenceConfidence::High,
            constraints: Vec::new(),
            boundaries: Vec::new(),
            risks: Vec::new(),
            success_criteria: Vec::new(),
            open_questions: Vec::new(),
        };
        assert!(!should_run_checker(&goal, &None));
        assert!(tool_definitions(0, ExecutionPermissionMode::Sandbox)
            .iter()
            .any(|tool| tool.name == "spawn_task"));
    }

    #[test]
    fn read_file_tool_advertises_builtin_document_extraction() {
        let tool = tool_definitions(0, ExecutionPermissionMode::Sandbox)
            .into_iter()
            .find(|tool| tool.name == "read_file")
            .expect("read_file tool must exist");

        assert!(tool.description.contains("PDF"));
        assert!(tool.description.contains("DOCX"));
        assert!(tool.description.contains("PPTX"));
        assert!(tool.description.contains("OCR capability gap"));
    }

    #[test]
    fn runtime_inspection_tool_is_always_available() {
        for permission in [
            ExecutionPermissionMode::Sandbox,
            ExecutionPermissionMode::FullAccess,
        ] {
            let tool = tool_definitions(0, permission)
                .into_iter()
                .find(|tool| tool.name == "inspect_runtime")
                .expect("inspect_runtime tool must exist for every permission mode");
            assert!(tool.description.contains("authoritative"));
            assert!(tool.description.contains("network authorization"));
        }
    }

    #[test]
    fn registered_plugin_tools_enter_the_model_tool_contract() {
        let definitions = plugin_tool_definitions(
            &[PluginToolRecord {
                name: "summarize".into(),
                exposed_name: "plugin__demo_reader__summarize".into(),
                description: "Summarize a local document.".into(),
                description_zh: "总结本地文档。".into(),
                parameters: json!({
                    "type": "object",
                    "properties": {"path": {"type": "string"}},
                    "required": ["path"]
                }),
            }],
            AppLocale::En,
        );

        assert_eq!(definitions.len(), 1);
        assert_eq!(definitions[0].name, "plugin__demo_reader__summarize");
        assert_eq!(definitions[0].description, "Summarize a local document.");
        assert_eq!(definitions[0].parameters["required"][0], "path");

        let localized = plugin_tool_definitions(
            &[PluginToolRecord {
                name: "summarize".into(),
                exposed_name: "plugin__demo_reader__summarize".into(),
                description: "Summarize a local document.".into(),
                description_zh: "总结本地文档。".into(),
                parameters: json!({"type":"object","properties":{}}),
            }],
            AppLocale::ZhCn,
        );
        assert_eq!(localized[0].description, "总结本地文档。");
    }

    #[tokio::test]
    async fn runtime_snapshot_exposes_the_embedded_design_kb_plugin() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let kernel = RuntimeKernel::new(store, "windows").unwrap();
        let snapshot = kernel.snapshot(false).await;
        let design_kb = snapshot
            .plugins
            .iter()
            .find(|plugin| plugin.id == "lingshu.design-kb")
            .expect("DesignKB must be represented in the runtime snapshot");

        assert!(design_kb.enabled);
        assert!(design_kb.available);
        assert_eq!(
            design_kb.tools[0].exposed_name,
            "create_designed_presentation"
        );
    }

    #[test]
    fn full_access_rejects_unverified_sandbox_and_network_claims() {
        let goal = GoalSpec {
            objective: "Explain current runtime access".into(),
            kind: GoalKind::Question,
            output_mode: OutputMode::ChatReply,
            reference_scope: ReferenceScope::CurrentInput,
            reference_evidence: vec!["Can you access the network?".into()],
            reference_explicit: true,
            reference_confidence: ReferenceConfidence::High,
            constraints: Vec::new(),
            boundaries: Vec::new(),
            risks: Vec::new(),
            success_criteria: Vec::new(),
            open_questions: Vec::new(),
        };
        assert!(completion_contract_issue(
            &goal,
            "A sandbox blocks my network access.",
            ExecutionPermissionMode::FullAccess,
            0,
            false,
        )
        .is_some());
        assert!(completion_contract_issue(
            &goal,
            "I cannot access the internet.",
            ExecutionPermissionMode::FullAccess,
            1,
            false,
        )
        .is_some());
        assert!(completion_contract_issue(
            &goal,
            "The network probe failed with a real DNS error.",
            ExecutionPermissionMode::FullAccess,
            1,
            true,
        )
        .is_none());
    }

    #[tokio::test]
    async fn command_execution_uses_live_permission_instead_of_the_task_snapshot() {
        let root = tempdir().unwrap();
        let store = RuntimeStore::open(root.path().join("State")).unwrap();
        let stale_settings = store.settings().await;
        assert_eq!(
            stale_settings.execution_permission_mode,
            ExecutionPermissionMode::Sandbox
        );
        let mut live_settings = stale_settings.clone();
        live_settings.execution_permission_mode = ExecutionPermissionMode::FullAccess;
        store.update_settings(live_settings).await.unwrap();
        let kernel = RuntimeKernel::new(store.clone(), std::env::consts::OS).unwrap();
        let receipt = store
            .enqueue("Verify live permission".into(), Vec::new())
            .await
            .unwrap();
        let task = store.task(receipt.thread_id).await.unwrap();
        let marker = root.path().join("live-permission.txt");

        #[cfg(target_os = "windows")]
        let command = format!(
            "$env:LINGSHU_EXECUTION_PERMISSION_MODE | Set-Content -NoNewline -LiteralPath '{}'",
            marker.display().to_string().replace('\'', "''")
        );
        #[cfg(not(target_os = "windows"))]
        let command = format!(
            "printf '%s' \"$LINGSHU_EXECUTION_PERMISSION_MODE\" > '{}'",
            marker.display()
        );
        let execution = kernel
            .execute_tool(
                task,
                GoalSpec {
                    objective: "Verify live permission".into(),
                    kind: GoalKind::Task,
                    output_mode: OutputMode::ExternalAction,
                    reference_scope: ReferenceScope::CurrentInput,
                    reference_evidence: Vec::new(),
                    reference_explicit: true,
                    reference_confidence: ReferenceConfidence::High,
                    constraints: Vec::new(),
                    boundaries: Vec::new(),
                    risks: Vec::new(),
                    success_criteria: vec!["Marker is written".into()],
                    open_questions: Vec::new(),
                },
                stale_settings,
                None,
                AgentToolCall {
                    id: "live-permission-command".into(),
                    name: "run_command".into(),
                    arguments_json: json!({
                        "command": command,
                        "timeout_seconds": local_command_test_timeout_seconds()
                    })
                    .to_string(),
                },
            )
            .await
            .unwrap();
        let output: Value = serde_json::from_str(&execution.output).unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(output["permission_mode"], "full_access");
        assert_eq!(output["runtime_sandbox_applied"], false);
        assert_eq!(std::fs::read_to_string(marker).unwrap(), "full_access");
    }

    #[cfg(target_os = "windows")]
    #[tokio::test]
    #[ignore = "requires public HTTPS access"]
    async fn full_access_permits_public_https_on_windows() {
        let workspace = tempdir().unwrap();
        let output = run_local_command(
            workspace.path(),
            "$response = Invoke-WebRequest -UseBasicParsing 'https://example.com'; if ($response.StatusCode -ne 200) { exit 1 }; Write-Output $response.StatusCode",
            Some(30),
            ExecutionPermissionMode::FullAccess,
        )
        .await
        .unwrap();
        let output: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(output["ok"], true, "{output}");
        assert_eq!(output["permission_mode"], "full_access");
        assert_eq!(output["network_authorization"], "allowed");
        assert_eq!(output["runtime_sandbox_applied"], false);
        assert!(output["stdout"]
            .as_str()
            .unwrap_or_default()
            .contains("200"));
    }

    #[test]
    fn pdf_attachment_context_contains_extracted_text() {
        let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../Examples/project-aurora/project-aurora-demo.pdf");
        let context = attachment_context(&[fixture]);

        assert!(context.contains("TYPE: Pdf"));
        assert!(context.contains("Project Aurora"));
        assert!(!context.contains("no text was extracted"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn simple_question_completes_goal_and_answer_without_tools_or_children() {
        let (endpoint, requests, server) = mock_provider(2, |request, _| {
            if request.get("stream") == Some(&Value::Bool(false)) {
                goal_response("Introduce LingShu", "question", "chat_reply")
            } else {
                openai_response(
                    Some("I am LingShu, an open-model agent runtime.".into()),
                    Some("Answer the identity question directly."),
                    Value::Null,
                )
            }
        });
        let (_directory, store, kernel) = test_kernel(endpoint).await;
        let receipt = kernel
            .submit("Who are you?".into(), Vec::new())
            .await
            .unwrap();

        let completed = tokio::time::timeout(
            Duration::from_secs(3),
            kernel.run_queue(Some("test-token".into())),
        )
        .await
        .expect("simple chat must not stall")
        .unwrap();
        assert_eq!(completed, 1);
        server.join().unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.status, TaskStatus::Completed);
        assert_eq!(task.role, TaskRole::Main);
        assert_eq!(task.goal_spec.unwrap().output_mode, OutputMode::ChatReply);
        assert_eq!(task.summary, "I am LingShu, an open-model agent runtime.");
        assert!(store.children(receipt.thread_id).await.is_empty());

        let events = store.events_after(0).await;
        assert!(events.iter().any(|event| {
            event.kind == RuntimeEventKind::Reasoning && event.state == RuntimeEventState::Completed
        }));
        assert!(!events.iter().any(|event| {
            matches!(
                event.kind,
                RuntimeEventKind::Tool | RuntimeEventKind::Delegation
            )
        }));
        assert!(events
            .iter()
            .filter(|event| event.kind == RuntimeEventKind::Model)
            .all(|event| event.state == RuntimeEventState::Completed));
        assert_eq!(requests.lock().unwrap().len(), 2);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn unsupported_sandbox_claim_is_corrected_with_real_tool_evidence() {
        #[cfg(target_os = "windows")]
        let permission_command = "Write-Output $env:LINGSHU_EXECUTION_PERMISSION_MODE".to_string();
        #[cfg(not(target_os = "windows"))]
        let permission_command = "printf '%s' \"$LINGSHU_EXECUTION_PERMISSION_MODE\"".to_string();
        let command_for_model = permission_command.clone();
        let command_timeout = local_command_test_timeout_seconds();
        let (endpoint, requests, server) = mock_provider(4, move |request, _| {
            if request.get("stream") == Some(&Value::Bool(false)) {
                return goal_response("Explain current runtime access", "question", "chat_reply");
            }
            let messages = request
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if messages
                .iter()
                .any(|message| message.get("role") == Some(&json!("tool")))
            {
                return openai_response(
                    Some("The live command confirms full_access; LingShu did not apply a process or network sandbox.".into()),
                    Some("Answer from the command evidence."),
                    Value::Null,
                );
            }
            if messages.iter().any(|message| {
                message
                    .get("content")
                    .and_then(Value::as_str)
                    .is_some_and(|content| content.contains("Runtime fact correction"))
            }) {
                return openai_response(
                    None,
                    Some("Verify the authoritative runtime state."),
                    json!([{
                        "id":"permission-probe",
                        "type":"function",
                        "function":{
                            "name":"run_command",
                            "arguments":json!({
                                "command": command_for_model,
                                "timeout_seconds": command_timeout
                            })
                            .to_string()
                        }
                    }]),
                );
            }
            openai_response(
                Some("A sandbox blocks my network access, even though the selector says full access.".into()),
                Some("Incorrectly infer a platform restriction."),
                Value::Null,
            )
        });
        let (_directory, store, kernel) = test_kernel(endpoint).await;
        let mut settings = store.settings().await;
        settings.execution_permission_mode = ExecutionPermissionMode::FullAccess;
        store.update_settings(settings).await.unwrap();
        let receipt = kernel
            .submit(
                "Can you use full access on this computer?".into(),
                Vec::new(),
            )
            .await
            .unwrap();

        let completed = tokio::time::timeout(
            runtime_contract_test_timeout(),
            kernel.run_queue(Some("test-token".into())),
        )
        .await
        .expect("runtime contract correction must not stall")
        .unwrap();
        assert_eq!(completed, 1);
        server.join().unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.status, TaskStatus::Completed);
        assert!(task.summary.contains("full_access"));
        assert!(!task.summary.contains("blocks my network"));
        assert!(task.session_messages.iter().any(|message| {
            message.role == AgentRole::Tool
                && message
                    .content
                    .contains("\"permission_mode\":\"full_access\"")
                && message.content.contains("full_access")
        }));
        assert!(store.events_after(0).await.iter().any(|event| {
            event.kind == RuntimeEventKind::Warning && event.title == "Runtime contract correction"
        }));
        assert_eq!(requests.lock().unwrap().len(), 4);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn macos_and_windows_shells_produce_identical_core_semantics() {
        let (endpoint, requests, server) = mock_provider(4, |request, _| {
            if request.get("stream") == Some(&Value::Bool(false)) {
                goal_response("Introduce LingShu", "question", "chat_reply")
            } else {
                openai_response(
                    Some("I am LingShu, an open-model agent runtime.".into()),
                    Some("Answer the identity question directly."),
                    Value::Null,
                )
            }
        });

        let (_mac_directory, mac_store, mac_kernel) =
            test_kernel_for_platform(endpoint.clone(), "macos").await;
        let mac_receipt = mac_kernel
            .submit("Who are you?".into(), Vec::new())
            .await
            .unwrap();
        mac_kernel
            .run_queue(Some("test-token".into()))
            .await
            .unwrap();

        let (_windows_directory, windows_store, windows_kernel) =
            test_kernel_for_platform(endpoint, "windows").await;
        let windows_receipt = windows_kernel
            .submit("Who are you?".into(), Vec::new())
            .await
            .unwrap();
        windows_kernel
            .run_queue(Some("test-token".into()))
            .await
            .unwrap();
        server.join().unwrap();

        let mac_task = mac_store.task(mac_receipt.thread_id).await.unwrap();
        let windows_task = windows_store.task(windows_receipt.thread_id).await.unwrap();
        assert_eq!(mac_task.prompt, windows_task.prompt);
        assert_eq!(mac_task.status, windows_task.status);
        assert_eq!(mac_task.goal_spec, windows_task.goal_spec);
        assert_eq!(mac_task.summary, windows_task.summary);
        assert_eq!(mac_task.error, windows_task.error);
        assert_eq!(mac_task.role, windows_task.role);
        assert_eq!(mac_task.origin, windows_task.origin);
        assert_eq!(mac_task.participant_name, windows_task.participant_name);
        assert_eq!(mac_task.depth, windows_task.depth);
        assert_eq!(mac_task.attachment_paths, windows_task.attachment_paths);
        assert_eq!(mac_task.artifacts, windows_task.artifacts);
        assert_eq!(
            mac_task
                .steps
                .iter()
                .map(|step| (&step.title, &step.detail, &step.status))
                .collect::<Vec<_>>(),
            windows_task
                .steps
                .iter()
                .map(|step| (&step.title, &step.detail, &step.status))
                .collect::<Vec<_>>()
        );
        assert_eq!(
            mac_task.session_messages.iter().skip(1).collect::<Vec<_>>(),
            windows_task
                .session_messages
                .iter()
                .skip(1)
                .collect::<Vec<_>>()
        );

        let mac_events = mac_store.events_after(0).await;
        let windows_events = windows_store.events_after(0).await;
        assert_eq!(
            mac_events
                .iter()
                .map(|event| (
                    event.sequence,
                    &event.kind,
                    &event.state,
                    &event.actor,
                    &event.title,
                    &event.detail,
                ))
                .collect::<Vec<_>>(),
            windows_events
                .iter()
                .map(|event| (
                    event.sequence,
                    &event.kind,
                    &event.state,
                    &event.actor,
                    &event.title,
                    &event.detail,
                ))
                .collect::<Vec<_>>()
        );

        let mac_snapshot = mac_kernel.snapshot(true).await;
        let windows_snapshot = windows_kernel.snapshot(true).await;
        assert_eq!(
            mac_snapshot.kernel_abi_version,
            windows_snapshot.kernel_abi_version
        );
        assert_eq!(
            mac_snapshot.queued_task_count,
            windows_snapshot.queued_task_count
        );
        assert_eq!(
            mac_snapshot.provider_configured,
            windows_snapshot.provider_configured
        );
        assert_eq!(mac_snapshot.platform, "macos");
        assert_eq!(windows_snapshot.platform, "windows");
        assert!(mac_snapshot.capabilities.computer_control);
        assert!(mac_snapshot.capabilities.realtime_perception);
        assert!(!windows_snapshot.capabilities.computer_control);
        assert!(!windows_snapshot.capabilities.realtime_perception);
        assert_eq!(
            mac_snapshot.capabilities.internal_preview,
            windows_snapshot.capabilities.internal_preview
        );
        assert_eq!(
            mac_snapshot.capabilities.external_open,
            windows_snapshot.capabilities.external_open
        );

        let captured = requests.lock().unwrap();
        assert_eq!(captured.len(), 4);
        let streamed_system_prompts = captured
            .iter()
            .filter(|request| request.get("stream") == Some(&Value::Bool(true)))
            .filter_map(|request| {
                request
                    .get("messages")?
                    .as_array()?
                    .first()?
                    .get("content")?
                    .as_str()
            })
            .collect::<Vec<_>>();
        assert_eq!(streamed_system_prompts.len(), 2);
        assert!(
            streamed_system_prompts[0].contains("computer_control=true, realtime_perception=true")
        );
        assert!(streamed_system_prompts[1]
            .contains("computer_control=false, realtime_perception=false"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn parallel_child_sessions_are_isolated_and_return_to_the_main_session() {
        let (endpoint, requests, server) = mock_provider(7, |request, _| {
            if request.get("stream") == Some(&Value::Bool(false)) {
                return goal_response("Complete assigned analysis", "task", "chat_reply");
            }
            let messages = request
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let system = messages
                .first()
                .and_then(|message| message.get("content"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            if system.contains("Child depth: 1/3") {
                return openai_response(
                    Some("Independent child result".into()),
                    Some("Complete only the isolated assignment."),
                    Value::Null,
                );
            }
            if messages
                .iter()
                .any(|message| message.get("role") == Some(&json!("tool")))
            {
                return openai_response(
                    Some("Both child results were received and combined.".into()),
                    Some("Synthesize the returned child summaries."),
                    Value::Null,
                );
            }
            openai_response(
                None,
                Some("Split two independent analyses."),
                json!([
                    {"id":"child-a","type":"function","function":{"name":"spawn_task","arguments":"{\"objective\":\"Analyze A\",\"role\":\"Analyst A\"}"}},
                    {"id":"child-b","type":"function","function":{"name":"spawn_task","arguments":"{\"objective\":\"Analyze B\",\"role\":\"Analyst B\"}"}}
                ]),
            )
        });
        let (_directory, store, kernel) = test_kernel(endpoint).await;
        let receipt = kernel
            .submit("Coordinate two independent analyses.".into(), Vec::new())
            .await
            .unwrap();

        tokio::time::timeout(
            Duration::from_secs(5),
            kernel.run_queue(Some("test-token".into())),
        )
        .await
        .expect("child orchestration must not stall")
        .unwrap();
        server.join().unwrap();

        let root = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(root.status, TaskStatus::Completed);
        assert_eq!(
            root.summary,
            "Both child results were received and combined."
        );
        let children = store.children(receipt.thread_id).await;
        assert_eq!(children.len(), 2);
        assert!(children.iter().all(|child| {
            child.status == TaskStatus::Completed
                && child.role == TaskRole::Worker
                && child.root_task_id == Some(receipt.thread_id)
                && child.session_messages != root.session_messages
        }));
        assert!(root
            .session_messages
            .iter()
            .filter(|message| message.role == AgentRole::Tool)
            .all(|message| message.content.contains("child_task_id")));
        let events = store.events_after(0).await;
        assert!(
            events
                .iter()
                .filter(|event| {
                    event.task_id == receipt.thread_id
                        && event.kind == RuntimeEventKind::Delegation
                        && event.state == RuntimeEventState::Completed
                })
                .count()
                >= 2
        );
        assert!(events
            .iter()
            .all(|event| event.state != RuntimeEventState::Running));
        assert_eq!(requests.lock().unwrap().len(), 7);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn human_action_blocks_and_resumes_the_same_agent_session() {
        let (endpoint, requests, server) = mock_provider(3, |request, _| {
            if request.get("stream") == Some(&Value::Bool(false)) {
                return goal_response(
                    "Continue after human confirmation",
                    "interaction",
                    "visible_interaction",
                );
            }
            let messages = request
                .get("messages")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if messages
                .iter()
                .any(|message| message.get("role") == Some(&json!("tool")))
            {
                return openai_response(
                    Some("Confirmation received; the original session resumed.".into()),
                    Some("Continue from the preserved tool call."),
                    Value::Null,
                );
            }
            openai_response(
                None,
                Some("A real human confirmation is required."),
                json!([{"id":"confirm-1","type":"function","function":{"name":"ask_user","arguments":"{\"prompt\":\"Confirm the external prerequisite.\"}"}}]),
            )
        });
        let (_directory, store, kernel) = test_kernel(endpoint).await;
        let receipt = kernel
            .submit(
                "Pause for my confirmation, then continue.".into(),
                Vec::new(),
            )
            .await
            .unwrap();
        kernel.run_queue(Some("test-token".into())).await.unwrap();

        let blocked = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(blocked.status, TaskStatus::NeedsUserAction);
        assert_eq!(blocked.pending_tool_call_id.as_deref(), Some("confirm-1"));
        assert_eq!(
            blocked.pending_question.as_deref(),
            Some("Confirm the external prerequisite.")
        );
        assert!(kernel
            .resume(
                receipt.thread_id,
                "Confirmed".into(),
                Some("test-token".into()),
            )
            .await
            .unwrap());
        server.join().unwrap();

        let resumed = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(resumed.status, TaskStatus::Completed);
        assert_eq!(
            resumed.summary,
            "Confirmation received; the original session resumed."
        );
        assert!(resumed.session_messages.iter().any(|message| {
            message.role == AgentRole::Tool
                && message.tool_call_id.as_deref() == Some("confirm-1")
                && message.content == "Confirmed"
        }));
        let interactions = store
            .events_after(0)
            .await
            .into_iter()
            .filter(|event| event.kind == RuntimeEventKind::HumanInteraction)
            .collect::<Vec<_>>();
        assert!(interactions
            .iter()
            .any(|event| event.state == RuntimeEventState::Blocked));
        assert!(interactions
            .iter()
            .any(|event| event.state == RuntimeEventState::Completed));
        assert_eq!(requests.lock().unwrap().len(), 3);
    }
}
