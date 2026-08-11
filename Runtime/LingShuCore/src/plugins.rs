use crate::artifacts::materialize_artifacts;
use crate::models::{
    AppLocale, ArtifactSpec, ExecutionPermissionMode, PluginPermissions, PluginRecord,
    PluginSource, PluginToolRecord,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::ffi::OsString;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use thiserror::Error;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

const PLUGIN_SCHEMA_VERSION: u32 = 1;
const OFFICE_FOUNDATION_ID: &str = "lingshu.office-foundation";
const OFFICE_WORD_TOOL: &str = "create_word_document";
const OFFICE_PRESENTATION_TOOL: &str = "create_basic_presentation";
const OFFICE_SPREADSHEET_TOOL: &str = "create_spreadsheet";
const DESIGN_KB_ID: &str = "lingshu.design-kb";
const DESIGN_KB_TOOL: &str = "create_designed_presentation";

#[derive(Debug, Error)]
pub enum PluginError {
    #[error("plugin manifest is invalid: {0}")]
    InvalidManifest(String),
    #[error("plugin was not found: {0}")]
    NotFound(String),
    #[error("plugin filesystem operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("plugin data is invalid: {0}")]
    Json(#[from] serde_json::Error),
    #[error("plugin execution failed: {0}")]
    Execution(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginManifest {
    #[serde(default = "default_schema_version")]
    schema_version: u32,
    id: String,
    name: String,
    version: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    description_zh: String,
    #[serde(default = "default_enabled")]
    enabled: bool,
    #[serde(default)]
    aliases: Vec<String>,
    #[serde(default)]
    permissions: PluginPermissions,
    entrypoint: PluginEntrypoint,
    #[serde(default)]
    tools: Vec<PluginToolManifest>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginEntrypoint {
    command: String,
    #[serde(default)]
    arguments: Vec<String>,
    #[serde(default = "default_timeout_seconds")]
    timeout_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PluginToolManifest {
    name: String,
    description: String,
    #[serde(default)]
    description_zh: String,
    #[serde(default = "empty_object_schema")]
    parameters: Value,
    #[serde(default)]
    capabilities: Vec<String>,
    #[serde(default)]
    priority: i32,
    #[serde(default)]
    fallback: bool,
}

#[derive(Debug)]
pub struct PluginExecution {
    pub output: String,
    pub artifact_paths: Vec<PathBuf>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PluginUsagePolicy {
    Required,
    Disabled,
}

impl PluginUsagePolicy {
    fn as_str(self) -> &'static str {
        match self {
            Self::Required => "required",
            Self::Disabled => "disabled_by_user",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PluginCapabilityRoute {
    pub capability: String,
    pub plugin_id: String,
    pub plugin_name: String,
    pub tool: PluginToolRecord,
    pub fallback: bool,
}

#[derive(Clone)]
pub struct PluginRegistry {
    user_root: Arc<PathBuf>,
    resource_root: Option<Arc<PathBuf>>,
    platform: Arc<String>,
}

impl PluginRegistry {
    pub fn new(
        data_dir: impl AsRef<Path>,
        resource_root: Option<PathBuf>,
        platform: impl Into<String>,
    ) -> Result<Self, PluginError> {
        let user_root = data_dir.as_ref().join("Plugins");
        fs::create_dir_all(&user_root)?;
        Ok(Self {
            user_root: Arc::new(user_root),
            resource_root: resource_root.map(Arc::new),
            platform: Arc::new(platform.into()),
        })
    }

    pub fn list(&self) -> Vec<PluginRecord> {
        let mut records = vec![office_foundation_record()];
        if let Some(root) = self.design_kb_root() {
            records.push(self.design_kb_record(root));
        } else {
            records.push(PluginRecord {
                id: DESIGN_KB_ID.into(),
                name: "DesignKB".into(),
                version: "1.0.0".into(),
                description: "LingShu's built-in presentation design system.".into(),
                description_zh: "灵枢内置的演示文稿设计系统。".into(),
                source: PluginSource::BuiltIn,
                enabled: true,
                available: false,
                runtime_ready: false,
                root_path: PathBuf::new(),
                permissions: design_kb_permissions(),
                tools: vec![design_kb_tool_record()],
                status_detail: "DesignKB resources are missing from this installation.".into(),
            });
        }
        records.extend(self.user_manifests().into_iter().map(|(root, manifest)| {
            let readiness = self.entrypoint_path(&root, &manifest.entrypoint.command);
            let available = readiness.is_some();
            PluginRecord {
                id: manifest.id.clone(),
                name: manifest.name.clone(),
                version: manifest.version.clone(),
                description: manifest.description.clone(),
                description_zh: manifest.description_zh.clone(),
                source: PluginSource::User,
                enabled: manifest.enabled,
                available,
                runtime_ready: available,
                root_path: root,
                permissions: manifest.permissions.clone(),
                tools: manifest
                    .tools
                    .iter()
                    .map(|tool| PluginToolRecord {
                        name: tool.name.clone(),
                        exposed_name: exposed_tool_name(&manifest.id, &tool.name),
                        description: tool.description.clone(),
                        description_zh: tool.description_zh.clone(),
                        parameters: tool.parameters.clone(),
                        capabilities: tool.capabilities.clone(),
                        priority: tool.priority,
                        fallback: tool.fallback,
                    })
                    .collect(),
                status_detail: if available {
                    "Ready".into()
                } else {
                    format!("Entrypoint is unavailable: {}", manifest.entrypoint.command)
                },
            }
        }));
        records.sort_by(|left, right| {
            source_rank(&left.source)
                .cmp(&source_rank(&right.source))
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
        });
        records
    }

    pub fn enabled_tools(&self) -> Vec<PluginToolRecord> {
        self.list()
            .into_iter()
            .filter(|plugin| plugin.enabled && plugin.available && plugin.runtime_ready)
            .flat_map(|plugin| plugin.tools)
            .collect()
    }

    pub fn routed_tools(&self, policy: PluginUsagePolicy) -> Vec<PluginToolRecord> {
        if policy == PluginUsagePolicy::Disabled {
            return Vec::new();
        }
        let tools = self.enabled_tools();
        let capabilities = tools
            .iter()
            .flat_map(|tool| tool.capabilities.iter().cloned())
            .collect::<BTreeSet<_>>();
        let selected = capabilities
            .iter()
            .filter_map(|capability| self.resolve_capability(capability, policy))
            .map(|route| route.tool.exposed_name)
            .collect::<BTreeSet<_>>();
        tools
            .into_iter()
            .filter(|tool| tool.capabilities.is_empty() || selected.contains(&tool.exposed_name))
            .collect()
    }

    pub fn resolve_capability(
        &self,
        capability: &str,
        policy: PluginUsagePolicy,
    ) -> Option<PluginCapabilityRoute> {
        self.capability_routes(capability, policy)
            .into_iter()
            .next()
    }

    pub fn prompt_context(&self, locale: AppLocale) -> String {
        let enabled = self
            .list()
            .into_iter()
            .filter(|plugin| plugin.enabled && plugin.available && plugin.runtime_ready)
            .collect::<Vec<_>>();
        if enabled.is_empty() {
            return match locale {
                AppLocale::ZhCn => "当前没有可用插件。".into(),
                AppLocale::En => "No plugins are currently available.".into(),
            };
        }
        let mut lines = match locale {
            AppLocale::ZhCn => vec!["已注册且可调用的插件能力：".to_string()],
            AppLocale::En => vec!["Registered and callable plugin capabilities:".to_string()],
        };
        for plugin in enabled {
            let description =
                if locale == AppLocale::ZhCn && !plugin.description_zh.trim().is_empty() {
                    &plugin.description_zh
                } else {
                    &plugin.description
                };
            let tools = plugin
                .tools
                .iter()
                .map(|tool| {
                    let capabilities = if tool.capabilities.is_empty() {
                        String::new()
                    } else {
                        format!(" [{}]", tool.capabilities.join(", "))
                    };
                    format!("{}{}", tool.exposed_name, capabilities)
                })
                .collect::<Vec<_>>()
                .join(", ");
            lines.push(format!(
                "- {} {}: {} Tools: {}",
                plugin.name, plugin.version, description, tools
            ));
        }
        lines.push(match locale {
            AppLocale::ZhCn => "插件路由硬约束：只要所需能力存在已启用、可用且运行就绪的插件，就必须调用插件；同一能力由运行时选择优先级最高的非兜底插件。基础能力只在没有更高优先级实现或其执行失败时兜底。仅当用户在当前请求中明确要求不使用插件时，才允许绕过插件。".into(),
            AppLocale::En => "Hard plugin-routing invariant: whenever an enabled, available, runtime-ready plugin provides the required capability, the plugin must be used. The runtime selects the highest-priority non-fallback provider for that capability. Foundation capabilities are fallback-only when no higher-priority implementation is ready or execution fails. Bypass plugins only when the user explicitly requests no plugins in the current request.".into(),
        });
        lines.join("\n")
    }

    pub fn install(&self, manifest_path: impl AsRef<Path>) -> Result<PluginRecord, PluginError> {
        let manifest_path = manifest_path.as_ref();
        if !manifest_path.is_file() {
            return Err(PluginError::InvalidManifest(format!(
                "manifest does not exist: {}",
                manifest_path.display()
            )));
        }
        let manifest = read_manifest(manifest_path)?;
        validate_manifest(&manifest)?;
        let source_root = manifest_path.parent().ok_or_else(|| {
            PluginError::InvalidManifest("manifest has no parent directory".into())
        })?;
        let target = self.user_root.join(&manifest.id);
        if target.exists() {
            return Err(PluginError::InvalidManifest(format!(
                "plugin {} is already installed",
                manifest.id
            )));
        }
        copy_directory(source_root, &target)?;
        self.list()
            .into_iter()
            .find(|record| record.id == manifest.id)
            .ok_or(PluginError::NotFound(manifest.id))
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<PluginRecord, PluginError> {
        if is_builtin_plugin(id) {
            if !enabled {
                return Err(PluginError::InvalidManifest(
                    "built-in LingShu plugins cannot be disabled".into(),
                ));
            }
            return self
                .list()
                .into_iter()
                .find(|record| record.id == id)
                .ok_or_else(|| PluginError::NotFound(id.into()));
        }
        let manifest_path = self.user_root.join(id).join("plugin.json");
        let mut manifest = read_manifest(&manifest_path)?;
        manifest.enabled = enabled;
        write_manifest(&manifest_path, &manifest)?;
        self.list()
            .into_iter()
            .find(|record| record.id == id)
            .ok_or_else(|| PluginError::NotFound(id.into()))
    }

    pub fn remove(&self, id: &str) -> Result<(), PluginError> {
        if is_builtin_plugin(id) {
            return Err(PluginError::InvalidManifest(
                "built-in LingShu plugins cannot be removed".into(),
            ));
        }
        validate_plugin_id(id)?;
        let target = self.user_root.join(id);
        if !target.is_dir() {
            return Err(PluginError::NotFound(id.into()));
        }
        fs::remove_dir_all(target)?;
        Ok(())
    }

    pub fn probe(&self, id: &str) -> Result<PluginRecord, PluginError> {
        self.list()
            .into_iter()
            .find(|record| record.id == id)
            .ok_or_else(|| PluginError::NotFound(id.into()))
    }

    pub async fn execute(
        &self,
        exposed_name: &str,
        arguments: Value,
        workspace: &Path,
        permission_mode: ExecutionPermissionMode,
    ) -> Result<PluginExecution, PluginError> {
        self.execute_exact(exposed_name, arguments, workspace, permission_mode)
            .await
    }

    pub async fn execute_capability(
        &self,
        capability: &str,
        arguments: Value,
        workspace: &Path,
        permission_mode: ExecutionPermissionMode,
        policy: PluginUsagePolicy,
        routed_from: &str,
    ) -> Result<PluginExecution, PluginError> {
        let routes = self.capability_routes(capability, policy);
        if routes.is_empty() {
            return Err(PluginError::NotFound(format!(
                "no runtime-ready plugin provides capability {capability}"
            )));
        }
        let mut attempts = Vec::new();
        let mut last_error = None;
        for route in routes {
            match self
                .execute_exact(
                    &route.tool.exposed_name,
                    arguments.clone(),
                    workspace,
                    permission_mode,
                )
                .await
            {
                Ok(mut execution) => {
                    let state = plugin_output_state(&execution.output);
                    attempts.push(json!({
                        "providerId": route.plugin_id.clone(),
                        "providerTool": route.tool.exposed_name.clone(),
                        "result": if state.retry_with_revised_input {
                            "revision_requested"
                        } else if state.rejected {
                            "rejected"
                        } else {
                            "completed"
                        }
                    }));
                    if !state.rejected || state.needs_user_action || state.retry_with_revised_input
                    {
                        execution.output = annotate_plugin_routing(
                            &execution.output,
                            capability,
                            &route,
                            policy,
                            routed_from,
                            attempts,
                        );
                        return Ok(execution);
                    }
                    last_error = Some(format!(
                        "{} rejected the request: {}",
                        route.plugin_name, execution.output
                    ));
                }
                Err(error) => {
                    attempts.push(json!({
                        "providerId": route.plugin_id.clone(),
                        "providerTool": route.tool.exposed_name.clone(),
                        "result": "failed",
                        "error": error.to_string()
                    }));
                    last_error = Some(error.to_string());
                }
            }
        }
        Err(PluginError::Execution(last_error.unwrap_or_else(|| {
            format!("all providers for capability {capability} failed")
        })))
    }

    async fn execute_exact(
        &self,
        exposed_name: &str,
        arguments: Value,
        workspace: &Path,
        permission_mode: ExecutionPermissionMode,
    ) -> Result<PluginExecution, PluginError> {
        if matches!(
            exposed_name,
            OFFICE_WORD_TOOL | OFFICE_PRESENTATION_TOOL | OFFICE_SPREADSHEET_TOOL
        ) {
            return execute_office_foundation(exposed_name, arguments, workspace);
        }
        if exposed_name == DESIGN_KB_TOOL {
            return self
                .execute_design_kb(arguments, workspace, permission_mode)
                .await;
        }
        let (root, manifest, tool) = self
            .user_manifests()
            .into_iter()
            .find_map(|(root, manifest)| {
                let tool = manifest
                    .tools
                    .iter()
                    .find(|tool| exposed_tool_name(&manifest.id, &tool.name) == exposed_name)
                    .cloned()?;
                Some((root, manifest, tool))
            })
            .ok_or_else(|| PluginError::NotFound(exposed_name.into()))?;
        if !manifest.enabled {
            return Err(PluginError::Execution(format!(
                "plugin {} is disabled",
                manifest.name
            )));
        }
        if permission_mode == ExecutionPermissionMode::Sandbox
            && manifest.permissions.requires_full_access()
        {
            return Ok(PluginExecution {
                output: json!({
                    "ok": false,
                    "needs_user_action": true,
                    "required_capability": "full_access",
                    "plugin": manifest.name,
                    "reason": "This plugin declares network, shell, or system-sensitive access. Switch this session to Full Access and resume from the same checkpoint."
                })
                .to_string(),
                artifact_paths: Vec::new(),
            });
        }
        let executable = self
            .entrypoint_path(&root, &manifest.entrypoint.command)
            .ok_or_else(|| {
                PluginError::Execution(format!(
                    "plugin entrypoint is unavailable: {}",
                    manifest.entrypoint.command
                ))
            })?;
        let input = serde_json::to_string(&arguments)?;
        let mut process = tokio::process::Command::new(executable);
        for argument in &manifest.entrypoint.arguments {
            process.arg(expand_argument(
                argument, &root, workspace, &input, &arguments, &tool.name,
            ));
        }
        process
            .current_dir(workspace)
            .env("LINGSHU_PLUGIN_ID", &manifest.id)
            .env("LINGSHU_PLUGIN_TOOL", &tool.name)
            .env("LINGSHU_WORKSPACE", workspace)
            .env(
                "LINGSHU_EXECUTION_PERMISSION_MODE",
                permission_mode.as_str(),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = process
            .spawn()
            .map_err(|error| PluginError::Execution(error.to_string()))?;
        if let Some(mut stdin) = child.stdin.take() {
            stdin.write_all(input.as_bytes()).await?;
        }
        let output = tokio::time::timeout(
            Duration::from_secs(manifest.entrypoint.timeout_seconds.clamp(1, 600)),
            child.wait_with_output(),
        )
        .await
        .map_err(|_| PluginError::Execution("plugin execution timed out".into()))??;
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if !output.status.success() {
            return Err(PluginError::Execution(if stderr.is_empty() {
                format!("plugin exited with {}", output.status)
            } else {
                stderr
            }));
        }
        let artifact_paths = collect_artifact_paths(&stdout, workspace);
        Ok(PluginExecution {
            output: if stdout.is_empty() {
                json!({"ok":true,"message":"plugin completed"}).to_string()
            } else {
                stdout
            },
            artifact_paths,
        })
    }

    fn capability_routes(
        &self,
        capability: &str,
        policy: PluginUsagePolicy,
    ) -> Vec<PluginCapabilityRoute> {
        if policy == PluginUsagePolicy::Disabled {
            return Vec::new();
        }
        let mut routes = self
            .list()
            .into_iter()
            .filter(|plugin| plugin.enabled && plugin.available && plugin.runtime_ready)
            .flat_map(|plugin| {
                plugin.tools.into_iter().filter_map(move |tool| {
                    let matches = tool
                        .capabilities
                        .iter()
                        .any(|candidate| candidate == capability);
                    matches.then(|| PluginCapabilityRoute {
                        capability: capability.to_string(),
                        plugin_id: plugin.id.clone(),
                        plugin_name: plugin.name.clone(),
                        fallback: tool.fallback,
                        tool,
                    })
                })
            })
            .collect::<Vec<_>>();
        routes.sort_by(|left, right| {
            left.fallback
                .cmp(&right.fallback)
                .then_with(|| right.tool.priority.cmp(&left.tool.priority))
                .then_with(|| left.plugin_id.cmp(&right.plugin_id))
                .then_with(|| left.tool.exposed_name.cmp(&right.tool.exposed_name))
        });
        routes
    }

    fn user_manifests(&self) -> Vec<(PathBuf, PluginManifest)> {
        let Ok(entries) = fs::read_dir(self.user_root.as_ref()) else {
            return Vec::new();
        };
        entries
            .flatten()
            .filter_map(|entry| {
                let root = entry.path();
                let manifest_path = root.join("plugin.json");
                let manifest = read_manifest(&manifest_path).ok()?;
                validate_manifest(&manifest).ok()?;
                Some((root, manifest))
            })
            .collect()
    }

    fn design_kb_root(&self) -> Option<PathBuf> {
        let mut candidates = Vec::new();
        if let Some(root) = &self.resource_root {
            candidates.push(root.join("DesignKB"));
            candidates.push(root.join("Resources").join("DesignKB"));
        }
        candidates.push(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("..")
                .join("Resources")
                .join("DesignKB"),
        );
        candidates.into_iter().find(|root| {
            [
                "generator.py",
                "layouts.json",
                "palettes.json",
                "typography.json",
                "rubric.md",
            ]
            .iter()
            .all(|file| root.join(file).is_file())
        })
    }

    fn design_kb_record(&self, root: PathBuf) -> PluginRecord {
        let runtime_ready = design_kb_invocation(&root, &self.platform).is_some();
        PluginRecord {
            id: DESIGN_KB_ID.into(),
            name: "DesignKB".into(),
            version: "1.0.0".into(),
            description:
                "Built-in presentation layouts, palettes, typography, icons, generator, and review rubric."
                    .into(),
            description_zh: "内置演示文稿版式、配色、字体、图标、生成器与验收规范。".into(),
            source: PluginSource::BuiltIn,
            enabled: true,
            available: true,
            runtime_ready,
            root_path: root,
            permissions: design_kb_permissions(),
            tools: vec![design_kb_tool_record()],
            status_detail: if runtime_ready {
                "Knowledge and generator ready".into()
            } else {
                "Knowledge ready; presentation generator runtime is unavailable".into()
            },
        }
    }

    async fn execute_design_kb(
        &self,
        arguments: Value,
        workspace: &Path,
        _permission_mode: ExecutionPermissionMode,
    ) -> Result<PluginExecution, PluginError> {
        let root = self
            .design_kb_root()
            .ok_or_else(|| PluginError::Execution("DesignKB resources are missing".into()))?;
        let file_name = arguments
            .get("file_name")
            .and_then(Value::as_str)
            .ok_or_else(|| PluginError::Execution("file_name is required".into()))?;
        if !file_name.to_lowercase().ends_with(".pptx") {
            return Err(PluginError::Execution(
                "file_name must end with .pptx".into(),
            ));
        }
        let quality_issues = presentation_plan_quality_issues(&arguments);
        if !quality_issues.is_empty() {
            return Ok(PluginExecution {
                output: json!({
                    "ok": false,
                    "retry_with_revised_input": true,
                    "reason": "The presentation plan is structurally valid but not yet presentation-quality. Revise the arguments and call this same capability again.",
                    "requirements": quality_issues,
                    "supported_layouts": [
                        "cover", "agenda", "section", "bullets", "bignumber",
                        "image-left", "image-right", "image-full", "twocol",
                        "timeline", "quote", "chart", "compare", "closing"
                    ]
                })
                .to_string(),
                artifact_paths: Vec::new(),
            });
        }
        let output_path = workspace_path(workspace, file_name)?;
        if let Some(parent) = output_path.parent() {
            fs::create_dir_all(parent)?;
        }
        let scratch = workspace.join(".lingshu").join("designkb");
        fs::create_dir_all(&scratch)?;
        let input_path = scratch.join(format!("{}.json", Uuid::new_v4()));
        let payload = json!({
            "title": arguments.get("title").cloned().unwrap_or(Value::Null),
            "theme": arguments.get("theme").cloned().unwrap_or_else(|| Value::String("midnight".into())),
            "template": arguments.get("template").cloned().unwrap_or(Value::Null),
            "slides": arguments.get("slides").cloned().unwrap_or_else(|| Value::Array(Vec::new()))
        });
        fs::write(&input_path, serde_json::to_vec_pretty(&payload)?)?;
        let Some((program, prefix)) = design_kb_invocation(&root, &self.platform) else {
            let _ = fs::remove_file(&input_path);
            return Ok(PluginExecution {
                output: json!({
                    "ok": false,
                    "needs_user_action": true,
                    "missing_capability": "designkb_generator_runtime",
                    "reason": "DesignKB knowledge is installed, but its bundled generator runtime is unavailable.",
                    "recovery": "Repair or reinstall LingShu so the bundled DesignKB generator is restored."
                })
                .to_string(),
                artifact_paths: Vec::new(),
            });
        };
        let mut process = tokio::process::Command::new(program);
        process.args(prefix);
        process
            .arg(&input_path)
            .arg(&output_path)
            .arg(&root)
            .current_dir(workspace)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let output = tokio::time::timeout(Duration::from_secs(300), process.output())
            .await
            .map_err(|_| PluginError::Execution("DesignKB generation timed out".into()))??;
        let _ = fs::remove_file(&input_path);
        if !output.status.success() || !output_path.is_file() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(PluginError::Execution(if stderr.is_empty() {
                format!("DesignKB generator exited with {}", output.status)
            } else {
                stderr
            }));
        }
        let metadata = fs::metadata(&output_path)?;
        Ok(PluginExecution {
            output: json!({
                "ok": true,
                "plugin": "DesignKB",
                "path": output_path,
                "bytes": metadata.len(),
                "theme": payload["theme"]
            })
            .to_string(),
            artifact_paths: vec![output_path],
        })
    }

    fn entrypoint_path(&self, root: &Path, command: &str) -> Option<PathBuf> {
        let candidate = PathBuf::from(command);
        if candidate.is_absolute() {
            return candidate.is_file().then_some(candidate);
        }
        if candidate.components().count() > 1 {
            let path = normalize_path(&root.join(candidate));
            return (path.starts_with(root) && path.is_file()).then_some(path);
        }
        find_command(command)
    }
}

fn is_builtin_plugin(id: &str) -> bool {
    matches!(id, OFFICE_FOUNDATION_ID | DESIGN_KB_ID)
}

fn office_foundation_record() -> PluginRecord {
    PluginRecord {
        id: OFFICE_FOUNDATION_ID.into(),
        name: "Office Foundation".into(),
        version: "1.0.0".into(),
        description: "Built-in, dependency-free Word, Excel, and basic PowerPoint creation shared by every LingShu client.".into(),
        description_zh: "由所有灵枢客户端共享的内置零依赖 Word、Excel 与基础 PowerPoint 生成能力。".into(),
        source: PluginSource::BuiltIn,
        enabled: true,
        available: true,
        runtime_ready: true,
        root_path: PathBuf::new(),
        permissions: office_foundation_permissions(),
        tools: vec![
            office_word_tool_record(),
            office_presentation_tool_record(),
            office_spreadsheet_tool_record(),
        ],
        status_detail: "Ready in the shared LingShu runtime core".into(),
    }
}

fn office_foundation_permissions() -> PluginPermissions {
    PluginPermissions {
        file_read: true,
        file_write: true,
        network: false,
        shell: false,
        system_sensitive: false,
    }
}

fn office_word_tool_record() -> PluginToolRecord {
    PluginToolRecord {
        name: OFFICE_WORD_TOOL.into(),
        exposed_name: OFFICE_WORD_TOOL.into(),
        description: "Create and register a dependency-free Word document in the Workspace. Markdown-style headings and lists are converted to document structure.".into(),
        description_zh: "在工作区创建并登记零依赖 Word 文档，支持将 Markdown 风格标题和列表转换为文档结构。".into(),
        parameters: json!({
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "file_name": {"type": "string", "description": "Workspace-relative .docx file name"},
                "content": {"type": "string", "description": "Document body; Markdown-style headings and lists are supported"}
            },
            "required": ["title", "file_name", "content"]
        }),
        capabilities: vec!["artifact.docx".into()],
        priority: 0,
        fallback: true,
    }
}

fn office_presentation_tool_record() -> PluginToolRecord {
    PluginToolRecord {
        name: OFFICE_PRESENTATION_TOOL.into(),
        exposed_name: OFFICE_PRESENTATION_TOOL.into(),
        description: "Create and register a dependency-free basic PowerPoint. This is a fallback provider when a higher-priority presentation plugin is runtime-ready.".into(),
        description_zh: "创建并登记零依赖基础 PowerPoint；当更高优先级的演示文稿插件运行就绪时，本工具仅作为兜底实现。".into(),
        parameters: json!({
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "file_name": {"type": "string", "description": "Workspace-relative .pptx file name"},
                "slides": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "title": {"type": "string"},
                            "bullets": {"type": "array", "items": {"type": "string"}},
                            "notes": {"type": "string"}
                        },
                        "required": ["title"]
                    }
                }
            },
            "required": ["title", "file_name", "slides"]
        }),
        capabilities: vec!["artifact.pptx".into()],
        priority: 0,
        fallback: true,
    }
}

fn office_spreadsheet_tool_record() -> PluginToolRecord {
    PluginToolRecord {
        name: OFFICE_SPREADSHEET_TOOL.into(),
        exposed_name: OFFICE_SPREADSHEET_TOOL.into(),
        description: "Create and register a dependency-free Excel workbook with one or more worksheets. Cells support strings, numbers, booleans, nulls, and formulas beginning with '='.".into(),
        description_zh: "创建并登记零依赖 Excel 工作簿，支持多个工作表以及字符串、数字、布尔值、空值和以“=”开头的公式。".into(),
        parameters: json!({
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "file_name": {"type": "string", "description": "Workspace-relative .xlsx file name"},
                "sheets": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "rows": {
                                "type": "array",
                                "items": {"type": "array", "items": {}}
                            }
                        },
                        "required": ["name", "rows"]
                    }
                }
            },
            "required": ["title", "file_name", "sheets"]
        }),
        capabilities: vec!["artifact.xlsx".into()],
        priority: 0,
        fallback: true,
    }
}

fn execute_office_foundation(
    tool_name: &str,
    arguments: Value,
    workspace: &Path,
) -> Result<PluginExecution, PluginError> {
    let (kind, extension) = match tool_name {
        OFFICE_WORD_TOOL => ("docx", "docx"),
        OFFICE_PRESENTATION_TOOL => ("pptx", "pptx"),
        OFFICE_SPREADSHEET_TOOL => ("xlsx", "xlsx"),
        _ => return Err(PluginError::NotFound(tool_name.into())),
    };
    let mut payload = arguments
        .as_object()
        .cloned()
        .ok_or_else(|| PluginError::Execution("Office tool arguments must be an object".into()))?;
    let file_name = payload
        .get("file_name")
        .and_then(Value::as_str)
        .ok_or_else(|| PluginError::Execution("file_name is required".into()))?;
    if Path::new(file_name)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| !value.eq_ignore_ascii_case(extension))
        .unwrap_or(true)
    {
        return Err(PluginError::Execution(format!(
            "file_name must end with .{extension}"
        )));
    }
    payload.insert("kind".into(), Value::String(kind.into()));
    payload
        .entry("content")
        .or_insert(Value::String(String::new()));
    payload.entry("slides").or_insert(Value::Array(Vec::new()));
    payload.entry("sheets").or_insert(Value::Array(Vec::new()));
    let spec: ArtifactSpec = serde_json::from_value(Value::Object(payload))?;
    let mut records = materialize_artifacts(workspace, &[spec])
        .map_err(|error| PluginError::Execution(error.to_string()))?;
    let record = records
        .pop()
        .ok_or_else(|| PluginError::Execution("Office artifact was not created".into()))?;
    Ok(PluginExecution {
        output: json!({
            "ok": true,
            "plugin": "Office Foundation",
            "kind": record.kind,
            "path": record.path,
            "bytes": record.size_bytes
        })
        .to_string(),
        artifact_paths: vec![record.path],
    })
}

fn design_kb_permissions() -> PluginPermissions {
    PluginPermissions {
        file_read: true,
        file_write: true,
        network: false,
        shell: false,
        system_sensitive: false,
    }
}

fn design_kb_tool_record() -> PluginToolRecord {
    PluginToolRecord {
        name: DESIGN_KB_TOOL.into(),
        exposed_name: DESIGN_KB_TOOL.into(),
        description: "Create and register a polished PowerPoint using LingShu DesignKB layouts, palettes, typography, icons, and review rules.".into(),
        description_zh: "使用灵枢 DesignKB 的版式、配色、字体、图标和验收规则生成并登记高质量 PowerPoint。".into(),
        parameters: json!({
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "file_name": {"type": "string", "description": "Workspace-relative .pptx path"},
                "theme": {
                    "type": "string",
                    "enum": ["midnight", "graphite", "ivory", "sand", "forest", "royal"],
                    "description": "Choose a palette that fits the subject; do not default blindly."
                },
                "template": {"type": "string", "description": "Optional existing .pptx template path"},
                "slides": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "layout": {
                                "type": "string",
                                "enum": ["cover", "agenda", "section", "bullets", "bignumber", "image-left", "image-right", "image-full", "twocol", "timeline", "quote", "chart", "compare", "closing"]
                            },
                            "title": {"type": "string"},
                            "subtitle": {"type": "string"},
                            "tagline": {"type": "string"},
                            "kicker": {"type": "string"},
                            "bullets": {"type": "array", "items": {"type": "string"}},
                            "icons": {"type": "array", "items": {"type": "string"}},
                            "number": {"type": ["string", "number"]},
                            "label": {"type": "string"},
                            "desc": {"type": "string"},
                            "left": {
                                "type": "object",
                                "properties": {
                                    "heading": {"type": "string"},
                                    "bullets": {"type": "array", "items": {"type": "string"}}
                                }
                            },
                            "right": {
                                "type": "object",
                                "properties": {
                                    "heading": {"type": "string"},
                                    "bullets": {"type": "array", "items": {"type": "string"}}
                                }
                            },
                            "metrics": {"type": "array", "items": {"type": "object"}},
                            "items": {"type": "array", "items": {"type": "string"}},
                            "steps": {
                                "type": "array",
                                "items": {
                                    "type": "object",
                                    "properties": {
                                        "label": {"type": "string"},
                                        "desc": {"type": "string"}
                                    }
                                }
                            },
                            "quote": {"type": "string"},
                            "attrib": {"type": "string"},
                            "image": {"type": "string"},
                            "chart": {
                                "type": "object",
                                "properties": {
                                    "type": {"type": "string", "enum": ["bar", "line", "pie"]},
                                    "categories": {"type": "array", "items": {"type": "string"}},
                                    "series": {
                                        "type": "array",
                                        "items": {
                                            "type": "object",
                                            "properties": {
                                                "name": {"type": "string"},
                                                "values": {"type": "array", "items": {"type": "number"}}
                                            }
                                        }
                                    }
                                }
                            },
                            "columns": {"type": "array", "items": {"type": "string"}},
                            "rows": {"type": "array", "items": {"type": "array"}},
                            "contact": {"type": "string"},
                            "index": {"type": ["string", "number"]},
                            "notes": {"type": "string"}
                        },
                        "required": ["layout", "title"]
                    }
                }
            },
            "required": ["title", "file_name", "slides"]
        }),
        capabilities: vec!["artifact.pptx".into()],
        priority: 100,
        fallback: false,
    }
}

fn design_kb_invocation(root: &Path, platform: &str) -> Option<(PathBuf, Vec<OsString>)> {
    let windows_helper = root.join("bin").join("designkb-generator.exe");
    if windows_helper.is_file() {
        return Some((windows_helper, Vec::new()));
    }
    let unix_helper = root.join("bin").join("designkb-generator");
    if unix_helper.is_file() {
        return Some((unix_helper, Vec::new()));
    }
    let script = root.join("generator.py");
    if !script.is_file() {
        return None;
    }
    if platform == "windows" {
        if let Some(py) = find_command("py") {
            return Some((py, vec![OsString::from("-3"), script.into_os_string()]));
        }
    }
    for command in ["python3", "python"] {
        if let Some(python) = find_command(command) {
            return Some((python, vec![script.clone().into_os_string()]));
        }
    }
    None
}

fn source_rank(source: &PluginSource) -> u8 {
    match source {
        PluginSource::BuiltIn => 0,
        PluginSource::User => 1,
    }
}

fn default_schema_version() -> u32 {
    PLUGIN_SCHEMA_VERSION
}

fn default_enabled() -> bool {
    true
}

fn default_timeout_seconds() -> u64 {
    120
}

fn empty_object_schema() -> Value {
    json!({"type":"object","properties":{}})
}

fn read_manifest(path: &Path) -> Result<PluginManifest, PluginError> {
    let bytes = fs::read(path)
        .map_err(|error| PluginError::InvalidManifest(format!("{}: {error}", path.display())))?;
    Ok(serde_json::from_slice(&bytes)?)
}

fn write_manifest(path: &Path, manifest: &PluginManifest) -> Result<(), PluginError> {
    let temporary = path.with_extension("json.tmp");
    fs::write(&temporary, serde_json::to_vec_pretty(manifest)?)?;
    fs::rename(temporary, path)?;
    Ok(())
}

fn validate_manifest(manifest: &PluginManifest) -> Result<(), PluginError> {
    if manifest.schema_version != PLUGIN_SCHEMA_VERSION {
        return Err(PluginError::InvalidManifest(format!(
            "unsupported schemaVersion {}",
            manifest.schema_version
        )));
    }
    validate_plugin_id(&manifest.id)?;
    if manifest.name.trim().is_empty()
        || manifest.version.trim().is_empty()
        || manifest.entrypoint.command.trim().is_empty()
        || manifest.tools.is_empty()
    {
        return Err(PluginError::InvalidManifest(
            "name, version, entrypoint.command, and at least one tool are required".into(),
        ));
    }
    for tool in &manifest.tools {
        validate_tool_name(&tool.name)?;
        for capability in &tool.capabilities {
            validate_capability_name(capability)?;
        }
        if tool.description.trim().is_empty() {
            return Err(PluginError::InvalidManifest(format!(
                "tool {} needs a description",
                tool.name
            )));
        }
    }
    Ok(())
}

fn validate_plugin_id(value: &str) -> Result<(), PluginError> {
    let valid = !value.is_empty()
        && value.len() <= 80
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || ".-_".contains(character));
    if valid && value != "." && value != ".." {
        Ok(())
    } else {
        Err(PluginError::InvalidManifest(format!(
            "invalid plugin id: {value}"
        )))
    }
}

fn validate_tool_name(value: &str) -> Result<(), PluginError> {
    let valid = !value.is_empty()
        && value.len() <= 64
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '_');
    if valid {
        Ok(())
    } else {
        Err(PluginError::InvalidManifest(format!(
            "invalid tool name: {value}"
        )))
    }
}

fn validate_capability_name(value: &str) -> Result<(), PluginError> {
    let valid = !value.is_empty()
        && value.len() <= 96
        && value
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || ".-_".contains(character));
    if valid {
        Ok(())
    } else {
        Err(PluginError::InvalidManifest(format!(
            "invalid capability name: {value}"
        )))
    }
}

fn exposed_tool_name(plugin_id: &str, tool_name: &str) -> String {
    let id = plugin_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();
    format!("plugin__{id}__{tool_name}")
}

fn copy_directory(source: &Path, target: &Path) -> Result<(), PluginError> {
    fs::create_dir_all(target)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if file_type.is_symlink() {
            return Err(PluginError::InvalidManifest(format!(
                "symbolic links are not allowed in plugin bundles: {}",
                entry.path().display()
            )));
        }
        let destination = target.join(entry.file_name());
        if file_type.is_dir() {
            copy_directory(&entry.path(), &destination)?;
        } else if file_type.is_file() {
            fs::copy(entry.path(), destination)?;
        }
    }
    Ok(())
}

fn expand_argument(
    template: &str,
    plugin_root: &Path,
    workspace: &Path,
    input: &str,
    arguments: &Value,
    tool_name: &str,
) -> OsString {
    let mut expanded = template
        .replace("{{plugin_dir}}", &plugin_root.display().to_string())
        .replace("{{workspace}}", &workspace.display().to_string())
        .replace("{{input}}", input)
        .replace("{{tool}}", tool_name);
    if let Some(object) = arguments.as_object() {
        for (key, value) in object {
            let replacement = value
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| value.to_string());
            expanded = expanded.replace(&format!("{{{{input.{key}}}}}"), &replacement);
        }
    }
    OsString::from(expanded)
}

fn find_command(name: &str) -> Option<PathBuf> {
    let direct = PathBuf::from(name);
    if direct.is_absolute() && direct.is_file() {
        return Some(direct);
    }
    let path = std::env::var_os("PATH")?;
    let extensions = if cfg!(target_os = "windows") {
        std::env::var_os("PATHEXT")
            .map(|value| {
                value
                    .to_string_lossy()
                    .split(';')
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|| vec![".EXE".into(), ".CMD".into(), ".BAT".into()])
    } else {
        vec![String::new()]
    };
    for root in std::env::split_paths(&path) {
        for extension in &extensions {
            let candidate = if extension.is_empty() || name.to_uppercase().ends_with(extension) {
                root.join(name)
            } else {
                root.join(format!("{name}{extension}"))
            };
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

fn workspace_path(workspace: &Path, raw: &str) -> Result<PathBuf, PluginError> {
    let workspace = normalize_path(workspace);
    let candidate = PathBuf::from(raw);
    let candidate = if candidate.is_absolute() {
        normalize_path(&candidate)
    } else {
        normalize_path(&workspace.join(candidate))
    };
    if candidate.starts_with(&workspace) {
        Ok(candidate)
    } else {
        Err(PluginError::Execution(format!(
            "output path is outside the Workspace: {}",
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

fn collect_artifact_paths(output: &str, workspace: &Path) -> Vec<PathBuf> {
    let Ok(value) = serde_json::from_str::<Value>(output) else {
        return Vec::new();
    };
    let mut raw = Vec::new();
    for key in ["path", "artifactPath"] {
        if let Some(path) = value.get(key).and_then(Value::as_str) {
            raw.push(path.to_string());
        }
    }
    for key in ["artifactPaths", "artifacts"] {
        if let Some(items) = value.get(key).and_then(Value::as_array) {
            for item in items {
                if let Some(path) = item
                    .as_str()
                    .or_else(|| item.get("path").and_then(Value::as_str))
                {
                    raw.push(path.to_string());
                }
            }
        }
    }
    raw.into_iter()
        .filter_map(|path| workspace_path(workspace, &path).ok())
        .filter(|path| path.is_file())
        .collect()
}

#[derive(Debug, Default)]
struct PluginOutputState {
    rejected: bool,
    needs_user_action: bool,
    retry_with_revised_input: bool,
}

fn plugin_output_state(output: &str) -> PluginOutputState {
    let Ok(value) = serde_json::from_str::<Value>(output) else {
        return PluginOutputState::default();
    };
    PluginOutputState {
        rejected: value.get("ok").and_then(Value::as_bool) == Some(false),
        needs_user_action: value
            .get("needs_user_action")
            .or_else(|| value.get("needsUserAction"))
            .and_then(Value::as_bool)
            == Some(true),
        retry_with_revised_input: value
            .get("retry_with_revised_input")
            .or_else(|| value.get("retryWithRevisedInput"))
            .and_then(Value::as_bool)
            == Some(true),
    }
}

fn presentation_plan_quality_issues(arguments: &Value) -> Vec<String> {
    const VALID_LAYOUTS: [&str; 14] = [
        "cover",
        "agenda",
        "section",
        "bullets",
        "bignumber",
        "image-left",
        "image-right",
        "image-full",
        "twocol",
        "timeline",
        "quote",
        "chart",
        "compare",
        "closing",
    ];

    let mut issues = Vec::new();
    let deck_title = value_text(arguments.get("title"));
    let file_stem = arguments
        .get("file_name")
        .and_then(Value::as_str)
        .and_then(|value| Path::new(value).file_stem())
        .and_then(|value| value.to_str())
        .unwrap_or_default();
    let Some(slides) = arguments.get("slides").and_then(Value::as_array) else {
        return vec!["Provide a non-empty slides array with content-driven layouts.".into()];
    };
    if slides.is_empty() {
        return vec!["Provide a non-empty slides array with content-driven layouts.".into()];
    }

    let mut layouts = BTreeSet::new();
    let mut bullet_slides = 0usize;
    for (index, slide) in slides.iter().enumerate() {
        let position = index + 1;
        let layout = slide
            .get("layout")
            .and_then(Value::as_str)
            .unwrap_or_default();
        if !VALID_LAYOUTS.contains(&layout) {
            issues.push(format!(
                "Slide {position}: choose one supported layout instead of '{layout}'."
            ));
            continue;
        }
        layouts.insert(layout.to_string());
        bullet_slides += usize::from(layout == "bullets");
        let title = value_text(slide.get("title"));
        if title.is_empty() {
            issues.push(format!("Slide {position}: title is required."));
        }

        for field in ["bullets", "items"] {
            if let Some(values) = slide.get(field).and_then(Value::as_array) {
                for value in values {
                    let text = value_text(Some(value));
                    if is_production_metadata(&text, &deck_title, file_stem, &title) {
                        issues.push(format!(
                            "Slide {position}: remove production metadata '{text}' from {field}; replace it with audience-facing content."
                        ));
                    }
                }
            }
        }

        match layout {
            "agenda" if !has_non_empty_array(slide, "items") => issues.push(format!(
                "Slide {position}: agenda requires substantive items."
            )),
            "bullets" | "image-left" | "image-right" if !has_non_empty_array(slide, "bullets") => {
                issues.push(format!(
                    "Slide {position}: {layout} requires substantive bullets."
                ))
            }
            "bignumber"
                if value_text(slide.get("number")).is_empty()
                    || value_text(slide.get("label")).is_empty() =>
            {
                issues.push(format!(
                    "Slide {position}: bignumber requires both number and label."
                ))
            }
            "twocol"
                if !has_non_empty_object_array(slide, "left", "bullets")
                    || !has_non_empty_object_array(slide, "right", "bullets") =>
            {
                issues.push(format!(
                    "Slide {position}: twocol requires populated left and right bullet groups."
                ))
            }
            "timeline" if !has_non_empty_array(slide, "steps") => issues.push(format!(
                "Slide {position}: timeline requires steps with labels and descriptions."
            )),
            "quote" if value_text(slide.get("quote")).is_empty() => issues.push(format!(
                "Slide {position}: quote requires a real quotation or central statement."
            )),
            "chart" if !valid_chart(slide.get("chart")) => issues.push(format!(
                "Slide {position}: chart requires categories and at least one numeric series."
            )),
            "compare"
                if !has_non_empty_array(slide, "columns")
                    || !has_non_empty_array(slide, "rows") =>
            {
                issues.push(format!(
                    "Slide {position}: compare requires columns and rows."
                ))
            }
            _ => {}
        }
    }

    if slides.len() >= 6 && layouts.len() < 3 {
        issues.push(
            "Use at least three layout families for a deck of six or more slides; choose layouts from the actual content.".into(),
        );
    } else if slides.len() >= 3 && layouts.len() < 2 {
        issues.push(
            "Use at least two layout families; do not render the entire deck as one repeated template."
                .into(),
        );
    }
    if slides.len() >= 6 && bullet_slides * 2 > slides.len() {
        issues.push(
            "Bullet-only pages exceed half the deck. Convert suitable content to comparison, timeline, chart, big-number, image, or section layouts.".into(),
        );
    }
    issues
}

fn value_text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(value)) => value.trim().to_string(),
        Some(Value::Number(value)) => value.to_string(),
        _ => String::new(),
    }
}

fn has_non_empty_array(value: &Value, key: &str) -> bool {
    value
        .get(key)
        .and_then(Value::as_array)
        .is_some_and(|items| !items.is_empty())
}

fn has_non_empty_object_array(value: &Value, object_key: &str, array_key: &str) -> bool {
    value
        .get(object_key)
        .and_then(|object| object.get(array_key))
        .and_then(Value::as_array)
        .is_some_and(|items| !items.is_empty())
}

fn valid_chart(value: Option<&Value>) -> bool {
    let Some(chart) = value else {
        return false;
    };
    has_non_empty_array(chart, "categories")
        && chart
            .get("series")
            .and_then(Value::as_array)
            .is_some_and(|series| {
                series.iter().any(|item| {
                    item.get("values")
                        .and_then(Value::as_array)
                        .is_some_and(|values| {
                            !values.is_empty() && values.iter().all(Value::is_number)
                        })
                })
            })
}

fn is_production_metadata(
    text: &str,
    deck_title: &str,
    file_stem: &str,
    slide_title: &str,
) -> bool {
    let normalized = text.trim().to_lowercase();
    if normalized.is_empty() {
        return true;
    }
    if [deck_title, file_stem, slide_title]
        .iter()
        .map(|candidate| candidate.trim().to_lowercase())
        .any(|candidate| !candidate.is_empty() && candidate == normalized)
    {
        return true;
    }
    let compact = normalized.replace(' ', "");
    let mut parts = compact.split('/');
    matches!(
        (parts.next(), parts.next(), parts.next()),
        (Some(left), Some(right), None)
            if !left.is_empty()
                && !right.is_empty()
                && left.chars().all(|ch| ch.is_ascii_digit())
                && right.chars().all(|ch| ch.is_ascii_digit())
    )
}

fn annotate_plugin_routing(
    output: &str,
    capability: &str,
    route: &PluginCapabilityRoute,
    policy: PluginUsagePolicy,
    routed_from: &str,
    attempts: Vec<Value>,
) -> String {
    let routing = json!({
        "policy": policy.as_str(),
        "capability": capability,
        "providerId": route.plugin_id,
        "providerName": route.plugin_name,
        "providerTool": route.tool.exposed_name,
        "routedFrom": routed_from,
        "fallback": route.fallback,
        "attempts": attempts
    });
    match serde_json::from_str::<Value>(output) {
        Ok(Value::Object(mut object)) => {
            object.insert("pluginRouting".into(), routing);
            Value::Object(object).to_string()
        }
        _ => json!({
            "ok": true,
            "output": output,
            "pluginRouting": routing
        })
        .to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::preview::{preview_file, PreviewKind};
    use tempfile::tempdir;

    #[test]
    fn plugin_output_state_preserves_recoverable_revision_request() {
        let state = plugin_output_state(
            r#"{"ok":false,"retry_with_revised_input":true,"requirements":["Use richer layouts"]}"#,
        );

        assert!(state.rejected);
        assert!(state.retry_with_revised_input);
        assert!(!state.needs_user_action);
    }

    #[test]
    fn presentation_quality_gate_rejects_metadata_only_deck() {
        let arguments = json!({
            "title": "LingShu self introduction",
            "file_name": "lingshu-self-introduction.pptx",
            "slides": [
                {"layout":"bullets","title":"LingShu self introduction","bullets":["LingShu self introduction","01 / 06"]},
                {"layout":"bullets","title":"Agenda","bullets":["LingShu self introduction","02 / 06"]},
                {"layout":"bullets","title":"About","bullets":["LingShu self introduction","03 / 06"]},
                {"layout":"bullets","title":"Features","bullets":["LingShu self introduction","04 / 06"]},
                {"layout":"bullets","title":"Architecture","bullets":["LingShu self introduction","05 / 06"]},
                {"layout":"bullets","title":"Closing","bullets":["LingShu self introduction","06 / 06"]}
            ]
        });

        let issues = presentation_plan_quality_issues(&arguments);

        assert!(issues
            .iter()
            .any(|issue| issue.contains("production metadata")));
        assert!(issues
            .iter()
            .any(|issue| issue.contains("three layout families")));
        assert!(issues
            .iter()
            .any(|issue| issue.contains("Bullet-only pages")));
    }

    #[test]
    fn presentation_quality_gate_accepts_content_driven_deck() {
        let arguments = json!({
            "title": "LingShu runtime",
            "file_name": "lingshu-runtime.pptx",
            "slides": [
                {"layout":"cover","title":"LingShu runtime","subtitle":"A model-neutral agent runtime"},
                {"layout":"agenda","title":"Today","items":["Why","How","Results"]},
                {"layout":"bullets","title":"Why it matters","bullets":["One runtime coordinates tools, memory, and delivery"]},
                {"layout":"bignumber","title":"Delivery","number":"2","label":"desktop platforms from one shared core"},
                {"layout":"timeline","title":"How work moves","steps":[{"label":"Plan","desc":"Translate intent into an executable goal"},{"label":"Deliver","desc":"Verify artifacts before handoff"}]},
                {"layout":"closing","title":"Next step","bullets":["Run the same workflow with your preferred model"]}
            ]
        });

        assert!(presentation_plan_quality_issues(&arguments).is_empty());
    }

    #[test]
    fn invalid_plugin_ids_cannot_escape_the_registry() {
        assert!(validate_plugin_id("../escape").is_err());
        assert!(validate_plugin_id("valid.plugin-1").is_ok());
    }

    #[test]
    fn registry_installs_and_toggles_a_local_plugin() {
        let data = tempdir().unwrap();
        let source = tempdir().unwrap();
        let manifest = json!({
            "schemaVersion": 1,
            "id": "demo.echo",
            "name": "Echo",
            "version": "1.0.0",
            "entrypoint": {"command": "missing-demo-command"},
            "tools": [{"name": "echo", "description": "Echo input"}]
        });
        fs::write(
            source.path().join("plugin.json"),
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let registry = PluginRegistry::new(data.path(), None, "windows").unwrap();
        let installed = registry.install(source.path().join("plugin.json")).unwrap();
        assert_eq!(installed.id, "demo.echo");
        assert!(installed.enabled);
        assert!(!installed.available);
        let disabled = registry.set_enabled("demo.echo", false).unwrap();
        assert!(!disabled.enabled);
        registry.remove("demo.echo").unwrap();
        assert!(registry.probe("demo.echo").is_err());
    }

    #[test]
    fn argument_templates_receive_structured_input() {
        let expanded = expand_argument(
            "{{workspace}}/{{input.file}}/{{tool}}",
            Path::new("/plugins/demo"),
            Path::new("/work"),
            r#"{"file":"out.md"}"#,
            &json!({"file":"out.md"}),
            "render",
        );
        assert_eq!(expanded, OsString::from("/work/out.md/render"));
    }

    #[test]
    fn source_design_kb_is_registered_for_development() {
        let data = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        let design_kb = registry.probe(DESIGN_KB_ID).unwrap();
        assert!(design_kb.available);
        assert_eq!(design_kb.tools[0].exposed_name, DESIGN_KB_TOOL);
    }

    #[test]
    fn office_foundation_is_always_registered_and_protected() {
        let data = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        let office = registry.probe(OFFICE_FOUNDATION_ID).unwrap();
        assert!(office.enabled);
        assert!(office.available);
        assert!(office.runtime_ready);
        assert_eq!(office.tools.len(), 3);
        assert!(office
            .tools
            .iter()
            .any(|tool| tool.exposed_name == OFFICE_SPREADSHEET_TOOL));
        assert!(registry.set_enabled(OFFICE_FOUNDATION_ID, false).is_err());
        assert!(registry.remove(OFFICE_FOUNDATION_ID).is_err());
    }

    #[test]
    fn capability_routing_prefers_any_ready_plugin_over_the_foundation_fallback() {
        let data = tempdir().unwrap();
        let source = tempdir().unwrap();
        let manifest = json!({
            "schemaVersion": 1,
            "id": "demo.sheet",
            "name": "Demo Sheet",
            "version": "1.0.0",
            "entrypoint": {"command": std::env::current_exe().unwrap()},
            "tools": [{
                "name": "create_sheet",
                "description": "Create a spreadsheet with a custom renderer.",
                "capabilities": ["artifact.xlsx"],
                "priority": 50,
                "fallback": false
            }]
        });
        fs::write(
            source.path().join("plugin.json"),
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        registry.install(source.path().join("plugin.json")).unwrap();

        let route = registry
            .resolve_capability("artifact.xlsx", PluginUsagePolicy::Required)
            .expect("a ready provider must be selected");
        assert_eq!(route.plugin_id, "demo.sheet");
        assert_eq!(route.tool.exposed_name, "plugin__demo_sheet__create_sheet");
        assert!(!route.fallback);

        let routed = registry.routed_tools(PluginUsagePolicy::Required);
        assert!(routed
            .iter()
            .any(|tool| tool.exposed_name == "plugin__demo_sheet__create_sheet"));
        assert!(!routed
            .iter()
            .any(|tool| tool.exposed_name == OFFICE_SPREADSHEET_TOOL));
    }

    #[test]
    fn explicit_plugin_opt_out_hides_all_plugin_tools_and_routes() {
        let data = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();

        assert!(registry
            .routed_tools(PluginUsagePolicy::Disabled)
            .is_empty());
        assert!(registry
            .resolve_capability("artifact.docx", PluginUsagePolicy::Disabled)
            .is_none());
    }

    #[test]
    fn foundation_provider_remains_available_when_no_specialized_plugin_exists() {
        let data = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        let route = registry
            .resolve_capability("artifact.docx", PluginUsagePolicy::Required)
            .expect("the foundation provider must cover common document artifacts");

        assert_eq!(route.plugin_id, OFFICE_FOUNDATION_ID);
        assert_eq!(route.tool.exposed_name, OFFICE_WORD_TOOL);
        assert!(route.fallback);
    }

    #[test]
    fn invalid_capability_identifiers_are_rejected_at_install_time() {
        let data = tempdir().unwrap();
        let source = tempdir().unwrap();
        let manifest = json!({
            "schemaVersion": 1,
            "id": "demo.invalid-capability",
            "name": "Invalid Capability",
            "version": "1.0.0",
            "entrypoint": {"command": std::env::current_exe().unwrap()},
            "tools": [{
                "name": "render",
                "description": "Invalid capability fixture.",
                "capabilities": ["../artifact.xlsx"]
            }]
        });
        fs::write(
            source.path().join("plugin.json"),
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();

        assert!(matches!(
            registry.install(source.path().join("plugin.json")),
            Err(PluginError::InvalidManifest(_))
        ));
    }

    #[tokio::test]
    async fn capability_execution_records_the_selected_provider() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        let result = registry
            .execute_capability(
                "artifact.xlsx",
                json!({
                    "title": "Routing audit",
                    "file_name": "routing-audit.xlsx",
                    "sheets": [{"name": "Summary", "rows": [["Provider", "Verified"], ["Plugin", true]]}]
                }),
                workspace.path(),
                ExecutionPermissionMode::Sandbox,
                PluginUsagePolicy::Required,
                "create_artifact",
            )
            .await
            .unwrap();
        let output: Value = serde_json::from_str(&result.output).unwrap();

        assert_eq!(output["pluginRouting"]["policy"], "required");
        assert_eq!(output["pluginRouting"]["capability"], "artifact.xlsx");
        assert_eq!(output["pluginRouting"]["providerId"], OFFICE_FOUNDATION_ID);
        assert_eq!(output["pluginRouting"]["fallback"], true);
        assert_eq!(result.artifact_paths.len(), 1);
    }

    #[tokio::test]
    async fn office_foundation_creates_a_previewable_spreadsheet() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        let result = registry
            .execute(
                OFFICE_SPREADSHEET_TOOL,
                json!({
                    "title": "Quarterly metrics",
                    "file_name": "quarterly-metrics.xlsx",
                    "sheets": [{
                        "name": "Summary",
                        "rows": [
                            ["Metric", "Value", "Verified"],
                            ["Revenue", 120, true]
                        ]
                    }]
                }),
                workspace.path(),
                ExecutionPermissionMode::Sandbox,
            )
            .await
            .unwrap();
        assert_eq!(result.artifact_paths.len(), 1);
        let preview = preview_file(&result.artifact_paths[0]).unwrap();
        assert_eq!(preview.kind, PreviewKind::Spreadsheet);
        assert!(preview.content.contains("Revenue\t120\tTRUE"));
    }

    #[tokio::test]
    #[ignore = "requires a bundled DesignKB helper or python-pptx"]
    async fn design_kb_executes_and_returns_a_real_powerpoint() {
        let data = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        let result = registry
            .execute(
                DESIGN_KB_TOOL,
                json!({
                    "title": "DesignKB smoke test",
                    "file_name": "designkb-smoke.pptx",
                    "theme": "midnight",
                    "slides": [
                        {"layout":"cover","title":"DesignKB smoke test","subtitle":"Shared Runtime Core"},
                        {"layout":"bullets","title":"Verified","bullets":["Knowledge loaded","Generator executed","Artifact returned"]}
                    ]
                }),
                workspace.path(),
                ExecutionPermissionMode::Sandbox,
            )
            .await
            .unwrap();
        assert!(result.output.contains("\"ok\":true"));
        assert_eq!(result.artifact_paths.len(), 1);
        assert!(result.artifact_paths[0].is_file());
        assert!(fs::metadata(&result.artifact_paths[0]).unwrap().len() > 1_000);

        let artifact_path = result.artifact_paths[0].clone();
        let first_preview = preview_file(&artifact_path).unwrap();
        assert_eq!(first_preview.kind, PreviewKind::Presentation);
        assert!(first_preview.faithful);
        assert_eq!(
            first_preview.rendered_mime_type.as_deref(),
            Some("application/pdf")
        );
        assert!(first_preview.rendered_content.is_some());

        registry
            .execute(
                DESIGN_KB_TOOL,
                json!({
                    "title": "DesignKB revised smoke test",
                    "file_name": "designkb-smoke.pptx",
                    "theme": "royal",
                    "slides": [
                        {"layout":"cover","title":"Revised artifact","subtitle":"Latest bytes win"},
                        {"layout":"bullets","title":"Current content","bullets":["The same path was overwritten","Preview revision follows file content"]}
                    ]
                }),
                workspace.path(),
                ExecutionPermissionMode::Sandbox,
            )
            .await
            .unwrap();

        let revised_preview = preview_file(&artifact_path).unwrap();
        assert_ne!(first_preview.revision, revised_preview.revision);
        assert!(revised_preview.content.contains("Revised artifact"));
        assert!(revised_preview.faithful);
        assert_eq!(
            revised_preview.rendered_mime_type.as_deref(),
            Some("application/pdf")
        );
        assert!(revised_preview.rendered_content.is_some());
    }

    #[tokio::test]
    #[ignore = "requires a local Python executable"]
    async fn installed_plugin_executes_and_returns_a_registered_artifact_path() {
        let python = find_command("python3")
            .or_else(|| find_command("python"))
            .expect("Python is required for this integration test");
        let data = tempdir().unwrap();
        let source = tempdir().unwrap();
        let workspace = tempdir().unwrap();
        let script = source.path().join("plugin.py");
        fs::write(
            &script,
            r#"import json, os, sys
payload = json.loads(sys.stdin.read())
path = os.path.join(os.environ["LINGSHU_WORKSPACE"], payload["file"])
with open(path, "w", encoding="utf-8") as stream:
    stream.write(payload["content"])
print(json.dumps({"ok": True, "path": path}))
"#,
        )
        .unwrap();
        let manifest = json!({
            "schemaVersion": 1,
            "id": "demo.writer",
            "name": "Demo Writer",
            "version": "1.0.0",
            "permissions": {"fileRead": true, "fileWrite": true},
            "entrypoint": {
                "command": python,
                "arguments": ["{{plugin_dir}}/plugin.py"]
            },
            "tools": [{
                "name": "write",
                "description": "Write a test artifact",
                "parameters": {
                    "type": "object",
                    "properties": {"file":{"type":"string"},"content":{"type":"string"}},
                    "required": ["file", "content"]
                }
            }]
        });
        fs::write(
            source.path().join("plugin.json"),
            serde_json::to_vec_pretty(&manifest).unwrap(),
        )
        .unwrap();
        let registry = PluginRegistry::new(data.path(), None, std::env::consts::OS).unwrap();
        registry.install(source.path().join("plugin.json")).unwrap();
        let exposed = registry
            .probe("demo.writer")
            .unwrap()
            .tools
            .first()
            .unwrap()
            .exposed_name
            .clone();
        let result = registry
            .execute(
                &exposed,
                json!({"file":"plugin-output.md","content":"plugin execution verified"}),
                workspace.path(),
                ExecutionPermissionMode::Sandbox,
            )
            .await
            .unwrap();
        assert_eq!(result.artifact_paths.len(), 1);
        assert_eq!(
            fs::read_to_string(&result.artifact_paths[0]).unwrap(),
            "plugin execution verified"
        );
    }
}
