use std::path::PathBuf;
use std::process::ExitStatus;

use forge_app::CommandInfra;
use forge_domain::CommandOutput;

use super::DesktopInfra;

#[async_trait::async_trait]
impl CommandInfra for DesktopInfra {
    async fn execute_command(
        &self,
        command: String,
        working_dir: PathBuf,
        silent: bool,
        env_vars: Option<Vec<String>>,
    ) -> anyhow::Result<CommandOutput> {
        self.inner
            .execute_command(command, working_dir, silent, env_vars)
            .await
    }

    async fn execute_command_raw(
        &self,
        command: &str,
        working_dir: PathBuf,
        env_vars: Option<Vec<String>>,
    ) -> anyhow::Result<ExitStatus> {
        self.inner
            .execute_command_raw(command, working_dir, env_vars)
            .await
    }
}
