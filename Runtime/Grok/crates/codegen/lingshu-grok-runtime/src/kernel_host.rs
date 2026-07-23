use libc::{c_char, c_int, c_void};
use lingshu_runtime_core::{
    provider_catalog, RuntimeKernel, RuntimeSettings, RuntimeStore, KERNEL_ABI_VERSION,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{CStr, CString};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use tokio::sync::{mpsc, RwLock};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

type EventCallback = extern "C" fn(*const c_char, *mut c_void);

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct KernelStartConfig {
    data_dir: PathBuf,
    #[serde(default = "default_platform")]
    platform: String,
}

fn default_platform() -> String {
    "macos".into()
}

#[derive(Debug, Deserialize)]
struct RPCRequest {
    id: u64,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ConfigureParams {
    settings: RuntimeSettings,
    #[serde(default)]
    api_key: Option<String>,
    #[serde(default = "default_true")]
    provider_configured: bool,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotParams {
    #[serde(default = "default_true")]
    provider_configured: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubmitParams {
    prompt: String,
    #[serde(default)]
    attachment_paths: Vec<PathBuf>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ThreadParams {
    thread_id: Uuid,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResumeParams {
    thread_id: Uuid,
    answer: String,
}

struct KernelHandle {
    input: mpsc::UnboundedSender<String>,
    shutdown: CancellationToken,
    thread: Option<std::thread::JoinHandle<()>>,
}

static KERNEL_RUNTIME: OnceLock<Mutex<Option<KernelHandle>>> = OnceLock::new();

fn kernel_slot() -> &'static Mutex<Option<KernelHandle>> {
    KERNEL_RUNTIME.get_or_init(|| Mutex::new(None))
}

fn emit(callback: Option<EventCallback>, context: usize, value: Value) {
    let Some(callback) = callback else { return };
    let Ok(text) = CString::new(value.to_string()) else {
        return;
    };
    callback(text.as_ptr(), context as *mut c_void);
}

fn response(id: u64, result: Result<Value, String>) -> Value {
    match result {
        Ok(result) => json!({"jsonrpc":"2.0","id":id,"result":result}),
        Err(message) => json!({
            "jsonrpc":"2.0",
            "id":id,
            "error":{"code":-32000,"message":message}
        }),
    }
}

fn decoded<T: for<'de> Deserialize<'de>>(value: Value) -> Result<T, String> {
    serde_json::from_value(value).map_err(|error| error.to_string())
}

async fn process_request(
    kernel: &RuntimeKernel,
    api_key: &Arc<RwLock<Option<String>>>,
    request: RPCRequest,
    callback: Option<EventCallback>,
    context: usize,
) -> Value {
    let id = request.id;
    let result = match request.method.as_str() {
        "kernel/ping" => Ok(json!({
            "ok": true,
            "kernelAbiVersion": KERNEL_ABI_VERSION,
        })),
        "kernel/providers" => serde_json::to_value(provider_catalog()).map_err(|e| e.to_string()),
        "kernel/configure" => match decoded::<ConfigureParams>(request.params) {
            Ok(params) => {
                let configured = params.provider_configured;
                let key = params.api_key.and_then(|value| {
                    let trimmed = value.trim().to_string();
                    (!trimmed.is_empty()).then_some(trimmed)
                });
                *api_key.write().await = key;
                match kernel.store().update_settings(params.settings).await {
                    Ok(()) => serde_json::to_value(kernel.snapshot(configured).await)
                        .map_err(|error| error.to_string()),
                    Err(error) => Err(error.to_string()),
                }
            }
            Err(error) => Err(error),
        },
        "kernel/snapshot" => match decoded::<SnapshotParams>(request.params) {
            Ok(params) => serde_json::to_value(kernel.snapshot(params.provider_configured).await)
                .map_err(|error| error.to_string()),
            Err(error) => Err(error),
        },
        "kernel/submit" => match decoded::<SubmitParams>(request.params) {
            Ok(params) if params.prompt.trim().is_empty() => Err("message is empty".into()),
            Ok(params) => match kernel.submit(params.prompt, params.attachment_paths).await {
                Ok(receipt) => {
                    let worker = kernel.clone();
                    let worker_key = api_key.read().await.clone();
                    tokio::spawn(async move {
                        if let Err(error) = worker.run_queue(worker_key).await {
                            emit(
                                callback,
                                context,
                                json!({
                                    "jsonrpc":"2.0",
                                    "method":"kernel/runtime_error",
                                    "params":{"message":error.to_string()}
                                }),
                            );
                        }
                    });
                    serde_json::to_value(receipt).map_err(|error| error.to_string())
                }
                Err(error) => Err(error.to_string()),
            },
            Err(error) => Err(error),
        },
        "kernel/resume" => match decoded::<ResumeParams>(request.params) {
            Ok(params) => {
                let worker = kernel.clone();
                let worker_key = api_key.read().await.clone();
                tokio::spawn(async move {
                    if let Err(error) = worker
                        .resume(params.thread_id, params.answer, worker_key)
                        .await
                    {
                        emit(
                            callback,
                            context,
                            json!({
                                "jsonrpc":"2.0",
                                "method":"kernel/runtime_error",
                                "params":{
                                    "threadId":params.thread_id,
                                    "message":error.to_string()
                                }
                            }),
                        );
                    }
                });
                Ok(json!({"accepted":true}))
            }
            Err(error) => Err(error),
        },
        "kernel/cancel" => match decoded::<ThreadParams>(request.params) {
            Ok(params) => kernel
                .cancel(params.thread_id)
                .await
                .map(|cancelled| json!({"cancelled":cancelled}))
                .map_err(|error| error.to_string()),
            Err(error) => Err(error),
        },
        other => Err(format!("unknown kernel method: {other}")),
    };
    response(id, result)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lingshu_kernel_runtime_start(
    config_json: *const c_char,
    callback: Option<EventCallback>,
    context: *mut c_void,
) -> c_int {
    if config_json.is_null() {
        return 1;
    }
    let mut slot = kernel_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if slot.is_some() {
        return 0;
    }
    let config_text = unsafe { CStr::from_ptr(config_json) };
    let Ok(config_text) = config_text.to_str() else {
        return 2;
    };
    let Ok(config) = serde_json::from_str::<KernelStartConfig>(config_text) else {
        return 3;
    };
    let Ok(store) = RuntimeStore::open(&config.data_dir) else {
        return 4;
    };
    let Ok(kernel) = RuntimeKernel::new(store, config.platform) else {
        return 5;
    };
    let (input_tx, mut input_rx) = mpsc::unbounded_channel::<String>();
    let shutdown = CancellationToken::new();
    let thread_shutdown = shutdown.clone();
    let callback_context = context as usize;
    let thread = std::thread::Builder::new()
        .name("lingshu-shared-kernel".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(4)
                .enable_all()
                .thread_name("lingshu-kernel-worker")
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    emit(
                        callback,
                        callback_context,
                        json!({
                            "kind":"kernel_runtime",
                            "status":"failed",
                            "error":error.to_string()
                        }),
                    );
                    return;
                }
            };
            runtime.block_on(async move {
                let api_key = Arc::new(RwLock::new(None));
                emit(
                    callback,
                    callback_context,
                    json!({
                        "kind":"kernel_runtime",
                        "status":"ready",
                        "kernelAbiVersion":KERNEL_ABI_VERSION
                    }),
                );
                loop {
                    tokio::select! {
                        _ = thread_shutdown.cancelled() => break,
                        message = input_rx.recv() => {
                            let Some(message) = message else { break };
                            let value = match serde_json::from_str::<RPCRequest>(&message) {
                                Ok(request) => process_request(
                                    &kernel,
                                    &api_key,
                                    request,
                                    callback,
                                    callback_context,
                                ).await,
                                Err(error) => json!({
                                    "jsonrpc":"2.0",
                                    "id":Value::Null,
                                    "error":{"code":-32700,"message":error.to_string()}
                                }),
                            };
                            emit(callback, callback_context, value);
                        }
                    }
                }
            });
        });
    let Ok(thread) = thread else { return 6 };
    *slot = Some(KernelHandle {
        input: input_tx,
        shutdown,
        thread: Some(thread),
    });
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lingshu_kernel_runtime_send(message: *const c_char) -> c_int {
    if message.is_null() {
        return 1;
    }
    let message = unsafe { CStr::from_ptr(message) };
    let Ok(message) = message.to_str() else {
        return 2;
    };
    let slot = kernel_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(runtime) = slot.as_ref() else {
        return 3;
    };
    runtime
        .input
        .send(message.to_string())
        .map(|_| 0)
        .unwrap_or(4)
}

#[unsafe(no_mangle)]
pub extern "C" fn lingshu_kernel_runtime_is_running() -> bool {
    kernel_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .is_some()
}

#[unsafe(no_mangle)]
pub extern "C" fn lingshu_kernel_runtime_stop() {
    let mut slot = kernel_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let Some(mut runtime) = slot.take() else {
        return;
    };
    runtime.shutdown.cancel();
    if let Some(thread) = runtime.thread.take() {
        let _ = thread.join();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use lingshu_runtime_core::{AppLocale, ExecutionPermissionMode, ProviderProtocol};
    use tempfile::tempdir;

    #[tokio::test]
    async fn shared_kernel_rpc_uses_the_canonical_runtime_kernel() {
        let root = tempdir().unwrap();
        let store = RuntimeStore::open(root.path()).unwrap();
        let kernel = RuntimeKernel::new(store, "macos").unwrap();
        let api_key = Arc::new(RwLock::new(None));
        let workspace = root.path().join("workspace");
        let settings = RuntimeSettings {
            locale: AppLocale::En,
            provider_id: "test".into(),
            provider_name: "Test".into(),
            protocol: ProviderProtocol::OpenaiChatCompletions,
            endpoint: "https://example.invalid/v1".into(),
            model: "test-model".into(),
            workspace: workspace.clone(),
            execution_permission_mode: ExecutionPermissionMode::FullAccess,
            first_run_complete: true,
        };
        let request = RPCRequest {
            id: 7,
            method: "kernel/configure".into(),
            params: json!({
                "settings":settings,
                "apiKey":"secret",
                "providerConfigured":true
            }),
        };
        let value = process_request(&kernel, &api_key, request, None, 0).await;
        assert_eq!(value["id"], 7);
        assert_eq!(value["result"]["platform"], "macos");
        assert_eq!(
            value["result"]["settings"]["workspace"],
            workspace.to_string_lossy().as_ref()
        );
        assert_eq!(
            value["result"]["settings"]["executionPermissionMode"],
            "full_access"
        );
        assert_eq!(api_key.read().await.as_deref(), Some("secret"));
    }
}
