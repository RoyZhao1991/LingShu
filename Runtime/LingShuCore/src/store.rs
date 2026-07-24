use crate::contract::{kernel_contract, PlatformCapabilities, KERNEL_ABI_VERSION};
use crate::models::*;
use chrono::Utc;
use serde::{Deserialize, Serialize};
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
        // A process cannot still own an active task after restart. Preserve the thread and make
        // the interruption explicit instead of pretending it is still running.
        if let Some(active) = state.active_task_id.take() {
            if let Some(task) = state
                .tasks
                .iter_mut()
                .find(|task| task.id == active && !task.status.is_terminal())
            {
                task.status = TaskStatus::Failed;
                task.error = Some("The previous process ended before this task completed.".into());
                task.updated_at = Utc::now();
            }
        }
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
            text: if queued {
                localized.queued
            } else {
                localized.thinking
            }
            .into(),
            created_at: now,
            state: MessageState::Thinking,
            thread_id: Some(thread_id),
            attachment_paths: Vec::new(),
        });
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
            assistant_message_id,
            attachment_paths,
            parent_task_id: None,
            root_task_id: Some(thread_id),
            role: TaskRole::Main,
            origin: TaskOrigin::Conversation,
            participant_name: "LingShu".into(),
            depth: 0,
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
            assistant_message_id: Uuid::new_v4(),
            attachment_paths: Vec::new(),
            parent_task_id: Some(parent_task_id),
            root_task_id,
            role,
            origin,
            participant_name,
            depth,
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
        tool_call_id: Option<String>,
        question: String,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::NeedsUserAction;
            task.pending_tool_call_id = tool_call_id;
            task.pending_question = Some(question.clone());
            task.updated_at = Utc::now();
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
                message.text = question;
                message.state = MessageState::NeedsUserAction;
            }
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
        if let Some(call_id) = task.pending_tool_call_id.take() {
            task.session_messages.push(AgentMessage {
                role: AgentRole::Tool,
                content: answer,
                tool_calls: Vec::new(),
                tool_call_id: Some(call_id),
            });
        } else {
            task.session_messages.push(AgentMessage {
                role: AgentRole::User,
                content: answer,
                tool_calls: Vec::new(),
                tool_call_id: None,
            });
        }
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

    pub async fn next_queued_id(&self) -> Option<Uuid> {
        self.state
            .read()
            .await
            .tasks
            .iter()
            .find(|task| task.status == TaskStatus::Queued)
            .map(|task| task.id)
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
            message.text = localized.running.into();
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
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::Completed;
            task.updated_at = Utc::now();
            task.summary = reply.clone();
            task.artifacts = artifacts;
            if let Some(step) = task.steps.last_mut() {
                step.status = TaskStatus::Completed;
                step.detail = localized.completed.into();
                step.updated_at = Utc::now();
            }
        }
        if let Some(message) = state.messages.iter_mut().find(|message| {
            message.thread_id == Some(thread_id) && message.role == MessageRole::Assistant
        }) {
            message.text = reply;
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
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::Failed;
            task.updated_at = Utc::now();
            task.summary = user_message.clone();
            task.error = Some(error);
            if let Some(step) = task.steps.last_mut() {
                step.status = TaskStatus::Failed;
                step.detail = localized.failed.into();
                step.updated_at = Utc::now();
            }
        }
        if let Some(message) = state.messages.iter_mut().find(|message| {
            message.thread_id == Some(thread_id) && message.role == MessageRole::Assistant
        }) {
            message.text = user_message;
            message.state = MessageState::Failed;
        }
        if state.active_task_id == Some(thread_id) {
            state.active_task_id = None;
        }
        drop(state);
        self.persist().await
    }

    pub async fn cancel(&self, thread_id: Uuid) -> Result<bool, StoreError> {
        let mut state = self.state.write().await;
        let localized = copy(state.settings.locale);
        let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) else {
            return Ok(false);
        };
        if task.status.is_terminal() {
            return Ok(false);
        }
        task.status = TaskStatus::Cancelled;
        task.updated_at = Utc::now();
        task.summary = localized.cancelled.into();
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
    queued: &'static str,
    thinking: &'static str,
    understand: &'static str,
    waiting_kernel: &'static str,
    generating_goal: &'static str,
    goal_accepted: &'static str,
    produce: &'static str,
    model_working: &'static str,
    running: &'static str,
    completed: &'static str,
    failed: &'static str,
    cancelled: &'static str,
}

fn copy(locale: AppLocale) -> RuntimeCopy {
    match locale {
        AppLocale::ZhCn => RuntimeCopy {
            welcome: "我是灵枢。配置一个主脑后，可以直接对话，也可以让我生成并登记文件产物。",
            queued: "已加入任务队列。",
            thinking: "理解中…",
            understand: "理解当前要求",
            waiting_kernel: "等待共享运行时内核接管",
            generating_goal: "正在生成完整 GoalSpec",
            goal_accepted: "GoalSpec 已通过共享内核契约校验",
            produce: "生成回复和产出物",
            model_working: "当前配置的模型正在处理",
            running: "执行中…",
            completed: "回复和产出物登记已完成",
            failed: "任务未能完成",
            cancelled: "已停止本轮任务。",
        },
        AppLocale::En => RuntimeCopy {
            welcome: "I am LingShu. Connect a brain channel to chat or create and register file artifacts.",
            queued: "Added to the main task queue.",
            thinking: "Understanding…",
            understand: "Understand the request",
            waiting_kernel: "Waiting for the shared runtime kernel",
            generating_goal: "Generating a complete GoalSpec",
            goal_accepted: "GoalSpec accepted by the shared kernel contract",
            produce: "Produce the response and artifacts",
            model_working: "The configured model is working",
            running: "Running…",
            completed: "Response and artifact registry completed",
            failed: "The task stopped before completion",
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
}
