#![recursion_limit = "256"]

pub mod artifacts;
pub mod contract;
pub mod engine;
mod loop_gateway;
pub mod loops;
pub mod memory;
pub mod model_client;
pub mod models;
pub mod plugins;
pub mod preview;
mod process;
pub mod providers;
pub mod store;
mod workspace_delta;

pub use contract::{
    kernel_contract, KernelContract, KernelInterfaceContract, PlatformCapabilities,
    KERNEL_ABI_VERSION, KERNEL_CONTRACT_JSON,
};
pub use engine::{EngineError, RuntimeKernel};
pub use loops::{LoopError, LoopExecution, LoopExecutionRequest, LoopRegistry};
pub use memory::{MemoryError, MemoryKernel};
pub use models::*;
pub use plugins::{PluginError, PluginRegistry};
pub use preview::{preview_file, PreviewKind, PreviewPayload};
pub use providers::{provider_catalog, ProviderPreset};
pub use store::RuntimeStore;
