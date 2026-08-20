use lingshu_runtime_core::{
    preview_file, provider_catalog, ExecutionPermissionMode, ExternalSkillRecord,
    MemoryDeleteRequest, MemoryDeleteResult, MemoryGetRequest, MemoryListItem, MemoryListPage,
    MemoryListRequest, MemoryMutationResult, MemoryUpsertRequest, PluginRecord, PreviewPayload,
    ProviderPreset, RuntimeFailureKind, RuntimeKernel, RuntimeSettings, RuntimeSnapshot,
    RuntimeStore, SubmitReceipt,
};
use serde::Serialize;
use std::path::PathBuf;
use tauri::{Manager, State};
use uuid::Uuid;

#[cfg(any(target_os = "windows", test))]
use std::{
    fs::{File, OpenOptions},
    io,
    path::Path,
};

const KEYRING_SERVICE: &str = "com.royzhao.lingshu";

struct AppState {
    kernel: RuntimeKernel,
    #[cfg(target_os = "windows")]
    _runtime_owner: RuntimeOwnerGuard,
}

/// The single-instance plugin focuses ordinary second launches. This OS file lock is the final
/// ownership fence if two processes start before the plugin's IPC window is ready.
#[cfg(any(target_os = "windows", test))]
#[derive(Debug)]
struct RuntimeOwnerGuard {
    _file: File,
}

#[cfg(any(target_os = "windows", test))]
impl RuntimeOwnerGuard {
    fn acquire(data_dir: &Path) -> io::Result<Self> {
        std::fs::create_dir_all(data_dir)?;
        let path = data_dir.join("windows-runtime-owner.lock");
        let file = OpenOptions::new()
            .create(true)
            .read(true)
            .write(true)
            .open(&path)?;
        file.try_lock().map_err(|error| {
            io::Error::other(format!(
                "another Nous runtime already owns {}: {error}",
                path.display()
            ))
        })?;
        Ok(Self { _file: file })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapPayload {
    snapshot: RuntimeSnapshot,
    providers: Vec<ProviderPreset>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SubmitMessagePayload {
    receipt: SubmitReceipt,
    snapshot: RuntimeSnapshot,
}

fn key_account(provider_id: &str) -> String {
    format!("brain::{provider_id}")
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn load_api_key(provider_id: &str) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_account(provider_id))
        .map_err(|error| format!("credential store initialization failed: {error}"))?;
    match entry.get_password() {
        Ok(value) if !value.trim().is_empty() => Ok(Some(value)),
        Ok(_) => Ok(None),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(error) => Err(format!("credential store read failed: {error}")),
    }
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn load_api_key(_provider_id: &str) -> Result<Option<String>, String> {
    Ok(None)
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn save_api_key(provider_id: &str, value: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_account(provider_id))
        .map_err(|error| format!("credential store initialization failed: {error}"))?;
    entry
        .set_password(value)
        .map_err(|error| format!("credential store write failed: {error}"))
}

#[cfg(any(target_os = "windows", target_os = "macos"))]
fn delete_api_key(provider_id: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(KEYRING_SERVICE, &key_account(provider_id))
        .map_err(|error| format!("credential store initialization failed: {error}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(error) => Err(format!("credential store delete failed: {error}")),
    }
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn delete_api_key(_provider_id: &str) -> Result<(), String> {
    Ok(())
}

#[cfg(not(any(target_os = "windows", target_os = "macos")))]
fn save_api_key(_provider_id: &str, _value: &str) -> Result<(), String> {
    Err("secure credential storage is unavailable on this platform".into())
}

fn provider_needs_key(provider_id: &str) -> bool {
    provider_catalog()
        .iter()
        .find(|provider| provider.id == provider_id)
        .map(|provider| provider.requires_api_key)
        .unwrap_or(true)
}

async fn is_provider_configured(settings: &RuntimeSettings) -> bool {
    !settings.endpoint.trim().is_empty()
        && !settings.model.trim().is_empty()
        && (!provider_needs_key(&settings.provider_id)
            || load_api_key(&settings.provider_id).ok().flatten().is_some())
}

#[tauri::command]
async fn bootstrap(state: State<'_, AppState>) -> Result<BootstrapPayload, String> {
    let settings = state.kernel.store().settings().await;
    let configured = is_provider_configured(&settings).await;
    Ok(BootstrapPayload {
        snapshot: state.kernel.snapshot(configured).await,
        providers: provider_catalog(),
    })
}

#[tauri::command]
async fn get_snapshot(state: State<'_, AppState>) -> Result<RuntimeSnapshot, String> {
    let settings = state.kernel.store().settings().await;
    let configured = is_provider_configured(&settings).await;
    Ok(state.kernel.snapshot(configured).await)
}

#[tauri::command]
async fn memory_list(
    state: State<'_, AppState>,
    request: MemoryListRequest,
) -> Result<MemoryListPage, String> {
    state
        .kernel
        .memory_list(request)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn memory_get(
    state: State<'_, AppState>,
    request: MemoryGetRequest,
) -> Result<MemoryListItem, String> {
    state
        .kernel
        .memory_get(request)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn memory_upsert(
    state: State<'_, AppState>,
    request: MemoryUpsertRequest,
) -> Result<MemoryMutationResult, String> {
    state
        .kernel
        .memory_upsert(request)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn memory_delete(
    state: State<'_, AppState>,
    request: MemoryDeleteRequest,
) -> Result<MemoryDeleteResult, String> {
    state
        .kernel
        .memory_delete(request)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn save_and_validate_settings(
    state: State<'_, AppState>,
    settings: RuntimeSettings,
    api_key: String,
) -> Result<RuntimeSnapshot, String> {
    let supplied = (!api_key.trim().is_empty()).then_some(api_key.trim().to_string());
    let stored = load_api_key(&settings.provider_id)?;
    let effective = supplied.as_deref().or(stored.as_deref());
    let locale = settings.locale;
    state
        .kernel
        .validate_provider(&settings, effective)
        .await
        .map_err(|error| error.user_message(locale))?;
    if let Some(value) = supplied.as_deref() {
        save_api_key(&settings.provider_id, value)?;
    }
    state
        .kernel
        .store()
        .update_settings(settings.clone())
        .await
        .map_err(|error| error.to_string())?;
    let worker = state.kernel.clone();
    let worker_key = load_api_key(&settings.provider_id)?;
    let provider_id = settings.provider_id.clone();
    tauri::async_runtime::spawn(async move {
        if let Ok(report) = worker.supervise_queue_report(worker_key).await {
            if report
                .failures
                .iter()
                .any(|failure| failure.kind == RuntimeFailureKind::Authentication)
            {
                let _ = delete_api_key(&provider_id);
            }
        }
    });
    Ok(state
        .kernel
        .snapshot(is_provider_configured(&settings).await)
        .await)
}

#[tauri::command]
async fn update_execution_permission_mode(
    state: State<'_, AppState>,
    mode: ExecutionPermissionMode,
) -> Result<RuntimeSnapshot, String> {
    let mut settings = state.kernel.store().settings().await;
    settings.execution_permission_mode = mode;
    state
        .kernel
        .store()
        .update_settings(settings.clone())
        .await
        .map_err(|error| error.to_string())?;
    Ok(state
        .kernel
        .snapshot(is_provider_configured(&settings).await)
        .await)
}

#[tauri::command]
async fn submit_message(
    state: State<'_, AppState>,
    prompt: String,
    attachment_paths: Vec<PathBuf>,
) -> Result<SubmitMessagePayload, String> {
    if prompt.trim().is_empty() {
        return Err("message is empty".into());
    }
    let settings = state.kernel.store().settings().await;
    let key = load_api_key(&settings.provider_id)?;
    if provider_needs_key(&settings.provider_id) && key.is_none() {
        return Err(format!("{} requires an API token", settings.provider_name));
    }
    let receipt = state
        .kernel
        .submit(prompt, attachment_paths)
        .await
        .map_err(|error| error.to_string())?;
    let snapshot = state
        .kernel
        .snapshot(is_provider_configured(&settings).await)
        .await;
    let kernel = state.kernel.clone();
    let provider_id = settings.provider_id;
    tauri::async_runtime::spawn(async move {
        if let Ok(report) = kernel.supervise_queue_report(key).await {
            if report
                .failures
                .iter()
                .any(|failure| failure.kind == RuntimeFailureKind::Authentication)
            {
                let _ = delete_api_key(&provider_id);
            }
        }
    });
    Ok(SubmitMessagePayload { receipt, snapshot })
}

#[tauri::command]
async fn cancel_task(state: State<'_, AppState>, thread_id: String) -> Result<bool, String> {
    let id = Uuid::parse_str(&thread_id).map_err(|error| error.to_string())?;
    state
        .kernel
        .cancel(id)
        .await
        .map_err(|error| error.to_string())
}

#[tauri::command]
async fn resume_task(
    state: State<'_, AppState>,
    thread_id: String,
    expected_tool_call_id: String,
    answer: String,
) -> Result<Option<RuntimeSnapshot>, String> {
    let id = Uuid::parse_str(&thread_id).map_err(|error| error.to_string())?;
    let task = state
        .kernel
        .store()
        .task(id)
        .await
        .ok_or_else(|| format!("task not found: {id}"))?;
    if task.status != lingshu_runtime_core::TaskStatus::NeedsUserAction {
        return Ok(None);
    }
    let settings = state.kernel.store().settings().await;
    let key = load_api_key(&settings.provider_id)?;
    if provider_needs_key(&settings.provider_id) && key.is_none() {
        return Err(format!("{} requires an API token", settings.provider_name));
    }
    let Some(prepared) = state
        .kernel
        .store()
        .prepare_resume_checkpoint(id, &expected_tool_call_id, answer.clone())
        .await
        .map_err(|error| error.to_string())?
    else {
        return Ok(None);
    };
    let snapshot = state
        .kernel
        .snapshot(is_provider_configured(&settings).await)
        .await;
    let kernel = state.kernel.clone();
    let provider_id = settings.provider_id;
    tauri::async_runtime::spawn(async move {
        let recovery_key = key.clone();
        if let Err(error) = kernel.run_prepared_resume(id, prepared, answer, key).await {
            if error.failure_kind() == RuntimeFailureKind::Authentication {
                let _ = delete_api_key(&provider_id);
            }
        }
        if let Ok(report) = kernel.supervise_queue_report(recovery_key).await {
            if report
                .failures
                .iter()
                .any(|failure| failure.kind == RuntimeFailureKind::Authentication)
            {
                let _ = delete_api_key(&provider_id);
            }
        }
    });
    Ok(Some(snapshot))
}

#[tauri::command]
async fn preview_path(path: PathBuf) -> Result<PreviewPayload, String> {
    tauri::async_runtime::spawn_blocking(move || {
        preview_file(path).map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| format!("preview worker failed: {error}"))?
}

#[tauri::command]
fn open_external(path: PathBuf) -> Result<(), String> {
    if !path.is_file() {
        return Err(format!("file does not exist: {}", path.display()));
    }
    open::that_detached(path).map_err(|error| error.to_string())
}

#[tauri::command]
fn reveal_path(path: PathBuf) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("path does not exist: {}", path.display()));
    }
    #[cfg(target_os = "windows")]
    {
        std::process::Command::new("explorer")
            .arg(format!("/select,{}", path.display()))
            .spawn()
            .map_err(|error| error.to_string())?;
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("open")
            .arg("-R")
            .arg(&path)
            .spawn()
            .map_err(|error| error.to_string())?;
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos")))]
    {
        let folder = path.parent().unwrap_or(path.as_path());
        open::that_detached(folder).map_err(|error| error.to_string())?;
    }
    Ok(())
}

#[tauri::command]
fn list_plugins(state: State<'_, AppState>) -> Vec<PluginRecord> {
    state.kernel.plugins().list()
}

#[tauri::command]
fn install_plugin(
    state: State<'_, AppState>,
    manifest_path: PathBuf,
) -> Result<PluginRecord, String> {
    state
        .kernel
        .plugins()
        .install(manifest_path)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn set_plugin_enabled(
    state: State<'_, AppState>,
    id: String,
    enabled: bool,
) -> Result<PluginRecord, String> {
    state
        .kernel
        .plugins()
        .set_enabled(&id, enabled)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn remove_plugin(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state
        .kernel
        .plugins()
        .remove(&id)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn probe_plugin(state: State<'_, AppState>, id: String) -> Result<PluginRecord, String> {
    state
        .kernel
        .plugins()
        .probe(&id)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn list_external_skills(state: State<'_, AppState>) -> Vec<ExternalSkillRecord> {
    state.kernel.external_skills().list()
}

#[tauri::command]
fn refresh_external_skills(state: State<'_, AppState>) -> Vec<ExternalSkillRecord> {
    state.kernel.external_skills().refresh()
}

#[tauri::command]
fn import_external_skill(
    state: State<'_, AppState>,
    path: PathBuf,
) -> Result<Vec<ExternalSkillRecord>, String> {
    state
        .kernel
        .external_skills()
        .import(path)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn set_external_skill_enabled(
    state: State<'_, AppState>,
    id: String,
    enabled: bool,
) -> Result<ExternalSkillRecord, String> {
    state
        .kernel
        .external_skills()
        .set_enabled(&id, enabled)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn remove_external_skill(state: State<'_, AppState>, id: String) -> Result<(), String> {
    state
        .kernel
        .external_skills()
        .remove(&id)
        .map_err(|error| error.to_string())
}

pub fn run() {
    let builder = tauri::Builder::default();
    // RuntimeStore locking is process-local, so Windows must have exactly one runtime owner.
    // A second launch only restores and focuses the existing window.
    #[cfg(target_os = "windows")]
    let builder = builder.plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
        if let Some(window) = app.get_webview_window("main") {
            let _ = window.show();
            let _ = window.unminimize();
            let _ = window.set_focus();
        }
    }));
    builder
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let data_dir = runtime_data_dir();
            #[cfg(target_os = "windows")]
            let runtime_owner = RuntimeOwnerGuard::acquire(&data_dir)?;
            let store = RuntimeStore::open(data_dir)?;
            let resource_root = app.path().resource_dir().ok();
            let kernel = RuntimeKernel::new_with_resources(store, "windows", resource_root)?;
            let recovery_kernel = kernel.clone();
            tauri::async_runtime::spawn(async move {
                let settings = recovery_kernel.store().settings().await;
                if !is_provider_configured(&settings).await {
                    return;
                }
                let Ok(key) = load_api_key(&settings.provider_id) else {
                    return;
                };
                if let Ok(report) = recovery_kernel.supervise_queue_report(key).await {
                    if report
                        .failures
                        .iter()
                        .any(|failure| failure.kind == RuntimeFailureKind::Authentication)
                    {
                        let _ = delete_api_key(&settings.provider_id);
                    }
                }
            });
            app.manage(AppState {
                kernel,
                #[cfg(target_os = "windows")]
                _runtime_owner: runtime_owner,
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            get_snapshot,
            memory_list,
            memory_get,
            memory_upsert,
            memory_delete,
            save_and_validate_settings,
            update_execution_permission_mode,
            submit_message,
            cancel_task,
            resume_task,
            preview_path,
            open_external,
            reveal_path,
            list_plugins,
            install_plugin,
            set_plugin_enabled,
            remove_plugin,
            probe_plugin,
            list_external_skills,
            refresh_external_skills,
            import_external_skill,
            set_external_skill_enabled,
            remove_external_skill,
        ])
        .run(tauri::generate_context!())
        .expect("error while running LingShu");
}

fn runtime_data_dir() -> PathBuf {
    // Native Windows releases use the canonical LingShu directory. A macOS debug shell uses an
    // isolated fixture directory so UI development can never mutate the installed Mac app state.
    #[cfg(all(debug_assertions, target_os = "macos"))]
    {
        return dirs::data_local_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("LingShuWindowsDev");
    }
    #[allow(unreachable_code)]
    RuntimeStore::default_data_dir()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_owner_lock_is_exclusive_until_the_owner_exits() {
        let directory = std::env::temp_dir().join(format!("lingshu-owner-test-{}", Uuid::new_v4()));
        let first = RuntimeOwnerGuard::acquire(&directory).unwrap();
        let error = RuntimeOwnerGuard::acquire(&directory).unwrap_err();
        assert!(error
            .to_string()
            .contains("another Nous runtime already owns"));

        drop(first);
        let next = RuntimeOwnerGuard::acquire(&directory).unwrap();
        drop(next);
        std::fs::remove_file(directory.join("windows-runtime-owner.lock")).unwrap();
        std::fs::remove_dir(directory).unwrap();
    }
}
