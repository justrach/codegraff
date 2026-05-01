use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::Context;
use bytes::Bytes;
use forge_app::domain::{McpConfig, McpServerConfig, Scope, ServerName};
use forge_app::{
    EnvironmentInfra, FileInfoInfra, FileReaderInfra, FileWriterInfra, KVStore, McpConfigManager,
    McpServerInfra,
};
use merge::Merge;

const BUNDLED_CODEDB_SERVER_NAME: &str = "codedb";
const BUNDLED_CODEDB_COMMAND: &str = "codedb";
const BUNDLED_CODEDB_MCP_ARG: &str = "mcp";

fn bundled_codedb_config() -> McpConfig {
    BTreeMap::from([(
        ServerName::from(BUNDLED_CODEDB_SERVER_NAME.to_string()),
        McpServerConfig::new_stdio(
            BUNDLED_CODEDB_COMMAND,
            vec![BUNDLED_CODEDB_MCP_ARG.to_string()],
            None,
        ),
    )])
    .into()
}

pub struct ForgeMcpManager<I> {
    infra: Arc<I>,
}

impl<I> ForgeMcpManager<I>
where
    I: McpServerInfra + FileReaderInfra + FileInfoInfra + EnvironmentInfra + KVStore,
{
    pub fn new(infra: Arc<I>) -> Self {
        Self { infra }
    }

    async fn read_config(&self, path: &Path) -> anyhow::Result<McpConfig> {
        let config = self.infra.read_utf8(path).await?;
        Ok(serde_json::from_str(&config)?)
    }

    async fn config_path(&self, scope: &Scope) -> anyhow::Result<PathBuf> {
        let env = self.infra.get_environment();
        match scope {
            Scope::User => Ok(env.mcp_user_config()),
            Scope::Local => Ok(env.mcp_local_config()),
        }
    }
}

#[async_trait::async_trait]
impl<I> McpConfigManager for ForgeMcpManager<I>
where
    I: McpServerInfra
        + FileReaderInfra
        + FileInfoInfra
        + EnvironmentInfra
        + FileWriterInfra
        + KVStore,
{
    async fn read_mcp_config(&self, scope: Option<&Scope>) -> anyhow::Result<McpConfig> {
        match scope {
            Some(scope) => {
                // Read only from the specified scope
                let config_path = self.config_path(scope).await?;
                if self.infra.is_file(&config_path).await.unwrap_or(false) {
                    self.read_config(&config_path).await
                } else {
                    Ok(McpConfig::default())
                }
            }
            None => {
                // Read and merge all configurations (original behavior)
                let env = self.infra.get_environment();
                let paths = vec![
                    // Configs at lower levels take precedence, so we read them in reverse order.
                    env.mcp_user_config().as_path().to_path_buf(),
                    env.mcp_local_config().as_path().to_path_buf(),
                ];
                let mut config = bundled_codedb_config();
                for path in paths {
                    if self.infra.is_file(&path).await.unwrap_or_default() {
                        let new_config = self.read_config(&path).await.context(format!(
                            "An error occurred while reading config at: {}",
                            path.display()
                        ))?;
                        config.merge(new_config);
                    }
                }
                Ok(config)
            }
        }
    }

    async fn write_mcp_config(&self, config: &McpConfig, scope: &Scope) -> anyhow::Result<()> {
        // Write config
        self.infra
            .write(
                self.config_path(scope).await?.as_path(),
                Bytes::from(serde_json::to_string_pretty(config)?),
            )
            .await?;

        // Clear the unified cache to force refresh on next use
        // Since we now use a merged hash, clearing any scope invalidates the cache
        self.infra.cache_clear().await?;

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;

    #[test]
    fn bundled_codedb_config_adds_stdio_mcp_server() {
        let fixture = bundled_codedb_config();
        let actual = fixture
            .mcp_servers
            .get(&ServerName::from(BUNDLED_CODEDB_SERVER_NAME.to_string()))
            .cloned();
        let expected = Some(McpServerConfig::new_stdio(
            BUNDLED_CODEDB_COMMAND,
            vec![BUNDLED_CODEDB_MCP_ARG.to_string()],
            None,
        ));

        assert_eq!(actual, expected);
    }

    #[test]
    fn user_codedb_config_overrides_bundled_default() {
        let mut fixture = bundled_codedb_config();
        let user_config = BTreeMap::from([(
            ServerName::from(BUNDLED_CODEDB_SERVER_NAME.to_string()),
            McpServerConfig::new_stdio("custom-codedb", vec!["mcp".to_string()], None),
        )])
        .into();
        fixture.merge(user_config);

        let actual = fixture
            .mcp_servers
            .get(&ServerName::from(BUNDLED_CODEDB_SERVER_NAME.to_string()))
            .cloned();
        let expected = Some(McpServerConfig::new_stdio(
            "custom-codedb",
            vec!["mcp".to_string()],
            None,
        ));

        assert_eq!(actual, expected);
    }
}
