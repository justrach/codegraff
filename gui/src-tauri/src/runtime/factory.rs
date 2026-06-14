use std::path::PathBuf;
use std::sync::Arc;

use forge_api::{API, ForgeAPI};
use forge_app::AgentRegistry;
use forge_config::ForgeConfig;
use forge_domain::{AgentId, Conversation, ConversationId};
use forge_infra::ForgeInfra;
use forge_repo::ForgeRepo;
use forge_services::ForgeServices;

use crate::bridge::desktop_infra::DesktopInfra;
use crate::bridge::followup::FollowupBridge;
use crate::runtime::format_error_chain;
pub(crate) type DesktopRepo = ForgeRepo<DesktopInfra>;
pub(crate) type DesktopServices = ForgeServices<DesktopRepo>;
pub(crate) type DesktopApi = ForgeAPI<DesktopServices, DesktopRepo>;

pub(crate) const MISSING_SESSION_MESSAGE: &str =
    "No provider is configured. Configure at least one provider in Settings.";

#[derive(Clone)]
pub(crate) struct ForgeRuntime {
    pub(crate) api: Arc<DesktopApi>,
    pub(crate) services: Arc<DesktopServices>,
    pub(crate) config: ForgeConfig,
    pub(crate) configuration_error: Option<String>,
}

pub(crate) struct RuntimeFactory {
    followups: Arc<FollowupBridge>,
}

impl RuntimeFactory {
    pub(crate) fn new(followups: Arc<FollowupBridge>) -> Self {
        Self { followups }
    }

    pub(crate) async fn build_runtime(
        &self,
        workspace_path: PathBuf,
        config: ForgeConfig,
        configuration_error: Option<String>,
    ) -> anyhow::Result<ForgeRuntime> {
        let infra = Arc::new(DesktopInfra::new(
            ForgeInfra::new(workspace_path, config.clone()),
            self.followups.clone(),
        ));
        let repo = Arc::new(ForgeRepo::new(infra));
        let services = Arc::new(ForgeServices::new(repo.clone()));
        services.set_active_agent_id(AgentId::default()).await?;
        let api = Arc::new(ForgeAPI::new(services.clone(), repo));

        Ok(ForgeRuntime { api, services, config, configuration_error })
    }
}

pub(crate) fn read_config() -> (ForgeConfig, Option<String>) {
    match ForgeConfig::read() {
        Ok(config) => (config, None),
        Err(error) => {
            let error = anyhow::Error::new(error);
            (ForgeConfig::default(), Some(format_error_chain(&error)))
        }
    }
}

pub(crate) fn configuration_error_message(
    configured: bool,
    configuration_error: Option<String>,
) -> Option<String> {
    if configured {
        configuration_error
    } else {
        Some(configuration_error.unwrap_or_else(|| MISSING_SESSION_MESSAGE.to_string()))
    }
}

#[async_trait::async_trait]
pub(crate) trait ConversationUpserter {
    async fn upsert_conversation_record(&self, conversation: Conversation) -> anyhow::Result<()>;
}

#[async_trait::async_trait]
impl ConversationUpserter for DesktopApi {
    async fn upsert_conversation_record(&self, conversation: Conversation) -> anyhow::Result<()> {
        self.upsert_conversation(conversation).await
    }
}

pub(crate) async fn create_conversation_record<A: ConversationUpserter + Sync>(
    api: &A,
    current: &mut Option<ConversationId>,
) -> anyhow::Result<ConversationId> {
    let conversation = Conversation::generate();
    let conversation_id = conversation.id;
    api.upsert_conversation_record(conversation).await?;
    *current = Some(conversation_id);
    Ok(conversation_id)
}
