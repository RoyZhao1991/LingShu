use crate::loop_gateway::{LoopGatewayError, LoopTransportGateway};
use crate::models::{
    AppLocale, ExecutionPermissionMode, GoalSpec, LoopEngineKind, LoopEngineRecord, RuntimeSettings,
};
use crate::workspace_delta::{WorkspaceBaseline, WorkspaceDeltaTracker};
use serde_json::to_string_pretty;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

const DEFAULT_HARNESS_TIMEOUT_SECONDS: u64 = 900;
const LOOP_TRANSPORT_OWNER: &str = "lingshu";

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
    #[error("loop engine filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Gateway(#[from] LoopGatewayError),
}

#[derive(Debug, Clone)]
pub struct LoopExecution {
    pub text: String,
    pub artifact_paths: Vec<PathBuf>,
}

pub struct LoopExecutionRequest<'a> {
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
        let executable = adapter.executable().ok_or_else(|| {
            LoopError::Unavailable(format!(
                "{} harness was not found or did not satisfy the managed-harness contract",
                adapter.name()
            ))
        })?;
        fs::create_dir_all(request.workspace)?;
        let baseline = self.begin_workspace_delta(request.workspace).await;
        let run_id = Uuid::new_v4();
        let run_root = self
            .scratch_root
            .join(format!("{}-{run_id}", adapter.kind().as_str()));
        let isolated_home = run_root.join("home");
        fs::create_dir_all(&isolated_home)?;
        restrict_private_directory(&run_root)?;
        let output_path = run_root.join("last-message.txt");
        let gateway = LoopTransportGateway::start(
            request.settings.clone(),
            request.api_key.map(str::to_string),
        )
        .await?;
        let gateway_base_url = gateway.base_url();
        let prompt = managed_harness_prompt(adapter.name(), &request);
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
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        remove_native_provider_environment(&mut process);
        let output =
            run_harness_process(process, &prompt, adapter.name(), adapter.timeout_seconds()).await;
        gateway.stop().await;
        let output = output?;
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if !output.status.success() {
            let detail = if stderr.is_empty() { stdout } else { stderr };
            let _ = fs::remove_file(&output_path);
            let _ = fs::remove_dir_all(&run_root);
            return Err(LoopError::Execution(if detail.is_empty() {
                format!("{} harness exited with {}", adapter.name(), output.status)
            } else {
                detail
            }));
        }
        let text = fs::read_to_string(&output_path)
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(stdout);
        let _ = fs::remove_file(&output_path);
        if text.trim().is_empty() {
            let _ = fs::remove_dir_all(&run_root);
            return Err(LoopError::Execution(format!(
                "{} harness completed without a final response",
                adapter.name()
            )));
        }
        let artifact_paths = self.finish_workspace_delta(baseline).await;
        let _ = fs::remove_dir_all(&run_root);
        Ok(LoopExecution {
            text,
            artifact_paths,
        })
    }
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

fn managed_harness_prompt(harness_name: &str, request: &LoopExecutionRequest<'_>) -> String {
    format!(
        "{}\n{}\nYou are the {} Loop harness selected inside LingShu's shared Rust runtime. You contribute only the reasoning and tool-orchestration loop. LingShu owns and injects the model transport; never use, request, inspect, or mention the harness vendor's login, account, subscription, quota, native provider endpoint, or native provider credential. LingShu also owns the durable task ledger, memory, permissions, plugins, artifacts, verification, and child-session lifecycle. Execute the accepted session objective in the supplied Workspace, run useful validations, and leave reusable deliverables there. Do not ask the user directly; report a precise blocker when human action is indispensable. Never expose hidden chain-of-thought. End with a concise result, validation evidence, and exact artifact paths.\n\nSession role: {}\nOriginal user or parent request:\n{}\n\nSession objective:\n{}\n\nAccepted GoalSpec:\n{}\n\nAttachments:\n{}\n\nIndependent checker correction, when present:\n{}\n\nRelevant long-term memory (background only; current objective wins):\n{}\n\nRegistered shared plugin context:\n{}",
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
    )
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
    let mut child = process
        .spawn()
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
    use tempfile::tempdir;

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
        let result = registry
            .run_managed_external_harness(
                &adapter,
                LoopExecutionRequest {
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
