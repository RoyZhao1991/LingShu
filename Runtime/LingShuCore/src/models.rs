use crate::contract::PlatformCapabilities;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum AppLocale {
    #[default]
    ZhCn,
    En,
}

impl AppLocale {
    pub fn language_directive(self) -> &'static str {
        match self {
            Self::ZhCn => "最高优先级：全程使用简体中文与用户沟通，代码、路径和专有名词除外。",
            Self::En => "Highest priority: communicate with the user in English throughout, except for code, paths, and proper nouns.",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ProviderProtocol {
    OpenaiResponses,
    OpenaiChatCompletions,
    AnthropicMessages,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum ExecutionPermissionMode {
    #[default]
    Sandbox,
    FullAccess,
}

impl ExecutionPermissionMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Sandbox => "sandbox",
            Self::FullAccess => "full_access",
        }
    }

    pub fn prompt_directive(self, locale: AppLocale) -> &'static str {
        match (self, locale) {
            (Self::Sandbox, AppLocale::ZhCn) => {
                "当前执行权限：sandbox。工作目录外写入和联网操作尚未获授权；确有必要时使用 ask_user 明确说明所需权限，不得把它误报为平台永久不支持。"
            }
            (Self::Sandbox, AppLocale::En) => {
                "Execution permission: sandbox. Network access and writes outside the Workspace are not authorized. If genuinely required, use ask_user to request the exact permission; never misreport this as a permanent platform limitation."
            }
            (Self::FullAccess, AppLocale::ZhCn) => {
                "当前执行权限：full_access。用户已预先授权本会话使用本地命令、联网、安装依赖和访问工作目录外路径；不得仅因这些操作再次索要权限，也不得声称沙箱阻止了网络。登录、凭据、付款、物理操作和操作系统隐私授权仍需用户参与。"
            }
            (Self::FullAccess, AppLocale::En) => {
                "Execution permission: full_access. The user has pre-authorized local commands, network access, dependency installation, and paths outside the Workspace for this session. Do not ask again solely for those operations or claim that a sandbox blocks networking. Login, credentials, payment, physical actions, and OS privacy grants still require the user."
            }
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeSettings {
    pub locale: AppLocale,
    pub provider_id: String,
    pub provider_name: String,
    pub protocol: ProviderProtocol,
    pub endpoint: String,
    pub model: String,
    pub workspace: PathBuf,
    #[serde(default)]
    pub execution_permission_mode: ExecutionPermissionMode,
    pub first_run_complete: bool,
}

impl Default for RuntimeSettings {
    fn default() -> Self {
        let workspace = dirs::document_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("LingShu Workspace");
        Self {
            locale: AppLocale::ZhCn,
            provider_id: "deepseek".into(),
            provider_name: "DeepSeek".into(),
            protocol: ProviderProtocol::OpenaiChatCompletions,
            endpoint: "https://api.deepseek.com".into(),
            model: "deepseek-chat".into(),
            workspace,
            execution_permission_mode: ExecutionPermissionMode::Sandbox,
            first_run_complete: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MessageRole {
    User,
    Assistant,
    System,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MessageState {
    Complete,
    Thinking,
    Failed,
    NeedsUserAction,
}

/// Persisted conversation state used by the shared agent loop. This mirrors the
/// frozen `LingShuAgentSessioning` message contract used by the macOS shell so a
/// blocked run can be resumed by any desktop shell without rebuilding context.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AgentRole {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentToolCall {
    pub id: String,
    pub name: String,
    pub arguments_json: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentMessage {
    pub role: AgentRole,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub tool_calls: Vec<AgentToolCall>,
    pub tool_call_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ChatMessage {
    pub id: Uuid,
    pub role: MessageRole,
    pub text: String,
    pub created_at: DateTime<Utc>,
    pub state: MessageState,
    pub thread_id: Option<Uuid>,
    #[serde(default)]
    pub attachment_paths: Vec<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GoalKind {
    Task,
    Interaction,
    Question,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum OutputMode {
    ChatReply,
    Artifact,
    VisibleInteraction,
    ExternalAction,
    Unspecified,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReferenceScope {
    CurrentInput,
    DefaultAnchor,
    CandidateBackground,
    VisibleContext,
    TaskThread,
    Memory,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReferenceConfidence {
    High,
    Medium,
    Low,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct GoalSpec {
    pub objective: String,
    pub kind: GoalKind,
    #[serde(rename = "output_mode")]
    pub output_mode: OutputMode,
    #[serde(rename = "reference_scope")]
    pub reference_scope: ReferenceScope,
    #[serde(rename = "reference_evidence", default)]
    pub reference_evidence: Vec<String>,
    #[serde(rename = "reference_explicit", default)]
    pub reference_explicit: bool,
    #[serde(rename = "reference_confidence")]
    pub reference_confidence: ReferenceConfidence,
    #[serde(default)]
    pub constraints: Vec<String>,
    #[serde(default)]
    pub boundaries: Vec<String>,
    #[serde(default)]
    pub risks: Vec<String>,
    #[serde(rename = "success_criteria", default)]
    pub success_criteria: Vec<String>,
    #[serde(rename = "open_questions", default)]
    pub open_questions: Vec<String>,
}

impl GoalSpec {
    pub fn is_ready(&self) -> bool {
        !self.objective.trim().is_empty()
            && self.kind != GoalKind::Unknown
            && self.output_mode != OutputMode::Unspecified
            && self.reference_scope != ReferenceScope::Unknown
            && self.reference_confidence != ReferenceConfidence::Unknown
            && (!(matches!(self.kind, GoalKind::Task | GoalKind::Interaction))
                || !self.success_criteria.is_empty())
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Queued,
    Understanding,
    Running,
    NeedsUserAction,
    Completed,
    Failed,
    Cancelled,
}

impl TaskStatus {
    pub fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum TaskRole {
    #[default]
    Main,
    Worker,
    Checker,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum TaskOrigin {
    #[default]
    Conversation,
    Subtask,
    Verification,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeEventKind {
    Status,
    Model,
    Reasoning,
    Tool,
    Plan,
    Delegation,
    HumanInteraction,
    Warning,
    Result,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeEventState {
    Running,
    Completed,
    Failed,
    Blocked,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeEvent {
    pub id: Uuid,
    pub sequence: u64,
    pub task_id: Uuid,
    pub parent_task_id: Option<Uuid>,
    pub kind: RuntimeEventKind,
    pub state: RuntimeEventState,
    pub actor: String,
    pub title: String,
    pub detail: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TaskStep {
    pub id: Uuid,
    pub title: String,
    pub detail: String,
    pub status: TaskStatus,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactRecord {
    pub id: Uuid,
    pub title: String,
    pub path: PathBuf,
    pub kind: String,
    pub size_bytes: u64,
    pub modified_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TaskRecord {
    pub id: Uuid,
    pub title: String,
    pub prompt: String,
    pub status: TaskStatus,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub goal_spec: Option<GoalSpec>,
    pub steps: Vec<TaskStep>,
    pub artifacts: Vec<ArtifactRecord>,
    pub summary: String,
    pub error: Option<String>,
    pub assistant_message_id: Uuid,
    #[serde(default)]
    pub attachment_paths: Vec<PathBuf>,
    #[serde(default)]
    pub parent_task_id: Option<Uuid>,
    #[serde(default)]
    pub root_task_id: Option<Uuid>,
    #[serde(default)]
    pub role: TaskRole,
    #[serde(default)]
    pub origin: TaskOrigin,
    #[serde(default = "default_participant_name")]
    pub participant_name: String,
    #[serde(default)]
    pub depth: u8,
    #[serde(default)]
    pub session_messages: Vec<AgentMessage>,
    #[serde(default)]
    pub pending_tool_call_id: Option<String>,
    #[serde(default)]
    pub pending_question: Option<String>,
}

fn default_participant_name() -> String {
    "LingShu".into()
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeSnapshot {
    pub kernel_abi_version: String,
    pub settings: RuntimeSettings,
    pub platform: String,
    pub capabilities: PlatformCapabilities,
    pub messages: Vec<ChatMessage>,
    pub tasks: Vec<TaskRecord>,
    pub active_task_id: Option<Uuid>,
    pub queued_task_count: usize,
    pub provider_configured: bool,
    #[serde(default)]
    pub events: Vec<RuntimeEvent>,
    #[serde(default)]
    pub latest_event_sequence: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SubmitReceipt {
    pub thread_id: Uuid,
    pub user_message_id: Uuid,
    pub assistant_message_id: Uuid,
    pub queued: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ArtifactSpec {
    pub title: String,
    pub file_name: String,
    pub kind: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub slides: Vec<SlideSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SlideSpec {
    pub title: String,
    #[serde(default)]
    pub bullets: Vec<String>,
    #[serde(default)]
    pub notes: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TaskCompletion {
    pub reply: String,
    #[serde(default)]
    pub artifacts: Vec<ArtifactSpec>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_settings_without_permission_mode_default_to_sandbox() {
        let settings: RuntimeSettings = serde_json::from_value(serde_json::json!({
            "locale": "en",
            "providerId": "legacy-provider",
            "providerName": "Legacy Provider",
            "protocol": "openai_chat_completions",
            "endpoint": "https://example.invalid/v1",
            "model": "legacy-model",
            "workspace": "/tmp/lingshu-legacy",
            "firstRunComplete": true
        }))
        .expect("legacy settings should remain readable");

        assert_eq!(
            settings.execution_permission_mode,
            ExecutionPermissionMode::Sandbox
        );
    }
}
