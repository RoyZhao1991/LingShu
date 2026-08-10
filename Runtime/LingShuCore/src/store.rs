use crate::contract::{kernel_contract, PlatformCapabilities, KERNEL_ABI_VERSION};
use crate::models::*;
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{Mutex, RwLock};
use uuid::Uuid;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("could not create LingShu data directory: {0}")]
    CreateDirectory(#[source] std::io::Error),
    #[error("could not encode LingShu state: {0}")]
    Encode(#[from] serde_json::Error),
    #[error("could not persist LingShu state: {0}")]
    Persist(#[source] std::io::Error),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedState {
    schema_version: u32,
    settings: RuntimeSettings,
    messages: Vec<ChatMessage>,
    tasks: Vec<TaskRecord>,
    active_task_id: Option<Uuid>,
    #[serde(default)]
    events: Vec<RuntimeEvent>,
    #[serde(default)]
    next_event_sequence: u64,
}

impl Default for PersistedState {
    fn default() -> Self {
        Self {
            schema_version: kernel_contract().state_schema_version,
            settings: RuntimeSettings::default(),
            messages: vec![ChatMessage {
                id: Uuid::new_v4(),
                role: MessageRole::Assistant,
                text: "我是灵枢。配置一个主脑后，可以直接对话，也可以让我生成并登记文件产物。"
                    .into(),
                created_at: Utc::now(),
                state: MessageState::Complete,
                thread_id: None,
                attachment_paths: Vec::new(),
            }],
            tasks: Vec::new(),
            active_task_id: None,
            events: Vec::new(),
            next_event_sequence: 1,
        }
    }
}

fn task_lineage_root(tasks: &[TaskRecord], task_id: Uuid) -> Uuid {
    tasks
        .iter()
        .find(|task| task.id == task_id)
        .and_then(|task| task.root_task_id)
        .unwrap_or(task_id)
}

fn descendant_ids(tasks: &[TaskRecord], ancestor_id: Uuid) -> Vec<Uuid> {
    let mut family = vec![ancestor_id];
    let mut cursor = 0;
    while cursor < family.len() {
        let parent_id = family[cursor];
        for task in tasks {
            if task.parent_task_id == Some(parent_id) && !family.contains(&task.id) {
                family.push(task.id);
            }
        }
        cursor += 1;
    }
    family.into_iter().skip(1).collect()
}

fn close_nonterminal_task(
    task: &mut TaskRecord,
    status: TaskStatus,
    summary: &str,
    error: Option<&str>,
    now: chrono::DateTime<Utc>,
) {
    if task.status.is_terminal() {
        return;
    }
    task.status = status.clone();
    task.updated_at = now;
    task.summary = summary.into();
    task.error = error.map(str::to_owned);
    task.pending_tool_call_id = None;
    task.pending_question = None;
    for step in &mut task.steps {
        if !step.status.is_terminal() {
            step.status = status.clone();
            step.detail = summary.into();
            step.updated_at = now;
        }
    }
}

fn close_nonterminal_descendants(
    state: &mut PersistedState,
    ancestor_id: Uuid,
    status: TaskStatus,
    summary: &str,
    error: Option<&str>,
    now: chrono::DateTime<Utc>,
) {
    let descendants = descendant_ids(&state.tasks, ancestor_id);
    for task in &mut state.tasks {
        if descendants.contains(&task.id) {
            close_nonterminal_task(task, status.clone(), summary, error, now);
        }
    }
}

fn recover_interrupted_tasks(state: &mut PersistedState) {
    let now = Utc::now();
    let (interruption, recovering, legacy_recovery, legacy_technical_gate, child_interrupted) =
        match state.settings.locale {
        AppLocale::ZhCn => (
            "上次进程在目标完成前退出，目标与产出物均已保留。",
            "检测到上次执行中断，目标已进入恢复队列。",
            "此记录来自旧版失败终态，目标与执行证据均已保留，正在按原会话自动恢复。",
            "旧版曾将技术故障误标为人机交互；目标与执行上下文已保留，现已转入技术恢复队列。",
            "上次进程退出时，此子任务尝试仍在运行；本次尝试已结束，主目标仍可继续。",
        ),
        AppLocale::En => (
            "The previous process exited before the goal was complete; the goal and artifacts were preserved.",
            "The previous run was interrupted; the goal is queued for recovery.",
            "This record used the legacy failed terminal state. The goal and execution evidence were preserved and the same session will recover automatically.",
            "An older build misclassified a technical failure as human interaction. The goal and execution context were preserved and moved to technical recovery.",
            "This child attempt was still running when the previous process exited. The attempt was closed and the parent goal remains recoverable.",
        ),
    };
    let active_root_id = state
        .active_task_id
        .take()
        .map(|active_id| task_lineage_root(&state.tasks, active_id));

    // `failed` existed as a terminal task state in older builds. Migrate root goals to the
    // automatic recovery state; failed child/checker records remain closed attempt evidence.
    for task in &mut state.tasks {
        if task.status != TaskStatus::Failed {
            continue;
        }
        if task.parent_task_id.is_none() {
            task.status = TaskStatus::NeedsRecovery;
            task.pending_question = None;
            task.summary = legacy_recovery.into();
            task.pending_tool_call_id = None;
            for step in &mut task.steps {
                if step.status == TaskStatus::Failed {
                    step.status = TaskStatus::NeedsRecovery;
                    step.detail = legacy_recovery.into();
                    step.updated_at = now;
                }
            }
        } else {
            task.status = TaskStatus::Cancelled;
            task.pending_question = None;
            task.pending_tool_call_id = None;
            task.summary = child_interrupted.into();
            for step in &mut task.steps {
                if step.status == TaskStatus::Failed {
                    step.status = TaskStatus::Cancelled;
                    step.detail = child_interrupted.into();
                    step.updated_at = now;
                }
            }
        }
        task.updated_at = now;
    }

    // Older builds also used `needs_user_action` for authentication, endpoint, model-name, and
    // protocol failures. Genuine `ask_user` checkpoints always carry the originating tool call
    // id, so an unbound checkpoint can be migrated without guessing or losing task context.
    for task in &mut state.tasks {
        if task.status != TaskStatus::NeedsUserAction || task.pending_tool_call_id.is_some() {
            continue;
        }
        let previous_detail = task
            .pending_question
            .take()
            .filter(|question| !question.trim().is_empty())
            .unwrap_or_else(|| task.summary.clone());
        task.pending_tool_call_id = None;
        if task.parent_task_id.is_none() {
            task.status = TaskStatus::NeedsRecovery;
            task.summary = legacy_technical_gate.into();
            if task.error.as_deref().unwrap_or_default().trim().is_empty() {
                task.error = Some(previous_detail);
            }
            for step in &mut task.steps {
                if step.status == TaskStatus::NeedsUserAction {
                    step.status = TaskStatus::NeedsRecovery;
                    step.detail = legacy_technical_gate.into();
                    step.updated_at = now;
                }
            }
        } else {
            task.status = TaskStatus::Cancelled;
            task.summary = child_interrupted.into();
            task.error = Some(previous_detail);
            for step in &mut task.steps {
                if step.status == TaskStatus::NeedsUserAction {
                    step.status = TaskStatus::Cancelled;
                    step.detail = child_interrupted.into();
                    step.updated_at = now;
                }
            }
        }
        task.updated_at = now;
    }

    if let Some(root_id) = active_root_id {
        if let Some(root) = state.tasks.iter_mut().find(|task| task.id == root_id) {
            if !root.status.is_terminal() {
                let recovery_status =
                    if root.goal_spec.is_some() || !root.session_messages.is_empty() {
                        TaskStatus::NeedsRecovery
                    } else {
                        TaskStatus::Queued
                    };
                root.status = recovery_status.clone();
                root.summary = recovering.into();
                root.error = Some(interruption.into());
                root.pending_tool_call_id = None;
                root.pending_question = None;
                root.updated_at = now;
                for step in &mut root.steps {
                    if !step.status.is_terminal() {
                        step.status = recovery_status.clone();
                        step.detail = recovering.into();
                        step.updated_at = now;
                    }
                }
            }
        }
        close_nonterminal_descendants(
            state,
            root_id,
            TaskStatus::Cancelled,
            child_interrupted,
            Some(interruption),
            now,
        );
    }

    // A process restart cannot preserve a live child driver. Goals with a persisted GoalSpec or
    // Loop transcript resume from that exact context; only pre-compilation work returns to queued.
    // Completed artifacts and completed children remain untouched.
    let root_ids = state
        .tasks
        .iter()
        .filter(|task| task.parent_task_id.is_none())
        .map(|task| task.id)
        .collect::<Vec<_>>();
    for root_id in root_ids {
        let root_status = state
            .tasks
            .iter()
            .find(|task| task.id == root_id)
            .map(|task| task.status.clone());
        match root_status {
            Some(TaskStatus::Understanding | TaskStatus::Running) => {
                if let Some(root) = state.tasks.iter_mut().find(|task| task.id == root_id) {
                    let recovery_status =
                        if root.goal_spec.is_some() || !root.session_messages.is_empty() {
                            TaskStatus::NeedsRecovery
                        } else {
                            TaskStatus::Queued
                        };
                    root.status = recovery_status.clone();
                    root.summary = recovering.into();
                    root.error = Some(interruption.into());
                    root.updated_at = now;
                    for step in &mut root.steps {
                        if !step.status.is_terminal() {
                            step.status = recovery_status.clone();
                            step.detail = recovering.into();
                            step.updated_at = now;
                        }
                    }
                }
                close_nonterminal_descendants(
                    state,
                    root_id,
                    TaskStatus::Cancelled,
                    child_interrupted,
                    Some(interruption),
                    now,
                );
            }
            Some(TaskStatus::Completed | TaskStatus::Cancelled) => {
                close_nonterminal_descendants(
                    state,
                    root_id,
                    TaskStatus::Cancelled,
                    child_interrupted,
                    None,
                    now,
                );
            }
            _ => {}
        }
    }

    let main_messages = state
        .tasks
        .iter()
        .filter(|task| task.parent_task_id.is_none())
        .map(|task| {
            (
                task.assistant_message_id,
                task.status.clone(),
                task.summary.clone(),
                task.pending_question.clone(),
            )
        })
        .collect::<Vec<_>>();
    for (assistant_id, status, summary, pending_question) in main_messages {
        let Some(message) = state
            .messages
            .iter_mut()
            .find(|message| message.id == assistant_id)
        else {
            continue;
        };
        match status {
            TaskStatus::Queued => {
                if is_transient_assistant_text(&message.text) {
                    message.text = recovering.into();
                }
                message.state = MessageState::Thinking;
            }
            TaskStatus::NeedsUserAction => {
                message.text =
                    merge_assistant_reply(&message.text, &pending_question.unwrap_or(summary));
                message.state = MessageState::NeedsUserAction;
            }
            TaskStatus::NeedsRecovery => {
                message.text = merge_assistant_reply(&message.text, &summary);
                message.state = MessageState::NeedsRecovery;
            }
            _ if message.state == MessageState::Failed => {
                message.text = merge_assistant_reply(&message.text, &summary);
                message.state = MessageState::NeedsRecovery;
            }
            _ => {}
        }
    }
}

#[derive(Clone)]
pub struct RuntimeStore {
    state: Arc<RwLock<PersistedState>>,
    data_file: Arc<PathBuf>,
    persist_guard: Arc<Mutex<()>>,
}

impl RuntimeStore {
    pub fn open(data_dir: impl AsRef<Path>) -> Result<Self, StoreError> {
        let data_dir = data_dir.as_ref();
        fs::create_dir_all(data_dir).map_err(StoreError::CreateDirectory)?;
        let data_file = data_dir.join("runtime-state.json");
        let mut state = fs::read(&data_file)
            .ok()
            .and_then(|data| serde_json::from_slice::<PersistedState>(&data).ok())
            .unwrap_or_default();
        if state.next_event_sequence == 0 {
            state.next_event_sequence = state
                .events
                .iter()
                .map(|event| event.sequence)
                .max()
                .unwrap_or(0)
                .saturating_add(1);
        }
        // No task driver survives a process restart. Repair the entire active lineage, including
        // child agents, so the UI never inherits a terminal parent with phantom running children.
        recover_interrupted_tasks(&mut state);
        fs::create_dir_all(&state.settings.workspace).map_err(StoreError::CreateDirectory)?;
        Self::write_state(&data_file, &state)?;
        let store = Self {
            state: Arc::new(RwLock::new(state)),
            data_file: Arc::new(data_file),
            persist_guard: Arc::new(Mutex::new(())),
        };
        Ok(store)
    }

    pub fn default_data_dir() -> PathBuf {
        dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("LingShu")
    }

    pub async fn settings(&self) -> RuntimeSettings {
        self.state.read().await.settings.clone()
    }

    pub async fn update_settings(&self, settings: RuntimeSettings) -> Result<(), StoreError> {
        fs::create_dir_all(&settings.workspace).map_err(StoreError::CreateDirectory)?;
        let mut state = self.state.write().await;
        state.settings = settings.clone();
        if state.messages.len() == 1 && state.messages[0].thread_id.is_none() {
            state.messages[0].text = copy(settings.locale).welcome.into();
        }
        drop(state);
        self.persist().await
    }

    pub async fn snapshot(
        &self,
        platform: &str,
        capabilities: PlatformCapabilities,
        provider_configured: bool,
    ) -> RuntimeSnapshot {
        let state = self.state.read().await;
        let queued_task_count = state
            .tasks
            .iter()
            .filter(|task| task.status == TaskStatus::Queued)
            .count();
        RuntimeSnapshot {
            kernel_abi_version: KERNEL_ABI_VERSION.into(),
            settings: state.settings.clone(),
            platform: platform.into(),
            capabilities,
            messages: state.messages.clone(),
            tasks: state.tasks.clone(),
            active_task_id: state.active_task_id,
            queued_task_count,
            provider_configured,
            events: state.events.clone(),
            latest_event_sequence: state.next_event_sequence.saturating_sub(1),
            plugins: Vec::new(),
            memory: MemorySnapshot::default(),
            loop_engines: Vec::new(),
        }
    }

    pub fn data_dir(&self) -> PathBuf {
        self.data_file
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(Self::default_data_dir)
    }

    pub async fn enqueue(
        &self,
        prompt: String,
        attachment_paths: Vec<PathBuf>,
    ) -> Result<SubmitReceipt, StoreError> {
        let now = Utc::now();
        let thread_id = Uuid::new_v4();
        let user_message_id = Uuid::new_v4();
        let assistant_message_id = Uuid::new_v4();
        let mut state = self.state.write().await;
        let localized = copy(state.settings.locale);
        let queued = state.active_task_id.is_some()
            || state
                .tasks
                .iter()
                .any(|task| task.status == TaskStatus::Queued);
        let loop_engine = state.settings.loop_engine;
        // Queue management belongs to the queue tray, not the conversation. A queued turn is
        // projected into chat only when `claim` actually promotes it for execution.
        if !queued {
            state.messages.push(ChatMessage {
                id: user_message_id,
                role: MessageRole::User,
                text: prompt.clone(),
                created_at: now,
                state: MessageState::Complete,
                thread_id: Some(thread_id),
                attachment_paths: attachment_paths.clone(),
            });
            state.messages.push(ChatMessage {
                id: assistant_message_id,
                role: MessageRole::Assistant,
                text: localized.thinking.into(),
                created_at: now,
                state: MessageState::Thinking,
                thread_id: Some(thread_id),
                attachment_paths: Vec::new(),
            });
        }
        state.tasks.push(TaskRecord {
            id: thread_id,
            title: prompt.chars().take(48).collect(),
            prompt,
            status: TaskStatus::Queued,
            created_at: now,
            updated_at: now,
            goal_spec: None,
            steps: vec![TaskStep {
                id: Uuid::new_v4(),
                title: localized.understand.into(),
                detail: localized.waiting_kernel.into(),
                status: TaskStatus::Queued,
                updated_at: now,
            }],
            artifacts: Vec::new(),
            summary: String::new(),
            error: None,
            user_message_id: Some(user_message_id),
            assistant_message_id,
            attachment_paths,
            parent_task_id: None,
            root_task_id: Some(thread_id),
            role: TaskRole::Main,
            origin: TaskOrigin::Conversation,
            participant_name: "LingShu".into(),
            depth: 0,
            loop_engine,
            session_messages: Vec::new(),
            pending_tool_call_id: None,
            pending_question: None,
        });
        drop(state);
        self.persist().await?;
        Ok(SubmitReceipt {
            thread_id,
            user_message_id,
            assistant_message_id,
            queued,
        })
    }

    pub async fn claim(&self, thread_id: Uuid) -> Result<bool, StoreError> {
        let mut state = self.state.write().await;
        let localized = copy(state.settings.locale);
        let claimable = state.active_task_id.is_none()
            && state
                .tasks
                .iter()
                .any(|task| task.id == thread_id && task.status == TaskStatus::Queued);
        if !claimable {
            return Ok(false);
        }
        state.active_task_id = Some(thread_id);
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::Understanding;
            task.updated_at = Utc::now();
            if let Some(step) = task.steps.first_mut() {
                step.status = TaskStatus::Understanding;
                step.detail = localized.generating_goal.into();
                step.updated_at = Utc::now();
            }
        }
        let promoted_conversation =
            state
                .tasks
                .iter()
                .find(|task| task.id == thread_id)
                .map(|task| {
                    (
                        task.user_message_id.unwrap_or_else(Uuid::new_v4),
                        task.assistant_message_id,
                        task.prompt.clone(),
                        task.attachment_paths.clone(),
                    )
                });
        if let Some((user_message_id, assistant_message_id, prompt, attachment_paths)) =
            promoted_conversation
        {
            let already_visible = state
                .messages
                .iter()
                .any(|message| message.thread_id == Some(thread_id));
            if !already_visible {
                let now = Utc::now();
                state.messages.push(ChatMessage {
                    id: user_message_id,
                    role: MessageRole::User,
                    text: prompt,
                    created_at: now,
                    state: MessageState::Complete,
                    thread_id: Some(thread_id),
                    attachment_paths,
                });
                state.messages.push(ChatMessage {
                    id: assistant_message_id,
                    role: MessageRole::Assistant,
                    text: localized.thinking.into(),
                    created_at: now,
                    state: MessageState::Thinking,
                    thread_id: Some(thread_id),
                    attachment_paths: Vec::new(),
                });
            }
        }
        drop(state);
        self.persist().await?;
        Ok(true)
    }

    pub async fn task(&self, thread_id: Uuid) -> Option<TaskRecord> {
        self.state
            .read()
            .await
            .tasks
            .iter()
            .find(|task| task.id == thread_id)
            .cloned()
    }

    pub async fn children(&self, parent_task_id: Uuid) -> Vec<TaskRecord> {
        self.state
            .read()
            .await
            .tasks
            .iter()
            .filter(|task| task.parent_task_id == Some(parent_task_id))
            .cloned()
            .collect()
    }

    pub async fn task_is_cancelled(&self, thread_id: Uuid) -> bool {
        self.state
            .read()
            .await
            .tasks
            .iter()
            .find(|task| task.id == thread_id)
            .map(|task| task.status == TaskStatus::Cancelled)
            .unwrap_or(true)
    }

    pub async fn events_after(&self, sequence: u64) -> Vec<RuntimeEvent> {
        self.state
            .read()
            .await
            .events
            .iter()
            .filter(|event| event.sequence > sequence)
            .cloned()
            .collect()
    }

    pub async fn append_event(
        &self,
        task_id: Uuid,
        kind: RuntimeEventKind,
        state_value: RuntimeEventState,
        actor: impl Into<String>,
        title: impl Into<String>,
        detail: impl Into<String>,
    ) -> Result<RuntimeEvent, StoreError> {
        let now = Utc::now();
        let mut state = self.state.write().await;
        let parent_task_id = state
            .tasks
            .iter()
            .find(|task| task.id == task_id)
            .and_then(|task| task.parent_task_id);
        let event = RuntimeEvent {
            id: Uuid::new_v4(),
            sequence: state.next_event_sequence,
            task_id,
            parent_task_id,
            kind,
            state: state_value,
            actor: actor.into(),
            title: title.into(),
            detail: detail.into(),
            created_at: now,
            updated_at: now,
        };
        state.next_event_sequence = state.next_event_sequence.saturating_add(1);
        state.events.push(event.clone());
        if state.events.len() > 8_000 {
            let remove = state.events.len() - 8_000;
            state.events.drain(..remove);
        }
        drop(state);
        self.persist().await?;
        Ok(event)
    }

    pub async fn append_event_detail(&self, event_id: Uuid, delta: &str) -> Result<(), StoreError> {
        if delta.is_empty() {
            return Ok(());
        }
        let mut state = self.state.write().await;
        if let Some(event) = state.events.iter_mut().find(|event| event.id == event_id) {
            event.detail.push_str(delta);
            event.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await
    }

    /// Streaming deltas remain immediately visible through `snapshot()` but are flushed once per
    /// completed model turn instead of rewriting the state file for every token.
    pub async fn append_event_detail_live(&self, event_id: Uuid, delta: &str) {
        if delta.is_empty() {
            return;
        }
        let mut state = self.state.write().await;
        if let Some(event) = state.events.iter_mut().find(|event| event.id == event_id) {
            event.detail.push_str(delta);
            event.updated_at = Utc::now();
        }
    }

    pub async fn finish_event(
        &self,
        event_id: Uuid,
        event_state: RuntimeEventState,
        detail: Option<String>,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if let Some(event) = state.events.iter_mut().find(|event| event.id == event_id) {
            event.state = event_state;
            if let Some(detail) = detail {
                event.detail = detail;
            }
            event.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await
    }

    pub async fn set_session_messages(
        &self,
        thread_id: Uuid,
        messages: Vec<AgentMessage>,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.session_messages = messages;
            task.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await
    }

    pub async fn set_assistant_text(
        &self,
        thread_id: Uuid,
        text: String,
        message_state: MessageState,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                message.text = text;
                message.state = message_state;
            }
        }
        drop(state);
        self.persist().await
    }

    /// Show a transient status only while the assistant has not produced visible output yet.
    /// Once a Loop turn has emitted text, later thinking/tool phases must keep that transcript.
    pub async fn set_assistant_placeholder_if_empty(
        &self,
        thread_id: Uuid,
        placeholder: String,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if message.state != MessageState::Complete {
                    if message.state == MessageState::NeedsUserAction
                        || is_transient_assistant_text(&message.text)
                    {
                        message.text = placeholder;
                    }
                    message.state = MessageState::Thinking;
                }
            }
        }
        drop(state);
        self.persist().await
    }

    /// Start a new visible Loop turn without replacing any text from earlier turns.
    /// Placeholder-only bubbles are cleared; real output receives a stable paragraph boundary.
    pub async fn begin_assistant_visible_turn(&self, thread_id: Uuid) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if message.state != MessageState::Complete {
                    if is_transient_assistant_text(&message.text) {
                        message.text.clear();
                    } else if !message.text.is_empty() {
                        let trimmed_length = message.text.trim_end_matches(['\r', '\n']).len();
                        message.text.truncate(trimmed_length);
                        message.text.push_str("\n\n");
                    }
                    message.state = MessageState::Thinking;
                }
            }
        }
        drop(state);
        self.persist().await
    }

    pub async fn append_assistant_delta(
        &self,
        thread_id: Uuid,
        delta: &str,
    ) -> Result<(), StoreError> {
        if delta.is_empty() {
            return Ok(());
        }
        let mut state = self.state.write().await;
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if message.state != MessageState::Complete {
                    message.text.push_str(delta);
                    message.state = MessageState::Thinking;
                }
            }
        }
        drop(state);
        self.persist().await
    }

    pub async fn append_assistant_delta_live(&self, thread_id: Uuid, delta: &str) {
        if delta.is_empty() {
            return;
        }
        let mut state = self.state.write().await;
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if message.state != MessageState::Complete {
                    message.text.push_str(delta);
                    message.state = MessageState::Thinking;
                }
            }
        }
    }

    pub async fn flush(&self) -> Result<(), StoreError> {
        self.persist().await
    }

    pub async fn update_plan(
        &self,
        thread_id: Uuid,
        items: Vec<(String, String, TaskStatus)>,
    ) -> Result<(), StoreError> {
        let now = Utc::now();
        let mut state = self.state.write().await;
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.steps = items
                .into_iter()
                .map(|(title, detail, status)| TaskStep {
                    id: Uuid::new_v4(),
                    title,
                    detail,
                    status,
                    updated_at: now,
                })
                .collect();
            task.updated_at = now;
        }
        drop(state);
        self.persist().await
    }

    pub async fn add_artifacts(
        &self,
        thread_id: Uuid,
        artifacts: Vec<ArtifactRecord>,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            for artifact in artifacts {
                if let Some(existing) = task
                    .artifacts
                    .iter_mut()
                    .find(|item| item.path == artifact.path)
                {
                    *existing = artifact;
                } else {
                    task.artifacts.push(artifact);
                }
            }
            task.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await
    }

    pub async fn create_child_task(
        &self,
        parent_task_id: Uuid,
        prompt: String,
        role: TaskRole,
        participant_name: String,
        origin: TaskOrigin,
        loop_engine: LoopEngineKind,
    ) -> Result<Uuid, StoreError> {
        let now = Utc::now();
        let child_id = Uuid::new_v4();
        let mut state = self.state.write().await;
        let parent = state
            .tasks
            .iter()
            .find(|task| task.id == parent_task_id)
            .cloned();
        let root_task_id = parent
            .as_ref()
            .and_then(|task| task.root_task_id)
            .or(Some(parent_task_id));
        let depth = parent
            .as_ref()
            .map(|task| task.depth.saturating_add(1))
            .unwrap_or(1);
        let localized = copy(state.settings.locale);
        state.tasks.push(TaskRecord {
            id: child_id,
            title: prompt.chars().take(64).collect(),
            prompt,
            status: TaskStatus::Understanding,
            created_at: now,
            updated_at: now,
            goal_spec: None,
            steps: vec![TaskStep {
                id: Uuid::new_v4(),
                title: localized.understand.into(),
                detail: localized.generating_goal.into(),
                status: TaskStatus::Understanding,
                updated_at: now,
            }],
            artifacts: Vec::new(),
            summary: String::new(),
            error: None,
            user_message_id: None,
            assistant_message_id: Uuid::new_v4(),
            attachment_paths: Vec::new(),
            parent_task_id: Some(parent_task_id),
            root_task_id,
            role,
            origin,
            participant_name,
            depth,
            loop_engine,
            session_messages: Vec::new(),
            pending_tool_call_id: None,
            pending_question: None,
        });
        drop(state);
        self.persist().await?;
        Ok(child_id)
    }

    pub async fn set_needs_user_action(
        &self,
        thread_id: Uuid,
        tool_call_id: String,
        question: String,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let now = Utc::now();
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::NeedsUserAction;
            task.pending_tool_call_id = Some(tool_call_id);
            task.pending_question = Some(question.clone());
            task.summary = question.clone();
            task.updated_at = now;
            if let Some(step) = task.steps.last_mut() {
                if !step.status.is_terminal() {
                    step.status = TaskStatus::NeedsUserAction;
                    step.detail = question.clone();
                    step.updated_at = now;
                }
            }
        }
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                message.text = merge_assistant_reply(&message.text, &question);
                message.state = MessageState::NeedsUserAction;
            }
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        drop(state);
        self.persist().await
    }

    /// Put a root goal into automatic recovery. Technical errors are retained in `error` and the
    /// event log, but do not masquerade as a request for human input or terminate the objective.
    pub async fn require_recovery(
        &self,
        thread_id: Uuid,
        user_message: String,
        error: String,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if state
            .tasks
            .iter()
            .find(|task| task.id == thread_id)
            .is_some_and(|task| task.status == TaskStatus::Cancelled)
        {
            return Ok(());
        }
        let now = Utc::now();
        let child_summary = match state.settings.locale {
            AppLocale::ZhCn => "父目标等待恢复，此轮子任务尝试已结束。",
            AppLocale::En => {
                "The parent goal is waiting to resume; this child-task attempt was closed."
            }
        };
        close_nonterminal_descendants(
            &mut state,
            thread_id,
            TaskStatus::Cancelled,
            child_summary,
            Some(&error),
            now,
        );
        let assistant_id =
            if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
                task.status = TaskStatus::NeedsRecovery;
                task.updated_at = now;
                task.summary = user_message.clone();
                task.error = Some(error);
                task.pending_tool_call_id = None;
                task.pending_question = None;
                if let Some(step) = task.steps.last_mut() {
                    if !step.status.is_terminal() {
                        step.status = TaskStatus::NeedsRecovery;
                        step.detail = user_message.clone();
                        step.updated_at = now;
                    }
                }
                Some(task.assistant_message_id)
            } else {
                None
            };
        if let Some(assistant_id) = assistant_id {
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                message.text = merge_assistant_reply(&message.text, &user_message);
                message.state = MessageState::NeedsRecovery;
            }
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        drop(state);
        self.persist().await
    }

    /// Close one worker/checker attempt without declaring its parent objective failed.
    pub async fn cancel_attempt(
        &self,
        thread_id: Uuid,
        summary: String,
        error: String,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let now = Utc::now();
        close_nonterminal_descendants(
            &mut state,
            thread_id,
            TaskStatus::Cancelled,
            &summary,
            Some(&error),
            now,
        );
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            close_nonterminal_task(task, TaskStatus::Cancelled, &summary, Some(&error), now);
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        drop(state);
        self.persist().await
    }

    pub async fn prepare_resume(
        &self,
        thread_id: Uuid,
        answer: String,
    ) -> Result<Option<TaskRecord>, StoreError> {
        let mut state = self.state.write().await;
        if state.active_task_id.is_some() {
            return Ok(None);
        }
        let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) else {
            return Ok(None);
        };
        if task.status != TaskStatus::NeedsUserAction {
            return Ok(None);
        }
        let Some(call_id) = task.pending_tool_call_id.take() else {
            return Ok(None);
        };
        task.session_messages.push(AgentMessage {
            role: AgentRole::Tool,
            content: answer,
            tool_calls: Vec::new(),
            tool_call_id: Some(call_id),
        });
        task.pending_question = None;
        task.status = TaskStatus::Running;
        task.updated_at = Utc::now();
        let resumes_main = task.role == TaskRole::Main;
        let task = task.clone();
        if resumes_main {
            state.active_task_id = Some(thread_id);
        }
        drop(state);
        self.persist().await?;
        Ok(Some(task))
    }

    /// Continue a technical recovery from the exact persisted Loop transcript. Unlike
    /// `prepare_resume`, this does not manufacture a user reply or resolve a human checkpoint.
    pub async fn prepare_continue(
        &self,
        thread_id: Uuid,
    ) -> Result<Option<TaskRecord>, StoreError> {
        let mut state = self.state.write().await;
        if state.active_task_id.is_some() {
            return Ok(None);
        }
        let locale = state.settings.locale;
        let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) else {
            return Ok(None);
        };
        if task.status != TaskStatus::NeedsRecovery {
            return Ok(None);
        }
        let detail = task.error.clone().unwrap_or_else(|| match locale {
            AppLocale::ZhCn => "上一轮运行被中断。".into(),
            AppLocale::En => "The previous runtime attempt was interrupted.".into(),
        });
        let recovery_instruction = match locale {
            AppLocale::ZhCn => "【运行时恢复】沿用当前 GoalSpec、已有上下文和产出物继续推进；不要重新开始，也不要因本次异常宣告失败。",
            AppLocale::En => "[Runtime recovery] Continue with the current GoalSpec, existing context, and artifacts. Do not restart or declare failure because of this attempt error.",
        };
        task.session_messages.push(AgentMessage {
            role: AgentRole::System,
            content: format!("{recovery_instruction}\n{detail}"),
            tool_calls: Vec::new(),
            tool_call_id: None,
        });
        task.pending_question = None;
        task.pending_tool_call_id = None;
        task.status = TaskStatus::Running;
        task.updated_at = Utc::now();
        let resumes_main = task.role == TaskRole::Main;
        let task = task.clone();
        if resumes_main {
            state.active_task_id = Some(thread_id);
        }
        drop(state);
        self.persist().await?;
        Ok(Some(task))
    }

    pub async fn requeue_for_retry(&self, thread_id: Uuid) -> Result<bool, StoreError> {
        let mut state = self.state.write().await;
        let localized = copy(state.settings.locale);
        let now = Utc::now();
        let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) else {
            return Ok(false);
        };
        if task.status.is_terminal() {
            return Ok(false);
        }
        task.status = TaskStatus::Queued;
        task.pending_tool_call_id = None;
        task.pending_question = None;
        task.updated_at = now;
        task.summary = localized.recovering.into();
        if let Some(step) = task.steps.last_mut() {
            if !step.status.is_terminal() {
                step.status = TaskStatus::Queued;
                step.detail = localized.recovering.into();
                step.updated_at = now;
            }
        }
        let assistant_id = task.assistant_message_id;
        if let Some(message) = state
            .messages
            .iter_mut()
            .find(|message| message.id == assistant_id)
        {
            if is_transient_assistant_text(&message.text) {
                message.text = localized.recovering.into();
            }
            message.state = MessageState::Thinking;
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        drop(state);
        self.persist().await?;
        Ok(true)
    }

    pub async fn next_queued_id(&self) -> Option<Uuid> {
        self.next_queued_id_excluding(&HashSet::new()).await
    }

    pub async fn next_queued_id_excluding(&self, excluded: &HashSet<Uuid>) -> Option<Uuid> {
        self.state
            .read()
            .await
            .tasks
            .iter()
            .find(|task| task.status == TaskStatus::Queued && !excluded.contains(&task.id))
            .map(|task| task.id)
    }

    pub async fn next_recovery_id(&self) -> Option<Uuid> {
        self.next_recovery_id_excluding(&HashSet::new()).await
    }

    pub async fn next_recovery_id_excluding(&self, excluded: &HashSet<Uuid>) -> Option<Uuid> {
        self.state
            .read()
            .await
            .tasks
            .iter()
            .find(|task| {
                task.parent_task_id.is_none()
                    && task.status == TaskStatus::NeedsRecovery
                    && !excluded.contains(&task.id)
            })
            .map(|task| task.id)
    }

    pub async fn has_runnable_tasks(&self) -> bool {
        self.state.read().await.tasks.iter().any(|task| {
            task.status == TaskStatus::Queued
                || (task.parent_task_id.is_none() && task.status == TaskStatus::NeedsRecovery)
        })
    }

    pub async fn conversation_context(
        &self,
        excluding_thread: Uuid,
        limit: usize,
    ) -> Vec<ChatMessage> {
        let state = self.state.read().await;
        let mut messages: Vec<_> = state
            .messages
            .iter()
            .filter(|message| {
                message.thread_id != Some(excluding_thread)
                    && message.state == MessageState::Complete
            })
            .rev()
            .take(limit)
            .cloned()
            .collect();
        messages.reverse();
        messages
    }

    pub async fn set_goal(&self, thread_id: Uuid, goal: GoalSpec) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let localized = copy(state.settings.locale);
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.title = goal.objective.chars().take(64).collect();
            task.goal_spec = Some(goal);
            task.status = TaskStatus::Running;
            task.updated_at = Utc::now();
            if let Some(step) = task.steps.first_mut() {
                step.status = TaskStatus::Completed;
                step.detail = localized.goal_accepted.into();
                step.updated_at = Utc::now();
            }
            task.steps.push(TaskStep {
                id: Uuid::new_v4(),
                title: localized.produce.into(),
                detail: localized.model_working.into(),
                status: TaskStatus::Running,
                updated_at: Utc::now(),
            });
        }
        if let Some(message) = state.messages.iter_mut().find(|message| {
            message.thread_id == Some(thread_id) && message.role == MessageRole::Assistant
        }) {
            if is_transient_assistant_text(&message.text) {
                message.text = localized.running.into();
            }
            message.state = MessageState::Thinking;
        }
        drop(state);
        self.persist().await
    }

    pub async fn complete(
        &self,
        thread_id: Uuid,
        reply: String,
        artifacts: Vec<ArtifactRecord>,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if state
            .tasks
            .iter()
            .find(|task| task.id == thread_id)
            .is_some_and(|task| task.status == TaskStatus::Cancelled)
        {
            return Ok(());
        }
        let localized = copy(state.settings.locale);
        let now = Utc::now();
        close_nonterminal_descendants(
            &mut state,
            thread_id,
            TaskStatus::Cancelled,
            "Closed when the parent task completed.",
            None,
            now,
        );
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::Completed;
            task.updated_at = now;
            task.summary = reply.clone();
            task.artifacts = artifacts;
            task.pending_tool_call_id = None;
            task.pending_question = None;
            if let Some(step) = task.steps.last_mut() {
                step.status = TaskStatus::Completed;
                step.detail = localized.completed.into();
                step.updated_at = now;
            }
        }
        if let Some(message) = state.messages.iter_mut().find(|message| {
            message.thread_id == Some(thread_id) && message.role == MessageRole::Assistant
        }) {
            message.text = merge_assistant_reply(&message.text, &reply);
            message.state = MessageState::Complete;
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        drop(state);
        self.persist().await
    }

    pub async fn fail(
        &self,
        thread_id: Uuid,
        user_message: String,
        error: String,
    ) -> Result<(), StoreError> {
        // Backward-compatible entry point for older hosts. Runtime failures are recoverable and
        // must never write the legacy terminal `failed` task state.
        self.require_recovery(thread_id, user_message, error).await
    }

    pub async fn cancel(&self, thread_id: Uuid) -> Result<bool, StoreError> {
        let mut state = self.state.write().await;
        let localized = copy(state.settings.locale);
        let Some(task) = state.tasks.iter().find(|task| task.id == thread_id) else {
            return Ok(false);
        };
        if task.status.is_terminal() {
            return Ok(false);
        }
        let now = Utc::now();
        close_nonterminal_descendants(
            &mut state,
            thread_id,
            TaskStatus::Cancelled,
            localized.cancelled,
            None,
            now,
        );
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            close_nonterminal_task(task, TaskStatus::Cancelled, localized.cancelled, None, now);
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        if let Some(message) = state.messages.iter_mut().find(|message| {
            message.thread_id == Some(thread_id) && message.role == MessageRole::Assistant
        }) {
            message.text = localized.cancelled.into();
            message.state = MessageState::Complete;
        }
        drop(state);
        self.persist().await?;
        Ok(true)
    }

    async fn persist(&self) -> Result<(), StoreError> {
        // Every writer snapshots only after entering this gate. Concurrent cancel/poll/update
        // calls therefore cannot rename the same temporary file out of order.
        let _guard = self.persist_guard.lock().await;
        let state = self.state.read().await.clone();
        Self::write_state(&self.data_file, &state)
    }

    fn write_state(path: &Path, state: &PersistedState) -> Result<(), StoreError> {
        let data = serde_json::to_vec_pretty(state)?;
        let temporary = path.with_extension("json.tmp");
        let mut file = fs::File::create(&temporary).map_err(StoreError::Persist)?;
        file.write_all(&data).map_err(StoreError::Persist)?;
        file.sync_all().map_err(StoreError::Persist)?;
        replace_file(&temporary, path).map_err(StoreError::Persist)
    }
}

#[cfg(not(target_os = "windows"))]
fn replace_file(source: &Path, destination: &Path) -> std::io::Result<()> {
    fs::rename(source, destination)
}

#[cfg(target_os = "windows")]
fn replace_file(source: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    let succeeded = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if succeeded == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

struct RuntimeCopy {
    welcome: &'static str,
    thinking: &'static str,
    understand: &'static str,
    waiting_kernel: &'static str,
    generating_goal: &'static str,
    goal_accepted: &'static str,
    produce: &'static str,
    model_working: &'static str,
    running: &'static str,
    recovering: &'static str,
    completed: &'static str,
    cancelled: &'static str,
}

fn is_transient_assistant_text(text: &str) -> bool {
    matches!(
        text.trim(),
        "" | "理解中…"
            | "Understanding…"
            | "思考中…"
            | "Thinking…"
            | "执行中…"
            | "Running…"
            | "Working…"
            | "正在恢复目标并重新进入执行队列…"
            | "Recovering the goal and returning it to the execution queue…"
    )
}

fn merge_assistant_reply(existing: &str, reply: &str) -> String {
    let existing = if is_transient_assistant_text(existing) {
        ""
    } else {
        existing.trim_end()
    };
    let reply = reply.trim();
    if existing.is_empty() {
        return reply.into();
    }
    if reply.is_empty() || existing.ends_with(reply) {
        return existing.into();
    }
    format!("{existing}\n\n{reply}")
}

fn copy(locale: AppLocale) -> RuntimeCopy {
    match locale {
        AppLocale::ZhCn => RuntimeCopy {
            welcome: "我是灵枢。配置一个主脑后，可以直接对话，也可以让我生成并登记文件产物。",
            thinking: "理解中…",
            understand: "理解当前要求",
            waiting_kernel: "等待共享运行时内核接管",
            generating_goal: "正在生成完整 GoalSpec",
            goal_accepted: "GoalSpec 已通过共享内核契约校验",
            produce: "生成回复和产出物",
            model_working: "当前配置的模型正在处理",
            running: "执行中…",
            recovering: "正在恢复目标并重新进入执行队列…",
            completed: "回复和产出物登记已完成",
            cancelled: "已停止本轮任务。",
        },
        AppLocale::En => RuntimeCopy {
            welcome: "I am LingShu. Connect a brain channel to chat or create and register file artifacts.",
            thinking: "Understanding…",
            understand: "Understand the request",
            waiting_kernel: "Waiting for the shared runtime kernel",
            generating_goal: "Generating a complete GoalSpec",
            goal_accepted: "GoalSpec accepted by the shared kernel contract",
            produce: "Produce the response and artifacts",
            model_working: "The configured model is working",
            running: "Running…",
            recovering: "Recovering the goal and returning it to the execution queue…",
            completed: "Response and artifact registry completed",
            cancelled: "This task was cancelled.",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn state_file_can_be_replaced_repeatedly() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let mut settings = store.settings().await;
        settings.first_run_complete = true;
        store.update_settings(settings.clone()).await.unwrap();
        settings.locale = AppLocale::En;
        store.update_settings(settings).await.unwrap();

        let reopened = RuntimeStore::open(directory.path()).unwrap();
        assert_eq!(reopened.settings().await.locale, AppLocale::En);
    }

    #[tokio::test]
    async fn enqueue_persists_attachments_on_the_user_message() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let attachment = PathBuf::from(r"C:\Users\Roy\Documents\resume.pdf");

        let receipt = store
            .enqueue("Review this resume".into(), vec![attachment.clone()])
            .await
            .unwrap();
        let snapshot = store
            .snapshot(
                "windows",
                PlatformCapabilities {
                    computer_control: false,
                    realtime_perception: false,
                    internal_preview: true,
                    external_open: true,
                },
                true,
            )
            .await;
        let user_message = snapshot
            .messages
            .iter()
            .find(|message| {
                message.thread_id == Some(receipt.thread_id) && message.role == MessageRole::User
            })
            .unwrap();

        assert_eq!(user_message.attachment_paths, vec![attachment]);
    }

    #[tokio::test]
    async fn assistant_output_appends_across_loop_turns_and_completion() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Build a report".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());

        store
            .set_assistant_placeholder_if_empty(receipt.thread_id, "思考中…".into())
            .await
            .unwrap();
        store
            .begin_assistant_visible_turn(receipt.thread_id)
            .await
            .unwrap();
        store
            .append_assistant_delta(receipt.thread_id, "第一轮进展")
            .await
            .unwrap();

        store
            .set_assistant_placeholder_if_empty(receipt.thread_id, "执行中…".into())
            .await
            .unwrap();
        store
            .set_assistant_placeholder_if_empty(receipt.thread_id, "思考中…".into())
            .await
            .unwrap();
        store
            .begin_assistant_visible_turn(receipt.thread_id)
            .await
            .unwrap();
        store
            .append_assistant_delta(receipt.thread_id, "最终答复")
            .await
            .unwrap();
        store
            .complete(receipt.thread_id, "最终答复".into(), Vec::new())
            .await
            .unwrap();

        let snapshot = store
            .snapshot(
                "macos",
                PlatformCapabilities {
                    computer_control: true,
                    realtime_perception: true,
                    internal_preview: true,
                    external_open: true,
                },
                true,
            )
            .await;
        let assistant = snapshot
            .messages
            .iter()
            .find(|message| message.id == receipt.assistant_message_id)
            .unwrap();

        assert_eq!(assistant.text, "第一轮进展\n\n最终答复");
        assert_eq!(assistant.state, MessageState::Complete);
    }

    #[tokio::test]
    async fn queued_task_enters_chat_only_after_it_is_claimed() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let first = store
            .enqueue("Run the active task".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(first.thread_id).await.unwrap());

        let attachment = PathBuf::from(r"C:\Users\Roy\Documents\queued.pdf");
        let queued = store
            .enqueue(
                "Run this after the active task".into(),
                vec![attachment.clone()],
            )
            .await
            .unwrap();
        assert!(queued.queued);

        let queued_snapshot = store
            .snapshot(
                "windows",
                PlatformCapabilities {
                    computer_control: false,
                    realtime_perception: false,
                    internal_preview: true,
                    external_open: true,
                },
                true,
            )
            .await;
        assert!(!queued_snapshot
            .messages
            .iter()
            .any(|message| message.thread_id == Some(queued.thread_id)));

        store
            .complete(first.thread_id, "Active task completed".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(queued.thread_id).await.unwrap());

        let promoted_snapshot = store
            .snapshot(
                "windows",
                PlatformCapabilities {
                    computer_control: false,
                    realtime_perception: false,
                    internal_preview: true,
                    external_open: true,
                },
                true,
            )
            .await;
        let promoted_messages = promoted_snapshot
            .messages
            .iter()
            .filter(|message| message.thread_id == Some(queued.thread_id))
            .collect::<Vec<_>>();

        assert_eq!(promoted_messages.len(), 2);
        assert_eq!(promoted_messages[0].role, MessageRole::User);
        assert_eq!(promoted_messages[0].attachment_paths, vec![attachment]);
        assert_eq!(promoted_messages[1].role, MessageRole::Assistant);
        assert_eq!(promoted_messages[1].state, MessageState::Thinking);
    }

    #[tokio::test]
    async fn completing_parent_closes_nonterminal_descendants() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Build a report".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());
        let child_id = store
            .create_child_task(
                receipt.thread_id,
                "Check the report".into(),
                TaskRole::Checker,
                "Checker".into(),
                TaskOrigin::Verification,
                LoopEngineKind::Grok,
            )
            .await
            .unwrap();

        store
            .complete(receipt.thread_id, "Delivered".into(), Vec::new())
            .await
            .unwrap();

        assert_eq!(
            store.task(receipt.thread_id).await.unwrap().status,
            TaskStatus::Completed
        );
        let child = store.task(child_id).await.unwrap();
        assert_eq!(child.status, TaskStatus::Cancelled);
        assert!(child.pending_question.is_none());
        assert!(child.steps.iter().all(|step| step.status.is_terminal()));
    }

    #[tokio::test]
    async fn restart_repairs_entire_active_lineage() {
        let directory = tempdir().unwrap();
        let root_id;
        let child_id;
        {
            let store = RuntimeStore::open(directory.path()).unwrap();
            let receipt = store
                .enqueue("Build a report".into(), Vec::new())
                .await
                .unwrap();
            root_id = receipt.thread_id;
            assert!(store.claim(root_id).await.unwrap());
            child_id = store
                .create_child_task(
                    root_id,
                    "Write a section".into(),
                    TaskRole::Worker,
                    "Writer".into(),
                    TaskOrigin::Subtask,
                    LoopEngineKind::Grok,
                )
                .await
                .unwrap();
        }

        let reopened = RuntimeStore::open(directory.path()).unwrap();
        let root = reopened.task(root_id).await.unwrap();
        let child = reopened.task(child_id).await.unwrap();
        assert_eq!(root.status, TaskStatus::Queued);
        assert_eq!(child.status, TaskStatus::Cancelled);
        assert!(root.error.is_some());
        assert!(child.error.is_some());
        let snapshot = reopened
            .snapshot(
                "macos",
                PlatformCapabilities {
                    computer_control: true,
                    realtime_perception: true,
                    internal_preview: true,
                    external_open: true,
                },
                true,
            )
            .await;
        assert!(snapshot.active_task_id.is_none());
        assert!(snapshot
            .tasks
            .iter()
            .all(|task| { task.status.is_terminal() || task.status == TaskStatus::Queued }));
    }

    #[tokio::test]
    async fn restart_preserves_loop_context_and_schedules_recovery() {
        let directory = tempdir().unwrap();
        let root_id;
        let preserved = AgentMessage {
            role: AgentRole::Assistant,
            content: "The report draft is halfway complete.".into(),
            tool_calls: Vec::new(),
            tool_call_id: None,
        };
        {
            let store = RuntimeStore::open(directory.path()).unwrap();
            let receipt = store
                .enqueue("Build a report".into(), Vec::new())
                .await
                .unwrap();
            root_id = receipt.thread_id;
            assert!(store.claim(root_id).await.unwrap());
            store
                .set_session_messages(root_id, vec![preserved.clone()])
                .await
                .unwrap();
        }

        let reopened = RuntimeStore::open(directory.path()).unwrap();
        let task = reopened.task(root_id).await.unwrap();
        assert_eq!(task.status, TaskStatus::NeedsRecovery);
        assert_eq!(task.session_messages, vec![preserved]);
        assert_eq!(reopened.next_recovery_id().await, Some(root_id));
        assert!(reopened.next_queued_id().await.is_none());
    }

    #[tokio::test]
    async fn restart_migrates_unbound_legacy_human_gate_to_technical_recovery() {
        let directory = tempdir().unwrap();
        let root_id;
        {
            let store = RuntimeStore::open(directory.path()).unwrap();
            let receipt = store
                .enqueue("Continue after the provider is repaired".into(), Vec::new())
                .await
                .unwrap();
            root_id = receipt.thread_id;
            let mut state = store.state.write().await;
            let task = state
                .tasks
                .iter_mut()
                .find(|task| task.id == root_id)
                .unwrap();
            task.status = TaskStatus::NeedsUserAction;
            task.pending_tool_call_id = None;
            task.pending_question = Some("The model service rejected this request.".into());
            task.steps[0].status = TaskStatus::NeedsUserAction;
            drop(state);
            store.persist().await.unwrap();
        }

        let reopened = RuntimeStore::open(directory.path()).unwrap();
        let task = reopened.task(root_id).await.unwrap();
        assert_eq!(task.status, TaskStatus::NeedsRecovery);
        assert!(task.pending_tool_call_id.is_none());
        assert!(task.pending_question.is_none());
        assert_eq!(
            task.error.as_deref(),
            Some("The model service rejected this request.")
        );
        assert_eq!(task.steps[0].status, TaskStatus::NeedsRecovery);
        assert_eq!(reopened.next_recovery_id().await, Some(root_id));
    }

    #[tokio::test]
    async fn restart_preserves_human_gate_bound_to_ask_user_tool_call() {
        let directory = tempdir().unwrap();
        let root_id;
        {
            let store = RuntimeStore::open(directory.path()).unwrap();
            let receipt = store
                .enqueue("Wait for my confirmation".into(), Vec::new())
                .await
                .unwrap();
            root_id = receipt.thread_id;
            store
                .set_needs_user_action(
                    root_id,
                    "ask-user-call-1".into(),
                    "Confirm the prerequisite.".into(),
                )
                .await
                .unwrap();
        }

        let reopened = RuntimeStore::open(directory.path()).unwrap();
        let task = reopened.task(root_id).await.unwrap();
        assert_eq!(task.status, TaskStatus::NeedsUserAction);
        assert_eq!(
            task.pending_tool_call_id.as_deref(),
            Some("ask-user-call-1")
        );
        assert_eq!(
            task.pending_question.as_deref(),
            Some("Confirm the prerequisite.")
        );
        assert!(reopened.next_recovery_id().await.is_none());
    }

    #[tokio::test]
    async fn runtime_failure_enters_automatic_recovery_without_failing_goal() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Build a report".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());

        store
            .fail(
                receipt.thread_id,
                "Update the model token, then continue.".into(),
                "authentication failed".into(),
            )
            .await
            .unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.status, TaskStatus::NeedsRecovery);
        assert!(task.pending_question.is_none());
        assert_eq!(task.error.as_deref(), Some("authentication failed"));
        assert!(!task.status.is_terminal());
        assert!(store
            .snapshot(
                "macos",
                PlatformCapabilities {
                    computer_control: true,
                    realtime_perception: true,
                    internal_preview: true,
                    external_open: true,
                },
                true,
            )
            .await
            .tasks
            .iter()
            .all(|task| task.status != TaskStatus::Failed));
    }

    #[tokio::test]
    async fn interrupted_child_attempt_does_not_fail_parent_goal() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Build a report".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());
        let child_id = store
            .create_child_task(
                receipt.thread_id,
                "Write a section".into(),
                TaskRole::Worker,
                "Writer".into(),
                TaskOrigin::Subtask,
                LoopEngineKind::Grok,
            )
            .await
            .unwrap();

        store
            .cancel_attempt(
                child_id,
                "This attempt was interrupted.".into(),
                "network timeout".into(),
            )
            .await
            .unwrap();

        let root = store.task(receipt.thread_id).await.unwrap();
        assert!(!root.status.is_terminal());
        assert_ne!(root.status, TaskStatus::Failed);
        assert_eq!(
            store.task(child_id).await.unwrap().status,
            TaskStatus::Cancelled
        );
    }
}
