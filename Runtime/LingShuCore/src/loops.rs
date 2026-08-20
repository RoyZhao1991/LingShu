use crate::loop_gateway::{LoopGatewayError, LoopTransportGateway};
use crate::models::{
    AppLocale, ExecutionPermissionMode, GoalSpec, LoopEngineKind, LoopEngineRecord, RuntimeSettings,
};
use crate::preview::file_revision;
use crate::process::spawn_tokio_process_tree;
use crate::workspace_delta::{WorkspaceBaseline, WorkspaceDeltaTracker};
use serde::{Deserialize, Serialize};
use serde_json::{json, to_string_pretty};
use std::collections::{BTreeMap, HashSet};
use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

const DEFAULT_HARNESS_TIMEOUT_SECONDS: u64 = 900;
const LOOP_TRANSPORT_OWNER: &str = "lingshu";
const MANAGED_LOOP_RESULT_PROTOCOL: &str = "lingshu.managed-loop-result.v1";
const MANAGED_LOOP_RESULT_OPEN: &str = "<lingshu_managed_loop_result>";
const MANAGED_LOOP_RESULT_CLOSE: &str = "</lingshu_managed_loop_result>";
const MAX_MANAGED_LOOP_REPLACEMENTS: usize = 32;
const MANAGED_LOOP_RECEIPT_PROTOCOL: &str = "lingshu.managed-loop-receipt.v1";
const MANAGED_LOOP_RECEIPTS_DIRECTORY: &str = "Receipts";
const MAX_RECEIPT_BASELINE_FILES: usize = 4_000;
const MAX_RECEIPT_WORKSPACE_DEPTH: usize = 10;
const MAX_RECEIPT_ARTIFACT_PATHS: usize = 4_000;
const MAX_RECEIPT_TEXT_BYTES: usize = 24_000;
const MAX_RECEIPT_ERROR_BYTES: usize = 8_000;
const MAX_RECEIPT_CONTEXT_BYTES: usize = 12_000;
const MAX_RECEIPT_CONTEXT_PATHS: usize = 96;
const MAX_PENDING_RECEIPTS_PER_TASK: usize = 64;

/// Non-negotiable ownership boundary shared by every Loop harness.
///
/// A harness may change how the reasoning/tool loop is implemented, but it cannot
/// change who owns identity, provider transport, quota, permissions, memory, plugins,
/// artifacts or verification. Keeping this policy outside individual adapters prevents
/// a future harness from silently falling back to its vendor account.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ManagedHarnessPolicy {
    transport_owner: &'static str,
    native_auth_disabled: bool,
    native_quota_disabled: bool,
}

impl ManagedHarnessPolicy {
    const LINGSHU_OWNED: Self = Self {
        transport_owner: LOOP_TRANSPORT_OWNER,
        native_auth_disabled: true,
        native_quota_disabled: true,
    };
}

#[derive(Debug, Error)]
pub enum LoopError {
    #[error("loop engine is unavailable: {0}")]
    Unavailable(String),
    #[error("loop engine execution failed: {0}")]
    Execution(String),
    #[error("managed loop result protocol error: {0}")]
    ResultProtocol(String),
    #[error("managed loop receipt error: {0}")]
    Receipt(String),
    #[error("loop engine filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Gateway(#[from] LoopGatewayError),
}

#[derive(Debug, Clone)]
pub struct LoopExecution {
    pub text: String,
    pub artifact_paths: Vec<PathBuf>,
    pub artifact_replacements: Vec<LoopArtifactReplacement>,
    pub receipt_id: LoopReceiptId,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoopReceiptId {
    pub task_id: Uuid,
    pub run_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LoopArtifactReplacement {
    /// A workspace-relative file created or modified during this harness run.
    pub new_path: PathBuf,
    /// A typed, revision-bound selector for one current artifact in the host manifest.
    pub replaces: LoopArtifactSelector,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LoopArtifactSelector {
    pub by: LoopArtifactSelectorKind,
    pub value: String,
    pub expected_raw_revision: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum LoopArtifactSelectorKind {
    #[serde(rename = "id")]
    Id,
    #[serde(rename = "logical_key")]
    LogicalKey,
    #[serde(rename = "path")]
    Path,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ManagedLoopResultEnvelope {
    protocol: String,
    run_id: Uuid,
    replacements: Vec<LoopArtifactReplacement>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ManagedLoopReceiptState {
    Running,
    Ready,
    Failed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ManagedLoopReceipt {
    protocol: String,
    generation: u32,
    receipt_id: LoopReceiptId,
    engine: LoopEngineKind,
    workspace: PathBuf,
    state: ManagedLoopReceiptState,
    created_at_millis: u64,
    text: String,
    artifact_paths: Vec<PathBuf>,
    artifact_replacements: Vec<LoopArtifactReplacement>,
    error: Option<String>,
    baseline: ReceiptWorkspaceBaseline,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReceiptWorkspaceBaseline {
    complete: bool,
    files: Vec<ReceiptBaselineFile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReceiptBaselineFile {
    path: PathBuf,
    revision: String,
}

#[derive(Debug)]
struct PendingReceiptContext {
    ready: Option<ManagedLoopReceipt>,
    failed: Vec<ManagedLoopReceipt>,
}

pub struct LoopExecutionRequest<'a> {
    pub task_id: Uuid,
    pub workspace: &'a Path,
    pub source_prompt: &'a str,
    pub attachment_paths: &'a [PathBuf],
    pub objective: &'a str,
    pub role: &'a str,
    pub goal: &'a GoalSpec,
    pub correction: Option<&'a str>,
    pub memory_context: &'a str,
    pub plugin_context: &'a str,
    pub locale: AppLocale,
    pub permission_mode: ExecutionPermissionMode,
    pub settings: &'a RuntimeSettings,
    pub api_key: Option<&'a str>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoopAdapterMode {
    InProcess,
    ExternalCli,
}

/// Stable component contract for every agent Loop supported by LingShu.
///
/// Adapters are compiled into the shared Rust kernel. The engine implementation may be
/// in-process (Grok) or discovered at runtime (Codex CLI), but both are selected and surfaced
/// through this same contract.
pub trait LoopAdapter: Send + Sync {
    fn kind(&self) -> LoopEngineKind;
    fn mode(&self) -> LoopAdapterMode;
    fn record(&self, selected: LoopEngineKind) -> LoopEngineRecord;
}

/// External harnesses may describe only their executable invocation. Authentication,
/// provider transport, permissions, memory, plugins, task state and artifacts remain
/// owned by the shared LingShu runner below.
trait ManagedExternalHarnessAdapter: Send + Sync {
    fn kind(&self) -> LoopEngineKind;
    fn name(&self) -> &'static str;
    fn executable(&self) -> Option<&Path>;
    fn isolated_home_variable(&self) -> &'static str;
    fn timeout_seconds(&self) -> u64 {
        DEFAULT_HARNESS_TIMEOUT_SECONDS
    }
    fn arguments(&self, invocation: &ManagedHarnessInvocation<'_>) -> Vec<String>;
}

struct ManagedHarnessInvocation<'a> {
    workspace: &'a Path,
    output_path: &'a Path,
    permission_mode: ExecutionPermissionMode,
    model: &'a str,
    gateway_base_url: &'a str,
}

struct GrokLoopAdapter;

impl LoopAdapter for GrokLoopAdapter {
    fn kind(&self) -> LoopEngineKind {
        LoopEngineKind::Grok
    }

    fn mode(&self) -> LoopAdapterMode {
        LoopAdapterMode::InProcess
    }

    fn record(&self, selected: LoopEngineKind) -> LoopEngineRecord {
        managed_loop_record(
            LoopEngineKind::Grok,
            "Grok Loop",
            "LingShu's in-process agent Loop with shared tools, memory, verification, and dynamic parallel subagents.",
            "灵枢同进程 Agent Loop，共享工具、记忆、验收与动态并行子 Agent。",
            true,
            selected,
            "in_process",
            None,
            "Built-in adapter and engine are ready",
        )
    }
}

struct CodexLoopAdapter {
    executable: Option<PathBuf>,
}

impl LoopAdapter for CodexLoopAdapter {
    fn kind(&self) -> LoopEngineKind {
        LoopEngineKind::Codex
    }

    fn mode(&self) -> LoopAdapterMode {
        LoopAdapterMode::ExternalCli
    }

    fn record(&self, selected: LoopEngineKind) -> LoopEngineRecord {
        managed_loop_record(
            LoopEngineKind::Codex,
            "Codex Loop",
            "Codex is used only as a replaceable Loop harness. LingShu injects model transport and owns identity, quota, permissions, memory, plugins, artifacts, and verification.",
            "Codex 仅作为可替换 Loop harness；模型传输由灵枢注入，身份、额度、权限、记忆、插件、产物和验收均由灵枢管理。",
            self.executable.is_some(),
            selected,
            "external_cli",
            self.executable.clone(),
            &self
                .executable
                .as_ref()
                .map(|path| format!("Managed harness ready: {}", path.display()))
                .unwrap_or_else(|| {
                    "The adapter is ready, but a Codex harness binary was not found. Bundle one, install it on PATH, or set LINGSHU_CODEX_HARNESS."
                        .into()
                }),
        )
    }
}

impl ManagedExternalHarnessAdapter for CodexLoopAdapter {
    fn kind(&self) -> LoopEngineKind {
        LoopEngineKind::Codex
    }

    fn name(&self) -> &'static str {
        "Codex"
    }

    fn executable(&self) -> Option<&Path> {
        self.executable.as_deref()
    }

    fn isolated_home_variable(&self) -> &'static str {
        "CODEX_HOME"
    }

    fn arguments(&self, invocation: &ManagedHarnessInvocation<'_>) -> Vec<String> {
        codex_exec_args(
            invocation.workspace,
            invocation.output_path,
            invocation.permission_mode,
            invocation.model,
            invocation.gateway_base_url,
        )
    }
}

#[derive(Clone)]
pub struct LoopRegistry {
    scratch_root: Arc<PathBuf>,
    workspace_delta: WorkspaceDeltaTracker,
}

impl LoopRegistry {
    pub fn new(
        data_dir: impl AsRef<Path>,
        _platform: impl Into<String>,
    ) -> Result<Self, LoopError> {
        let data_dir = data_dir.as_ref();
        let scratch_root = data_dir.join("LoopRuns");
        fs::create_dir_all(&scratch_root)?;
        Ok(Self {
            scratch_root: Arc::new(scratch_root),
            workspace_delta: WorkspaceDeltaTracker::new(data_dir),
        })
    }

    pub(crate) async fn begin_workspace_delta(&self, workspace: &Path) -> WorkspaceBaseline {
        let tracker = self.workspace_delta.clone();
        let workspace = workspace.to_path_buf();
        let fallback_workspace = workspace.clone();
        tokio::task::spawn_blocking(move || tracker.baseline(&workspace))
            .await
            .unwrap_or_else(|_| self.workspace_delta.baseline(&fallback_workspace))
    }

    pub(crate) async fn finish_workspace_delta(&self, baseline: WorkspaceBaseline) -> Vec<PathBuf> {
        let tracker = self.workspace_delta.clone();
        let fallback = baseline.clone();
        tokio::task::spawn_blocking(move || tracker.changed_files(baseline))
            .await
            .unwrap_or_else(|_| self.workspace_delta.changed_files(fallback))
    }

    pub fn list(&self, selected: LoopEngineKind) -> Vec<LoopEngineRecord> {
        self.adapters()
            .into_iter()
            .map(|adapter| adapter.record(selected))
            .collect()
    }

    pub fn mode(&self, kind: LoopEngineKind) -> LoopAdapterMode {
        self.adapters()
            .into_iter()
            .find(|adapter| adapter.kind() == kind)
            .map(|adapter| adapter.mode())
            .unwrap_or(LoopAdapterMode::InProcess)
    }

    /// Complete the second phase after the host has atomically registered every artifact in the
    /// execution. Acknowledgement is idempotent so a host crash immediately after deletion can
    /// safely retry it.
    pub async fn acknowledge_receipt(&self, receipt_id: LoopReceiptId) -> Result<(), LoopError> {
        let scratch_root = self.scratch_root.as_ref().clone();
        tokio::task::spawn_blocking(move || acknowledge_receipt_sync(&scratch_root, receipt_id))
            .await
            .map_err(|error| {
                LoopError::Receipt(format!("receipt acknowledgement task failed: {error}"))
            })?
    }

    /// Return a ready receipt to the retry queue when host-side validation or atomic registration
    /// rejects it. The changed paths and bounded diagnostic remain durable for the next run.
    pub async fn reject_receipt(
        &self,
        receipt_id: LoopReceiptId,
        error: String,
    ) -> Result<(), LoopError> {
        let scratch_root = self.scratch_root.as_ref().clone();
        tokio::task::spawn_blocking(move || reject_receipt_sync(&scratch_root, receipt_id, &error))
            .await
            .map_err(|error| {
                LoopError::Receipt(format!("receipt rejection task failed: {error}"))
            })?
    }

    fn adapters(&self) -> Vec<Box<dyn LoopAdapter>> {
        vec![
            Box::new(GrokLoopAdapter),
            Box::new(CodexLoopAdapter {
                executable: self.codex_executable(),
            }),
        ]
    }

    fn external_adapter(
        &self,
        kind: LoopEngineKind,
    ) -> Option<Box<dyn ManagedExternalHarnessAdapter>> {
        match kind {
            LoopEngineKind::Codex => Some(Box::new(CodexLoopAdapter {
                executable: self.codex_executable(),
            })),
            LoopEngineKind::Grok => None,
        }
    }

    pub fn codex_executable(&self) -> Option<PathBuf> {
        for variable in ["LINGSHU_CODEX_HARNESS", "LINGSHU_CODEX_EXECUTABLE"] {
            if let Some(path) = env::var_os(variable).map(PathBuf::from) {
                if executable_candidate(&path) {
                    return Some(path);
                }
            }
        }

        let mut candidates = Vec::new();
        if let Ok(current) = env::current_exe() {
            if let Some(parent) = current.parent() {
                candidates.push(parent.join("LoopHarnesses").join(executable_name("codex")));
                candidates.push(parent.join("loop-harnesses").join(executable_name("codex")));
                candidates.push(
                    parent
                        .join("resources")
                        .join("loop-harnesses")
                        .join(executable_name("codex")),
                );
                candidates.push(
                    parent
                        .parent()
                        .unwrap_or(parent)
                        .join("Resources")
                        .join("LoopHarnesses")
                        .join(executable_name("codex")),
                );
            }
        }
        candidates
            .into_iter()
            .find(|path| executable_candidate(path))
            .or_else(|| find_on_path("codex"))
    }

    pub async fn run(
        &self,
        kind: LoopEngineKind,
        request: LoopExecutionRequest<'_>,
    ) -> Result<LoopExecution, LoopError> {
        let adapter = self.external_adapter(kind).ok_or_else(|| {
            LoopError::Execution(format!(
                "{} is an in-process Loop and must be executed by the runtime host",
                kind.as_str()
            ))
        })?;
        self.run_managed_external_harness(adapter.as_ref(), request)
            .await
    }

    async fn run_managed_external_harness(
        &self,
        adapter: &dyn ManagedExternalHarnessAdapter,
        request: LoopExecutionRequest<'_>,
    ) -> Result<LoopExecution, LoopError> {
        fs::create_dir_all(request.workspace)?;
        let workspace = receipt_workspace_identity(request.workspace);
        let scratch_root = self.scratch_root.as_ref().clone();
        let pending = tokio::task::spawn_blocking({
            let scratch_root = scratch_root.clone();
            let workspace = workspace.clone();
            move || prepare_pending_receipts(&scratch_root, request.task_id, &workspace)
        })
        .await
        .map_err(|error| LoopError::Receipt(format!("receipt recovery task failed: {error}")))??;
        if let Some(ready) = pending.ready {
            return loop_execution_from_receipt(ready);
        }

        let executable = adapter.executable().ok_or_else(|| {
            LoopError::Unavailable(format!(
                "{} harness was not found or did not satisfy the managed-harness contract",
                adapter.name()
            ))
        })?;

        let recovery_context = failed_receipt_context(&pending.failed);
        let inherited_paths = merge_receipt_artifact_paths(
            &workspace,
            pending
                .failed
                .iter()
                .flat_map(|receipt| receipt.artifact_paths.iter().cloned()),
        );
        let inherited_error = bounded_join(
            pending
                .failed
                .iter()
                .filter_map(|receipt| receipt.error.as_deref()),
            "\n\n",
            MAX_RECEIPT_ERROR_BYTES,
        );
        let inherited_claims = pending
            .failed
            .iter()
            .flat_map(|receipt| receipt.artifact_replacements.iter().cloned())
            .take(MAX_MANAGED_LOOP_REPLACEMENTS)
            .collect::<Vec<_>>();
        let obsolete_receipts = pending
            .failed
            .iter()
            .map(|receipt| receipt.receipt_id)
            .collect::<Vec<_>>();

        let baseline = self.begin_workspace_delta(request.workspace).await;
        let durable_baseline = tokio::task::spawn_blocking({
            let workspace = workspace.clone();
            move || receipt_workspace_baseline(&workspace)
        })
        .await
        .map_err(|error| LoopError::Receipt(format!("receipt baseline task failed: {error}")))?;
        let run_id = Uuid::new_v4();
        let receipt_id = LoopReceiptId {
            task_id: request.task_id,
            run_id,
        };
        let run_root = receipt_run_root(&scratch_root, receipt_id);
        let isolated_home = run_root.join("home");
        fs::create_dir_all(&isolated_home)?;
        restrict_private_directory(&run_root)?;
        if let Some(task_root) = run_root.parent() {
            restrict_private_directory(task_root)?;
        }
        let output_path = run_root.join("last-message.txt");
        let mut receipt = ManagedLoopReceipt {
            protocol: MANAGED_LOOP_RECEIPT_PROTOCOL.into(),
            generation: 1,
            receipt_id,
            engine: adapter.kind(),
            workspace: workspace.clone(),
            state: ManagedLoopReceiptState::Running,
            created_at_millis: unix_time_millis(),
            text: String::new(),
            artifact_paths: inherited_paths,
            artifact_replacements: inherited_claims,
            error: (!inherited_error.is_empty()).then_some(inherited_error),
            baseline: durable_baseline,
        };
        persist_receipt(&run_root, &receipt)?;

        let gateway = match LoopTransportGateway::start(
            request.settings.clone(),
            request.api_key.map(str::to_string),
        )
        .await
        {
            Ok(gateway) => gateway,
            Err(error) => {
                let error = LoopError::Gateway(error);
                self.finalize_failed_receipt(
                    baseline,
                    &mut receipt,
                    &run_root,
                    &obsolete_receipts,
                    "",
                    &error.to_string(),
                )
                .await?;
                return Err(error);
            }
        };
        let gateway_base_url = gateway.base_url();
        let prompt = managed_harness_prompt(
            adapter.name(),
            &request,
            run_id,
            recovery_context.as_deref(),
        );
        let invocation = ManagedHarnessInvocation {
            workspace: request.workspace,
            output_path: &output_path,
            permission_mode: request.permission_mode,
            model: &request.settings.model,
            gateway_base_url: &gateway_base_url,
        };
        let args = adapter.arguments(&invocation);
        let mut process = tokio::process::Command::new(executable);
        process
            .args(&args)
            .current_dir(request.workspace)
            .env(adapter.isolated_home_variable(), &isolated_home)
            .env("LINGSHU_LOOP_GATEWAY_TOKEN", gateway.bearer_token())
            .env("LINGSHU_LOOP_ENGINE", adapter.kind().as_str())
            .env(
                "LINGSHU_LOOP_TRANSPORT_OWNER",
                ManagedHarnessPolicy::LINGSHU_OWNED.transport_owner,
            )
            .env("LINGSHU_LOOP_NATIVE_AUTH", "disabled")
            .env("LINGSHU_LOOP_NATIVE_QUOTA", "disabled")
            .env("LINGSHU_WORKSPACE", request.workspace)
            .env(
                "LINGSHU_EXECUTION_PERMISSION_MODE",
                request.permission_mode.as_str(),
            )
            .env(
                "LINGSHU_NETWORK_ACCESS",
                if request.permission_mode == ExecutionPermissionMode::FullAccess {
                    "allowed"
                } else {
                    "blocked"
                },
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        remove_native_provider_environment(&mut process);
        let output =
            run_harness_process(process, &prompt, adapter.name(), adapter.timeout_seconds()).await;
        gateway.stop().await;
        let output = match output {
            Ok(output) => output,
            Err(error) => {
                let raw_text = fs::read_to_string(&output_path).unwrap_or_default();
                self.finalize_failed_receipt(
                    baseline,
                    &mut receipt,
                    &run_root,
                    &obsolete_receipts,
                    &raw_text,
                    &error.to_string(),
                )
                .await?;
                return Err(error);
            }
        };
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if !output.status.success() {
            let detail = if stderr.is_empty() {
                stdout.clone()
            } else {
                stderr
            };
            let error = LoopError::Execution(if detail.is_empty() {
                format!("{} harness exited with {}", adapter.name(), output.status)
            } else {
                detail
            });
            let raw_text = fs::read_to_string(&output_path).unwrap_or(stdout);
            self.finalize_failed_receipt(
                baseline,
                &mut receipt,
                &run_root,
                &obsolete_receipts,
                &raw_text,
                &error.to_string(),
            )
            .await?;
            return Err(error);
        }
        let raw_text = fs::read_to_string(&output_path)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(stdout);
        if raw_text.trim().is_empty() {
            let error = LoopError::Execution(format!(
                "{} harness completed without a final response",
                adapter.name()
            ));
            self.finalize_failed_receipt(
                baseline,
                &mut receipt,
                &run_root,
                &obsolete_receipts,
                "",
                &error.to_string(),
            )
            .await?;
            return Err(error);
        }
        let artifact_paths = self.finish_workspace_delta(baseline).await;
        receipt.artifact_paths = merge_receipt_artifact_paths(
            &workspace,
            receipt.artifact_paths.iter().cloned().chain(artifact_paths),
        );
        let (text, artifact_replacements) = match parse_managed_loop_result(&raw_text, run_id) {
            Ok(result) => result,
            Err(error) => {
                finalize_failed_receipt_sync(
                    &scratch_root,
                    &mut receipt,
                    &run_root,
                    &obsolete_receipts,
                    &raw_text,
                    &error.to_string(),
                )?;
                return Err(error);
            }
        };
        receipt.generation = receipt.generation.saturating_add(1);
        receipt.state = ManagedLoopReceiptState::Ready;
        receipt.text = truncate_receipt_value(&text, MAX_RECEIPT_TEXT_BYTES);
        receipt.artifact_replacements = artifact_replacements;
        receipt.error = None;
        receipt.baseline = ReceiptWorkspaceBaseline::default();
        persist_receipt(&run_root, &receipt)?;
        cleanup_receipt_transients(&run_root);
        clear_obsolete_receipts(&scratch_root, &obsolete_receipts, receipt.receipt_id);
        loop_execution_from_receipt(receipt)
    }

    async fn finalize_failed_receipt(
        &self,
        baseline: WorkspaceBaseline,
        receipt: &mut ManagedLoopReceipt,
        run_root: &Path,
        obsolete_receipts: &[LoopReceiptId],
        text: &str,
        error: &str,
    ) -> Result<(), LoopError> {
        let changed = self.finish_workspace_delta(baseline).await;
        receipt.artifact_paths = merge_receipt_artifact_paths(
            &receipt.workspace,
            receipt.artifact_paths.iter().cloned().chain(changed),
        );
        finalize_failed_receipt_sync(
            self.scratch_root.as_ref(),
            receipt,
            run_root,
            obsolete_receipts,
            text,
            error,
        )
    }
}

fn receipt_workspace_identity(workspace: &Path) -> PathBuf {
    fs::canonicalize(workspace).unwrap_or_else(|_| workspace.to_path_buf())
}

fn unix_time_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .min(u64::MAX as u128) as u64
}

fn receipt_task_root(scratch_root: &Path, task_id: Uuid) -> PathBuf {
    scratch_root
        .join(MANAGED_LOOP_RECEIPTS_DIRECTORY)
        .join(task_id.to_string())
}

fn receipt_run_root(scratch_root: &Path, receipt_id: LoopReceiptId) -> PathBuf {
    receipt_task_root(scratch_root, receipt_id.task_id).join(receipt_id.run_id.to_string())
}

fn receipt_file_name(generation: u32) -> String {
    format!("receipt-{generation:010}.json")
}

fn persist_receipt(run_root: &Path, receipt: &ManagedLoopReceipt) -> Result<(), LoopError> {
    validate_receipt_bounds(receipt)?;
    fs::create_dir_all(run_root)?;
    restrict_private_directory(run_root)?;
    let path = run_root.join(receipt_file_name(receipt.generation));
    let bytes = serde_json::to_vec_pretty(receipt)
        .map_err(|error| LoopError::Receipt(format!("could not encode receipt: {error}")))?;
    let mut file = fs::File::create(&path)?;
    file.write_all(&bytes)?;
    file.sync_all()?;

    #[cfg(unix)]
    if let Ok(directory) = fs::File::open(run_root) {
        let _ = directory.sync_all();
    }

    // Generations are immutable. Once the new file is synced, older generations can be removed
    // without creating an overwrite window on Windows. Retain one previous generation as a
    // fallback for a torn final write, while keeping each receipt directory bounded.
    let mut generations = fs::read_dir(run_root)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|candidate| {
            candidate
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("receipt-") && name.ends_with(".json"))
        })
        .collect::<Vec<_>>();
    generations.sort_by(|left, right| right.file_name().cmp(&left.file_name()));
    for candidate in generations.into_iter().skip(2) {
        let _ = fs::remove_file(candidate);
    }
    Ok(())
}

fn validate_receipt_bounds(receipt: &ManagedLoopReceipt) -> Result<(), LoopError> {
    if receipt.protocol != MANAGED_LOOP_RECEIPT_PROTOCOL {
        return Err(LoopError::Receipt(format!(
            "unsupported receipt protocol {:?}",
            receipt.protocol
        )));
    }
    if receipt.artifact_paths.len() > MAX_RECEIPT_ARTIFACT_PATHS
        || receipt.baseline.files.len() > MAX_RECEIPT_BASELINE_FILES
        || receipt.artifact_replacements.len() > MAX_MANAGED_LOOP_REPLACEMENTS
        || receipt.text.len() > MAX_RECEIPT_TEXT_BYTES
        || receipt
            .error
            .as_ref()
            .is_some_and(|error| error.len() > MAX_RECEIPT_ERROR_BYTES)
    {
        return Err(LoopError::Receipt(
            "receipt exceeded its bounded persistence contract".into(),
        ));
    }
    if receipt
        .artifact_paths
        .iter()
        .chain(receipt.baseline.files.iter().map(|file| &file.path))
        .any(|path| !is_workspace_relative_result_path(path))
    {
        return Err(LoopError::Receipt(
            "receipt contains a non-relative workspace path".into(),
        ));
    }
    Ok(())
}

fn load_receipt(run_root: &Path, expected: LoopReceiptId) -> Result<ManagedLoopReceipt, LoopError> {
    let mut generations = fs::read_dir(run_root)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("receipt-") && name.ends_with(".json"))
        })
        .collect::<Vec<_>>();
    generations.sort_by(|left, right| right.file_name().cmp(&left.file_name()));
    let mut last_error = None;
    for path in generations {
        let result = fs::read(&path).map_err(LoopError::Io).and_then(|bytes| {
            serde_json::from_slice::<ManagedLoopReceipt>(&bytes).map_err(|error| {
                LoopError::Receipt(format!("could not decode {}: {error}", path.display()))
            })
        });
        match result {
            Ok(receipt) => {
                validate_receipt_bounds(&receipt)?;
                if receipt.receipt_id != expected {
                    return Err(LoopError::Receipt(format!(
                        "receipt identity mismatch in {}",
                        path.display()
                    )));
                }
                return Ok(receipt);
            }
            Err(error) => last_error = Some(error),
        }
    }
    Err(last_error.unwrap_or_else(|| {
        LoopError::Receipt(format!(
            "no durable receipt found in {}",
            run_root.display()
        ))
    }))
}

fn prepare_pending_receipts(
    scratch_root: &Path,
    task_id: Uuid,
    workspace: &Path,
) -> Result<PendingReceiptContext, LoopError> {
    let task_root = receipt_task_root(scratch_root, task_id);
    if !task_root.is_dir() {
        return Ok(PendingReceiptContext {
            ready: None,
            failed: Vec::new(),
        });
    }
    let mut run_ids = fs::read_dir(&task_root)?
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .filter_map(|entry| {
            entry
                .file_name()
                .to_str()
                .and_then(|name| Uuid::parse_str(name).ok())
        })
        .collect::<Vec<_>>();
    run_ids.sort();
    if run_ids.len() > MAX_PENDING_RECEIPTS_PER_TASK {
        return Err(LoopError::Receipt(format!(
            "task {task_id} has {} pending receipts; manual recovery is required before continuing",
            run_ids.len()
        )));
    }

    let mut ready = Vec::new();
    let mut failed = Vec::new();
    for run_id in run_ids {
        let receipt_id = LoopReceiptId { task_id, run_id };
        let run_root = receipt_run_root(scratch_root, receipt_id);
        let mut receipt = load_receipt(&run_root, receipt_id)?;
        if receipt.workspace != workspace {
            return Err(LoopError::Receipt(format!(
                "pending receipt {run_id} belongs to workspace {}, not {}",
                receipt.workspace.display(),
                workspace.display()
            )));
        }
        if receipt.state == ManagedLoopReceiptState::Running {
            recover_running_receipt(&run_root, &mut receipt)?;
        }
        match receipt.state {
            ManagedLoopReceiptState::Ready => ready.push(receipt),
            ManagedLoopReceiptState::Failed => failed.push(receipt),
            ManagedLoopReceiptState::Running => unreachable!("running receipt was recovered"),
        }
    }
    if ready.len() > 1 {
        return Err(LoopError::Receipt(format!(
            "task {task_id} has multiple ready receipts; refusing an ambiguous replay"
        )));
    }
    let mut ready = ready.pop();
    if let Some(receipt) = ready.as_mut() {
        if !failed.is_empty() {
            receipt.artifact_paths = merge_receipt_artifact_paths(
                workspace,
                receipt.artifact_paths.iter().cloned().chain(
                    failed
                        .iter()
                        .flat_map(|item| item.artifact_paths.iter().cloned()),
                ),
            );
            receipt.generation = receipt.generation.saturating_add(1);
            let ready_root = receipt_run_root(scratch_root, receipt.receipt_id);
            persist_receipt(&ready_root, receipt)?;
            let obsolete = failed
                .iter()
                .map(|item| item.receipt_id)
                .collect::<Vec<_>>();
            clear_obsolete_receipts(scratch_root, &obsolete, receipt.receipt_id);
            failed.clear();
        }
    }
    Ok(PendingReceiptContext { ready, failed })
}

fn recover_running_receipt(
    run_root: &Path,
    receipt: &mut ManagedLoopReceipt,
) -> Result<(), LoopError> {
    let baseline_complete = receipt.baseline.complete;
    let changed = receipt_changed_since_baseline(&receipt.workspace, &receipt.baseline);
    receipt.artifact_paths = merge_receipt_artifact_paths(
        &receipt.workspace,
        receipt.artifact_paths.iter().cloned().chain(changed),
    );
    let raw_text = fs::read_to_string(run_root.join("last-message.txt")).unwrap_or_default();
    receipt.generation = receipt.generation.saturating_add(1);
    receipt.baseline = ReceiptWorkspaceBaseline::default();
    if !baseline_complete {
        receipt.state = ManagedLoopReceiptState::Failed;
        receipt.text = truncate_receipt_value(&raw_text, MAX_RECEIPT_TEXT_BYTES);
        receipt.artifact_replacements.clear();
        receipt.error = Some(truncate_receipt_value(
            "The previous managed external run was interrupted and its bounded durable baseline was incomplete. The discovered changed paths were retained, but a fresh run must reconcile the Workspace before commit.",
            MAX_RECEIPT_ERROR_BYTES,
        ));
    } else if raw_text.trim().is_empty() {
        receipt.state = ManagedLoopReceiptState::Failed;
        receipt.error = Some(truncate_receipt_value(
            "The previous managed external run was interrupted before a durable final result was written.",
            MAX_RECEIPT_ERROR_BYTES,
        ));
    } else {
        match parse_managed_loop_result(&raw_text, receipt.receipt_id.run_id) {
            Ok((text, replacements)) => {
                receipt.state = ManagedLoopReceiptState::Ready;
                receipt.text = truncate_receipt_value(&text, MAX_RECEIPT_TEXT_BYTES);
                receipt.artifact_replacements = replacements;
                receipt.error = None;
            }
            Err(error) => {
                receipt.state = ManagedLoopReceiptState::Failed;
                receipt.text = truncate_receipt_value(&raw_text, MAX_RECEIPT_TEXT_BYTES);
                receipt.artifact_replacements.clear();
                receipt.error = Some(truncate_receipt_value(
                    &format!("Recovered interrupted run could not be committed: {error}"),
                    MAX_RECEIPT_ERROR_BYTES,
                ));
            }
        }
    }
    persist_receipt(run_root, receipt)?;
    cleanup_receipt_transients(run_root);
    Ok(())
}

fn loop_execution_from_receipt(receipt: ManagedLoopReceipt) -> Result<LoopExecution, LoopError> {
    if receipt.state != ManagedLoopReceiptState::Ready {
        return Err(LoopError::Receipt(format!(
            "receipt {} is not ready for replay",
            receipt.receipt_id.run_id
        )));
    }
    if receipt.text.trim().is_empty() {
        return Err(LoopError::Receipt(format!(
            "ready receipt {} has no final result",
            receipt.receipt_id.run_id
        )));
    }
    Ok(LoopExecution {
        text: receipt.text,
        artifact_paths: receipt.artifact_paths,
        artifact_replacements: receipt.artifact_replacements,
        receipt_id: receipt.receipt_id,
    })
}

fn finalize_failed_receipt_sync(
    scratch_root: &Path,
    receipt: &mut ManagedLoopReceipt,
    run_root: &Path,
    obsolete_receipts: &[LoopReceiptId],
    text: &str,
    error: &str,
) -> Result<(), LoopError> {
    receipt.generation = receipt.generation.saturating_add(1);
    receipt.state = ManagedLoopReceiptState::Failed;
    if !text.trim().is_empty() {
        receipt.text = truncate_receipt_value(text, MAX_RECEIPT_TEXT_BYTES);
    }
    let previous_error = receipt.error.as_deref().unwrap_or_default();
    receipt.error = Some(bounded_join(
        [previous_error, error]
            .into_iter()
            .filter(|value| !value.trim().is_empty()),
        "\n\n",
        MAX_RECEIPT_ERROR_BYTES,
    ));
    receipt.baseline = ReceiptWorkspaceBaseline::default();
    persist_receipt(run_root, receipt)?;
    cleanup_receipt_transients(run_root);
    clear_obsolete_receipts(scratch_root, obsolete_receipts, receipt.receipt_id);
    Ok(())
}

fn acknowledge_receipt_sync(
    scratch_root: &Path,
    receipt_id: LoopReceiptId,
) -> Result<(), LoopError> {
    let run_root = receipt_run_root(scratch_root, receipt_id);
    if !run_root.exists() {
        return Ok(());
    }
    let receipt = load_receipt(&run_root, receipt_id)?;
    if receipt.state != ManagedLoopReceiptState::Ready {
        return Err(LoopError::Receipt(format!(
            "cannot acknowledge receipt {} while it is {:?}",
            receipt_id.run_id, receipt.state
        )));
    }
    fs::remove_dir_all(&run_root)?;
    remove_empty_receipt_task_root(scratch_root, receipt_id.task_id);
    Ok(())
}

fn reject_receipt_sync(
    scratch_root: &Path,
    receipt_id: LoopReceiptId,
    error: &str,
) -> Result<(), LoopError> {
    let run_root = receipt_run_root(scratch_root, receipt_id);
    if !run_root.is_dir() {
        return Err(LoopError::Receipt(format!(
            "cannot reject missing receipt {}",
            receipt_id.run_id
        )));
    }
    let mut receipt = load_receipt(&run_root, receipt_id)?;
    if receipt.state == ManagedLoopReceiptState::Running {
        return Err(LoopError::Receipt(format!(
            "cannot reject receipt {} before its run is finalized",
            receipt_id.run_id
        )));
    }
    receipt.generation = receipt.generation.saturating_add(1);
    receipt.state = ManagedLoopReceiptState::Failed;
    receipt.error = Some(truncate_receipt_value(
        if error.trim().is_empty() {
            "The host rejected the ready receipt without a diagnostic."
        } else {
            error
        },
        MAX_RECEIPT_ERROR_BYTES,
    ));
    receipt.baseline = ReceiptWorkspaceBaseline::default();
    persist_receipt(&run_root, &receipt)?;
    cleanup_receipt_transients(&run_root);
    Ok(())
}

fn cleanup_receipt_transients(run_root: &Path) {
    let _ = fs::remove_file(run_root.join("last-message.txt"));
    let _ = fs::remove_dir_all(run_root.join("home"));
}

fn clear_obsolete_receipts(
    scratch_root: &Path,
    receipts: &[LoopReceiptId],
    retained: LoopReceiptId,
) {
    for receipt_id in receipts {
        if *receipt_id != retained {
            let _ = fs::remove_dir_all(receipt_run_root(scratch_root, *receipt_id));
            remove_empty_receipt_task_root(scratch_root, receipt_id.task_id);
        }
    }
}

fn remove_empty_receipt_task_root(scratch_root: &Path, task_id: Uuid) {
    let task_root = receipt_task_root(scratch_root, task_id);
    if fs::read_dir(&task_root)
        .ok()
        .is_some_and(|mut entries| entries.next().is_none())
    {
        let _ = fs::remove_dir(task_root);
    }
}

fn failed_receipt_context(receipts: &[ManagedLoopReceipt]) -> Option<String> {
    if receipts.is_empty() {
        return None;
    }
    let mut sections = Vec::new();
    for receipt in receipts {
        let paths = receipt
            .artifact_paths
            .iter()
            .take(MAX_RECEIPT_CONTEXT_PATHS)
            .map(|path| format!("- {}", path.display()))
            .collect::<Vec<_>>()
            .join("\n");
        let claims = receipt
            .artifact_replacements
            .iter()
            .take(MAX_MANAGED_LOOP_REPLACEMENTS)
            .map(|claim| {
                let by = match claim.replaces.by {
                    LoopArtifactSelectorKind::Id => "id",
                    LoopArtifactSelectorKind::LogicalKey => "logical_key",
                    LoopArtifactSelectorKind::Path => "path",
                };
                format!(
                    "- {} replaces {by}:{} at raw revision {}",
                    claim.new_path.display(),
                    claim.replaces.value,
                    claim.replaces.expected_raw_revision
                )
            })
            .collect::<Vec<_>>()
            .join("\n");
        sections.push(format!(
            "Receipt runId={} was not acknowledged.\nPrior error: {}\nPending changed paths:\n{}\nRejected or uncommitted save-as claims:\n{}",
            receipt.receipt_id.run_id,
            receipt.error.as_deref().unwrap_or("unspecified host interruption"),
            if paths.is_empty() { "(none)" } else { &paths },
            if claims.is_empty() { "(none)" } else { &claims },
        ));
    }
    let guidance = "Reconcile these pending files before finishing: keep and correctly declare valid deliverables, or delete obsolete/invalid files. The host will merge every still-existing pending path into this run's artifact commit.";
    let joined = format!("{guidance}\n\n{}", sections.join("\n\n"));
    Some(truncate_receipt_value(&joined, MAX_RECEIPT_CONTEXT_BYTES))
}

fn bounded_join<'a>(
    values: impl IntoIterator<Item = &'a str>,
    separator: &str,
    max_bytes: usize,
) -> String {
    let joined = values
        .into_iter()
        .filter(|value| !value.trim().is_empty())
        .collect::<Vec<_>>()
        .join(separator);
    truncate_receipt_value(&joined, max_bytes)
}

fn truncate_receipt_value(value: &str, max_bytes: usize) -> String {
    if value.len() <= max_bytes {
        return value.to_string();
    }
    let mut end = max_bytes.saturating_sub('…'.len_utf8()).min(value.len());
    while end > 0 && !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}…", &value[..end])
}

fn merge_receipt_artifact_paths(
    workspace: &Path,
    paths: impl IntoIterator<Item = PathBuf>,
) -> Vec<PathBuf> {
    let mut unique = BTreeMap::new();
    for path in paths {
        if unique.len() >= MAX_RECEIPT_ARTIFACT_PATHS || !is_workspace_relative_result_path(&path) {
            continue;
        }
        let absolute = workspace.join(&path);
        let Ok(metadata) = fs::symlink_metadata(&absolute) else {
            continue;
        };
        if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            continue;
        }
        unique.insert(path.to_string_lossy().replace('\\', "/"), path);
    }
    unique.into_values().collect()
}

fn receipt_workspace_baseline(workspace: &Path) -> ReceiptWorkspaceBaseline {
    let mut files = Vec::new();
    let mut complete = true;
    collect_receipt_workspace_files(workspace, workspace, 0, &mut files, &mut complete);
    ReceiptWorkspaceBaseline { complete, files }
}

fn collect_receipt_workspace_files(
    root: &Path,
    directory: &Path,
    depth: usize,
    files: &mut Vec<ReceiptBaselineFile>,
    complete: &mut bool,
) {
    if depth > MAX_RECEIPT_WORKSPACE_DEPTH || files.len() >= MAX_RECEIPT_BASELINE_FILES {
        *complete = false;
        return;
    }
    let Ok(entries) = fs::read_dir(directory) else {
        *complete = false;
        return;
    };
    for entry in entries.flatten() {
        if files.len() >= MAX_RECEIPT_BASELINE_FILES {
            *complete = false;
            break;
        }
        let path = entry.path();
        let relative = match path.strip_prefix(root) {
            Ok(relative) => relative.to_path_buf(),
            Err(_) => {
                *complete = false;
                continue;
            }
        };
        let Ok(metadata) = fs::symlink_metadata(&path) else {
            *complete = false;
            continue;
        };
        if metadata.file_type().is_symlink() || receipt_workspace_noise(&relative) {
            continue;
        }
        if metadata.is_dir() {
            collect_receipt_workspace_files(root, &path, depth + 1, files, complete);
        } else if metadata.is_file() {
            match file_revision(&path) {
                Ok(revision) => files.push(ReceiptBaselineFile {
                    path: relative,
                    revision,
                }),
                Err(_) => *complete = false,
            }
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
}

fn receipt_changed_since_baseline(
    workspace: &Path,
    baseline: &ReceiptWorkspaceBaseline,
) -> Vec<PathBuf> {
    let after = receipt_workspace_baseline(workspace);
    let before = baseline
        .files
        .iter()
        .map(|file| (file.path.clone(), file.revision.as_str()))
        .collect::<BTreeMap<_, _>>();
    after
        .files
        .into_iter()
        .filter(|file| before.get(&file.path).copied() != Some(file.revision.as_str()))
        .map(|file| file.path)
        .collect()
}

fn receipt_workspace_noise(path: &Path) -> bool {
    const SKIP_DIRECTORIES: &[&str] = &[
        ".git",
        ".lingshu",
        ".build",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        "dist",
        "build",
        "target",
        ".pytest_cache",
        ".idea",
        ".next",
        ".cache",
        "DerivedData",
    ];
    if path.components().any(|component| {
        let value = component.as_os_str().to_string_lossy();
        SKIP_DIRECTORIES
            .iter()
            .any(|candidate| value.eq_ignore_ascii_case(candidate))
    }) {
        return true;
    }
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    matches!(extension.as_str(), "pyc" | "pyo" | "class" | "o")
        || path.file_name().is_some_and(|name| name == ".DS_Store")
}

fn managed_loop_record(
    id: LoopEngineKind,
    name: &str,
    description: &str,
    description_zh: &str,
    available: bool,
    selected: LoopEngineKind,
    execution_mode: &str,
    executable: Option<PathBuf>,
    status_detail: &str,
) -> LoopEngineRecord {
    let policy = ManagedHarnessPolicy::LINGSHU_OWNED;
    LoopEngineRecord {
        id,
        name: name.into(),
        description: description.into(),
        description_zh: description_zh.into(),
        adapter_builtin: true,
        available,
        selected: selected == id,
        execution_mode: execution_mode.into(),
        executable,
        status_detail: status_detail.into(),
        harness_only: true,
        transport_owner: policy.transport_owner.into(),
        native_auth_disabled: policy.native_auth_disabled,
        native_quota_disabled: policy.native_quota_disabled,
    }
}

fn managed_harness_prompt(
    harness_name: &str,
    request: &LoopExecutionRequest<'_>,
    run_id: Uuid,
    recovery_context: Option<&str>,
) -> String {
    let footer_example = format!(
        "{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}",
        json!({
            "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
            "runId": run_id,
            "replacements": [{
                "newPath": "deliverables/deck-ivory.pptx",
                "replaces": {
                    "by": "id",
                    "value": "<exact current artifact id from the host manifest>",
                    "expectedRawRevision": "<exact current raw_revision from the host manifest>"
                }
            }]
        })
    );
    format!(
        "{}\n{}\nYou are the {} Loop harness selected inside LingShu's shared Rust runtime. You contribute only the reasoning and tool-orchestration loop. LingShu owns and injects the model transport; never use, request, inspect, or mention the harness vendor's login, account, subscription, quota, native provider endpoint, or native provider credential. LingShu also owns the durable task ledger, memory, permissions, plugins, artifacts, verification, and child-session lifecycle. Execute the accepted session objective in the supplied Workspace, run useful validations, and leave reusable deliverables there. Do not ask the user directly; report a precise blocker when human action is indispensable. Never expose hidden chain-of-thought. End with a concise result, validation evidence, and exact artifact paths.\n\nManaged result run ID: {run_id}. For a save-as revision only, append exactly one final host-only footer after the human-readable result. Its protocol must be {MANAGED_LOOP_RESULT_PROTOCOL}, and its runId must be exactly {run_id}. Each replacement must use a forward-slash workspace-relative newPath with no '.' or '..' segment and a replaces selector whose by is exactly id, logical_key, or path; copy its value and expectedRawRevision exactly from one CURRENT ARTIFACT MANIFEST entry. Example:\n{footer_example}\nDo not put any text after this footer. Omit it for same-path edits and genuine companion files. Every declared newPath must be a file changed by this run. A new path without this explicit declaration is always a companion.\n\nSession role: {}\nOriginal user or parent request:\n{}\n\nSession objective:\n{}\n\nAccepted GoalSpec:\n{}\n\nAttachments:\n{}\n\nIndependent checker correction, when present:\n{}\n\nRelevant long-term memory (background only; current objective wins):\n{}\n\nRegistered shared plugin context:\n{}\n\nDurable recovery context from earlier unacknowledged external runs:\n{}",
        request.locale.language_directive(),
        request.permission_mode.prompt_directive(request.locale),
        harness_name,
        request.role,
        request.source_prompt,
        request.objective,
        to_string_pretty(request.goal).unwrap_or_else(|_| "{}".into()),
        if request.attachment_paths.is_empty() {
            "(none)".into()
        } else {
            request
                .attachment_paths
                .iter()
                .map(|path| format!("- {}", path.display()))
                .collect::<Vec<_>>()
                .join("\n")
        },
        request.correction.unwrap_or("(none)"),
        if request.memory_context.trim().is_empty() {
            "(none)"
        } else {
            request.memory_context
        },
        if request.plugin_context.trim().is_empty() {
            "(none)"
        } else {
            request.plugin_context
        },
        recovery_context.unwrap_or("(none)"),
    )
}

/// Parse and remove the optional host-only result footer. Only the complete absence of both
/// marker tokens is legacy output. Once either token is present, every protocol invariant is
/// mandatory so a malformed save-as claim cannot silently become an additive companion.
fn parse_managed_loop_result(
    raw: &str,
    expected_run_id: Uuid,
) -> Result<(String, Vec<LoopArtifactReplacement>), LoopError> {
    let open_count = raw.matches(MANAGED_LOOP_RESULT_OPEN).count();
    let close_count = raw.matches(MANAGED_LOOP_RESULT_CLOSE).count();
    if open_count == 0 && close_count == 0 {
        if contains_unwrapped_managed_result(raw) {
            return Err(result_protocol_error(
                "managed result protocol object was emitted without the required footer markers",
            ));
        }
        return Ok((raw.trim().to_string(), Vec::new()));
    }
    if open_count != 1 || close_count != 1 {
        return Err(result_protocol_error(format!(
            "expected exactly one footer marker pair, found {open_count} opening and {close_count} closing markers"
        )));
    }

    let open = raw.find(MANAGED_LOOP_RESULT_OPEN).ok_or_else(|| {
        result_protocol_error("the managed result footer is missing its opening marker")
    })?;
    let payload_start = open + MANAGED_LOOP_RESULT_OPEN.len();
    let relative_close = raw[payload_start..]
        .find(MANAGED_LOOP_RESULT_CLOSE)
        .ok_or_else(|| result_protocol_error("the managed result footer closes before it opens"))?;
    let close = payload_start + relative_close;
    let footer_end = close + MANAGED_LOOP_RESULT_CLOSE.len();
    if !raw[footer_end..].trim().is_empty() {
        return Err(result_protocol_error(
            "the managed result footer must be the final output",
        ));
    }

    let envelope =
        serde_json::from_str::<ManagedLoopResultEnvelope>(raw[payload_start..close].trim())
            .map_err(|error| result_protocol_error(format!("invalid footer JSON: {error}")))?;
    if envelope.protocol != MANAGED_LOOP_RESULT_PROTOCOL {
        return Err(result_protocol_error(format!(
            "unsupported protocol {:?}; expected {MANAGED_LOOP_RESULT_PROTOCOL}",
            envelope.protocol
        )));
    }
    if envelope.run_id != expected_run_id {
        return Err(result_protocol_error(format!(
            "runId mismatch: expected {expected_run_id}, found {}",
            envelope.run_id
        )));
    }
    if envelope.replacements.len() > MAX_MANAGED_LOOP_REPLACEMENTS {
        return Err(result_protocol_error(format!(
            "too many replacements: maximum {MAX_MANAGED_LOOP_REPLACEMENTS}"
        )));
    }

    let mut new_paths = HashSet::new();
    let mut targets = HashSet::new();
    for replacement in &envelope.replacements {
        if !is_workspace_relative_result_path(&replacement.new_path) {
            return Err(result_protocol_error(format!(
                "newPath must be a normalized workspace-relative file path: {:?}",
                replacement.new_path
            )));
        }
        let normalized_path = replacement.new_path.to_string_lossy().replace('\\', "/");
        if !new_paths.insert(normalized_path) {
            return Err(result_protocol_error(
                "the same newPath was declared more than once",
            ));
        }

        let selector = &replacement.replaces;
        if selector.value.is_empty()
            || selector.value.trim() != selector.value
            || selector.expected_raw_revision.is_empty()
            || selector.expected_raw_revision.trim() != selector.expected_raw_revision
        {
            return Err(result_protocol_error(
                "replacement selectors require non-empty, unpadded value and expectedRawRevision fields",
            ));
        }
        if selector.by == LoopArtifactSelectorKind::Id && Uuid::parse_str(&selector.value).is_err()
        {
            return Err(result_protocol_error(
                "an id selector value must be a valid UUID",
            ));
        }
        let selector_kind = match selector.by {
            LoopArtifactSelectorKind::Id => "id",
            LoopArtifactSelectorKind::LogicalKey => "logical_key",
            LoopArtifactSelectorKind::Path => "path",
        };
        if !targets.insert(format!("{selector_kind}\0{}", selector.value)) {
            return Err(result_protocol_error(
                "the same current artifact target was claimed more than once",
            ));
        }
    }

    let text = raw[..open].trim();
    if text.is_empty() {
        return Err(result_protocol_error(
            "the footer must follow a human-readable result",
        ));
    }
    Ok((text.to_string(), envelope.replacements))
}

fn contains_unwrapped_managed_result(raw: &str) -> bool {
    let has_protocol_intent = raw.contains("lingshu.managed-loop-result.")
        && raw.contains("runId")
        && raw.contains("replacements");
    if has_protocol_intent {
        return true;
    }
    if !raw.contains(MANAGED_LOOP_RESULT_PROTOCOL) {
        return false;
    }
    let trimmed = raw.trim();
    if parsed_value_is_managed_result(trimmed) {
        return true;
    }
    if let Some(block) = trailing_fenced_block(trimmed) {
        if parsed_value_is_managed_result(block) {
            return true;
        }
    }
    trimmed
        .char_indices()
        .rev()
        .filter(|(_, character)| *character == '{')
        .any(|(index, _)| parsed_value_is_managed_result(&trimmed[index..]))
}

fn parsed_value_is_managed_result(candidate: &str) -> bool {
    let Ok(serde_json::Value::Object(object)) =
        serde_json::from_str::<serde_json::Value>(candidate.trim())
    else {
        return false;
    };
    object.get("protocol").and_then(|value| value.as_str()) == Some(MANAGED_LOOP_RESULT_PROTOCOL)
        && object.contains_key("runId")
        && object.contains_key("replacements")
}

fn trailing_fenced_block(raw: &str) -> Option<&str> {
    let without_close = raw.strip_suffix("```")?.trim_end();
    let open = without_close.rfind("```")?;
    let mut block = without_close[open + 3..].trim();
    if let Some((language, content)) = block.split_once('\n') {
        if language.trim().eq_ignore_ascii_case("json") {
            block = content.trim();
        }
    }
    Some(block)
}

fn result_protocol_error(detail: impl Into<String>) -> LoopError {
    LoopError::ResultProtocol(detail.into())
}

fn is_workspace_relative_result_path(path: &Path) -> bool {
    let value = path.to_string_lossy();
    if value.is_empty()
        || value.trim() != value
        || value.contains('\0')
        || path.is_absolute()
        || value.starts_with('/')
        || value.starts_with('\\')
        || value.as_bytes().get(1) == Some(&b':')
    {
        return false;
    }
    value
        .split(|character| character == '/' || character == '\\')
        .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
}

fn codex_exec_args(
    workspace: &Path,
    output_path: &Path,
    permission_mode: ExecutionPermissionMode,
    model: &str,
    gateway_base_url: &str,
) -> Vec<String> {
    let mut args = vec![
        "exec".to_string(),
        "--ignore-user-config".into(),
        "--ignore-rules".into(),
        "-c".into(),
        format!("model_provider={}", toml_string("lingshu")),
        "-c".into(),
        format!(
            "model_providers.lingshu.name={}",
            toml_string("LingShu Managed Loop Transport")
        ),
        "-c".into(),
        format!(
            "model_providers.lingshu.base_url={}",
            toml_string(gateway_base_url)
        ),
        "-c".into(),
        "model_providers.lingshu.env_key=\"LINGSHU_LOOP_GATEWAY_TOKEN\"".into(),
        "-c".into(),
        "model_providers.lingshu.wire_api=\"responses\"".into(),
        "-c".into(),
        "model_providers.lingshu.requires_openai_auth=false".into(),
        "--model".into(),
        model.into(),
    ];
    match permission_mode {
        ExecutionPermissionMode::Sandbox => {
            args.push("--sandbox".into());
            args.push("workspace-write".into());
        }
        ExecutionPermissionMode::FullAccess => {
            args.push("--dangerously-bypass-approvals-and-sandbox".into());
        }
    }
    args.extend([
        "--skip-git-repo-check".into(),
        "--ephemeral".into(),
        "--cd".into(),
        workspace.to_string_lossy().into_owned(),
        "--output-last-message".into(),
        output_path.to_string_lossy().into_owned(),
        "-".into(),
    ]);
    args
}

fn toml_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', "\\\\").replace('"', "\\\""))
}

async fn run_harness_process(
    mut process: tokio::process::Command,
    prompt: &str,
    harness_name: &str,
    timeout_seconds: u64,
) -> Result<std::process::Output, LoopError> {
    let (mut child, _process_tree) = spawn_tokio_process_tree(&mut process)
        .map_err(|error| LoopError::Execution(error.to_string()))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(prompt.as_bytes()).await?;
    }
    tokio::time::timeout(
        Duration::from_secs(timeout_seconds),
        child.wait_with_output(),
    )
    .await
    .map_err(|_| {
        LoopError::Execution(format!(
            "{harness_name} harness timed out after {timeout_seconds} seconds"
        ))
    })?
    .map_err(LoopError::Io)
}

fn remove_native_provider_environment(process: &mut tokio::process::Command) {
    for variable in [
        "OPENAI_API_KEY",
        "OPENAI_BASE_URL",
        "OPENAI_ORG_ID",
        "OPENAI_ORGANIZATION",
        "CODEX_API_KEY",
        "CHATGPT_ACCESS_TOKEN",
        "CHATGPT_ACCOUNT_ID",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "XAI_API_KEY",
        "XAI_BASE_URL",
        "GROK_API_KEY",
        "DEEPSEEK_API_KEY",
        "DEEPSEEK_BASE_URL",
        "MINIMAX_API_KEY",
        "MINIMAX_BASE_URL",
    ] {
        process.env_remove(variable);
    }
}

fn restrict_private_directory(path: &Path) -> Result<(), std::io::Error> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

fn executable_candidate(path: &Path) -> bool {
    path.is_file()
}

fn executable_name(command: &str) -> String {
    if cfg!(windows) {
        format!("{command}.exe")
    } else {
        command.into()
    }
}

fn find_on_path(command: &str) -> Option<PathBuf> {
    let path = env::var_os("PATH")?;
    let names = if cfg!(windows) {
        let extensions = env::var_os("PATHEXT")
            .map(|value| {
                value
                    .to_string_lossy()
                    .split(';')
                    .filter(|item| !item.trim().is_empty())
                    .map(|item| item.to_ascii_lowercase())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| vec![".exe".into(), ".cmd".into(), ".bat".into()]);
        extensions
            .into_iter()
            .map(|extension| format!("{command}{extension}"))
            .collect::<Vec<_>>()
    } else {
        vec![command.into()]
    };
    env::split_paths(&path)
        .flat_map(|directory| names.iter().map(move |name| directory.join(name)))
        .find(|candidate| executable_candidate(candidate))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::{GoalKind, OutputMode, ReferenceConfidence, ReferenceScope};
    use std::process::{Command as StdCommand, Stdio as StdStdio};
    use tempfile::tempdir;

    const PROCESS_TREE_HOME_ENV: &str = "LINGSHU_TEST_LOOP_TREE_HOME";
    const PROCESS_TREE_GRANDCHILD_ENV: &str = "LINGSHU_TEST_LOOP_TREE_GRANDCHILD";
    const PROCESS_TREE_STARTED_FILE: &str = "loop-grandchild-started.txt";
    const PROCESS_TREE_LATE_FILE: &str = "loop-grandchild-late.txt";

    struct ProcessTreeFixtureAdapter {
        executable: PathBuf,
    }

    impl ManagedExternalHarnessAdapter for ProcessTreeFixtureAdapter {
        fn kind(&self) -> LoopEngineKind {
            LoopEngineKind::Codex
        }

        fn name(&self) -> &'static str {
            "ProcessTreeFixture"
        }

        fn executable(&self) -> Option<&Path> {
            Some(&self.executable)
        }

        fn isolated_home_variable(&self) -> &'static str {
            PROCESS_TREE_HOME_ENV
        }

        fn timeout_seconds(&self) -> u64 {
            30
        }

        fn arguments(&self, _invocation: &ManagedHarnessInvocation<'_>) -> Vec<String> {
            vec![
                "--exact".into(),
                "loops::tests::process_tree_fixture".into(),
                "--nocapture".into(),
            ]
        }
    }

    /// Executed in a nested copy of this test binary by the managed-harness cancellation test.
    #[test]
    fn process_tree_fixture() {
        if std::env::var_os(PROCESS_TREE_HOME_ENV).is_none() {
            return;
        }
        let workspace = PathBuf::from(
            std::env::var_os("LINGSHU_WORKSPACE").expect("fixture workspace must be configured"),
        );
        if std::env::var_os(PROCESS_TREE_GRANDCHILD_ENV).is_some() {
            fs::write(workspace.join(PROCESS_TREE_STARTED_FILE), "started").unwrap();
            std::thread::sleep(Duration::from_millis(800));
            fs::write(workspace.join(PROCESS_TREE_LATE_FILE), "survived").unwrap();
            return;
        }

        let mut grandchild = StdCommand::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "loops::tests::process_tree_fixture",
                "--nocapture",
            ])
            .env(PROCESS_TREE_GRANDCHILD_ENV, "1")
            .stdin(StdStdio::null())
            .stdout(StdStdio::null())
            .stderr(StdStdio::null())
            .spawn()
            .unwrap();
        std::thread::sleep(Duration::from_secs(30));
        let _ = grandchild.wait();
    }

    async fn wait_for_fixture_file(path: &Path) {
        tokio::time::timeout(Duration::from_secs(5), async {
            while !path.is_file() {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("fixture grandchild did not start");
    }

    fn goal() -> GoalSpec {
        GoalSpec {
            objective: "Create a verified file".into(),
            kind: GoalKind::Task,
            output_mode: OutputMode::Artifact,
            reference_scope: ReferenceScope::CurrentInput,
            reference_evidence: Vec::new(),
            reference_explicit: true,
            reference_confidence: ReferenceConfidence::High,
            constraints: Vec::new(),
            boundaries: Vec::new(),
            risks: Vec::new(),
            success_criteria: vec!["The file exists".into()],
            open_questions: Vec::new(),
        }
    }

    fn test_receipt(
        receipt_id: LoopReceiptId,
        workspace: &Path,
        state: ManagedLoopReceiptState,
    ) -> ManagedLoopReceipt {
        ManagedLoopReceipt {
            protocol: MANAGED_LOOP_RECEIPT_PROTOCOL.into(),
            generation: 1,
            receipt_id,
            engine: LoopEngineKind::Codex,
            workspace: receipt_workspace_identity(workspace),
            state,
            created_at_millis: unix_time_millis(),
            text: String::new(),
            artifact_paths: Vec::new(),
            artifact_replacements: Vec::new(),
            error: None,
            baseline: ReceiptWorkspaceBaseline::default(),
        }
    }

    #[test]
    fn every_registered_loop_has_the_same_lingshu_owned_harness_policy() {
        let data = tempdir().unwrap();
        let registry = LoopRegistry::new(data.path(), std::env::consts::OS).unwrap();
        let records = registry.list(LoopEngineKind::Grok);
        let grok = records
            .iter()
            .find(|record| record.id == LoopEngineKind::Grok)
            .unwrap();
        assert!(grok.available);
        assert!(grok.selected);
        assert_eq!(grok.execution_mode, "in_process");
        for record in records {
            assert!(record.harness_only);
            assert_eq!(
                record.transport_owner,
                ManagedHarnessPolicy::LINGSHU_OWNED.transport_owner
            );
            assert!(record.native_auth_disabled);
            assert!(record.native_quota_disabled);
        }
    }

    #[test]
    fn codex_permission_arguments_are_forwarded_without_ambiguity() {
        let workspace = Path::new("/tmp/workspace");
        let output = Path::new("/tmp/output.txt");
        let sandbox = codex_exec_args(
            workspace,
            output,
            ExecutionPermissionMode::Sandbox,
            "test-model",
            "http://127.0.0.1:1234/v1",
        );
        assert!(sandbox
            .windows(2)
            .any(|pair| pair == ["--sandbox", "workspace-write"]));
        assert!(!sandbox
            .iter()
            .any(|value| value == "--dangerously-bypass-approvals-and-sandbox"));
        assert!(sandbox.iter().any(|value| value == "--ignore-user-config"));
        assert!(sandbox
            .iter()
            .any(|value| value == "model_providers.lingshu.requires_openai_auth=false"));
        assert!(sandbox
            .iter()
            .any(|value| value.contains("127.0.0.1:1234/v1")));

        let full = codex_exec_args(
            workspace,
            output,
            ExecutionPermissionMode::FullAccess,
            "test-model",
            "http://127.0.0.1:1234/v1",
        );
        assert!(full
            .iter()
            .any(|value| value == "--dangerously-bypass-approvals-and-sandbox"));
        assert!(!full.iter().any(|value| value == "--sandbox"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn codex_adapter_collects_the_final_message_and_changed_artifact() {
        use std::os::unix::fs::PermissionsExt;

        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let script = data.path().join("fake-codex");
        fs::write(
            &script,
            r#"#!/bin/sh
out=""
if [ -z "$CODEX_HOME" ] || [ -z "$LINGSHU_LOOP_GATEWAY_TOKEN" ]; then
  exit 90
fi
if [ -n "$OPENAI_API_KEY" ] || [ -n "$CODEX_API_KEY" ] || [ -n "$CHATGPT_ACCESS_TOKEN" ]; then
  exit 91
fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
printf 'fake codex completed' > "$out"
printf 'verified artifact' > "$PWD/codex-artifact.md"
"#,
        )
        .unwrap();
        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script, permissions).unwrap();

        let registry = LoopRegistry::new(data.path(), "macos").unwrap();
        let adapter = CodexLoopAdapter {
            executable: Some(script),
        };
        let goal = goal();
        let settings = RuntimeSettings::default();
        let task_id = Uuid::new_v4();
        let result = registry
            .run_managed_external_harness(
                &adapter,
                LoopExecutionRequest {
                    task_id,
                    workspace: workspace.path(),
                    source_prompt: "Create a file",
                    attachment_paths: &[],
                    objective: "Create a file",
                    role: "Engineer",
                    goal: &goal,
                    correction: None,
                    memory_context: "",
                    plugin_context: "",
                    locale: AppLocale::En,
                    permission_mode: ExecutionPermissionMode::Sandbox,
                    settings: &settings,
                    api_key: Some("provider-secret-must-stay-in-gateway"),
                },
            )
            .await
            .unwrap();
        assert_eq!(result.text, "fake codex completed");
        assert_eq!(
            result.artifact_paths,
            vec![PathBuf::from("codex-artifact.md")]
        );
        assert!(result.artifact_replacements.is_empty());
        assert_eq!(result.receipt_id.task_id, task_id);
        registry
            .acknowledge_receipt(result.receipt_id)
            .await
            .unwrap();
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cancelling_managed_harness_kills_its_delayed_grandchild() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let registry = Arc::new(LoopRegistry::new(data.path(), std::env::consts::OS).unwrap());
        let workspace_path = workspace.path().to_path_buf();
        let harness_registry = registry.clone();
        let harness = tokio::spawn(async move {
            let adapter = ProcessTreeFixtureAdapter {
                executable: std::env::current_exe().unwrap(),
            };
            let goal = goal();
            let settings = RuntimeSettings::default();
            harness_registry
                .run_managed_external_harness(
                    &adapter,
                    LoopExecutionRequest {
                        task_id: Uuid::new_v4(),
                        workspace: &workspace_path,
                        source_prompt: "Wait until cancelled",
                        attachment_paths: &[],
                        objective: "Exercise process-tree cancellation",
                        role: "Fixture",
                        goal: &goal,
                        correction: None,
                        memory_context: "",
                        plugin_context: "",
                        locale: AppLocale::En,
                        permission_mode: ExecutionPermissionMode::Sandbox,
                        settings: &settings,
                        api_key: None,
                    },
                )
                .await
        });

        wait_for_fixture_file(&workspace.path().join(PROCESS_TREE_STARTED_FILE)).await;
        harness.abort();
        assert!(harness.await.unwrap_err().is_cancelled());
        tokio::time::sleep(Duration::from_millis(1_200)).await;

        assert!(!workspace.path().join(PROCESS_TREE_LATE_FILE).exists());
    }

    #[tokio::test]
    async fn ready_receipt_replays_without_a_harness_and_acknowledgement_is_idempotent() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        fs::write(workspace.path().join("ready.md"), "durable result").unwrap();
        let registry = LoopRegistry::new(data.path(), std::env::consts::OS).unwrap();
        let receipt_id = LoopReceiptId {
            task_id: Uuid::new_v4(),
            run_id: Uuid::new_v4(),
        };
        let mut receipt =
            test_receipt(receipt_id, workspace.path(), ManagedLoopReceiptState::Ready);
        receipt.text = "replay me".into();
        receipt.artifact_paths = vec![PathBuf::from("ready.md")];
        let run_root = receipt_run_root(registry.scratch_root.as_ref(), receipt_id);
        persist_receipt(&run_root, &receipt).unwrap();

        let adapter = CodexLoopAdapter { executable: None };
        let goal = goal();
        let settings = RuntimeSettings::default();
        let result = registry
            .run_managed_external_harness(
                &adapter,
                LoopExecutionRequest {
                    task_id: receipt_id.task_id,
                    workspace: workspace.path(),
                    source_prompt: "Replay the durable result",
                    attachment_paths: &[],
                    objective: "Replay the durable result",
                    role: "Maker",
                    goal: &goal,
                    correction: None,
                    memory_context: "",
                    plugin_context: "",
                    locale: AppLocale::En,
                    permission_mode: ExecutionPermissionMode::Sandbox,
                    settings: &settings,
                    api_key: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.text, "replay me");
        assert_eq!(result.artifact_paths, vec![PathBuf::from("ready.md")]);
        assert_eq!(result.receipt_id, receipt_id);

        registry.acknowledge_receipt(receipt_id).await.unwrap();
        assert!(!run_root.exists());
        registry.acknowledge_receipt(receipt_id).await.unwrap();
    }

    #[tokio::test]
    async fn interrupted_running_receipt_recovers_delta_and_ready_output_after_restart() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        fs::write(workspace.path().join("base.md"), "before").unwrap();
        let registry = LoopRegistry::new(data.path(), std::env::consts::OS).unwrap();
        let receipt_id = LoopReceiptId {
            task_id: Uuid::new_v4(),
            run_id: Uuid::new_v4(),
        };
        let mut receipt = test_receipt(
            receipt_id,
            workspace.path(),
            ManagedLoopReceiptState::Running,
        );
        receipt.baseline = receipt_workspace_baseline(workspace.path());
        let run_root = receipt_run_root(registry.scratch_root.as_ref(), receipt_id);
        persist_receipt(&run_root, &receipt).unwrap();

        fs::write(workspace.path().join("base.md"), "after").unwrap();
        fs::write(workspace.path().join("crash.md"), "new file").unwrap();
        let artifact_id = Uuid::new_v4();
        let final_text = format!(
            "recovered result\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}",
            json!({
                "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
                "runId": receipt_id.run_id,
                "replacements": [{
                    "newPath": "crash.md",
                    "replaces": {
                        "by": "id",
                        "value": artifact_id,
                        "expectedRawRevision": "raw-before-crash"
                    }
                }]
            })
        );
        fs::write(run_root.join("last-message.txt"), final_text).unwrap();

        let adapter = CodexLoopAdapter { executable: None };
        let goal = goal();
        let settings = RuntimeSettings::default();
        let result = registry
            .run_managed_external_harness(
                &adapter,
                LoopExecutionRequest {
                    task_id: receipt_id.task_id,
                    workspace: workspace.path(),
                    source_prompt: "Recover interrupted work",
                    attachment_paths: &[],
                    objective: "Recover interrupted work",
                    role: "Maker",
                    goal: &goal,
                    correction: None,
                    memory_context: "",
                    plugin_context: "",
                    locale: AppLocale::En,
                    permission_mode: ExecutionPermissionMode::Sandbox,
                    settings: &settings,
                    api_key: None,
                },
            )
            .await
            .unwrap();
        assert_eq!(result.text, "recovered result");
        assert_eq!(
            result.artifact_paths,
            vec![PathBuf::from("base.md"), PathBuf::from("crash.md")]
        );
        assert_eq!(result.artifact_replacements.len(), 1);
        assert_eq!(
            result.artifact_replacements[0].new_path,
            Path::new("crash.md")
        );
        assert!(!run_root.join("last-message.txt").exists());
        registry.acknowledge_receipt(receipt_id).await.unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejected_receipt_injects_bounded_context_merges_paths_and_clears_old_run() {
        use std::os::unix::fs::PermissionsExt;

        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        fs::write(workspace.path().join("pending.md"), "pending").unwrap();
        let registry = LoopRegistry::new(data.path(), "macos").unwrap();
        let old_id = LoopReceiptId {
            task_id: Uuid::new_v4(),
            run_id: Uuid::new_v4(),
        };
        let mut old = test_receipt(old_id, workspace.path(), ManagedLoopReceiptState::Ready);
        old.text = "old result".into();
        old.artifact_paths = vec![PathBuf::from("pending.md")];
        let old_root = receipt_run_root(registry.scratch_root.as_ref(), old_id);
        persist_receipt(&old_root, &old).unwrap();
        registry
            .reject_receipt(
                old_id,
                "host atomic registration rejected the stale claim".into(),
            )
            .await
            .unwrap();

        let script = data.path().join("retry-codex");
        fs::write(
            &script,
            r#"#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
cat > "$PWD/recovery-prompt.txt"
printf 'retry completed' > "$out"
printf 'new result' > "$PWD/new.md"
"#,
        )
        .unwrap();
        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script, permissions).unwrap();

        let adapter = CodexLoopAdapter {
            executable: Some(script),
        };
        let goal = goal();
        let settings = RuntimeSettings::default();
        let result = registry
            .run_managed_external_harness(
                &adapter,
                LoopExecutionRequest {
                    task_id: old_id.task_id,
                    workspace: workspace.path(),
                    source_prompt: "Retry the rejected run",
                    attachment_paths: &[],
                    objective: "Retry the rejected run",
                    role: "Maker",
                    goal: &goal,
                    correction: None,
                    memory_context: "",
                    plugin_context: "",
                    locale: AppLocale::En,
                    permission_mode: ExecutionPermissionMode::Sandbox,
                    settings: &settings,
                    api_key: Some("provider-secret"),
                },
            )
            .await
            .unwrap();
        let paths = result.artifact_paths.iter().collect::<HashSet<_>>();
        assert!(paths.contains(&PathBuf::from("pending.md")));
        assert!(paths.contains(&PathBuf::from("new.md")));
        let prompt = fs::read_to_string(workspace.path().join("recovery-prompt.txt")).unwrap();
        assert!(prompt.contains("host atomic registration rejected the stale claim"));
        assert!(prompt.contains("pending.md"));
        assert!(!old_root.exists());
        assert!(receipt_run_root(registry.scratch_root.as_ref(), result.receipt_id).exists());
        registry
            .acknowledge_receipt(result.receipt_id)
            .await
            .unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn malformed_result_error_still_persists_the_workspace_delta() {
        use std::os::unix::fs::PermissionsExt;

        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let registry = LoopRegistry::new(data.path(), "macos").unwrap();
        let task_id = Uuid::new_v4();
        let script = data.path().join("malformed-codex");
        fs::write(
            &script,
            format!(
                r#"#!/bin/sh
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then
    out="$2"
    shift 2
  else
    shift
  fi
done
cat >/dev/null
printf 'orphan bytes' > "$PWD/orphan.md"
printf 'result
{MANAGED_LOOP_RESULT_OPEN}{{bad-json}}{MANAGED_LOOP_RESULT_CLOSE}' > "$out"
"#
            ),
        )
        .unwrap();
        let mut permissions = fs::metadata(&script).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script, permissions).unwrap();
        let adapter = CodexLoopAdapter {
            executable: Some(script),
        };
        let goal = goal();
        let settings = RuntimeSettings::default();
        let error = registry
            .run_managed_external_harness(
                &adapter,
                LoopExecutionRequest {
                    task_id,
                    workspace: workspace.path(),
                    source_prompt: "Produce a malformed result",
                    attachment_paths: &[],
                    objective: "Produce a malformed result",
                    role: "Maker",
                    goal: &goal,
                    correction: None,
                    memory_context: "",
                    plugin_context: "",
                    locale: AppLocale::En,
                    permission_mode: ExecutionPermissionMode::Sandbox,
                    settings: &settings,
                    api_key: Some("provider-secret"),
                },
            )
            .await
            .unwrap_err();
        assert!(matches!(error, LoopError::ResultProtocol(_)));

        let pending = prepare_pending_receipts(
            registry.scratch_root.as_ref(),
            task_id,
            &receipt_workspace_identity(workspace.path()),
        )
        .unwrap();
        assert!(pending.ready.is_none());
        assert_eq!(pending.failed.len(), 1);
        assert_eq!(
            pending.failed[0].artifact_paths,
            vec![PathBuf::from("orphan.md")]
        );
        assert!(pending.failed[0]
            .error
            .as_deref()
            .unwrap()
            .contains("protocol error"));
        let failed_root =
            receipt_run_root(registry.scratch_root.as_ref(), pending.failed[0].receipt_id);
        assert!(failed_root.is_dir());
        assert!(!failed_root.join("home").exists());
        assert!(!failed_root.join("last-message.txt").exists());
    }

    #[test]
    fn managed_harness_prompt_injects_the_run_bound_typed_result_protocol() {
        let goal = goal();
        let settings = RuntimeSettings::default();
        let run_id = Uuid::parse_str("9368bd8f-b2ee-4cd1-8602-1f78e340cc3a").unwrap();
        let request = LoopExecutionRequest {
            task_id: Uuid::new_v4(),
            workspace: Path::new("/tmp/workspace"),
            source_prompt: "Revise the deck",
            attachment_paths: &[],
            objective: "Revise the deck",
            role: "Maker",
            goal: &goal,
            correction: Some("Use an ivory theme"),
            memory_context: "",
            plugin_context: "",
            locale: AppLocale::En,
            permission_mode: ExecutionPermissionMode::Sandbox,
            settings: &settings,
            api_key: None,
        };

        let prompt = managed_harness_prompt("Codex", &request, run_id, None);
        assert!(prompt.contains(MANAGED_LOOP_RESULT_PROTOCOL));
        assert!(prompt.contains(&format!("Managed result run ID: {run_id}")));
        assert!(prompt.contains(&format!("\"runId\":\"{run_id}\"")));
        assert!(prompt.contains("\"newPath\":\"deliverables/deck-ivory.pptx\""));
        assert!(prompt.contains("\"expectedRawRevision\""));
        assert!(prompt.contains("id, logical_key, or path"));
        assert!(prompt.contains(MANAGED_LOOP_RESULT_OPEN));
        assert!(prompt.contains(MANAGED_LOOP_RESULT_CLOSE));
    }

    #[test]
    fn managed_result_parser_returns_typed_replacements_and_hides_the_footer() {
        let run_id = Uuid::parse_str("9368bd8f-b2ee-4cd1-8602-1f78e340cc3a").unwrap();
        let artifact_id = Uuid::parse_str("688a8059-03d6-4f3b-92f8-f86beb2ad9c0").unwrap();
        let raw = format!(
            "Revised the deck and verified all slides.\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}\n",
            json!({
                "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
                "runId": run_id,
                "replacements": [{
                    "newPath": "deliverables/deck-ivory.pptx",
                    "replaces": {
                        "by": "id",
                        "value": artifact_id,
                        "expectedRawRevision": "0123456789abcdef"
                    }
                }]
            })
        );

        let (text, replacements) = parse_managed_loop_result(&raw, run_id).unwrap();
        assert_eq!(text, "Revised the deck and verified all slides.");
        assert_eq!(
            replacements,
            vec![LoopArtifactReplacement {
                new_path: PathBuf::from("deliverables/deck-ivory.pptx"),
                replaces: LoopArtifactSelector {
                    by: LoopArtifactSelectorKind::Id,
                    value: artifact_id.to_string(),
                    expected_raw_revision: "0123456789abcdef".into(),
                },
            }]
        );
    }

    #[test]
    fn managed_result_parser_keeps_unmarked_legacy_text() {
        let run_id = Uuid::new_v4();
        let (text, replacements) =
            parse_managed_loop_result("\nlegacy harness result\n", run_id).unwrap();
        assert_eq!(text, "legacy harness result");
        assert!(replacements.is_empty());

        let protocol_prose = format!(
            "The documentation mentions {MANAGED_LOOP_RESULT_PROTOCOL}, but this is ordinary prose."
        );
        let (text, replacements) = parse_managed_loop_result(&protocol_prose, run_id).unwrap();
        assert_eq!(text, protocol_prose);
        assert!(replacements.is_empty());
    }

    #[test]
    fn managed_result_parser_rejects_an_unwrapped_protocol_object() {
        let run_id = Uuid::new_v4();
        let payload = json!({
            "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
            "runId": run_id,
            "replacements": []
        });
        for raw in [payload.to_string(), format!("human result\n{payload}")] {
            assert!(matches!(
                parse_managed_loop_result(&raw, run_id),
                Err(LoopError::ResultProtocol(_))
            ));
        }
    }

    #[test]
    fn managed_result_parser_rejects_an_unwrapped_final_json_code_block() {
        let run_id = Uuid::new_v4();
        let payload = json!({
            "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
            "runId": run_id,
            "replacements": []
        });
        let raw = format!("human result\n```json\n{payload}\n```");
        assert!(matches!(
            parse_managed_loop_result(&raw, run_id),
            Err(LoopError::ResultProtocol(_))
        ));
    }

    #[test]
    fn managed_result_parser_rejects_malformed_or_wrong_version_unwrapped_protocol_intent() {
        let run_id = Uuid::new_v4();
        let malformed = format!(
            "human result\n{{\"protocol\":\"{MANAGED_LOOP_RESULT_PROTOCOL}\",\"runId\":\"{run_id}\",\"replacements\":[BAD]}}"
        );
        let wrong_version = format!(
            "human result\n{{\"protocol\":\"lingshu.managed-loop-result.v2\",\"runId\":\"{run_id}\",\"replacements\":[]}}"
        );
        for raw in [malformed, wrong_version] {
            assert!(matches!(
                parse_managed_loop_result(&raw, run_id),
                Err(LoopError::ResultProtocol(_))
            ));
        }
    }

    #[test]
    fn managed_result_parser_rejects_every_malformed_marked_result() {
        let run_id = Uuid::parse_str("9368bd8f-b2ee-4cd1-8602-1f78e340cc3a").unwrap();
        let malformed = [
            format!("result\n{MANAGED_LOOP_RESULT_OPEN}{{not-json}}{MANAGED_LOOP_RESULT_CLOSE}"),
            format!("result\n{MANAGED_LOOP_RESULT_OPEN}{{}}{MANAGED_LOOP_RESULT_CLOSE}"),
            format!("result\n{MANAGED_LOOP_RESULT_OPEN}"),
            format!(
                "result\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}",
                json!({
                    "protocol": "lingshu.managed-loop-result.v2",
                    "runId": run_id,
                    "replacements": []
                })
            ),
            format!(
                "result\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}\ntrailing text",
                json!({
                    "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
                    "runId": run_id,
                    "replacements": []
                })
            ),
            format!(
                "result\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}",
                json!({
                    "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
                    "runId": run_id,
                    "replacements": [{
                        "newPath": "../deck.pptx",
                        "replaces": {
                            "by": "path",
                            "value": "/workspace/deck.pptx",
                            "expectedRawRevision": "revision"
                        }
                    }]
                })
            ),
            format!(
                "result\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}",
                json!({
                    "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
                    "runId": run_id,
                    "replacements": [{
                        "newPath": "deck-ivory.pptx",
                        "replaces": {
                            "by": "logical_key",
                            "value": "deck.pptx"
                        }
                    }]
                })
            ),
        ];

        for raw in malformed {
            assert!(
                matches!(
                    parse_managed_loop_result(&raw, run_id),
                    Err(LoopError::ResultProtocol(_))
                ),
                "marked output must not downgrade to legacy text: {raw}"
            );
        }
    }

    #[test]
    fn managed_result_parser_rejects_a_footer_from_another_run() {
        let expected_run_id = Uuid::parse_str("9368bd8f-b2ee-4cd1-8602-1f78e340cc3a").unwrap();
        let wrong_run_id = Uuid::parse_str("8955592d-22b9-478d-b523-fe3b955f2313").unwrap();
        let raw = format!(
            "result\n{MANAGED_LOOP_RESULT_OPEN}{}{MANAGED_LOOP_RESULT_CLOSE}",
            json!({
                "protocol": MANAGED_LOOP_RESULT_PROTOCOL,
                "runId": wrong_run_id,
                "replacements": []
            })
        );

        let error = parse_managed_loop_result(&raw, expected_run_id).unwrap_err();
        assert!(matches!(error, LoopError::ResultProtocol(_)));
        assert!(error.to_string().contains("runId mismatch"));
    }

    #[test]
    fn every_registered_loop_uses_the_same_lingshu_owned_boundary() {
        let data = tempdir().unwrap();
        let registry = LoopRegistry::new(data.path(), std::env::consts::OS).unwrap();
        for record in registry.list(LoopEngineKind::Grok) {
            assert!(record.harness_only, "{} is not harness-only", record.name);
            assert_eq!(record.transport_owner, "lingshu", "{}", record.name);
            assert!(record.native_auth_disabled, "{}", record.name);
            assert!(record.native_quota_disabled, "{}", record.name);
        }
    }
}
