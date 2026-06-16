use std::collections::BTreeMap;

use bytes::Bytes;
use forge_app::{HttpInfra, McpServerInfra};
use forge_domain::McpServerConfig;
use forge_eventsource::EventSource;
use forge_infra::ForgeInfra;
use reqwest::header::HeaderMap;
use reqwest::{Response, Url};

use super::DesktopInfra;

#[async_trait::async_trait]
impl McpServerInfra for DesktopInfra {
    type Client = <ForgeInfra as McpServerInfra>::Client;

    async fn connect(
        &self,
        config: McpServerConfig,
        env_vars: &BTreeMap<String, String>,
        environment: &forge_domain::Environment,
    ) -> anyhow::Result<Self::Client> {
        self.inner.connect(config, env_vars, environment).await
    }
}

#[async_trait::async_trait]
impl HttpInfra for DesktopInfra {
    async fn http_get(&self, url: &Url, headers: Option<HeaderMap>) -> anyhow::Result<Response> {
        self.inner.http_get(url, headers).await
    }

    async fn http_post(
        &self,
        url: &Url,
        headers: Option<HeaderMap>,
        body: Bytes,
    ) -> anyhow::Result<Response> {
        self.inner.http_post(url, headers, body).await
    }

    async fn http_delete(&self, url: &Url) -> anyhow::Result<Response> {
        self.inner.http_delete(url).await
    }

    async fn http_eventsource(
        &self,
        url: &Url,
        headers: Option<HeaderMap>,
        body: Bytes,
    ) -> anyhow::Result<EventSource> {
        self.inner.http_eventsource(url, headers, body).await
    }
}
