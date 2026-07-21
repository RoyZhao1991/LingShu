//! First-run provider setup for the interactive pager.

use anyhow::{Context, Result};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode};
use std::io::{self, IsTerminal, Write};
use xai_grok_shell::provider_catalog::{
    CatalogError, ModelCatalogCache, ProviderAccount, ProviderKind, ProviderStore, discover_models,
    load_cache, load_store, save_cache, save_store,
};

/// Prepare the provider selected by the user before the ACP agent starts.
///
/// Existing provider accounts are refreshed on every launch. A cached catalog
/// is accepted only for transient discovery failures; rejected credentials
/// return to setup. Existing xAI browser auth and hand-written BYOK config are
/// left alone.
pub async fn ensure_provider_ready(raw_config: &toml::Value, has_xai_session: bool) -> Result<()> {
    let mut store = load_store().context("failed to load provider credentials")?;
    let mut cache = load_cache().context("failed to load provider model cache")?;

    if let Some((provider_id, account)) = store
        .active()
        .map(|(id, account)| (id.to_string(), account.clone()))
        .filter(|(_, account)| account.enabled && !account.api_key.trim().is_empty())
    {
        print!(
            "Refreshing {} model catalog... ",
            account.kind.display_name()
        );
        io::stdout().flush()?;
        match discover_models(&account).await {
            Ok(models) => {
                println!("{} models found.", models.len());
                update_cache(&provider_id, models, &mut cache)?;
                return Ok(());
            }
            Err(error)
                if cached_models_available(&provider_id, &cache) && !is_auth_error(&error) =>
            {
                println!("using cached catalog ({error}).");
                return Ok(());
            }
            Err(error) => {
                println!("failed: {error}");
                if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
                    return Err(error.into());
                }
                println!("The saved provider needs attention. Choose a provider again.\n");
            }
        }
    } else if has_xai_session || raw_config_has_api_credentials(raw_config) {
        return Ok(());
    }

    if !io::stdin().is_terminal() || !io::stdout().is_terminal() {
        anyhow::bail!(
            "no usable authorization found; start Grok interactively to configure a provider"
        );
    }

    run_setup_wizard(&mut store, &mut cache).await
}

fn is_auth_error(error: &CatalogError) -> bool {
    matches!(error, CatalogError::Authentication { .. })
}

fn cached_models_available(provider_id: &str, cache: &ModelCatalogCache) -> bool {
    cache
        .catalogs
        .get(provider_id)
        .is_some_and(|catalog| !catalog.models.is_empty())
}

fn update_cache(
    provider_id: &str,
    models: Vec<String>,
    cache: &mut ModelCatalogCache,
) -> Result<()> {
    cache.catalogs.insert(
        provider_id.to_string(),
        xai_grok_shell::provider_catalog::CachedCatalog {
            fetched_at_unix: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            models,
        },
    );
    save_cache(cache).context("failed to save provider model cache")
}

async fn run_setup_wizard(store: &mut ProviderStore, cache: &mut ModelCatalogCache) -> Result<()> {
    loop {
        draw_provider_panel();
        let choice = read_line("Choose a channel [1-7]: ")?;
        if choice.trim() == "7" {
            // Preserve the upstream xAI browser-login flow. The normal welcome
            // screen will open it after the agent connects.
            return Ok(());
        }
        let Some(kind) = provider_kind_from_choice(choice.trim()) else {
            println!("Please enter a number from 1 to 7.\n");
            continue;
        };

        let mut account = ProviderAccount::new(kind, read_secret("API token: ")?);
        if kind == ProviderKind::OpenaiCompatible {
            let base_url = read_line("Inference base URL (for example https://host/v1): ")?;
            let models_url = read_line("Models URL (for example https://host/v1/models): ")?;
            account.base_url = Some(base_url.trim().trim_end_matches('/').to_string());
            account.models_url = Some(models_url.trim().to_string());
        }

        print!("Detecting models from {}... ", kind.display_name());
        io::stdout().flush()?;
        let models = match discover_models(&account).await {
            Ok(models) => {
                println!("{} models found.\n", models.len());
                models
            }
            Err(error) => {
                println!("failed: {error}\n");
                continue;
            }
        };
        let selected_model = choose_model(&models)?;
        account.selected_model = Some(selected_model.clone());

        let provider_id = kind.id().to_string();
        store.active_provider = Some(provider_id.clone());
        store.providers.insert(provider_id.clone(), account);
        save_store(store).context("failed to save provider credentials")?;
        update_cache(&provider_id, models, cache)?;
        println!(
            "\nConfigured {} with model {}. Starting Grok...\n",
            kind.display_name(),
            selected_model
        );
        return Ok(());
    }
}

fn draw_provider_panel() {
    println!();
    println!("┌─ Model provider setup ───────────────────────────────────┐");
    println!("│ No usable authorization was found.                      │");
    println!("│ Models are read live from the selected provider.        │");
    println!("├──────────────────────────────────────────────────────────┤");
    println!("│  1. xAI / Grok API token                                │");
    println!("│  2. OpenAI / GPT API token                              │");
    println!("│  3. Anthropic / Claude API token                        │");
    println!("│  4. Moonshot / Kimi API token                           │");
    println!("│  5. DeepSeek API token                                  │");
    println!("│  6. Other OpenAI-compatible provider                    │");
    println!("│  7. xAI browser login                                   │");
    println!("└──────────────────────────────────────────────────────────┘");
}

fn provider_kind_from_choice(choice: &str) -> Option<ProviderKind> {
    match choice {
        "1" => Some(ProviderKind::Xai),
        "2" => Some(ProviderKind::Openai),
        "3" => Some(ProviderKind::Anthropic),
        "4" => Some(ProviderKind::Kimi),
        "5" => Some(ProviderKind::Deepseek),
        "6" => Some(ProviderKind::OpenaiCompatible),
        _ => None,
    }
}

fn choose_model(models: &[String]) -> Result<String> {
    let mut visible: Vec<usize> = (0..models.len()).collect();
    loop {
        let shown = visible.len().min(30);
        for (row, model_index) in visible.iter().take(shown).enumerate() {
            println!("  {:>2}. {}", row + 1, models[*model_index]);
        }
        if visible.len() > shown {
            println!("  … {} more (type text to filter)", visible.len() - shown);
        }
        let input = read_line("Select a number, or type text to filter: ")?;
        let input = input.trim();
        if let Ok(number) = input.parse::<usize>()
            && number > 0
            && number <= shown
        {
            return Ok(models[visible[number - 1]].clone());
        }
        if let Some(model) = models.iter().find(|model| model.as_str() == input) {
            return Ok(model.clone());
        }
        let needle = input.to_ascii_lowercase();
        visible = models
            .iter()
            .enumerate()
            .filter(|(_, model)| model.to_ascii_lowercase().contains(&needle))
            .map(|(index, _)| index)
            .collect();
        if visible.is_empty() {
            println!("No detected model matches {input:?}.\n");
            visible = (0..models.len()).collect();
        } else {
            println!();
        }
    }
}

fn read_line(prompt: &str) -> Result<String> {
    print!("{prompt}");
    io::stdout().flush()?;
    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    Ok(input)
}

fn read_secret(prompt: &str) -> Result<String> {
    print!("{prompt}");
    io::stdout().flush()?;
    enable_raw_mode()?;
    let _raw_guard = RawModeGuard;
    let mut secret = String::new();
    loop {
        if let Event::Key(key) = event::read()? {
            if key.kind != KeyEventKind::Press {
                continue;
            }
            match key.code {
                KeyCode::Enter => {
                    println!();
                    return Ok(secret);
                }
                KeyCode::Char('c') if key.modifiers.contains(KeyModifiers::CONTROL) => {
                    println!();
                    anyhow::bail!("provider setup cancelled");
                }
                KeyCode::Char(ch) if !key.modifiers.contains(KeyModifiers::CONTROL) => {
                    secret.push(ch);
                    print!("•");
                    io::stdout().flush()?;
                }
                KeyCode::Backspace if secret.pop().is_some() => {
                    print!("\u{8} \u{8}");
                    io::stdout().flush()?;
                }
                _ => {}
            }
        }
    }
}

struct RawModeGuard;

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
    }
}

fn raw_config_has_api_credentials(raw: &toml::Value) -> bool {
    if xai_grok_shell::agent::auth_method::has_xai_api_key_env() {
        return true;
    }
    if xai_grok_shell::auth::read_api_key(&xai_grok_shell::util::grok_home::grok_home())
        .is_some_and(|key| !key.trim().is_empty())
    {
        return true;
    }
    raw.get("model")
        .and_then(toml::Value::as_table)
        .is_some_and(|models| {
            models.values().any(|model| {
                model
                    .get("api_key")
                    .and_then(toml::Value::as_str)
                    .is_some_and(|key| !key.trim().is_empty())
                    || model.get("env_key").is_some_and(configured_env_key_is_set)
            })
        })
}

fn configured_env_key_is_set(value: &toml::Value) -> bool {
    if let Some(name) = value.as_str() {
        return std::env::var(name).is_ok_and(|value| !value.trim().is_empty());
    }
    value.as_array().is_some_and(|names| {
        names.iter().any(|name| {
            name.as_str()
                .is_some_and(|name| std::env::var(name).is_ok_and(|value| !value.trim().is_empty()))
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_menu_maps_without_model_ids() {
        assert_eq!(provider_kind_from_choice("1"), Some(ProviderKind::Xai));
        assert_eq!(provider_kind_from_choice("5"), Some(ProviderKind::Deepseek));
        assert_eq!(
            provider_kind_from_choice("6"),
            Some(ProviderKind::OpenaiCompatible)
        );
        assert_eq!(provider_kind_from_choice("7"), None);
    }

    #[test]
    fn detects_existing_inline_byok_key() {
        let raw: toml::Value = toml::from_str(
            r#"
            [model.custom]
            model = "anything"
            base_url = "https://example.test/v1"
            api_key = "already-configured"
            context_window = 1000
            "#,
        )
        .unwrap();
        assert!(raw_config_has_api_credentials(&raw));
    }
}
