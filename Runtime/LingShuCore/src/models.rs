use crate::contract::PlatformCapabilities;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
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

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum LoopEngineKind {
    #[default]
    #[serde(alias = "native", alias = "embeddedGrok", alias = "embedded_grok")]
    Grok,
    Codex,
}

impl LoopEngineKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Grok => "grok",
            Self::Codex => "codex",
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
    #[serde(
        default,
        alias = "workerLoopEngine",
        alias = "worker_loop_engine",
        alias = "engine"
    )]
    pub loop_engine: LoopEngineKind,
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
            loop_engine: LoopEngineKind::Grok,
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
    NeedsRecovery,
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
    NeedsRecovery,
    NeedsUserAction,
    Completed,
    Failed,
    Cancelled,
}

impl TaskStatus {
    pub fn is_terminal(&self) -> bool {
        // `Failed` is kept only so older persisted state can still be decoded. A goal is never
        // terminal merely because one model/tool attempt failed: the store migrates that legacy
        // state to a recoverable state on open. Only an accepted completion or an explicit
        // cancellation closes the objective.
        matches!(self, Self::Completed | Self::Cancelled)
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
    /// Stable semantic delivery slot. Physical paths may change because artifact materialization
    /// preserves earlier files with a numeric suffix.
    #[serde(default)]
    pub logical_key: Option<String>,
    /// Content SHA-256 captured when this record was registered.
    #[serde(default)]
    pub revision: String,
    /// Stable content/structure fingerprint that excludes container timestamps and other
    /// packaging noise.
    #[serde(default)]
    pub semantic_revision: String,
    /// Canonical creation evidence not always recoverable from a file alone (for example a
    /// DesignKB engine or requested theme).
    #[serde(default)]
    pub semantic_context: String,
    #[serde(default)]
    pub supersedes: Option<Uuid>,
    #[serde(default)]
    pub superseded_by: Option<Uuid>,
}

/// Durable host evidence for an artifact review cycle. This is deliberately independent from
/// the model transcript: adapter failures and process restarts may compact or repair that
/// transcript, but they must not make an already-reviewed delivery look new or forget a repeated
/// rejection.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PendingExternalOutcome {
    pub run_id: Uuid,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct ReviewProgress {
    /// `None` means no checker has reviewed this goal yet. `Some(empty)` means a checker reviewed
    /// a delivery with no registered files, so the two states must remain distinguishable.
    #[serde(default)]
    pub last_reviewed_artifact_revisions: Option<BTreeMap<PathBuf, String>>,
    /// Counts are keyed by a fixed-size digest of canonical checker finding, semantic delivery,
    /// and canonical create/register evidence. Each evidence state accumulates independently.
    #[serde(default)]
    pub rejection_evidence_occurrences: BTreeMap<String, u32>,
    /// Review compaction can discard completed tool protocol groups. Preserve their canonical
    /// artifact evidence so the same delivery has the same signature after recovery.
    #[serde(default)]
    pub latest_nonempty_tool_evidence: String,
    /// Recently committed managed external-run receipts. The Store records a receipt in the same
    /// transaction as its artifact mutations so a crash before filesystem acknowledgement can be
    /// replayed exactly once.
    #[serde(default)]
    pub applied_external_run_ids: Vec<Uuid>,
    /// External artifacts, their run id, and this final text were committed atomically. Until a
    /// checker correction, human gate, or completion is durably persisted, recovery must consume
    /// this outcome instead of launching the maker again.
    #[serde(default)]
    pub pending_external_outcome: Option<PendingExternalOutcome>,
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
    /// The current delivery only. Superseded or duplicate attempts live in
    /// `superseded_artifacts`, keeping existing clients and checkers on the active version.
    pub artifacts: Vec<ArtifactRecord>,
    #[serde(default)]
    pub superseded_artifacts: Vec<ArtifactRecord>,
    pub summary: String,
    pub error: Option<String>,
    #[serde(default)]
    pub user_message_id: Option<Uuid>,
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
    pub loop_engine: LoopEngineKind,
    #[serde(default)]
    pub session_messages: Vec<AgentMessage>,
    #[serde(default)]
    pub pending_tool_call_id: Option<String>,
    #[serde(default)]
    pub pending_question: Option<String>,
    #[serde(default)]
    pub review_progress: ReviewProgress,
}

fn default_participant_name() -> String {
    "LingShu".into()
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RuntimeFailureKind {
    Authentication,
    Quota,
    RateLimited,
    Network,
    Timeout,
    InvalidRequest,
    InvalidResponse,
    Server,
    Unknown,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QueueFailure {
    pub thread_id: Uuid,
    pub kind: RuntimeFailureKind,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct QueueRunReport {
    pub completed: usize,
    pub failures: Vec<QueueFailure>,
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
    #[serde(default)]
    pub plugins: Vec<PluginRecord>,
    #[serde(default)]
    pub memory: MemorySnapshot,
    #[serde(default)]
    pub loop_engines: Vec<LoopEngineRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LoopEngineRecord {
    pub id: LoopEngineKind,
    pub name: String,
    pub description: String,
    pub description_zh: String,
    #[serde(default)]
    pub adapter_builtin: bool,
    pub available: bool,
    pub selected: bool,
    pub execution_mode: String,
    pub executable: Option<PathBuf>,
    pub status_detail: String,
    #[serde(default = "default_true")]
    pub harness_only: bool,
    #[serde(default = "default_loop_transport_owner")]
    pub transport_owner: String,
    #[serde(default = "default_true")]
    pub native_auth_disabled: bool,
    #[serde(default = "default_true")]
    pub native_quota_disabled: bool,
}

fn default_true() -> bool {
    true
}

fn default_loop_transport_owner() -> String {
    "lingshu".into()
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum MemoryKind {
    #[default]
    Conversation,
    Task,
    Fact,
    Preference,
    Experience,
    Artifact,
    Knowledge,
}

impl MemoryKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Conversation => "conversation",
            Self::Task => "task",
            Self::Fact => "fact",
            Self::Preference => "preference",
            Self::Experience => "experience",
            Self::Artifact => "artifact",
            Self::Knowledge => "knowledge",
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum MemoryTier {
    #[default]
    Hot,
    Cold,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "snake_case")]
pub enum MemorySource {
    #[default]
    Runtime,
    UserExplicit,
    Task,
    LegacySwift,
    Platform,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryEntry {
    pub id: String,
    pub kind: MemoryKind,
    pub tier: MemoryTier,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub last_prompt: String,
    #[serde(default)]
    pub tags: Vec<String>,
    pub source: MemorySource,
    pub importance: f64,
    pub confidence: f64,
    #[serde(default)]
    pub sensitive: bool,
    #[serde(default)]
    pub message_count: u32,
    pub task_id: Option<String>,
    pub execution_record_id: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub archived_at: Option<DateTime<Utc>>,
    pub compressed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub access_count: u32,
    pub last_accessed_at: Option<DateTime<Utc>>,
    pub fingerprint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryHit {
    pub entry: MemoryEntry,
    pub score: f64,
    pub matched_by: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemoryRecall {
    pub query: String,
    #[serde(default)]
    pub hits: Vec<MemoryHit>,
    #[serde(default)]
    pub context: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemorySnapshot {
    pub schema_version: u32,
    pub total_count: usize,
    pub hot_count: usize,
    pub cold_count: usize,
    #[serde(default)]
    pub counts_by_kind: std::collections::BTreeMap<String, usize>,
    pub latest_updated_at: Option<DateTime<Utc>>,
    pub last_consolidated_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub imported_sources: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryImportEntry {
    pub id: String,
    #[serde(default)]
    pub kind: MemoryKind,
    #[serde(default)]
    pub tier: MemoryTier,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub last_prompt: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub source: MemorySource,
    #[serde(default = "default_memory_importance")]
    pub importance: f64,
    #[serde(default = "default_memory_confidence")]
    pub confidence: f64,
    #[serde(default)]
    pub sensitive: bool,
    #[serde(default)]
    pub message_count: u32,
    pub task_id: Option<String>,
    pub execution_record_id: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
    pub updated_at: Option<DateTime<Utc>>,
    pub archived_at: Option<DateTime<Utc>>,
    pub compressed_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub aliases: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemoryImportPayload {
    pub source: String,
    pub source_version: String,
    #[serde(default)]
    pub entries: Vec<MemoryImportEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct MemoryImportResult {
    pub imported: usize,
    pub updated: usize,
    pub skipped: usize,
    pub snapshot: MemorySnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct MemoryWriteRequest {
    #[serde(default)]
    pub kind: MemoryKind,
    pub title: String,
    pub content: String,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default = "default_memory_importance")]
    pub importance: f64,
    #[serde(default = "default_memory_confidence")]
    pub confidence: f64,
    #[serde(default)]
    pub sensitive: bool,
}

fn default_memory_importance() -> f64 {
    0.5
}

fn default_memory_confidence() -> f64 {
    0.7
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub struct PluginPermissions {
    #[serde(default)]
    pub file_read: bool,
    #[serde(default)]
    pub file_write: bool,
    #[serde(default)]
    pub network: bool,
    #[serde(default)]
    pub shell: bool,
    #[serde(default)]
    pub system_sensitive: bool,
}

impl PluginPermissions {
    pub fn requires_full_access(&self) -> bool {
        self.network || self.shell || self.system_sensitive
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PluginToolRecord {
    pub name: String,
    pub exposed_name: String,
    pub description: String,
    #[serde(default)]
    pub description_zh: String,
    #[serde(default)]
    pub parameters: Value,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub fallback: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum PluginSource {
    BuiltIn,
    User,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PluginRecord {
    pub id: String,
    pub name: String,
    pub version: String,
    pub description: String,
    pub description_zh: String,
    pub source: PluginSource,
    pub enabled: bool,
    pub available: bool,
    pub runtime_ready: bool,
    pub root_path: PathBuf,
    pub permissions: PluginPermissions,
    pub tools: Vec<PluginToolRecord>,
    pub status_detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PluginScaffoldRequest {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub description_zh: String,
    pub tool_name: String,
    pub tool_description: String,
    #[serde(default)]
    pub tool_description_zh: String,
    #[serde(default)]
    pub permissions: PluginPermissions,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PluginScaffoldResult {
    pub root_path: PathBuf,
    pub manifest_path: PathBuf,
    pub entrypoint_path: PathBuf,
    pub plugin: PluginRecord,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KnowledgeImportRequest {
    pub path: PathBuf,
    pub title: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
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
    #[serde(alias = "file_name")]
    pub file_name: String,
    pub kind: String,
    #[serde(default)]
    pub content: String,
    #[serde(default)]
    pub slides: Vec<SlideSpec>,
    #[serde(default)]
    pub sheets: Vec<SheetSpec>,
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
pub struct SheetSpec {
    pub name: String,
    #[serde(default)]
    pub rows: Vec<Vec<Value>>,
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
    fn artifact_spec_accepts_tool_contract_and_persisted_field_names() {
        let snake_case: ArtifactSpec = serde_json::from_value(serde_json::json!({
            "title": "Report",
            "file_name": "report.docx",
            "kind": "docx"
        }))
        .expect("the advertised tool contract must deserialize");
        let camel_case: ArtifactSpec = serde_json::from_value(serde_json::json!({
            "title": "Report",
            "fileName": "report.docx",
            "kind": "docx"
        }))
        .expect("the persisted camelCase contract must remain readable");

        assert_eq!(snake_case.file_name, "report.docx");
        assert_eq!(camel_case.file_name, "report.docx");
    }

    #[test]
    fn legacy_artifact_record_defaults_new_provenance_fields() {
        let record: ArtifactRecord = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "Legacy report",
            "path": "/tmp/legacy-report.md",
            "kind": "markdown",
            "sizeBytes": 10,
            "modifiedAt": "2025-01-01T00:00:00Z"
        }))
        .unwrap();

        assert!(record.logical_key.is_none());
        assert!(record.revision.is_empty());
        assert!(record.semantic_revision.is_empty());
        assert!(record.semantic_context.is_empty());
        assert!(record.supersedes.is_none());
        assert!(record.superseded_by.is_none());
    }

    #[test]
    fn legacy_task_record_defaults_durable_review_progress() {
        let task: TaskRecord = serde_json::from_value(serde_json::json!({
            "id": "00000000-0000-0000-0000-000000000010",
            "title": "Legacy task",
            "prompt": "Create a report",
            "status": "running",
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "goalSpec": null,
            "steps": [],
            "artifacts": [],
            "summary": "",
            "error": null,
            "assistantMessageId": "00000000-0000-0000-0000-000000000011"
        }))
        .expect("schema-v1 task records without reviewProgress must remain readable");

        assert_eq!(task.review_progress, ReviewProgress::default());
        assert!(task
            .review_progress
            .last_reviewed_artifact_revisions
            .is_none());
    }

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
        assert_eq!(settings.loop_engine, LoopEngineKind::Grok);
    }
}
