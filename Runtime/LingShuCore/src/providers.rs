use crate::models::ProviderProtocol;
use serde::Serialize;

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ProviderPreset {
    pub id: &'static str,
    pub name: &'static str,
    pub region: &'static str,
    pub endpoint: &'static str,
    pub protocol: ProviderProtocol,
    pub default_models: &'static [&'static str],
    pub requires_api_key: bool,
}

pub fn provider_catalog() -> Vec<ProviderPreset> {
    vec![
        ProviderPreset {
            id: "deepseek",
            name: "DeepSeek",
            region: "CN",
            endpoint: "https://api.deepseek.com",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["deepseek-chat", "deepseek-reasoner"],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "minimax-official",
            name: "MiniMax",
            region: "CN",
            endpoint: "https://api.minimaxi.com/v1",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["MiniMax-M3", "MiniMax-M2.7"],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "openai",
            name: "OpenAI",
            region: "Global",
            endpoint: "https://api.openai.com/v1",
            protocol: ProviderProtocol::OpenaiResponses,
            default_models: &["gpt-5.5", "gpt-5", "gpt-4.1", "gpt-4o"],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "anthropic",
            name: "Anthropic Claude",
            region: "Global",
            endpoint: "https://api.anthropic.com/v1",
            protocol: ProviderProtocol::AnthropicMessages,
            default_models: &["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "openrouter",
            name: "OpenRouter",
            region: "Global",
            endpoint: "https://openrouter.ai/api/v1",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &[
                "openai/gpt-5",
                "anthropic/claude-sonnet-4.5",
                "deepseek/deepseek-chat",
            ],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "qwen-dashscope",
            name: "Alibaba Qwen / DashScope",
            region: "CN",
            endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["qwen-max", "qwen-plus", "qwen3-coder-plus"],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "doubao",
            name: "Doubao / Volcengine",
            region: "CN",
            endpoint: "https://ark.cn-beijing.volces.com/api/v3",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["doubao-seed-1.6", "doubao-1.5-pro"],
            requires_api_key: true,
        },
        ProviderPreset {
            id: "ollama",
            name: "Ollama",
            region: "Local",
            endpoint: "http://localhost:11434/v1",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["qwen3:8b", "deepseek-r1:8b", "llama3.3"],
            requires_api_key: false,
        },
        ProviderPreset {
            id: "lm-studio",
            name: "LM Studio",
            region: "Local",
            endpoint: "http://localhost:1234/v1",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["local-model"],
            requires_api_key: false,
        },
        ProviderPreset {
            id: "custom-compatible",
            name: "Custom OpenAI-compatible",
            region: "Custom",
            endpoint: "https://your-gateway.example.com/v1",
            protocol: ProviderProtocol::OpenaiChatCompletions,
            default_models: &["custom-model"],
            requires_api_key: true,
        },
    ]
}
