use libc::{c_char, c_int, c_void};
use lingshu_runtime_core::{KERNEL_ABI_VERSION, KERNEL_CONTRACT_JSON};
use serde::Deserialize;
use std::ffi::{CStr, CString};
use std::sync::{Mutex, OnceLock};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use xai_grok_shell::agent::app::run_embedded_agent;
use xai_grok_shell::agent::config::{AgentMode, Config as AgentConfig};

type EventCallback = extern "C" fn(*const c_char, *mut c_void);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeStartConfig {
    grok_home: String,
    config_toml: String,
    #[serde(default)]
    environment: std::collections::HashMap<String, String>,
}

struct RuntimeHandle {
    input: mpsc::UnboundedSender<String>,
    shutdown: CancellationToken,
    thread: Option<std::thread::JoinHandle<()>>,
}

static RUNTIME: OnceLock<Mutex<Option<RuntimeHandle>>> = OnceLock::new();
static KERNEL_CONTRACT_C_STRING: OnceLock<CString> = OnceLock::new();

fn runtime_slot() -> &'static Mutex<Option<RuntimeHandle>> {
    RUNTIME.get_or_init(|| Mutex::new(None))
}

fn emit(callback: Option<EventCallback>, context: usize, value: serde_json::Value) {
    let Some(callback) = callback else { return };
    let Ok(text) = CString::new(value.to_string()) else {
        return;
    };
    callback(text.as_ptr(), context as *mut c_void);
}

fn parse_config(config: &RuntimeStartConfig) -> Result<AgentConfig, String> {
    let raw = if config.config_toml.trim().is_empty() {
        toml::Value::Table(toml::map::Map::new())
    } else {
        toml::from_str::<toml::Value>(&config.config_toml).map_err(|error| error.to_string())?
    };
    let mut agent = AgentConfig::new_from_toml_cfg(&raw)?;
    agent.mode = AgentMode::Generic;
    Ok(agent)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lingshu_grok_runtime_start(
    config_json: *const c_char,
    callback: Option<EventCallback>,
    context: *mut c_void,
) -> c_int {
    if config_json.is_null() {
        return 1;
    }

    let mut slot = runtime_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if slot.is_some() {
        return 0;
    }

    let config_text = unsafe { CStr::from_ptr(config_json) };
    let Ok(config_text) = config_text.to_str() else {
        return 2;
    };
    let Ok(config) = serde_json::from_str::<RuntimeStartConfig>(config_text) else {
        return 3;
    };
    unsafe { std::env::set_var("GROK_HOME", &config.grok_home) };
    for (key, value) in &config.environment {
        unsafe { std::env::set_var(key, value) };
    }
    let Ok(agent_config) = parse_config(&config) else {
        return 4;
    };

    let (input_tx, input_rx) = mpsc::unbounded_channel::<String>();
    let (output_tx, mut output_rx) = mpsc::unbounded_channel::<String>();
    let shutdown = CancellationToken::new();
    let thread_shutdown = shutdown.clone();
    let callback_context = context as usize;

    let thread = std::thread::Builder::new()
        .name("lingshu-agent-runtime".to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .thread_name("lingshu-agent-worker")
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    emit(
                        callback,
                        callback_context,
                        serde_json::json!({
                            "kind": "runtime",
                            "status": "failed",
                            "error": error.to_string(),
                        }),
                    );
                    return;
                }
            };

            runtime.block_on(async move {
                emit(
                    callback,
                    callback_context,
                    serde_json::json!({
                        "kind": "runtime",
                        "status": "starting",
                        "kernelAbiVersion": KERNEL_ABI_VERSION,
                    }),
                );

                let output_task = tokio::spawn(async move {
                    while let Some(message) = output_rx.recv().await {
                        let value = serde_json::from_str(&message).unwrap_or_else(
                            |_| serde_json::json!({ "kind": "raw", "payload": message }),
                        );
                        emit(callback, callback_context, value);
                    }
                });

                let result = run_embedded_agent(
                    &agent_config,
                    input_rx,
                    output_tx,
                    thread_shutdown.clone(),
                    None,
                )
                .await;

                if let Err(error) = result {
                    emit(
                        callback,
                        callback_context,
                        serde_json::json!({
                            "kind": "runtime",
                            "status": "failed",
                            "error": error.to_string(),
                        }),
                    );
                }
                thread_shutdown.cancel();
                output_task.abort();
            });
        });

    let Ok(thread) = thread else { return 5 };
    *slot = Some(RuntimeHandle {
        input: input_tx,
        shutdown,
        thread: Some(thread),
    });
    0
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lingshu_grok_runtime_send(message: *const c_char) -> c_int {
    if message.is_null() {
        return 1;
    }
    let message = unsafe { CStr::from_ptr(message) };
    let Ok(message) = message.to_str() else {
        return 2;
    };
    let slot = runtime_slot()
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
pub extern "C" fn lingshu_grok_runtime_is_running() -> bool {
    runtime_slot()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .is_some()
}

#[unsafe(no_mangle)]
pub extern "C" fn lingshu_grok_runtime_stop() {
    let mut slot = runtime_slot()
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

#[unsafe(no_mangle)]
pub extern "C" fn lingshu_grok_runtime_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

#[unsafe(no_mangle)]
pub extern "C" fn lingshu_grok_runtime_kernel_contract() -> *const c_char {
    KERNEL_CONTRACT_C_STRING
        .get_or_init(|| {
            CString::new(KERNEL_CONTRACT_JSON).expect("kernel contract contains no NUL bytes")
        })
        .as_ptr()
}
