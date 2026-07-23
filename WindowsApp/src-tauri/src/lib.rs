use lingshu_runtime_core::{
    preview_file, provider_catalog, ExecutionPermissionMode, PreviewPayload, ProviderPreset,
    RuntimeKernel, RuntimeSettings, RuntimeSnapshot, RuntimeStore, SubmitReceipt,
};
use serde::Serialize;
use std::path::PathBuf;
use tauri::State;
use uuid::Uuid;

const KEYRING_SERVICE: &str = "com.royzhao.lingshu";

struct AppState {
    kernel: RuntimeKernel,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BootstrapPayload {
    snapshot: RuntimeSnapshot,
    providers: Vec<ProviderPreset>,
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
async fn save_and_validate_settings(
    state: State<'_, AppState>,
    settings: RuntimeSettings,
    api_key: String,
) -> Result<RuntimeSnapshot, String> {
    let supplied = (!api_key.trim().is_empty()).then_some(api_key.trim().to_string());
    let stored = load_api_key(&settings.provider_id)?;
    let effective = supplied.as_deref().or(stored.as_deref());
    state
        .kernel
        .validate_provider(&settings, effective)
        .await
        .map_err(|error| error.to_string())?;
    if let Some(value) = supplied.as_deref() {
        save_api_key(&settings.provider_id, value)?;
    }
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
) -> Result<SubmitReceipt, String> {
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
    let kernel = state.kernel.clone();
    tauri::async_runtime::spawn(async move {
        let _ = kernel.run_queue(key).await;
    });
    Ok(receipt)
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
    answer: String,
) -> Result<bool, String> {
    let id = Uuid::parse_str(&thread_id).map_err(|error| error.to_string())?;
    let task = state
        .kernel
        .store()
        .task(id)
        .await
        .ok_or_else(|| format!("task not found: {id}"))?;
    if task.status != lingshu_runtime_core::TaskStatus::NeedsUserAction {
        return Ok(false);
    }
    let settings = state.kernel.store().settings().await;
    let key = load_api_key(&settings.provider_id)?;
    if provider_needs_key(&settings.provider_id) && key.is_none() {
        return Err(format!("{} requires an API token", settings.provider_name));
    }
    let kernel = state.kernel.clone();
    tauri::async_runtime::spawn(async move {
        if let Err(error) = kernel.resume(id, answer, key).await {
            let locale = kernel.store().settings().await.locale;
            let message = match locale {
                lingshu_runtime_core::AppLocale::ZhCn => {
                    format!("本轮恢复后未能完成：{error}。执行记录已保留。")
                }
                lingshu_runtime_core::AppLocale::En => {
                    format!("The resumed run could not complete: {error}. Its trace was preserved.")
                }
            };
            let _ = kernel.store().fail(id, message, error.to_string()).await;
        }
    });
    Ok(true)
}

#[tauri::command]
fn preview_path(path: PathBuf) -> Result<PreviewPayload, String> {
    preview_file(path).map_err(|error| error.to_string())
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

pub fn run() {
    let store =
        RuntimeStore::open(runtime_data_dir()).expect("LingShu runtime store must initialize");
    let kernel = RuntimeKernel::new(store, "windows")
        .expect("Windows capabilities must exist in the shared kernel contract");
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState { kernel })
        .invoke_handler(tauri::generate_handler![
            bootstrap,
            get_snapshot,
            save_and_validate_settings,
            update_execution_permission_mode,
            submit_message,
            cancel_task,
            resume_task,
            preview_path,
            open_external,
            reveal_path,
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
