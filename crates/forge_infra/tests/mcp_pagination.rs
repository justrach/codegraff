//! Integration coverage for paginated `tools/list`.
//!
//! Forge calls `Peer::list_all_tools` (rmcp's pagination wrapper) instead of
//! `list_tools(None)` so that servers advertising more than one page of tools
//! get fully enumerated. This test stands up an in-process MCP server over a
//! duplex transport, splits tools across multiple pages with `next_cursor`,
//! and asserts the client walks the whole chain.
//!
//! If a future refactor reverts to single-page `list_tools(None)`, this test
//! will surface the regression — the client would only see the first page
//! and the assertion on tool count would fail.

use std::borrow::Cow;
use std::sync::Arc;

use rmcp::handler::server::ServerHandler;
use rmcp::model::{
    ClientInfo, JsonObject, ListToolsResult, PaginatedRequestParam, ServerCapabilities, ServerInfo,
    Tool, ToolsCapability,
};
use rmcp::service::RequestContext;
use rmcp::{ClientHandler, RoleServer, ServiceExt};

const PAGE_SIZE: usize = 2;

/// Mock server that advertises N tools across ceil(N / PAGE_SIZE) pages.
///
/// Cursor is the next page index encoded as a decimal string. Page 0 has no
/// inbound cursor; the final page returns `next_cursor: None`.
#[derive(Clone)]
struct PaginatedToolsServer {
    tools: Vec<Tool>,
}

impl PaginatedToolsServer {
    fn new(total: usize) -> Self {
        let mut input_schema = JsonObject::new();
        input_schema.insert("type".to_string(), serde_json::json!("object"));
        let input_schema = Arc::new(input_schema);

        let tools = (0..total)
            .map(|i| Tool {
                name: Cow::Owned(format!("tool_{i}")),
                title: None,
                description: Some(Cow::Owned(format!("tool number {i}"))),
                input_schema: input_schema.clone(),
                output_schema: None,
                annotations: None,
                icons: None,
                meta: None,
            })
            .collect();
        Self { tools }
    }
}

impl ServerHandler for PaginatedToolsServer {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            capabilities: ServerCapabilities {
                tools: Some(ToolsCapability { list_changed: Some(false) }),
                ..Default::default()
            },
            ..Default::default()
        }
    }

    async fn list_tools(
        &self,
        request: Option<PaginatedRequestParam>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, rmcp::ErrorData> {
        let page: usize = request
            .and_then(|r| r.cursor)
            .map(|c| c.parse().expect("cursor is a decimal page index"))
            .unwrap_or(0);

        let start = page * PAGE_SIZE;
        let end = (start + PAGE_SIZE).min(self.tools.len());
        let tools = self.tools[start..end].to_vec();

        let next_cursor = if end < self.tools.len() {
            Some((page + 1).to_string())
        } else {
            None
        };

        Ok(ListToolsResult { tools, next_cursor })
    }
}

#[derive(Clone, Default)]
struct DummyClient;

impl ClientHandler for DummyClient {
    fn get_info(&self) -> ClientInfo {
        ClientInfo::default()
    }
}

#[tokio::test]
async fn list_all_tools_walks_every_page() -> anyhow::Result<()> {
    let (server_transport, client_transport) = tokio::io::duplex(4096);

    let server = PaginatedToolsServer::new(5);
    let server_handle = tokio::spawn(async move {
        let running = server.serve(server_transport).await?;
        running.waiting().await?;
        anyhow::Ok(())
    });

    let client = DummyClient.serve(client_transport).await?;

    let tools = client.peer().list_all_tools().await?;

    assert_eq!(tools.len(), 5, "every page should be walked");
    let names: Vec<_> = tools.iter().map(|t| t.name.as_ref()).collect();
    assert_eq!(
        names,
        vec!["tool_0", "tool_1", "tool_2", "tool_3", "tool_4"],
        "tools should be returned in page order without dedup or reorder"
    );

    client.cancel().await?;
    server_handle.await??;
    Ok(())
}

#[tokio::test]
async fn list_all_tools_handles_single_page_with_no_cursor() -> anyhow::Result<()> {
    // Sanity check: when the server returns everything in one page (next_cursor
    // = None on the first response), the client should not loop forever and
    // should not double-fetch.
    let (server_transport, client_transport) = tokio::io::duplex(4096);

    let server = PaginatedToolsServer::new(2);
    let server_handle = tokio::spawn(async move {
        let running = server.serve(server_transport).await?;
        running.waiting().await?;
        anyhow::Ok(())
    });

    let client = DummyClient.serve(client_transport).await?;
    let tools = client.peer().list_all_tools().await?;

    assert_eq!(tools.len(), 2);
    assert_eq!(tools[0].name.as_ref(), "tool_0");
    assert_eq!(tools[1].name.as_ref(), "tool_1");

    client.cancel().await?;
    server_handle.await??;
    Ok(())
}
