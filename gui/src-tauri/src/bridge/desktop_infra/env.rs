use std::collections::BTreeMap;

use forge_app::{EnvironmentInfra, GrpcInfra, StrategyFactory};
use forge_domain::{AuthMethod, ProviderId, URLParamSpec};

use super::DesktopInfra;

impl EnvironmentInfra for DesktopInfra {
    type Config = forge_config::ForgeConfig;

    fn get_env_var(&self, key: &str) -> Option<String> {
        self.inner.get_env_var(key)
    }

    fn get_env_vars(&self) -> BTreeMap<String, String> {
        self.inner.get_env_vars()
    }

    fn get_environment(&self) -> forge_domain::Environment {
        self.inner.get_environment()
    }

    fn get_config(&self) -> anyhow::Result<Self::Config> {
        self.inner.get_config()
    }

    async fn update_environment(
        &self,
        ops: Vec<forge_domain::ConfigOperation>,
    ) -> anyhow::Result<()> {
        self.inner.update_environment(ops).await
    }
}

impl StrategyFactory for DesktopInfra {
    type Strategy = <forge_infra::ForgeInfra as StrategyFactory>::Strategy;

    fn create_auth_strategy(
        &self,
        provider_id: ProviderId,
        auth_method: AuthMethod,
        required_params: Vec<URLParamSpec>,
    ) -> anyhow::Result<Self::Strategy> {
        self.inner
            .create_auth_strategy(provider_id, auth_method, required_params)
    }
}

impl GrpcInfra for DesktopInfra {
    fn channel(&self) -> anyhow::Result<tonic::transport::Channel> {
        self.inner.channel()
    }

    fn hydrate(&self) {
        self.inner.hydrate();
    }
}
