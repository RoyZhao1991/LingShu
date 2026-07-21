//! Multi-provider credentials and dynamically discovered model catalogs.
//!
//! Provider presets intentionally contain protocol metadata and endpoints only.
//! Model identifiers always come from the provider's model-list endpoint (or a
//! previously fetched cache when that endpoint is temporarily unavailable).

use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fs;
use std::io;
use std::num::NonZeroU64;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use thiserror::Error;

const PROVIDERS_FILE: &str = "providers.toml";
const MODEL_CACHE_FILE: &str = "provider_models_cache.json";
const DEFAULT_CONTEXT_WINDOW: u64 = 200_000;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Xai,
    Openai,
    Anthropic,
    Kimi,
    Deepseek,
    OpenaiCompatible,
}

impl ProviderKind {
    pub const BUILT_INS: [Self; 5] = [
        Self::Xai,
        Self::Openai,
        Self::Anthropic,
        Self::Kimi,
        Self::Deepseek,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Xai => "xai",
            Self::Openai => "openai",
            Self::Anthropic => "anthropic",
            Self::Kimi => "kimi",
            Self::Deepseek => "deepseek",
            Self::OpenaiCompatible => "openai_compatible",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Xai => "xAI / Grok",
            Self::Openai => "OpenAI / GPT",
            Self::Anthropic => "Anthropic / Claude",
            Self::Kimi => "Moonshot / Kimi",
            Self::Deepseek => "DeepSeek",
            Self::OpenaiCompatible => "OpenAI-compatible",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProviderBackend {
    ChatCompletions,
    Responses,
    Messages,
}

#[derive(Clone, Copy, Debug)]
struct ProviderPreset {
    base_url: &'static str,
    models_url: &'static str,
    backend: ProviderBackend,
}

fn preset(kind: ProviderKind) -> Option<ProviderPreset> {
    match kind {
        ProviderKind::Xai => Some(ProviderPreset {
            base_url: "https://api.x.ai/v1",
            // The language-model endpoint excludes image/video-only models,
            // which cannot drive a code-agent conversation.
            models_url: "https://api.x.ai/v1/language-models",
            backend: ProviderBackend::ChatCompletions,
        }),
        ProviderKind::Openai => Some(ProviderPreset {
            base_url: "https://api.openai.com/v1",
            models_url: "https://api.openai.com/v1/models",
            backend: ProviderBackend::Responses,
        }),
        ProviderKind::Anthropic => Some(ProviderPreset {
            base_url: "https://api.anthropic.com/v1",
            models_url: "https://api.anthropic.com/v1/models",
            backend: ProviderBackend::Messages,
        }),
        ProviderKind::Kimi => Some(ProviderPreset {
            base_url: "https://api.moonshot.ai/v1",
            models_url: "https://api.moonshot.ai/v1/models",
            backend: ProviderBackend::ChatCompletions,
        }),
        ProviderKind::Deepseek => Some(ProviderPreset {
            base_url: "https://api.deepseek.com",
            models_url: "https://api.deepseek.com/models",
            backend: ProviderBackend::ChatCompletions,
        }),
        ProviderKind::OpenaiCompatible => None,
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct ProviderAccount {
    pub kind: ProviderKind,
    pub api_key: String,
    pub base_url: Option<String>,
    pub models_url: Option<String>,
    pub selected_model: Option<String>,
    pub context_window: u64,
    pub enabled: bool,
}

impl Default for ProviderAccount {
    fn default() -> Self {
        Self {
            kind: ProviderKind::Openai,
            api_key: String::new(),
            base_url: None,
            models_url: None,
            selected_model: None,
            context_window: DEFAULT_CONTEXT_WINDOW,
            enabled: true,
        }
    }
}

impl ProviderAccount {
    pub fn new(kind: ProviderKind, api_key: String) -> Self {
        Self {
            kind,
            api_key,
            ..Self::default()
        }
    }

    fn effective_base_url(&self) -> Result<&str, CatalogError> {
        self.base_url
            .as_deref()
            .or_else(|| preset(self.kind).map(|p| p.base_url))
            .filter(|url| !url.trim().is_empty())
            .ok_or(CatalogError::MissingEndpoint("base URL"))
    }

    fn effective_models_url(&self) -> Result<&str, CatalogError> {
        self.models_url
            .as_deref()
            .or_else(|| preset(self.kind).map(|p| p.models_url))
            .filter(|url| !url.trim().is_empty())
            .ok_or(CatalogError::MissingEndpoint("models URL"))
    }

    fn backend(&self) -> ProviderBackend {
        preset(self.kind)
            .map(|p| p.backend)
            .unwrap_or(ProviderBackend::ChatCompletions)
    }
}

#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct ProviderStore {
    pub active_provider: Option<String>,
    pub providers: IndexMap<String, ProviderAccount>,
}

impl ProviderStore {
    pub fn has_enabled_provider(&self) -> bool {
        self.providers
            .values()
            .any(|provider| provider.enabled && !provider.api_key.trim().is_empty())
    }

    pub fn active(&self) -> Option<(&str, &ProviderAccount)> {
        let id = self.active_provider.as_deref()?;
        self.providers
            .get_key_value(id)
            .map(|(id, account)| (id.as_str(), account))
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct ModelCatalogCache {
    pub catalogs: IndexMap<String, CachedCatalog>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct CachedCatalog {
    pub fetched_at_unix: u64,
    pub models: Vec<String>,
}

#[derive(Debug, Error)]
pub enum CatalogError {
    #[error("provider {0} is not configured")]
    MissingEndpoint(&'static str),
    #[error("the provider rejected this API token ({status})")]
    Authentication { status: reqwest::StatusCode },
    #[error("the provider returned HTTP {status}: {body}")]
    Http {
        status: reqwest::StatusCode,
        body: String,
    },
    #[error("could not reach the provider: {0}")]
    Network(#[from] reqwest::Error),
    #[error("invalid model-list response: {0}")]
    Protocol(String),
    #[error("the provider returned an empty model list")]
    Empty,
    #[error("provider configuration error: {0}")]
    Config(String),
    #[error(transparent)]
    Io(#[from] io::Error),
    #[error(transparent)]
    TomlDeserialize(#[from] toml::de::Error),
    #[error(transparent)]
    TomlSerialize(#[from] toml::ser::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

#[derive(Debug, Deserialize)]
struct ModelsPage {
    // OpenAI-compatible APIs use `data`; xAI's richer language-model
    // endpoint uses `models`.
    #[serde(default, alias = "models")]
    data: Vec<ModelListEntry>,
    #[serde(default)]
    has_more: bool,
    last_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ModelListEntry {
    id: String,
}

pub fn providers_path() -> PathBuf {
    xai_grok_config::grok_home().join(PROVIDERS_FILE)
}

pub fn cache_path() -> PathBuf {
    xai_grok_config::grok_home().join(MODEL_CACHE_FILE)
}

pub fn load_store() -> Result<ProviderStore, CatalogError> {
    load_store_from(&providers_path())
}

fn load_store_from(path: &Path) -> Result<ProviderStore, CatalogError> {
    match fs::read_to_string(path) {
        Ok(contents) => Ok(toml::from_str(&contents)?),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(ProviderStore::default()),
        Err(error) => Err(error.into()),
    }
}

pub fn save_store(store: &ProviderStore) -> Result<(), CatalogError> {
    save_store_to(&providers_path(), store)
}

fn save_store_to(path: &Path, store: &ProviderStore) -> Result<(), CatalogError> {
    let contents = toml::to_string_pretty(store)?;
    write_private_file(path, contents.as_bytes())?;
    Ok(())
}

pub fn load_cache() -> Result<ModelCatalogCache, CatalogError> {
    load_cache_from(&cache_path())
}

fn load_cache_from(path: &Path) -> Result<ModelCatalogCache, CatalogError> {
    match fs::read(path) {
        Ok(contents) => Ok(serde_json::from_slice(&contents)?),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(ModelCatalogCache::default()),
        Err(error) => Err(error.into()),
    }
}

pub fn save_cache(cache: &ModelCatalogCache) -> Result<(), CatalogError> {
    let contents = serde_json::to_vec_pretty(cache)?;
    write_private_file(&cache_path(), &contents)?;
    Ok(())
}

fn write_private_file(path: &Path, contents: &[u8]) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let temp = path.with_extension("tmp");
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let mut file = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&temp)?;
        io::Write::write_all(&mut file, contents)?;
        file.sync_all()?;
        fs::set_permissions(&temp, fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    {
        fs::write(&temp, contents)?;
    }
    fs::rename(temp, path)?;
    Ok(())
}

pub async fn discover_models(account: &ProviderAccount) -> Result<Vec<String>, CatalogError> {
    if account.api_key.trim().is_empty() {
        return Err(CatalogError::Config("API token is empty".to_string()));
    }

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(25))
        .build()?;
    let mut after_id: Option<String> = None;
    let mut models = Vec::new();
    let mut seen = HashSet::new();

    loop {
        let mut request = client.get(account.effective_models_url()?);
        if account.kind == ProviderKind::Anthropic {
            request = request
                .header("x-api-key", account.api_key.trim())
                .header("anthropic-version", "2023-06-01")
                .query(&[("limit", "1000")]);
            if let Some(after_id) = after_id.as_deref() {
                request = request.query(&[("after_id", after_id)]);
            }
        } else {
            request = request.bearer_auth(account.api_key.trim());
        }

        let response = request.send().await?;
        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(CatalogError::Authentication { status });
        }
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(CatalogError::Http {
                status,
                body: body.chars().take(300).collect(),
            });
        }

        let page: ModelsPage = response
            .json()
            .await
            .map_err(|error| CatalogError::Protocol(error.to_string()))?;
        for entry in page.data {
            let id = entry.id.trim();
            if !id.is_empty() && seen.insert(id.to_string()) {
                models.push(id.to_string());
            }
        }

        if account.kind != ProviderKind::Anthropic || !page.has_more {
            break;
        }
        let Some(last_id) = page.last_id.filter(|id| !id.trim().is_empty()) else {
            return Err(CatalogError::Protocol(
                "Anthropic returned has_more=true without last_id".to_string(),
            ));
        };
        after_id = Some(last_id);
    }

    if models.is_empty() {
        return Err(CatalogError::Empty);
    }
    Ok(models)
}

pub async fn refresh_provider(
    provider_id: &str,
    account: &ProviderAccount,
    cache: &mut ModelCatalogCache,
) -> Result<Vec<String>, CatalogError> {
    let models = discover_models(account).await?;
    let fetched_at_unix = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    cache.catalogs.insert(
        provider_id.to_string(),
        CachedCatalog {
            fetched_at_unix,
            models: models.clone(),
        },
    );
    save_cache(cache)?;
    Ok(models)
}

/// Inject provider models and credentials into an already merged config.
///
/// The API token exists only in this in-memory value; it is never copied into
/// `config.toml`. Catalog keys are namespaced (`provider/model`) to avoid model
/// ID collisions between vendors.
pub fn materialize_provider_config(
    raw_config: &mut toml::Value,
    store: &ProviderStore,
    cache: &ModelCatalogCache,
) -> Result<bool, CatalogError> {
    let Some((active_id, active)) = store.active() else {
        return Ok(false);
    };
    if !active.enabled || active.api_key.trim().is_empty() {
        return Ok(false);
    }

    let cached_models = cache
        .catalogs
        .get(active_id)
        .map(|catalog| catalog.models.clone())
        .unwrap_or_default();
    let mut models = cached_models;
    if let Some(selected) = active.selected_model.as_deref()
        && !selected.trim().is_empty()
        && !models.iter().any(|model| model == selected)
    {
        // Never silently switch away from a user's selection merely because a
        // provider temporarily omitted it from a later catalog response.
        models.push(selected.to_string());
    }
    if models.is_empty() {
        return Ok(false);
    }

    let root = raw_config
        .as_table_mut()
        .ok_or_else(|| CatalogError::Config("effective config root is not a table".to_string()))?;
    let model_table = root
        .entry("model")
        .or_insert_with(|| toml::Value::Table(toml::map::Map::new()))
        .as_table_mut()
        .ok_or_else(|| CatalogError::Config("`model` is not a table".to_string()))?;

    let context_window = NonZeroU64::new(active.context_window)
        .unwrap_or_else(|| NonZeroU64::new(DEFAULT_CONTEXT_WINDOW).unwrap())
        .get() as i64;
    let mut allowed_models = Vec::with_capacity(models.len());
    for model_id in &models {
        let catalog_key = format!("{active_id}/{model_id}");
        allowed_models.push(toml::Value::String(catalog_key.clone()));
        let mut entry = toml::map::Map::new();
        entry.insert("model".to_string(), toml::Value::String(model_id.clone()));
        entry.insert(
            "base_url".to_string(),
            toml::Value::String(active.effective_base_url()?.to_string()),
        );
        entry.insert(
            "api_key".to_string(),
            toml::Value::String(active.api_key.clone()),
        );
        entry.insert(
            "api_backend".to_string(),
            toml::Value::String(
                match active.backend() {
                    ProviderBackend::ChatCompletions => "chat_completions",
                    ProviderBackend::Responses => "responses",
                    ProviderBackend::Messages => "messages",
                }
                .to_string(),
            ),
        );
        entry.insert(
            "context_window".to_string(),
            toml::Value::Integer(context_window),
        );
        entry.insert("supported_in_api".to_string(), toml::Value::Boolean(true));
        entry.insert("name".to_string(), toml::Value::String(model_id.clone()));
        if active.kind == ProviderKind::Anthropic {
            entry.insert(
                "auth_scheme".to_string(),
                toml::Value::String("x_api_key".to_string()),
            );
            let mut headers = toml::map::Map::new();
            headers.insert(
                "anthropic-version".to_string(),
                toml::Value::String("2023-06-01".to_string()),
            );
            entry.insert("extra_headers".to_string(), toml::Value::Table(headers));
        }
        model_table.insert(catalog_key, toml::Value::Table(entry));
    }

    let selected = active
        .selected_model
        .as_deref()
        .filter(|selected| models.iter().any(|model| model == *selected))
        .unwrap_or(&models[0]);
    let models_table = root
        .entry("models")
        .or_insert_with(|| toml::Value::Table(toml::map::Map::new()))
        .as_table_mut()
        .ok_or_else(|| CatalogError::Config("`models` is not a table".to_string()))?;
    models_table.insert(
        "default".to_string(),
        toml::Value::String(format!("{active_id}/{selected}")),
    );
    models_table.insert(
        "allowed_models".to_string(),
        toml::Value::Array(allowed_models),
    );
    Ok(true)
}

pub fn materialize_saved_providers(raw_config: &mut toml::Value) -> Result<bool, CatalogError> {
    let store = load_store()?;
    let cache = load_cache()?;
    materialize_provider_config(raw_config, &store, &cache)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presets_contain_endpoints_but_no_model_ids() {
        for kind in ProviderKind::BUILT_INS {
            let preset = preset(kind).unwrap();
            assert!(
                preset
                    .models_url
                    .rsplit('/')
                    .next()
                    .is_some_and(|segment| segment.contains("models"))
            );
            assert!(!preset.base_url.is_empty());
        }
    }

    #[test]
    fn materializes_every_discovered_model_and_selected_default() {
        let account = ProviderAccount {
            kind: ProviderKind::Anthropic,
            api_key: "secret-token".to_string(),
            selected_model: Some("model-from-api-b".to_string()),
            ..ProviderAccount::default()
        };
        let store = ProviderStore {
            active_provider: Some("anthropic".to_string()),
            providers: IndexMap::from_iter([("anthropic".to_string(), account)]),
        };
        let cache = ModelCatalogCache {
            catalogs: IndexMap::from_iter([(
                "anthropic".to_string(),
                CachedCatalog {
                    fetched_at_unix: 1,
                    models: vec![
                        "model-from-api-a".to_string(),
                        "model-from-api-b".to_string(),
                    ],
                },
            )]),
        };
        let mut raw = toml::Value::Table(toml::map::Map::new());

        assert!(materialize_provider_config(&mut raw, &store, &cache).unwrap());
        assert_eq!(
            raw["models"]["default"].as_str(),
            Some("anthropic/model-from-api-b")
        );
        assert_eq!(
            raw["model"]["anthropic/model-from-api-a"]["model"].as_str(),
            Some("model-from-api-a")
        );
        assert_eq!(
            raw["model"]["anthropic/model-from-api-a"]["auth_scheme"].as_str(),
            Some("x_api_key")
        );
        assert_eq!(
            raw["model"]["anthropic/model-from-api-a"]["api_key"].as_str(),
            Some("secret-token")
        );
    }

    #[cfg(unix)]
    #[test]
    fn provider_credentials_are_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(PROVIDERS_FILE);
        save_store_to(&path, &ProviderStore::default()).unwrap();
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn parses_openai_and_anthropic_model_pages_without_known_ids() {
        let openai: ModelsPage = serde_json::from_str(
            r#"{"object":"list","data":[{"id":"server-model-1"},{"id":"server-model-2"}]}"#,
        )
        .unwrap();
        assert_eq!(openai.data[0].id, "server-model-1");

        let anthropic: ModelsPage = serde_json::from_str(
            r#"{"data":[{"id":"server-model-3"}],"has_more":true,"last_id":"cursor"}"#,
        )
        .unwrap();
        assert!(anthropic.has_more);
        assert_eq!(anthropic.last_id.as_deref(), Some("cursor"));

        let xai_language_models: ModelsPage =
            serde_json::from_str(r#"{"models":[{"id":"server-language-model"}]}"#).unwrap();
        assert_eq!(xai_language_models.data[0].id, "server-language-model");
    }

    #[tokio::test]
    async fn discovers_server_returned_models_with_bearer_auth() {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 4096];
            let bytes = stream.read(&mut request).unwrap();
            let request = String::from_utf8_lossy(&request[..bytes]);
            assert!(request.starts_with("GET /v1/models "));
            assert!(
                request
                    .to_ascii_lowercase()
                    .contains("authorization: bearer token-used-only-for-this-test")
            );
            let body = r#"{"data":[{"id":"only-the-server-knows-this-model"}]}"#;
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });

        let models_url = format!("http://{address}/v1/models");
        let account = ProviderAccount {
            kind: ProviderKind::OpenaiCompatible,
            api_key: "token-used-only-for-this-test".to_string(),
            base_url: Some(format!("http://{address}/v1")),
            models_url: Some(models_url),
            ..ProviderAccount::default()
        };
        let models = discover_models(&account).await.unwrap();
        server.join().unwrap();
        assert_eq!(models, vec!["only-the-server-knows-this-model"]);
    }
}
