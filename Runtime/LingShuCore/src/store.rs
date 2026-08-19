use crate::artifacts::artifact_path_logical_key;
use crate::contract::{kernel_contract, PlatformCapabilities, KERNEL_ABI_VERSION};
use crate::models::*;
use crate::preview::{file_revision, semantic_file_revision};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::{watch, Mutex, RwLock};
use uuid::Uuid;

const MAX_APPLIED_EXTERNAL_RUN_IDS: usize = 64;

#[derive(Debug, Error)]
pub enum StoreError {
    #[error("could not create LingShu data directory: {0}")]
    CreateDirectory(#[source] std::io::Error),
    #[error("could not encode LingShu state: {0}")]
    Encode(#[from] serde_json::Error),
    #[error("could not persist LingShu state: {0}")]
    Persist(#[source] std::io::Error),
    #[error("artifact supersession target is not a current delivery: {0}")]
    MissingArtifactSupersessionTarget(Uuid),
    #[error("invalid external artifact registration: {0}")]
    InvalidExternalArtifactRegistration(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ArtifactRegistrationMode {
    Additive,
    CheckerRevision,
    ExplicitSupersession,
}

#[derive(Debug, Clone)]
pub(crate) struct ArtifactRegistration {
    pub current: ArtifactRecord,
    pub changed: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct ArtifactSupersession {
    pub superseded_artifact_id: Uuid,
    pub replacement: ArtifactRecord,
}

/// One item in an external harness commit. Undeclared changed files have no target and remain
/// additive companions. A declared save-as replacement carries the exact pre-run raw revision so
/// the Store can reject stale or ambiguous claims before mutating any artifact state.
#[derive(Debug, Clone)]
pub(crate) struct ExternalArtifactRegistration {
    pub artifact: ArtifactRecord,
    pub superseded_artifact_id: Option<Uuid>,
    pub expected_superseded_revision: Option<String>,
}

/// Keep persisted model transcripts valid when an execution attempt stops after the assistant
/// emitted tool calls but before every result was recorded. Recovery and synthetic human gates
/// may append new messages only after each earlier call has a matching Tool message.
pub(crate) fn close_unanswered_tool_calls(messages: &mut Vec<AgentMessage>) {
    close_unanswered_tool_calls_except(messages, None);
}

pub(crate) fn close_unanswered_tool_calls_except(
    messages: &mut Vec<AgentMessage>,
    pending_call_id: Option<&str>,
) {
    let answered = messages
        .iter()
        .filter(|message| message.role == AgentRole::Tool)
        .filter_map(|message| message.tool_call_id.clone())
        .collect::<HashSet<_>>();
    let mut insertions = Vec::new();
    for (index, message) in messages.iter().enumerate() {
        if message.role != AgentRole::Assistant || message.tool_calls.is_empty() {
            continue;
        }
        let missing = message
            .tool_calls
            .iter()
            .filter(|call| {
                !answered.contains(&call.id) && pending_call_id != Some(call.id.as_str())
            })
            .map(|call| AgentMessage {
                role: AgentRole::Tool,
                content: serde_json::json!({
                    "ok": false,
                    "recoverable": true,
                    "attempt_status": "interrupted",
                    "tool": call.name,
                    "instruction": "The runtime stopped this tool call before a result was recorded. Continue from the preserved session state."
                })
                .to_string(),
                tool_calls: Vec::new(),
                tool_call_id: Some(call.id.clone()),
            })
            .collect::<Vec<_>>();
        if missing.is_empty() {
            continue;
        }
        let mut insertion_index = index + 1;
        while insertion_index < messages.len() && messages[insertion_index].role == AgentRole::Tool
        {
            insertion_index += 1;
        }
        insertions.push((insertion_index, missing));
    }
    for (index, missing) in insertions.into_iter().rev() {
        messages.splice(index..index, missing);
    }
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
    /// Assistant messages that still contain host-owned progress copy rather than model output.
    /// Tracking provenance avoids treating legitimate model text such as `Thinking…` as a
    /// placeholder merely because its bytes happen to match localized progress copy.
    #[serde(default)]
    assistant_placeholder_message_ids: HashSet<Uuid>,
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
            assistant_placeholder_message_ids: HashSet::new(),
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

/// Manual termination is a control-state change, not a replacement result. Keep every piece of
/// work already recorded on the task and its steps while closing anything that was still active.
fn terminate_nonterminal_task_preserving_content(
    task: &mut TaskRecord,
    now: chrono::DateTime<Utc>,
) {
    if task.status.is_terminal() {
        return;
    }
    task.status = TaskStatus::Cancelled;
    task.updated_at = now;
    task.pending_tool_call_id = None;
    task.pending_question = None;
    for step in &mut task.steps {
        if !step.status.is_terminal() {
            step.status = TaskStatus::Cancelled;
            step.updated_at = now;
        }
    }
}

fn terminate_lineage_preserving_content(
    state: &mut PersistedState,
    root_id: Uuid,
    now: chrono::DateTime<Utc>,
) {
    let mut lineage = descendant_ids(&state.tasks, root_id);
    lineage.push(root_id);
    for task in &mut state.tasks {
        if lineage.contains(&task.id) {
            terminate_nonterminal_task_preserving_content(task, now);
        }
    }
    for event in &mut state.events {
        if lineage.contains(&event.task_id)
            && matches!(
                event.state,
                RuntimeEventState::Running | RuntimeEventState::Blocked
            )
        {
            event.state = RuntimeEventState::Cancelled;
            event.updated_at = now;
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
        let is_placeholder = state
            .assistant_placeholder_message_ids
            .contains(&assistant_id);
        let Some(message) = state
            .messages
            .iter_mut()
            .find(|message| message.id == assistant_id)
        else {
            continue;
        };
        match status {
            TaskStatus::Queued => {
                if is_placeholder {
                    message.text = recovering.into();
                }
                message.state = MessageState::Thinking;
            }
            TaskStatus::NeedsUserAction => {
                message.text = merge_assistant_reply(
                    &message.text,
                    &pending_question.unwrap_or(summary),
                    is_placeholder,
                );
                message.state = MessageState::NeedsUserAction;
            }
            TaskStatus::NeedsRecovery => {
                message.text = merge_assistant_reply(&message.text, &summary, is_placeholder);
                message.state = MessageState::NeedsRecovery;
            }
            _ if message.state == MessageState::Failed => {
                message.text = merge_assistant_reply(&message.text, &summary, is_placeholder);
                message.state = MessageState::NeedsRecovery;
            }
            _ => {}
        }
    }
}

fn hydrate_artifact_provenance(state: &mut PersistedState) {
    for artifact in state.tasks.iter_mut().flat_map(|task| {
        task.artifacts
            .iter_mut()
            .chain(task.superseded_artifacts.iter_mut())
    }) {
        if artifact.logical_key.is_none() {
            artifact.logical_key = Some(artifact_path_logical_key(&artifact.path));
        }
        if artifact.revision.is_empty() {
            artifact.revision = file_revision(&artifact.path).unwrap_or_default();
        }
        if artifact.semantic_revision.is_empty() {
            artifact.semantic_revision = semantic_file_revision(&artifact.path)
                .unwrap_or_else(|_| artifact.revision.clone());
        }
    }
}

#[derive(Clone)]
pub struct RuntimeStore {
    state: Arc<RwLock<PersistedState>>,
    data_file: Arc<PathBuf>,
    persist_guard: Arc<Mutex<()>>,
    cancellation_signals: Arc<Mutex<HashMap<Uuid, watch::Sender<bool>>>>,
}

fn register_task_artifact(
    task: &mut TaskRecord,
    mut artifact: ArtifactRecord,
    explicit_supersession: Option<Uuid>,
) -> ArtifactRegistration {
    // A workspace observer may see a superseded file again because historical physical files are
    // intentionally retained. Even if those bytes were modified, an ordinary registration must
    // never reactivate that rejected path. Refresh the history record in place (preserving its
    // identity and provenance links) and keep returning the current delivery.
    if let Some(history_index) = (explicit_supersession.is_none()
        && !task
            .artifacts
            .iter()
            .any(|current| current.path == artifact.path))
    .then(|| {
        task.superseded_artifacts
            .iter()
            .position(|history| history.path == artifact.path)
    })
    .flatten()
    {
        let history = task.superseded_artifacts[history_index].clone();
        let current = task
            .artifacts
            .iter()
            .find(|current| {
                current.logical_key == history.logical_key
                    || history.superseded_by == Some(current.id)
            })
            .cloned();
        artifact.id = history.id;
        artifact.logical_key = history.logical_key.clone();
        artifact.semantic_context = history.semantic_context.clone();
        artifact.supersedes = history.supersedes;
        artifact.superseded_by = current
            .as_ref()
            .map(|current| current.id)
            .or(history.superseded_by);
        task.superseded_artifacts[history_index] = artifact.clone();
        return ArtifactRegistration {
            current: current.unwrap_or(artifact),
            changed: false,
        };
    }

    let explicit_index = explicit_supersession.and_then(|target_id| {
        task.artifacts
            .iter()
            .position(|current| current.id == target_id)
    });
    let exact_path_index = task
        .artifacts
        .iter()
        .position(|current| current.path == artifact.path);
    let current_index = explicit_index.or(exact_path_index).or_else(|| {
        artifact.logical_key.as_ref().and_then(|key| {
            task.artifacts
                .iter()
                .position(|current| current.logical_key.as_ref() == Some(key))
        })
    });

    let Some(index) = current_index else {
        task.artifacts.push(artifact.clone());
        return ArtifactRegistration {
            current: artifact,
            changed: true,
        };
    };

    let current = task.artifacts[index].clone();
    // Exact paths retain their established semantic slot even when an automatic workspace delta
    // observes the file again using path-derived provenance.
    artifact.logical_key = current
        .logical_key
        .clone()
        .or_else(|| artifact.logical_key.clone());
    if exact_path_index.is_some() && explicit_supersession.is_none() {
        artifact.semantic_context = current.semantic_context.clone();
    }
    if explicit_supersession.is_none()
        && artifact.semantic_revision == current.semantic_revision
        && artifact.semantic_context == current.semantic_context
    {
        if artifact.path != current.path
            && !task.superseded_artifacts.iter().any(|history| {
                history.path == artifact.path && history.revision == artifact.revision
            })
        {
            artifact.supersedes = None;
            artifact.superseded_by = Some(current.id);
            task.superseded_artifacts.push(artifact);
        }
        return ArtifactRegistration {
            current,
            changed: false,
        };
    }

    artifact.supersedes = Some(current.id);
    artifact.superseded_by = None;
    let mut superseded = std::mem::replace(&mut task.artifacts[index], artifact.clone());
    superseded.superseded_by = Some(artifact.id);
    task.superseded_artifacts.push(superseded);
    ArtifactRegistration {
        current: artifact,
        changed: true,
    }
}

fn store_artifact_path_identity(path: &Path) -> String {
    let mut value = path.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        value.make_ascii_lowercase();
    }
    value
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
        // Added provenance fields are serde-defaulted, so schema-v1 state remains readable.
        // Hydrate only exact path identity; never guess that legacy `name-2.ext` was a revision,
        // because it may be a genuine companion artifact.
        hydrate_artifact_provenance(&mut state);
        // No task driver survives a process restart. Repair the entire active lineage, including
        // child agents, so the UI never inherits a terminal parent with phantom running children.
        recover_interrupted_tasks(&mut state);
        fs::create_dir_all(&state.settings.workspace).map_err(StoreError::CreateDirectory)?;
        Self::write_state(&data_file, &state)?;
        let store = Self {
            state: Arc::new(RwLock::new(state)),
            data_file: Arc::new(data_file),
            persist_guard: Arc::new(Mutex::new(())),
            cancellation_signals: Arc::new(Mutex::new(HashMap::new())),
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
            state
                .assistant_placeholder_message_ids
                .insert(assistant_message_id);
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
            superseded_artifacts: Vec::new(),
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
            review_progress: ReviewProgress::default(),
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
                state
                    .assistant_placeholder_message_ids
                    .insert(assistant_message_id);
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

    /// Resolve when manual termination seals this task (or one of its ancestors). The signal is
    /// process-local and deliberately separate from persisted status: status is the durable source
    /// of truth, while this wake-up lets an in-flight provider, tool, or external adapter be
    /// dropped immediately instead of waiting for its ordinary timeout.
    pub(crate) async fn wait_for_cancellation(&self, thread_id: Uuid) {
        let mut receiver = self.cancellation_receiver(thread_id).await;
        if *receiver.borrow() {
            return;
        }
        while receiver.changed().await.is_ok() {
            if *receiver.borrow() {
                return;
            }
        }
    }

    /// A synchronous worker can poll this receiver without entering the async runtime. This is
    /// used by host renderers so manual termination tears down the renderer itself, not merely the
    /// Tokio task waiting for its result.
    pub(crate) async fn cancellation_receiver(&self, thread_id: Uuid) -> watch::Receiver<bool> {
        let mut signals = self.cancellation_signals.lock().await;
        signals
            .entry(thread_id)
            .or_insert_with(|| watch::channel(false).0)
            .subscribe()
    }

    pub(crate) async fn clear_cancellation_lineage(&self, thread_id: Uuid) {
        let lineage = {
            let state = self.state.read().await;
            let mut lineage = descendant_ids(&state.tasks, thread_id);
            lineage.push(thread_id);
            lineage
        };
        self.cancellation_signals
            .lock()
            .await
            .retain(|task_id, _| !lineage.contains(task_id));
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
        let task_cancelled = state
            .tasks
            .iter()
            .find(|task| task.id == task_id)
            .is_some_and(|task| task.status == TaskStatus::Cancelled);
        let event = RuntimeEvent {
            id: Uuid::new_v4(),
            sequence: state.next_event_sequence,
            task_id,
            parent_task_id,
            kind,
            state: if task_cancelled {
                RuntimeEventState::Cancelled
            } else {
                state_value
            },
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
        let task_cancelled = state
            .events
            .iter()
            .find(|event| event.id == event_id)
            .and_then(|event| state.tasks.iter().find(|task| task.id == event.task_id))
            .is_some_and(|task| task.status == TaskStatus::Cancelled);
        if !task_cancelled {
            if let Some(event) = state.events.iter_mut().find(|event| event.id == event_id) {
                event.detail.push_str(delta);
                event.updated_at = Utc::now();
            }
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
        let task_cancelled = state
            .events
            .iter()
            .find(|event| event.id == event_id)
            .and_then(|event| state.tasks.iter().find(|task| task.id == event.task_id))
            .is_some_and(|task| task.status == TaskStatus::Cancelled);
        if !task_cancelled {
            if let Some(event) = state.events.iter_mut().find(|event| event.id == event_id) {
                event.detail.push_str(delta);
                event.updated_at = Utc::now();
            }
        }
    }

    pub async fn finish_event(
        &self,
        event_id: Uuid,
        event_state: RuntimeEventState,
        detail: Option<String>,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        let task_cancelled = state
            .events
            .iter()
            .find(|event| event.id == event_id)
            .and_then(|event| state.tasks.iter().find(|task| task.id == event.task_id))
            .is_some_and(|task| task.status == TaskStatus::Cancelled);
        if !task_cancelled {
            if let Some(event) = state.events.iter_mut().find(|event| event.id == event_id) {
                event.state = event_state;
                if let Some(detail) = detail {
                    event.detail = detail;
                }
                event.updated_at = Utc::now();
            }
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
        if let Some(task) = state
            .tasks
            .iter_mut()
            .find(|task| task.id == thread_id && task.status != TaskStatus::Cancelled)
        {
            task.session_messages = messages;
            task.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await
    }

    pub async fn set_session_messages_for_next_attempt(
        &self,
        thread_id: Uuid,
        messages: Vec<AgentMessage>,
    ) -> Result<(), StoreError> {
        let mut state = self.state.write().await;
        if let Some(task) = state
            .tasks
            .iter_mut()
            .find(|task| task.id == thread_id && task.status != TaskStatus::Cancelled)
        {
            task.session_messages = messages;
            task.review_progress.pending_external_outcome = None;
            task.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await
    }

    /// Persist one checker observation before any revision adapter, human handoff, or completion
    /// branch can interrupt the process. A repeated signature is counted independently of other
    /// signatures, so alternating A/B failures cannot evade no-progress detection.
    pub async fn record_review_observation(
        &self,
        thread_id: Uuid,
        artifact_revisions: BTreeMap<PathBuf, String>,
        latest_nonempty_tool_evidence: String,
        rejection_evidence_digest: Option<String>,
    ) -> Result<Option<u32>, StoreError> {
        let mut state = self.state.write().await;
        let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) else {
            return Ok(None);
        };
        if task.status == TaskStatus::Cancelled {
            return Ok(None);
        }
        task.review_progress.last_reviewed_artifact_revisions = Some(artifact_revisions);
        if !latest_nonempty_tool_evidence.is_empty() {
            task.review_progress.latest_nonempty_tool_evidence = latest_nonempty_tool_evidence;
        }
        let occurrences = if let Some(digest) = rejection_evidence_digest {
            let count = task
                .review_progress
                .rejection_evidence_occurrences
                .entry(digest)
                .or_default();
            *count = count.saturating_add(1);
            *count
        } else {
            0
        };
        task.updated_at = Utc::now();
        drop(state);
        self.persist().await?;
        Ok(Some(occurrences))
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
            .find(|task| task.id == thread_id && task.status != TaskStatus::Cancelled)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            if !text.is_empty() {
                state
                    .assistant_placeholder_message_ids
                    .remove(&assistant_id);
            }
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
            let is_placeholder = state
                .assistant_placeholder_message_ids
                .contains(&assistant_id);
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if message.state != MessageState::Complete {
                    if is_placeholder {
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
            let was_placeholder = state
                .assistant_placeholder_message_ids
                .remove(&assistant_id);
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if message.state != MessageState::Complete {
                    if was_placeholder {
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
            state
                .assistant_placeholder_message_ids
                .remove(&assistant_id);
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
            state
                .assistant_placeholder_message_ids
                .remove(&assistant_id);
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
        if let Some(task) = state
            .tasks
            .iter_mut()
            .find(|task| task.id == thread_id && task.status != TaskStatus::Cancelled)
        {
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
        self.add_artifacts_with_results(thread_id, artifacts)
            .await
            .map(|_| ())
    }

    pub(crate) async fn add_artifacts_with_results(
        &self,
        thread_id: Uuid,
        artifacts: Vec<ArtifactRecord>,
    ) -> Result<Vec<ArtifactRegistration>, StoreError> {
        self.register_artifacts(thread_id, artifacts, ArtifactRegistrationMode::Additive)
            .await
    }

    pub(crate) async fn revise_artifacts(
        &self,
        thread_id: Uuid,
        artifacts: Vec<ArtifactRecord>,
    ) -> Result<Vec<ArtifactRegistration>, StoreError> {
        self.register_artifacts(
            thread_id,
            artifacts,
            ArtifactRegistrationMode::CheckerRevision,
        )
        .await
    }

    /// Replace explicitly selected current delivery records. This is the only safe way for a
    /// create-artifact revision with a deliberately different file name/logical key to replace an
    /// earlier delivery: checker mode alone cannot distinguish that rename from a new companion.
    pub(crate) async fn supersede_artifacts(
        &self,
        thread_id: Uuid,
        supersessions: Vec<ArtifactSupersession>,
    ) -> Result<Vec<ArtifactRegistration>, StoreError> {
        let artifacts = supersessions
            .into_iter()
            .map(|supersession| {
                let mut replacement = supersession.replacement;
                replacement.supersedes = Some(supersession.superseded_artifact_id);
                replacement
            })
            .collect();
        self.register_artifacts(
            thread_id,
            artifacts,
            ArtifactRegistrationMode::ExplicitSupersession,
        )
        .await
    }

    /// Atomically register every file changed by one external harness run. All explicit
    /// supersession claims are validated against current artifact identity and live raw bytes
    /// before the first mutation, so an invalid claim cannot partially replace the delivery.
    pub(crate) async fn register_external_artifacts(
        &self,
        thread_id: Uuid,
        run_id: Uuid,
        outcome_text: String,
        mut registrations: Vec<ExternalArtifactRegistration>,
    ) -> Result<Vec<ArtifactRegistration>, StoreError> {
        let mut state = self.state.write().await;
        let mut results = Vec::new();
        let task = state
            .tasks
            .iter_mut()
            .find(|task| task.id == thread_id)
            .ok_or_else(|| {
                StoreError::InvalidExternalArtifactRegistration(format!(
                    "task {thread_id} no longer exists"
                ))
            })?;
        if task.status == TaskStatus::Cancelled {
            return Ok(results);
        }
        if task
            .review_progress
            .applied_external_run_ids
            .contains(&run_id)
        {
            return Ok(results);
        }
        {
            for registration in &mut registrations {
                let artifact = &mut registration.artifact;
                if artifact.logical_key.is_none() {
                    artifact.logical_key = Some(artifact_path_logical_key(&artifact.path));
                }
                if artifact.revision.is_empty() {
                    artifact.revision = file_revision(&artifact.path).unwrap_or_default();
                }
                if artifact.semantic_revision.is_empty() {
                    artifact.semantic_revision = semantic_file_revision(&artifact.path)
                        .unwrap_or_else(|_| artifact.revision.clone());
                }
            }

            let mut incoming_paths = HashSet::new();
            let mut claimed_targets = HashSet::new();
            for registration in &registrations {
                if !incoming_paths.insert(registration.artifact.path.clone()) {
                    return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                        "duplicate changed path: {}",
                        registration.artifact.path.display()
                    )));
                }
                let Some(target_id) = registration.superseded_artifact_id else {
                    if registration.expected_superseded_revision.is_some() {
                        return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                            "an expected target revision was supplied without a target for {}",
                            registration.artifact.path.display()
                        )));
                    }
                    continue;
                };
                if !claimed_targets.insert(target_id) {
                    return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                        "current artifact {target_id} was claimed more than once"
                    )));
                }
                let expected = registration
                    .expected_superseded_revision
                    .as_deref()
                    .filter(|revision| !revision.trim().is_empty())
                    .ok_or_else(|| {
                        StoreError::InvalidExternalArtifactRegistration(format!(
                            "replacement for current artifact {target_id} omitted expectedRawRevision"
                        ))
                    })?;
                let target = task
                    .artifacts
                    .iter()
                    .find(|artifact| artifact.id == target_id)
                    .ok_or(StoreError::MissingArtifactSupersessionTarget(target_id))?;
                let replacement_path = store_artifact_path_identity(&registration.artifact.path);
                if task.artifacts.iter().any(|artifact| {
                    store_artifact_path_identity(&artifact.path) == replacement_path
                }) {
                    return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                        "save-as replacement path already belongs to a current artifact: {}",
                        registration.artifact.path.display()
                    )));
                }
                if task.superseded_artifacts.iter().any(|artifact| {
                    store_artifact_path_identity(&artifact.path) == replacement_path
                }) {
                    return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                        "save-as replacement path belongs to superseded history: {}",
                        registration.artifact.path.display()
                    )));
                }
                let live_revision = file_revision(&target.path).unwrap_or_default();
                if live_revision != expected {
                    return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                        "current artifact {target_id} changed after the harness manifest (expected {expected}, found {live_revision})"
                    )));
                }
            }
            for registration in &registrations {
                if let Some(target_id) = registration.superseded_artifact_id {
                    let target_path = task
                        .artifacts
                        .iter()
                        .find(|artifact| artifact.id == target_id)
                        .map(|artifact| artifact.path.clone())
                        .ok_or(StoreError::MissingArtifactSupersessionTarget(target_id))?;
                    if incoming_paths.contains(&target_path) {
                        return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                            "replacement target {} was also modified in place",
                            target_path.display()
                        )));
                    }
                }
            }

            for mut registration in registrations {
                if let Some(target_id) = registration.superseded_artifact_id {
                    let target = task
                        .artifacts
                        .iter()
                        .find(|artifact| artifact.id == target_id)
                        .ok_or(StoreError::MissingArtifactSupersessionTarget(target_id))?;
                    registration.artifact.logical_key = target.logical_key.clone();
                }
                results.push(register_task_artifact(
                    task,
                    registration.artifact,
                    registration.superseded_artifact_id,
                ));
            }
            task.session_messages.push(AgentMessage {
                role: AgentRole::Assistant,
                content: outcome_text.clone(),
                tool_calls: Vec::new(),
                tool_call_id: None,
            });
            task.review_progress.pending_external_outcome = Some(PendingExternalOutcome {
                run_id,
                text: outcome_text,
            });
            task.review_progress.applied_external_run_ids.push(run_id);
            let excess = task
                .review_progress
                .applied_external_run_ids
                .len()
                .saturating_sub(MAX_APPLIED_EXTERNAL_RUN_IDS);
            if excess > 0 {
                task.review_progress
                    .applied_external_run_ids
                    .drain(..excess);
            }
            task.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await?;
        Ok(results)
    }

    pub(crate) async fn register_child_artifacts(
        &self,
        thread_id: Uuid,
        child_id: Uuid,
        mut artifacts: Vec<ArtifactRecord>,
        checker_revision: bool,
    ) -> Result<Vec<ArtifactRegistration>, StoreError> {
        for artifact in &mut artifacts {
            let key = artifact
                .logical_key
                .clone()
                .unwrap_or_else(|| artifact_path_logical_key(&artifact.path));
            artifact.logical_key = Some(format!("child:{child_id}:{key}"));
        }
        self.register_artifacts(
            thread_id,
            artifacts,
            if checker_revision {
                ArtifactRegistrationMode::CheckerRevision
            } else {
                ArtifactRegistrationMode::Additive
            },
        )
        .await
    }

    async fn register_artifacts(
        &self,
        thread_id: Uuid,
        mut artifacts: Vec<ArtifactRecord>,
        mode: ArtifactRegistrationMode,
    ) -> Result<Vec<ArtifactRegistration>, StoreError> {
        let mut state = self.state.write().await;
        let mut registrations = Vec::new();
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            if task.status == TaskStatus::Cancelled {
                return Ok(registrations);
            }
            for artifact in &mut artifacts {
                if artifact.logical_key.is_none() {
                    artifact.logical_key = Some(artifact_path_logical_key(&artifact.path));
                }
                if artifact.revision.is_empty() {
                    artifact.revision = file_revision(&artifact.path).unwrap_or_default();
                }
                if artifact.semantic_revision.is_empty() {
                    artifact.semantic_revision = semantic_file_revision(&artifact.path)
                        .unwrap_or_else(|_| artifact.revision.clone());
                }
            }

            if mode == ArtifactRegistrationMode::ExplicitSupersession {
                let mut replacement_paths = HashSet::new();
                let mut target_ids = HashSet::new();
                for artifact in &mut artifacts {
                    let target_id = artifact
                        .supersedes
                        .ok_or(StoreError::MissingArtifactSupersessionTarget(Uuid::nil()))?;
                    if !target_ids.insert(target_id) {
                        return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                            "current artifact {target_id} was claimed more than once"
                        )));
                    }
                    let Some(target) = task
                        .artifacts
                        .iter()
                        .find(|current| current.id == target_id)
                    else {
                        return Err(StoreError::MissingArtifactSupersessionTarget(target_id));
                    };
                    let replacement_path = store_artifact_path_identity(&artifact.path);
                    if !replacement_paths.insert(replacement_path.clone()) {
                        return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                            "duplicate replacement path: {}",
                            artifact.path.display()
                        )));
                    }
                    if task.artifacts.iter().any(|current| {
                        store_artifact_path_identity(&current.path) == replacement_path
                    }) {
                        return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                            "save-as replacement path already belongs to a current artifact: {}",
                            artifact.path.display()
                        )));
                    }
                    if task.superseded_artifacts.iter().any(|history| {
                        store_artifact_path_identity(&history.path) == replacement_path
                    }) {
                        return Err(StoreError::InvalidExternalArtifactRegistration(format!(
                            "save-as replacement path belongs to superseded history: {}",
                            artifact.path.display()
                        )));
                    }
                    artifact.logical_key = target.logical_key.clone();
                }
            }

            // Checker review does not make a new physical path a revision by itself. Unknown
            // paths are additive companions; replacement requires an exact current path/logical
            // slot or the explicit supersession API above.
            for artifact in artifacts {
                let explicit_supersession = (mode
                    == ArtifactRegistrationMode::ExplicitSupersession)
                    .then_some(artifact.supersedes)
                    .flatten();
                registrations.push(register_task_artifact(
                    task,
                    artifact,
                    explicit_supersession,
                ));
            }
            task.updated_at = Utc::now();
        }
        drop(state);
        self.persist().await?;
        Ok(registrations)
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
        let child_status = if parent
            .as_ref()
            .is_some_and(|task| task.status.is_terminal())
        {
            TaskStatus::Cancelled
        } else {
            TaskStatus::Understanding
        };
        state.tasks.push(TaskRecord {
            id: child_id,
            title: prompt.chars().take(64).collect(),
            prompt,
            status: child_status.clone(),
            created_at: now,
            updated_at: now,
            goal_spec: None,
            steps: vec![TaskStep {
                id: Uuid::new_v4(),
                title: localized.understand.into(),
                detail: if child_status == TaskStatus::Cancelled {
                    localized.cancelled.into()
                } else {
                    localized.generating_goal.into()
                },
                status: child_status.clone(),
                updated_at: now,
            }],
            artifacts: Vec::new(),
            superseded_artifacts: Vec::new(),
            summary: if child_status == TaskStatus::Cancelled {
                localized.cancelled.into()
            } else {
                String::new()
            },
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
            review_progress: ReviewProgress::default(),
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
        if state
            .tasks
            .iter()
            .find(|task| task.id == thread_id)
            .is_some_and(|task| task.status == TaskStatus::Cancelled)
        {
            return Ok(());
        }
        if let Some(task) = state.tasks.iter_mut().find(|task| task.id == thread_id) {
            task.status = TaskStatus::NeedsUserAction;
            task.pending_tool_call_id = Some(tool_call_id);
            task.pending_question = Some(question.clone());
            task.summary = question.clone();
            task.review_progress.pending_external_outcome = None;
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
            let was_placeholder = state
                .assistant_placeholder_message_ids
                .remove(&assistant_id);
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                message.text = merge_assistant_reply(&message.text, &question, was_placeholder);
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
            let is_placeholder = state
                .assistant_placeholder_message_ids
                .contains(&assistant_id);
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                message.text = merge_assistant_reply(&message.text, &user_message, is_placeholder);
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
        close_unanswered_tool_calls(&mut task.session_messages);
        task.session_messages.retain(|message| {
            !(message.role == AgentRole::System
                && (message.content.starts_with("【运行时恢复】")
                    || message.content.starts_with("[Runtime recovery]")))
        });
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
        let is_placeholder = state
            .assistant_placeholder_message_ids
            .contains(&assistant_id);
        if let Some(message) = state
            .messages
            .iter_mut()
            .find(|message| message.id == assistant_id)
        {
            if is_placeholder {
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
            task.title = goal.objective.chars().take(64).collect();
            task.goal_spec = Some(goal);
            task.review_progress = ReviewProgress::default();
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
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            let is_placeholder = state
                .assistant_placeholder_message_ids
                .contains(&assistant_id);
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                if is_placeholder {
                    message.text = localized.running.into();
                }
                message.state = MessageState::Thinking;
            }
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
            task.review_progress = ReviewProgress::default();
            task.pending_tool_call_id = None;
            task.pending_question = None;
            if let Some(step) = task.steps.last_mut() {
                step.status = TaskStatus::Completed;
                step.detail = localized.completed.into();
                step.updated_at = now;
            }
        }
        let assistant_id = state
            .tasks
            .iter()
            .find(|task| task.id == thread_id && task.role == TaskRole::Main)
            .map(|task| task.assistant_message_id);
        if let Some(assistant_id) = assistant_id {
            let was_placeholder = state
                .assistant_placeholder_message_ids
                .remove(&assistant_id);
            if let Some(message) = state
                .messages
                .iter_mut()
                .find(|message| message.id == assistant_id)
            {
                message.text = merge_assistant_reply(&message.text, &reply, was_placeholder);
                message.state = MessageState::Complete;
            }
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
        let Some(requested_task) = state.tasks.iter().find(|task| task.id == thread_id) else {
            return Ok(false);
        };
        if requested_task.status.is_terminal() {
            return Ok(false);
        }
        // A checker is synchronously awaited by the foreground root. Stopping it must close the
        // complete objective; otherwise the root can remain Running forever while still owning
        // `active_task_id`. An ordinary worker is different: its cancelled result is returned to
        // the parent tool loop so the main session can adapt and continue.
        let requested_role = requested_task.role.clone();
        let root_id = task_lineage_root(&state.tasks, thread_id);
        let cancellation_root = if requested_role == TaskRole::Checker {
            root_id
        } else {
            thread_id
        };
        let assistant_message_id = state
            .tasks
            .iter()
            .find(|task| task.id == cancellation_root)
            .map(|task| task.assistant_message_id)
            .unwrap_or(requested_task.assistant_message_id);
        let mut cancelled_lineage = descendant_ids(&state.tasks, cancellation_root);
        cancelled_lineage.push(cancellation_root);
        let now = Utc::now();
        terminate_lineage_preserving_content(&mut state, cancellation_root, now);
        let active_belongs_to_lineage = state.active_task_id.is_some_and(|active_id| {
            active_id == cancellation_root
                || (requested_role == TaskRole::Checker
                    && task_lineage_root(&state.tasks, active_id) == cancellation_root)
        });
        if active_belongs_to_lineage {
            state.active_task_id = None;
        }
        let was_placeholder = state
            .assistant_placeholder_message_ids
            .remove(&assistant_message_id);
        if let Some(message) = state
            .messages
            .iter_mut()
            .find(|message| message.id == assistant_message_id)
        {
            if was_placeholder || message.text.is_empty() {
                message.text = localized.cancelled.into();
            }
            message.state = MessageState::Complete;
        }
        drop(state);
        {
            let mut signals = self.cancellation_signals.lock().await;
            for task_id in cancelled_lineage {
                signals
                    .entry(task_id)
                    .or_insert_with(|| watch::channel(false).0)
                    .send_replace(true);
            }
        }
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

fn merge_assistant_reply(existing: &str, reply: &str, existing_is_placeholder: bool) -> String {
    let existing = if existing_is_placeholder {
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
            cancelled: "任务已终止，已执行内容已保留。",
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
            cancelled: "Task terminated. Work already performed was preserved.",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::artifacts::materialize_artifacts;
    use tempfile::tempdir;

    fn observed_path_artifact(
        path: PathBuf,
        title: &str,
        kind: &str,
        content: &str,
    ) -> ArtifactRecord {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, content).unwrap();
        ArtifactRecord {
            id: Uuid::new_v4(),
            title: title.into(),
            path,
            kind: kind.into(),
            size_bytes: content.len() as u64,
            modified_at: Utc::now(),
            logical_key: None,
            revision: String::new(),
            semantic_revision: String::new(),
            semantic_context: String::new(),
            supersedes: None,
            superseded_by: None,
        }
    }

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
    async fn distinct_initial_file_names_remain_current_companions() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Create two companion files".into(), Vec::new())
            .await
            .unwrap();
        let records = materialize_artifacts(
            &directory.path().join("Workspace"),
            &[
                ArtifactSpec {
                    title: "Main report".into(),
                    file_name: "report.md".into(),
                    kind: "markdown".into(),
                    content: "Main report".into(),
                    slides: Vec::new(),
                    sheets: Vec::new(),
                },
                ArtifactSpec {
                    title: "Appendix".into(),
                    file_name: "appendix.md".into(),
                    kind: "markdown".into(),
                    content: "Appendix".into(),
                    slides: Vec::new(),
                    sheets: Vec::new(),
                },
            ],
        )
        .unwrap();
        store
            .add_artifacts(receipt.thread_id, records)
            .await
            .unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts.len(), 2);
        assert!(task.superseded_artifacts.is_empty());
    }

    #[tokio::test]
    async fn checker_revision_keeps_different_explicit_create_slot_as_companion() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let state_directory = directory.path().join("State");
        let store = RuntimeStore::open(&state_directory).unwrap();
        let receipt = store
            .enqueue("Create a report, then add its appendix".into(), Vec::new())
            .await
            .unwrap();
        let report = materialize_artifacts(
            &workspace,
            &[ArtifactSpec {
                title: "Report".into(),
                file_name: "report.md".into(),
                kind: "markdown".into(),
                content: "Report body".into(),
                slides: Vec::new(),
                sheets: Vec::new(),
            }],
        )
        .unwrap();
        store
            .add_artifacts(receipt.thread_id, report)
            .await
            .unwrap();

        let appendix = materialize_artifacts(
            &workspace,
            &[ArtifactSpec {
                title: "Appendix".into(),
                file_name: "appendix.md".into(),
                kind: "markdown".into(),
                content: "Appendix body".into(),
                slides: Vec::new(),
                sheets: Vec::new(),
            }],
        )
        .unwrap();
        store
            .revise_artifacts(receipt.thread_id, appendix)
            .await
            .unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts.len(), 2);
        assert!(task
            .artifacts
            .iter()
            .any(|artifact| artifact.logical_key.as_deref() == Some("create:report.md")));
        assert!(task
            .artifacts
            .iter()
            .any(|artifact| artifact.logical_key.as_deref() == Some("create:appendix.md")));
        assert!(task.superseded_artifacts.is_empty());
    }

    #[tokio::test]
    async fn checker_revision_keeps_new_path_derived_pdf_as_companion() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Keep the report and add its source file".into(), Vec::new())
            .await
            .unwrap();
        let report = observed_path_artifact(
            workspace.join("report.pdf"),
            "Report",
            "pdf",
            "report payload",
        );
        store
            .add_artifacts(receipt.thread_id, vec![report])
            .await
            .unwrap();

        let sources = observed_path_artifact(
            workspace.join("sources.pdf"),
            "Sources",
            "pdf",
            "sources payload",
        );
        store
            .revise_artifacts(receipt.thread_id, vec![sources])
            .await
            .unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts.len(), 2);
        assert!(task
            .artifacts
            .iter()
            .any(|artifact| artifact.path.ends_with("report.pdf")));
        assert!(task
            .artifacts
            .iter()
            .any(|artifact| artifact.path.ends_with("sources.pdf")));
        assert!(task.superseded_artifacts.is_empty());
    }

    #[tokio::test]
    async fn explicit_supersession_replaces_a_renamed_create_delivery() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Revise the delivery under a new name".into(), Vec::new())
            .await
            .unwrap();
        let initial = materialize_artifacts(
            &workspace,
            &[ArtifactSpec {
                title: "Ivory".into(),
                file_name: "ivory.md".into(),
                kind: "markdown".into(),
                content: "Same body".into(),
                slides: Vec::new(),
                sheets: Vec::new(),
            }],
        )
        .unwrap();
        store
            .add_artifacts(receipt.thread_id, initial)
            .await
            .unwrap();
        let original = store.task(receipt.thread_id).await.unwrap().artifacts[0].clone();
        let replacement = materialize_artifacts(
            &workspace,
            &[ArtifactSpec {
                title: "Sand".into(),
                file_name: "sand.md".into(),
                kind: "markdown".into(),
                content: "Same body".into(),
                slides: Vec::new(),
                sheets: Vec::new(),
            }],
        )
        .unwrap()
        .remove(0);

        let registrations = store
            .supersede_artifacts(
                receipt.thread_id,
                vec![ArtifactSupersession {
                    superseded_artifact_id: original.id,
                    replacement,
                }],
            )
            .await
            .unwrap();

        assert_eq!(registrations.len(), 1);
        assert!(registrations[0].changed);
        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts.len(), 1);
        assert_eq!(task.superseded_artifacts.len(), 1);
        let current = &task.artifacts[0];
        assert!(current.path.ends_with("sand.md"));
        assert_eq!(current.logical_key, original.logical_key);
        assert_eq!(current.supersedes, Some(original.id));
        assert_eq!(task.superseded_artifacts[0].superseded_by, Some(current.id));
    }

    #[tokio::test]
    async fn explicit_supersession_cannot_overwrite_another_current_path() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Keep both current files".into(), Vec::new())
            .await
            .unwrap();
        let first =
            observed_path_artifact(workspace.join("first.md"), "First", "markdown", "first");
        let second =
            observed_path_artifact(workspace.join("second.md"), "Second", "markdown", "second");
        store
            .add_artifacts(receipt.thread_id, vec![first, second])
            .await
            .unwrap();
        let before = store.task(receipt.thread_id).await.unwrap();
        let collision = observed_path_artifact(
            workspace.join("second.md"),
            "Collision",
            "markdown",
            "attempted collision",
        );

        let error = store
            .supersede_artifacts(
                receipt.thread_id,
                vec![ArtifactSupersession {
                    superseded_artifact_id: before.artifacts[0].id,
                    replacement: collision,
                }],
            )
            .await
            .unwrap_err();

        assert!(error
            .to_string()
            .contains("already belongs to a current artifact"));
        let after = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(after.artifacts, before.artifacts);
        assert_eq!(after.superseded_artifacts, before.superseded_artifacts);
    }

    #[tokio::test]
    async fn explicit_supersession_cannot_reactivate_a_history_path() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Keep history rejected".into(), Vec::new())
            .await
            .unwrap();
        let old = observed_path_artifact(workspace.join("old.md"), "Old", "markdown", "old");
        store
            .add_artifacts(receipt.thread_id, vec![old])
            .await
            .unwrap();
        let old_id = store.task(receipt.thread_id).await.unwrap().artifacts[0].id;
        let current = observed_path_artifact(
            workspace.join("current.md"),
            "Current",
            "markdown",
            "current",
        );
        store
            .supersede_artifacts(
                receipt.thread_id,
                vec![ArtifactSupersession {
                    superseded_artifact_id: old_id,
                    replacement: current,
                }],
            )
            .await
            .unwrap();
        let before = store.task(receipt.thread_id).await.unwrap();
        let revival = observed_path_artifact(
            workspace.join("old.md"),
            "Revival",
            "markdown",
            "attempted revival",
        );

        let error = store
            .supersede_artifacts(
                receipt.thread_id,
                vec![ArtifactSupersession {
                    superseded_artifact_id: before.artifacts[0].id,
                    replacement: revival,
                }],
            )
            .await
            .unwrap_err();

        assert!(error.to_string().contains("superseded history"));
        let after = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(after.artifacts, before.artifacts);
        assert_eq!(after.superseded_artifacts, before.superseded_artifacts);
    }

    #[tokio::test]
    async fn external_commit_atomically_replaces_a_renamed_delivery_and_keeps_companions() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let state_directory = directory.path().join("State");
        let store = RuntimeStore::open(&state_directory).unwrap();
        let receipt = store
            .enqueue("Revise the deck and add sources".into(), Vec::new())
            .await
            .unwrap();
        let initial = observed_path_artifact(
            workspace.join("deck.pptx"),
            "Deck",
            "pptx",
            "initial deck bytes",
        );
        store
            .add_artifacts(receipt.thread_id, vec![initial])
            .await
            .unwrap();
        let original = store.task(receipt.thread_id).await.unwrap().artifacts[0].clone();
        let replacement = observed_path_artifact(
            workspace.join("deck-ivory.pptx"),
            "Ivory deck",
            "pptx",
            "revised ivory deck bytes",
        );
        let companion = observed_path_artifact(
            workspace.join("sources.pptx"),
            "Sources",
            "pptx",
            "source appendix bytes",
        );
        let run_id = Uuid::new_v4();
        let commit = vec![
            ExternalArtifactRegistration {
                artifact: replacement,
                superseded_artifact_id: Some(original.id),
                expected_superseded_revision: Some(original.revision.clone()),
            },
            ExternalArtifactRegistration {
                artifact: companion,
                superseded_artifact_id: None,
                expected_superseded_revision: None,
            },
        ];

        store
            .register_external_artifacts(
                receipt.thread_id,
                run_id,
                "External result".into(),
                commit.clone(),
            )
            .await
            .unwrap();

        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts.len(), 2);
        assert_eq!(task.superseded_artifacts.len(), 1);
        assert!(task
            .artifacts
            .iter()
            .any(|artifact| artifact.path.ends_with("deck-ivory.pptx")));
        assert!(task
            .artifacts
            .iter()
            .any(|artifact| artifact.path.ends_with("sources.pptx")));
        assert!(!task
            .artifacts
            .iter()
            .any(|artifact| artifact.path.ends_with("deck.pptx")));
        assert_eq!(task.superseded_artifacts[0].id, original.id);
        assert!(task
            .review_progress
            .applied_external_run_ids
            .contains(&run_id));

        let replay = store
            .register_external_artifacts(
                receipt.thread_id,
                run_id,
                "External result".into(),
                commit.clone(),
            )
            .await
            .unwrap();
        assert!(replay.is_empty());
        assert_eq!(store.task(receipt.thread_id).await.unwrap(), task);

        drop(store);
        let reopened = RuntimeStore::open(&state_directory).unwrap();
        let replay_after_restart = reopened
            .register_external_artifacts(
                receipt.thread_id,
                run_id,
                "External result".into(),
                commit,
            )
            .await
            .unwrap();
        assert!(replay_after_restart.is_empty());
        assert_eq!(reopened.task(receipt.thread_id).await.unwrap(), task);
    }

    #[tokio::test]
    async fn invalid_external_replacement_claim_leaves_the_entire_registry_unchanged() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue(
                "Reject a stale external replacement batch".into(),
                Vec::new(),
            )
            .await
            .unwrap();
        let initial = observed_path_artifact(
            workspace.join("report.md"),
            "Report",
            "markdown",
            "current report",
        );
        store
            .add_artifacts(receipt.thread_id, vec![initial])
            .await
            .unwrap();
        let before = store.task(receipt.thread_id).await.unwrap();
        let stale_replacement = observed_path_artifact(
            workspace.join("report-revised.md"),
            "Revised report",
            "markdown",
            "revised report",
        );
        let otherwise_valid_companion = observed_path_artifact(
            workspace.join("appendix.md"),
            "Appendix",
            "markdown",
            "appendix",
        );

        let error = store
            .register_external_artifacts(
                receipt.thread_id,
                Uuid::new_v4(),
                "Invalid external result".into(),
                vec![
                    ExternalArtifactRegistration {
                        artifact: stale_replacement,
                        superseded_artifact_id: Some(before.artifacts[0].id),
                        expected_superseded_revision: Some("stale-raw-revision".into()),
                    },
                    ExternalArtifactRegistration {
                        artifact: otherwise_valid_companion,
                        superseded_artifact_id: None,
                        expected_superseded_revision: None,
                    },
                ],
            )
            .await
            .unwrap_err();

        assert!(error
            .to_string()
            .contains("changed after the harness manifest"));
        let after = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(after.artifacts, before.artifacts);
        assert_eq!(after.superseded_artifacts, before.superseded_artifacts);
    }

    #[tokio::test]
    async fn external_replacement_cannot_claim_another_current_artifact_path() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Keep both current files".into(), Vec::new())
            .await
            .unwrap();
        let first =
            observed_path_artifact(workspace.join("first.md"), "First", "markdown", "first");
        let second =
            observed_path_artifact(workspace.join("second.md"), "Second", "markdown", "second");
        store
            .add_artifacts(receipt.thread_id, vec![first, second])
            .await
            .unwrap();
        let before = store.task(receipt.thread_id).await.unwrap();
        let replacement = observed_path_artifact(
            workspace.join("second.md"),
            "Collision",
            "markdown",
            "attempted collision",
        );

        let error = store
            .register_external_artifacts(
                receipt.thread_id,
                Uuid::new_v4(),
                "Invalid external result".into(),
                vec![ExternalArtifactRegistration {
                    artifact: replacement,
                    superseded_artifact_id: Some(before.artifacts[0].id),
                    expected_superseded_revision: Some(before.artifacts[0].revision.clone()),
                }],
            )
            .await
            .unwrap_err();

        assert!(error
            .to_string()
            .contains("already belongs to a current artifact"));
        let after = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(after.artifacts, before.artifacts);
        assert_eq!(after.superseded_artifacts, before.superseded_artifacts);
    }

    #[tokio::test]
    async fn external_replacement_cannot_reactivate_a_superseded_path() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue("Keep rejected history superseded".into(), Vec::new())
            .await
            .unwrap();
        let initial = observed_path_artifact(workspace.join("old.md"), "Old", "markdown", "old");
        store
            .add_artifacts(receipt.thread_id, vec![initial])
            .await
            .unwrap();
        let original = store.task(receipt.thread_id).await.unwrap().artifacts[0].clone();
        let current = observed_path_artifact(
            workspace.join("current.md"),
            "Current",
            "markdown",
            "current",
        );
        store
            .supersede_artifacts(
                receipt.thread_id,
                vec![ArtifactSupersession {
                    superseded_artifact_id: original.id,
                    replacement: current,
                }],
            )
            .await
            .unwrap();
        let before = store.task(receipt.thread_id).await.unwrap();
        let revived = observed_path_artifact(
            workspace.join("old.md"),
            "Revived old",
            "markdown",
            "attempted revival",
        );

        let error = store
            .register_external_artifacts(
                receipt.thread_id,
                Uuid::new_v4(),
                "Invalid external result".into(),
                vec![ExternalArtifactRegistration {
                    artifact: revived,
                    superseded_artifact_id: Some(before.artifacts[0].id),
                    expected_superseded_revision: Some(before.artifacts[0].revision.clone()),
                }],
            )
            .await
            .unwrap_err();

        assert!(error.to_string().contains("superseded history"));
        let after = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(after.artifacts, before.artifacts);
        assert_eq!(after.superseded_artifacts, before.superseded_artifacts);
    }

    #[tokio::test]
    async fn observing_modified_superseded_path_never_reactivates_it() {
        let directory = tempdir().unwrap();
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(directory.path().join("State")).unwrap();
        let receipt = store
            .enqueue(
                "Revise a report while retaining its history".into(),
                Vec::new(),
            )
            .await
            .unwrap();
        let initial = materialize_artifacts(
            &workspace,
            &[ArtifactSpec {
                title: "Report v1".into(),
                file_name: "report-v1.md".into(),
                kind: "markdown".into(),
                content: "Version one".into(),
                slides: Vec::new(),
                sheets: Vec::new(),
            }],
        )
        .unwrap();
        store
            .add_artifacts(receipt.thread_id, initial)
            .await
            .unwrap();
        let original = store.task(receipt.thread_id).await.unwrap().artifacts[0].clone();
        let replacement = materialize_artifacts(
            &workspace,
            &[ArtifactSpec {
                title: "Report v2".into(),
                file_name: "report-v2.md".into(),
                kind: "markdown".into(),
                content: "Version two".into(),
                slides: Vec::new(),
                sheets: Vec::new(),
            }],
        )
        .unwrap()
        .remove(0);
        store
            .supersede_artifacts(
                receipt.thread_id,
                vec![ArtifactSupersession {
                    superseded_artifact_id: original.id,
                    replacement,
                }],
            )
            .await
            .unwrap();
        let accepted = store.task(receipt.thread_id).await.unwrap().artifacts[0].clone();

        fs::write(&original.path, "Version one path was modified later").unwrap();
        let mut observed_history = original.clone();
        observed_history.id = Uuid::new_v4();
        observed_history.logical_key = None;
        observed_history.revision.clear();
        observed_history.semantic_revision.clear();
        observed_history.semantic_context.clear();
        observed_history.supersedes = None;
        observed_history.superseded_by = None;
        let registrations = store
            .add_artifacts_with_results(receipt.thread_id, vec![observed_history])
            .await
            .unwrap();

        assert_eq!(registrations.len(), 1);
        assert!(!registrations[0].changed);
        assert_eq!(registrations[0].current.id, accepted.id);
        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts, vec![accepted.clone()]);
        assert_eq!(task.superseded_artifacts.len(), 1);
        let refreshed_history = &task.superseded_artifacts[0];
        assert_eq!(refreshed_history.id, original.id);
        assert_eq!(refreshed_history.path, original.path);
        assert_eq!(
            refreshed_history.revision,
            file_revision(&original.path).unwrap()
        );
        assert_eq!(refreshed_history.superseded_by, Some(accepted.id));

        fs::write(&original.path, "Checker observed another later mutation").unwrap();
        let mut checker_observation = original.clone();
        checker_observation.id = Uuid::new_v4();
        checker_observation.logical_key = None;
        checker_observation.revision.clear();
        checker_observation.semantic_revision.clear();
        checker_observation.supersedes = None;
        checker_observation.superseded_by = None;
        let checker_registrations = store
            .revise_artifacts(receipt.thread_id, vec![checker_observation])
            .await
            .unwrap();
        assert!(!checker_registrations[0].changed);
        assert_eq!(checker_registrations[0].current.id, accepted.id);
        let task = store.task(receipt.thread_id).await.unwrap();
        assert_eq!(task.artifacts, vec![accepted]);
        assert_eq!(task.superseded_artifacts.len(), 1);
        assert_eq!(
            task.superseded_artifacts[0].revision,
            file_revision(&original.path).unwrap()
        );
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
    async fn manual_termination_preserves_all_recorded_work_and_cannot_be_overwritten() {
        let directory = tempdir().unwrap();
        let state_directory = directory.path().join("State");
        let workspace = directory.path().join("Workspace");
        let store = RuntimeStore::open(&state_directory).unwrap();
        let receipt = store
            .enqueue("Build a reviewed report".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());

        let goal = GoalSpec {
            objective: "Build a reviewed report".into(),
            kind: GoalKind::Task,
            output_mode: OutputMode::Artifact,
            reference_scope: ReferenceScope::CurrentInput,
            reference_evidence: Vec::new(),
            reference_explicit: true,
            reference_confidence: ReferenceConfidence::High,
            constraints: Vec::new(),
            boundaries: Vec::new(),
            risks: Vec::new(),
            success_criteria: vec!["Keep all work completed before termination".into()],
            open_questions: Vec::new(),
        };
        store
            .set_goal(receipt.thread_id, goal.clone())
            .await
            .unwrap();
        store
            .update_plan(
                receipt.thread_id,
                vec![
                    (
                        "Collect evidence".into(),
                        "Evidence collected".into(),
                        TaskStatus::Completed,
                    ),
                    (
                        "Write report".into(),
                        "Drafted three sections".into(),
                        TaskStatus::Running,
                    ),
                ],
            )
            .await
            .unwrap();
        store
            .begin_assistant_visible_turn(receipt.thread_id)
            .await
            .unwrap();
        let visible_work = "已完成资料整理。\n\n报告前三节已经写入工作区。";
        store
            .append_assistant_delta(receipt.thread_id, visible_work)
            .await
            .unwrap();
        let preserved_session = vec![AgentMessage {
            role: AgentRole::Assistant,
            content: "Preserved model transcript".into(),
            tool_calls: Vec::new(),
            tool_call_id: None,
        }];
        store
            .set_session_messages(receipt.thread_id, preserved_session.clone())
            .await
            .unwrap();

        let artifact = observed_path_artifact(
            workspace.join("report.md"),
            "Report",
            "markdown",
            "# Preserved report\n\nThree completed sections.",
        );
        store
            .add_artifacts(receipt.thread_id, vec![artifact])
            .await
            .unwrap();
        let completed_event = store
            .append_event(
                receipt.thread_id,
                RuntimeEventKind::Tool,
                RuntimeEventState::Completed,
                "LingShu",
                "Collected evidence",
                "Three sources were recorded.",
            )
            .await
            .unwrap();
        let running_event = store
            .append_event(
                receipt.thread_id,
                RuntimeEventKind::Model,
                RuntimeEventState::Running,
                "LingShu",
                "Writing report",
                "Drafted three sections.",
            )
            .await
            .unwrap();
        let child_id = store
            .create_child_task(
                receipt.thread_id,
                "Check citations".into(),
                TaskRole::Checker,
                "Checker".into(),
                TaskOrigin::Verification,
                LoopEngineKind::Grok,
            )
            .await
            .unwrap();
        let child_event = store
            .append_event(
                child_id,
                RuntimeEventKind::HumanInteraction,
                RuntimeEventState::Blocked,
                "Checker",
                "Waiting for one citation",
                "The existing citation analysis must be preserved.",
            )
            .await
            .unwrap();
        {
            let mut state = store.state.write().await;
            let root = state
                .tasks
                .iter_mut()
                .find(|task| task.id == receipt.thread_id)
                .unwrap();
            root.summary = "Three report sections are complete.".into();
            root.error = Some("One citation remains unresolved.".into());
            root.pending_tool_call_id = Some("pending-before-termination".into());
            root.pending_question = Some("Provide the final citation".into());
            let child = state
                .tasks
                .iter_mut()
                .find(|task| task.id == child_id)
                .unwrap();
            child.summary = "Citation checker preserved summary".into();
            child.error = Some("Citation source unavailable".into());
            child.steps[0].detail = "Checked all available citations".into();
        }
        store.flush().await.unwrap();

        let before = store.task(receipt.thread_id).await.unwrap();
        let child_before = store.task(child_id).await.unwrap();
        assert!(store.cancel(receipt.thread_id).await.unwrap());

        let terminated = store.task(receipt.thread_id).await.unwrap();
        let terminated_child = store.task(child_id).await.unwrap();
        assert_eq!(terminated.status, TaskStatus::Cancelled);
        assert_eq!(terminated.summary, before.summary);
        assert_eq!(terminated.error, before.error);
        assert_eq!(terminated.session_messages, preserved_session);
        assert_eq!(terminated.artifacts, before.artifacts);
        assert_eq!(terminated.superseded_artifacts, before.superseded_artifacts);
        assert_eq!(terminated.steps[0].status, TaskStatus::Completed);
        assert_eq!(terminated.steps[0].detail, "Evidence collected");
        assert_eq!(terminated.steps[1].status, TaskStatus::Cancelled);
        assert_eq!(terminated.steps[1].detail, "Drafted three sections");
        assert!(terminated.pending_tool_call_id.is_none());
        assert!(terminated.pending_question.is_none());
        assert_eq!(terminated_child.status, TaskStatus::Cancelled);
        assert_eq!(terminated_child.summary, child_before.summary);
        assert_eq!(terminated_child.error, child_before.error);
        assert_eq!(
            terminated_child.steps[0].detail,
            "Checked all available citations"
        );

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
        let assistant = snapshot
            .messages
            .iter()
            .find(|message| message.id == receipt.assistant_message_id)
            .unwrap();
        assert_eq!(assistant.text, visible_work);
        assert_eq!(assistant.state, MessageState::Complete);
        assert!(snapshot.active_task_id.is_none());
        assert_eq!(
            snapshot
                .events
                .iter()
                .find(|event| event.id == completed_event.id)
                .unwrap()
                .state,
            RuntimeEventState::Completed
        );
        for event_id in [running_event.id, child_event.id] {
            let event = snapshot
                .events
                .iter()
                .find(|event| event.id == event_id)
                .unwrap();
            assert_eq!(event.state, RuntimeEventState::Cancelled);
        }

        // Results returning after the Stop click must not reopen or rewrite the sealed task.
        store.set_goal(receipt.thread_id, goal).await.unwrap();
        store
            .set_needs_user_action(
                receipt.thread_id,
                "late-question".into(),
                "This must not appear".into(),
            )
            .await
            .unwrap();
        store
            .set_assistant_text(
                receipt.thread_id,
                "Late model output".into(),
                MessageState::Thinking,
            )
            .await
            .unwrap();
        store
            .update_plan(
                receipt.thread_id,
                vec![(
                    "Late plan".into(),
                    "Must not replace the preserved plan".into(),
                    TaskStatus::Running,
                )],
            )
            .await
            .unwrap();
        store
            .set_session_messages(
                receipt.thread_id,
                vec![AgentMessage {
                    role: AgentRole::Assistant,
                    content: "Late transcript".into(),
                    tool_calls: Vec::new(),
                    tool_call_id: None,
                }],
            )
            .await
            .unwrap();
        store
            .append_event_detail(running_event.id, " Late event detail")
            .await
            .unwrap();
        store
            .finish_event(
                running_event.id,
                RuntimeEventState::Completed,
                Some("Late replacement detail".into()),
            )
            .await
            .unwrap();
        store
            .complete(receipt.thread_id, "Late completion".into(), Vec::new())
            .await
            .unwrap();
        let late_artifact = observed_path_artifact(
            workspace.join("late-report.md"),
            "Late report",
            "markdown",
            "This file may exist, but it must not reopen the terminated task.",
        );
        store
            .add_artifacts(receipt.thread_id, vec![late_artifact])
            .await
            .unwrap();
        let late_external_run_id = Uuid::new_v4();
        let late_external_artifact = observed_path_artifact(
            workspace.join("late-external.md"),
            "Late external report",
            "markdown",
            "This external result returned after termination.",
        );
        assert!(store
            .register_external_artifacts(
                receipt.thread_id,
                late_external_run_id,
                "Late external outcome".into(),
                vec![ExternalArtifactRegistration {
                    artifact: late_external_artifact,
                    superseded_artifact_id: None,
                    expected_superseded_revision: None,
                }],
            )
            .await
            .unwrap()
            .is_empty());
        let late_child_id = store
            .create_child_task(
                receipt.thread_id,
                "Late child".into(),
                TaskRole::Worker,
                "Worker".into(),
                TaskOrigin::Subtask,
                LoopEngineKind::Grok,
            )
            .await
            .unwrap();
        assert_eq!(
            store.task(late_child_id).await.unwrap().status,
            TaskStatus::Cancelled
        );

        let reopened = RuntimeStore::open(&state_directory).unwrap();
        let persisted = reopened.task(receipt.thread_id).await.unwrap();
        assert_eq!(persisted.status, TaskStatus::Cancelled);
        assert_eq!(persisted.summary, before.summary);
        assert_eq!(persisted.error, before.error);
        assert_eq!(persisted.steps, terminated.steps);
        assert_eq!(persisted.session_messages, preserved_session);
        assert_eq!(persisted.artifacts, before.artifacts);
        assert!(persisted.review_progress.pending_external_outcome.is_none());
        assert!(!persisted
            .review_progress
            .applied_external_run_ids
            .contains(&late_external_run_id));
        let persisted_snapshot = reopened
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
        let persisted_assistant = persisted_snapshot
            .messages
            .iter()
            .find(|message| message.id == receipt.assistant_message_id)
            .unwrap();
        assert_eq!(persisted_assistant.text, visible_work);
        let persisted_running_event = persisted_snapshot
            .events
            .iter()
            .find(|event| event.id == running_event.id)
            .unwrap();
        assert_eq!(persisted_running_event.state, RuntimeEventState::Cancelled);
        assert_eq!(persisted_running_event.detail, "Drafted three sections.");
    }

    #[tokio::test]
    async fn manual_termination_replaces_only_a_transient_placeholder() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Stop before visible output".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());
        drop(store);
        let store = RuntimeStore::open(directory.path()).unwrap();

        assert!(store.cancel(receipt.thread_id).await.unwrap());
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
        let assistant = snapshot
            .messages
            .iter()
            .find(|message| message.id == receipt.assistant_message_id)
            .unwrap();
        assert_eq!(assistant.text, "任务已终止，已执行内容已保留。");
        assert_eq!(assistant.state, MessageState::Complete);
        assert_eq!(
            store.task(receipt.thread_id).await.unwrap().status,
            TaskStatus::Cancelled
        );
    }

    #[tokio::test]
    async fn manual_termination_preserves_model_text_that_matches_placeholder_copy() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Return a literal progress word".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());

        store
            .begin_assistant_visible_turn(receipt.thread_id)
            .await
            .unwrap();
        store
            .append_assistant_delta(receipt.thread_id, "Thinking…")
            .await
            .unwrap();
        // Later runtime phases may request another progress placeholder. Provenance, rather than
        // string equality, must keep the already streamed model text intact.
        store
            .set_assistant_placeholder_if_empty(receipt.thread_id, "Running…".into())
            .await
            .unwrap();

        assert!(store.cancel(receipt.thread_id).await.unwrap());
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
        let assistant = snapshot
            .messages
            .iter()
            .find(|message| message.id == receipt.assistant_message_id)
            .unwrap();
        assert_eq!(assistant.text, "Thinking…");
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
    async fn repeated_technical_recovery_keeps_only_the_latest_runtime_marker() {
        let directory = tempdir().unwrap();
        let store = RuntimeStore::open(directory.path()).unwrap();
        let receipt = store
            .enqueue("Build a report".into(), Vec::new())
            .await
            .unwrap();
        assert!(store.claim(receipt.thread_id).await.unwrap());
        store
            .set_session_messages(
                receipt.thread_id,
                vec![AgentMessage {
                    role: AgentRole::Assistant,
                    content: "Preserved work".into(),
                    tool_calls: vec![AgentToolCall {
                        id: "interrupted-before-recovery".into(),
                        name: "run_command".into(),
                        arguments_json: "{\"command\":\"probe\"}".into(),
                    }],
                    tool_call_id: None,
                }],
            )
            .await
            .unwrap();

        store
            .require_recovery(
                receipt.thread_id,
                "First recovery".into(),
                "first error".into(),
            )
            .await
            .unwrap();
        let first = store
            .prepare_continue(receipt.thread_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            first
                .session_messages
                .iter()
                .filter(|message| {
                    message.content.starts_with("[Runtime recovery]")
                        || message.content.starts_with("【运行时恢复】")
                })
                .count(),
            1
        );
        let interrupted_result_index = first
            .session_messages
            .iter()
            .position(|message| {
                message.role == AgentRole::Tool
                    && message.tool_call_id.as_deref() == Some("interrupted-before-recovery")
            })
            .unwrap();
        let recovery_marker_index = first
            .session_messages
            .iter()
            .position(|message| {
                message.content.starts_with("[Runtime recovery]")
                    || message.content.starts_with("【运行时恢复】")
            })
            .unwrap();
        assert!(interrupted_result_index < recovery_marker_index);

        store
            .require_recovery(
                receipt.thread_id,
                "Second recovery".into(),
                "second error".into(),
            )
            .await
            .unwrap();
        let second = store
            .prepare_continue(receipt.thread_id)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(
            second
                .session_messages
                .iter()
                .filter(|message| {
                    message.content.starts_with("[Runtime recovery]")
                        || message.content.starts_with("【运行时恢复】")
                })
                .count(),
            1
        );
        assert!(second
            .session_messages
            .iter()
            .any(|message| message.content == "Preserved work"));
        assert!(second
            .session_messages
            .iter()
            .any(|message| message.content.contains("second error")));
    }

    #[tokio::test]
    async fn review_progress_survives_recovery_and_restart_then_clears_at_goal_boundaries() {
        let directory = tempdir().unwrap();
        let state_directory = directory.path().join("State");
        let thread_id;
        let baseline = BTreeMap::from([(
            directory.path().join("Workspace/report.md"),
            "raw-revision-1".to_string(),
        )]);
        let goal = GoalSpec {
            objective: "Create a reviewed report".into(),
            kind: GoalKind::Task,
            output_mode: OutputMode::Artifact,
            reference_scope: ReferenceScope::CurrentInput,
            reference_evidence: Vec::new(),
            reference_explicit: true,
            reference_confidence: ReferenceConfidence::High,
            constraints: Vec::new(),
            boundaries: Vec::new(),
            risks: Vec::new(),
            success_criteria: vec!["The report passes review".into()],
            open_questions: Vec::new(),
        };

        {
            let store = RuntimeStore::open(&state_directory).unwrap();
            let receipt = store
                .enqueue("Create a reviewed report".into(), Vec::new())
                .await
                .unwrap();
            thread_id = receipt.thread_id;
            assert!(store.claim(thread_id).await.unwrap());
            store.set_goal(thread_id, goal.clone()).await.unwrap();
            assert_eq!(
                store
                    .record_review_observation(
                        thread_id,
                        baseline.clone(),
                        "canonical-create-evidence".into(),
                        Some("evidence-digest-a".into()),
                    )
                    .await
                    .unwrap(),
                Some(1)
            );
            store
                .require_recovery(
                    thread_id,
                    "Recover the same review".into(),
                    "adapter interrupted".into(),
                )
                .await
                .unwrap();
            let task = store.task(thread_id).await.unwrap();
            assert_eq!(
                task.review_progress.last_reviewed_artifact_revisions,
                Some(baseline.clone())
            );
        }

        let reopened = RuntimeStore::open(&state_directory).unwrap();
        let recovered = reopened.task(thread_id).await.unwrap();
        assert_eq!(recovered.status, TaskStatus::NeedsRecovery);
        assert_eq!(
            recovered.review_progress.last_reviewed_artifact_revisions,
            Some(baseline.clone())
        );
        assert_eq!(
            recovered
                .review_progress
                .rejection_evidence_occurrences
                .get("evidence-digest-a"),
            Some(&1)
        );
        assert_eq!(
            recovered.review_progress.latest_nonempty_tool_evidence,
            "canonical-create-evidence"
        );
        let continued = reopened.prepare_continue(thread_id).await.unwrap().unwrap();
        assert_eq!(continued.review_progress, recovered.review_progress);
        assert_eq!(
            reopened
                .record_review_observation(
                    thread_id,
                    baseline,
                    String::new(),
                    Some("evidence-digest-a".into()),
                )
                .await
                .unwrap(),
            Some(2)
        );

        reopened.set_goal(thread_id, goal.clone()).await.unwrap();
        assert_eq!(
            reopened.task(thread_id).await.unwrap().review_progress,
            ReviewProgress::default()
        );
        reopened
            .record_review_observation(
                thread_id,
                BTreeMap::new(),
                "new-goal-evidence".into(),
                Some("new-goal-digest".into()),
            )
            .await
            .unwrap();
        reopened
            .complete(thread_id, "Accepted".into(), Vec::new())
            .await
            .unwrap();
        assert_eq!(
            reopened.task(thread_id).await.unwrap().review_progress,
            ReviewProgress::default()
        );
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
