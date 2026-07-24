use crate::models::{
    AppLocale, ExecutionPermissionMode, PluginPermissions, PluginRecord, PluginSource,
    PluginToolRecord,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
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
}

#[derive(Debug)]
pub struct PluginExecution {
    pub output: String,
    pub artifact_paths: Vec<PathBuf>,
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
        let mut records = Vec::new();
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
            .filter(|plugin| plugin.enabled && plugin.available)
            .flat_map(|plugin| plugin.tools)
            .collect()
    }

    pub fn prompt_context(&self, locale: AppLocale) -> String {
        let enabled = self
            .list()
            .into_iter()
            .filter(|plugin| plugin.enabled && plugin.available)
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
                .map(|tool| tool.exposed_name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            lines.push(format!(
                "- {} {}: {} Tools: {}",
                plugin.name, plugin.version, description, tools
            ));
        }
        if self.design_kb_root().is_some() {
            lines.push(self.design_kb_prompt(locale));
        }
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
        if id == DESIGN_KB_ID {
            if !enabled {
                return Err(PluginError::InvalidManifest(
                    "the built-in DesignKB plugin cannot be disabled".into(),
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
        if id == DESIGN_KB_ID {
            return Err(PluginError::InvalidManifest(
                "the built-in DesignKB plugin cannot be removed".into(),
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

    fn design_kb_prompt(&self, locale: AppLocale) -> String {
        let Some(root) = self.design_kb_root() else {
            return String::new();
        };
        let palette_ids = json_ids(&root.join("palettes.json"), "palettes");
        let layout_ids = json_ids(&root.join("layouts.json"), "layouts");
        let rubric = fs::read_to_string(root.join("rubric.md"))
            .unwrap_or_default()
            .lines()
            .filter(|line| line.trim_start().starts_with('-'))
            .take(6)
            .collect::<Vec<_>>()
            .join(" ");
        match locale {
            AppLocale::ZhCn => format!(
                "DesignKB 是生成 PowerPoint 的首选能力。需要可交付演示文稿时，优先调用 {DESIGN_KB_TOOL}，逐页选择合适 layout，不要退化成纯文本 create_artifact。可用主题：{}。可用版式：{}。验收要点：{}",
                palette_ids.join(", "),
                layout_ids.join(", "),
                rubric
            ),
            AppLocale::En => format!(
                "DesignKB is the preferred PowerPoint capability. For a deliverable presentation, call {DESIGN_KB_TOOL}, choose an appropriate layout per slide, and do not fall back to a text-only create_artifact deck. Themes: {}. Layouts: {}. Review rubric: {}",
                palette_ids.join(", "),
                layout_ids.join(", "),
                rubric
            ),
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
                "theme": {"type": "string", "description": "DesignKB palette id"},
                "template": {"type": "string", "description": "Optional existing .pptx template path"},
                "slides": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "layout": {"type": "string"},
                            "title": {"type": "string"},
                            "subtitle": {"type": "string"},
                            "bullets": {"type": "array", "items": {"type": "string"}},
                            "left": {"type": "object"},
                            "right": {"type": "object"},
                            "metrics": {"type": "array"},
                            "items": {"type": "array"},
                            "quote": {"type": "string"},
                            "image": {"type": "string"},
                            "notes": {"type": "string"}
                        },
                        "required": ["layout", "title"]
                    }
                }
            },
            "required": ["title", "file_name", "slides"]
        }),
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

fn json_ids(path: &Path, collection: &str) -> Vec<String> {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.get(collection).and_then(Value::as_array).cloned())
        .unwrap_or_default()
        .into_iter()
        .filter_map(|item| item.get("id").and_then(Value::as_str).map(str::to_string))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

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
