//! N-API bindings for the codegraff agent.
//!
//! See `sdk/typescript/lib.js` and `sdk/typescript/lib.d.ts` for the
//! ergonomic public surface; this module exposes the raw building blocks.
//! Methods that return data structures emit JSON strings; the `Graff` JS
//! wrapper parses them so callers get typed objects.

use std::collections::HashMap;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Arc, OnceLock};

use forge_api::{API, ChatRequest, ForgeAPI};
use forge_config::ForgeConfig;
use forge_domain::{
    AgentId, ApiKey, ApiKeyResponse, AuthContext, AuthContextRequest, AuthContextResponse,
    AuthMethod, ChatResponse, Conversation, ConversationId, Event, ModelId, ProviderId, URLParam,
    URLParamValue,
};
use forge_stream::MpscStream;
use futures::StreamExt;
use napi::bindgen_prelude::*;
use napi_derive::napi;
use tokio::sync::Mutex as AsyncMutex;

mod wire;
use wire::WireEvent;

static CRYPTO_INIT: OnceLock<()> = OnceLock::new();

fn ensure_crypto() {
    CRYPTO_INIT.get_or_init(|| {
        // Required by rustls 0.23+ when multiple crypto providers are linked.
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

fn err(msg: impl Into<String>) -> napi::Error {
    napi::Error::from_reason(msg.into())
}

fn map_err<E: std::fmt::Debug>(e: E) -> napi::Error {
    err(format!("{e:?}"))
}

fn parse_conv_id(s: &str) -> Result<ConversationId> {
    ConversationId::from_str(s).map_err(|e| err(format!("invalid conversation id `{s}`: {e:?}")))
}

fn to_json<T: serde::Serialize>(v: &T, what: &str) -> Result<String> {
    serde_json::to_string(v).map_err(|e| err(format!("serialize {what}: {e}")))
}

/// JS-friendly mirror of `forge_domain::ChatRequest`.
#[napi(object)]
pub struct ChatRequestJs {
    /// User prompt to send to the agent.
    pub prompt: String,
    /// Optional UUID of an existing conversation to resume. When omitted a
    /// fresh conversation is created.
    pub conversation_id: Option<String>,
    /// Optional per-request model override (e.g. `"claude-opus-4-7"`). Must
    /// belong to the agent's authenticated provider or chat will fail.
    pub model: Option<String>,
}

/// Handle to an embedded ForgeAPI instance.
#[napi]
pub struct GraffApi {
    inner: Arc<dyn API>,
}

#[napi]
impl GraffApi {
    /// Initialise a ForgeAPI rooted at `cwd`. Reads global config from
    /// `~/.forge/forge.toml` (and merges env overrides). The cwd determines
    /// workspace-scoped state (conversation history, .forge/ folder, etc).
    #[napi(factory)]
    pub async fn init(cwd: String) -> Result<GraffApi> {
        ensure_crypto();
        let cwd = PathBuf::from(cwd);
        let config = ForgeConfig::read().map_err(|e| err(format!("ForgeConfig::read: {e:?}")))?;
        let api: Arc<dyn API> = Arc::new(ForgeAPI::init(cwd, config));
        Ok(GraffApi { inner: api })
    }

    /// Set or replace the API key credential for a provider — the BYOK entrypoint.
    ///
    /// `provider_id` is the snake_case provider name (e.g. "openai",
    /// "anthropic", "open_router", "xai", "cerebras", "github_copilot").
    /// `extra_params` is an optional list of `[name, value]` pairs for
    /// providers that need URL parameters alongside the key (e.g.
    /// Vertex AI's project + location). Most providers can pass `None`.
    ///
    /// Routes through the same auth flow `graff provider login` uses,
    /// so credentials persist in the configured auth store and the next
    /// `chat()` whose `model` belongs to this provider authenticates
    /// without further setup.
    #[napi]
    pub async fn upsert_credential(
        &self,
        provider_id: String,
        api_key: String,
        extra_params: Option<Vec<Vec<String>>>,
    ) -> Result<()> {
        let id: ProviderId = provider_id.into();
        let init = self
            .inner
            .init_provider_auth(id.clone(), AuthMethod::ApiKey)
            .await
            .map_err(map_err)?;
        let request = match init {
            AuthContextRequest::ApiKey(req) => req,
            _ => return Err(err(format!(
                "provider {id} does not use ApiKey auth"
            ))),
        };
        let mut url_params: HashMap<URLParam, URLParamValue> = HashMap::new();
        if let Some(pairs) = extra_params {
            for pair in pairs {
                if pair.len() != 2 {
                    return Err(err(format!(
                        "extra_params entries must be [name, value] pairs; got {} fields",
                        pair.len()
                    )));
                }
                url_params.insert(URLParam::from(pair[0].clone()), URLParamValue::from(pair[1].clone()));
            }
        }
        let response = ApiKeyResponse { api_key: ApiKey::from(api_key), url_params };
        let context = AuthContextResponse::ApiKey(AuthContext { request, response });
        self.inner
            .complete_provider_auth(id, context, std::time::Duration::from_secs(30))
            .await
            .map_err(map_err)?;
        Ok(())
    }

    /// Remove a provider's credential. Mirrors `graff provider logout`.
    #[napi]
    pub async fn remove_credential(&self, provider_id: String) -> Result<()> {
        let id: ProviderId = provider_id.into();
        self.inner.remove_provider(&id).await.map_err(map_err)?;
        Ok(())
    }

    /// Send a chat request and return a streaming handle.
    ///
    /// If `conversation_id` is omitted a fresh `Conversation` is created and
    /// upserted before the chat begins. Pull events off the returned handle
    /// via `next()` until it yields `null` (end of stream), or `cancel()` to
    /// abort early.
    #[napi]
    pub async fn chat(&self, req: ChatRequestJs) -> Result<ChatStreamHandle> {
        let conversation_id = match req.conversation_id {
            Some(s) => parse_conv_id(&s)?,
            None => {
                let conv = Conversation::generate();
                let id = conv.id;
                self.inner
                    .upsert_conversation(conv)
                    .await
                    .map_err(map_err)?;
                id
            }
        };

        let event = Event::new(req.prompt);
        let mut chat_req = ChatRequest::new(event, conversation_id);
        if let Some(model_str) = req.model {
            chat_req.model_override = Some(ModelId::new(model_str));
        }

        let stream = self.inner.chat(chat_req).await.map_err(map_err)?;

        Ok(ChatStreamHandle {
            inner: Arc::new(AsyncMutex::new(Some(stream))),
            conversation_id: conversation_id.into_string(),
        })
    }

    /// List conversations for the active workspace as a JSON array. The TS
    /// wrapper parses this into `Conversation[]`.
    #[napi]
    pub async fn list_conversations(&self, limit: Option<u32>) -> Result<String> {
        let convs = self
            .inner
            .get_conversations(limit.map(|n| n as usize))
            .await
            .map_err(map_err)?;
        to_json(&convs, "conversations")
    }

    /// Fetch a single conversation by id, or `null` when absent.
    #[napi]
    pub async fn get_conversation(&self, id: String) -> Result<Option<String>> {
        let conv_id = parse_conv_id(&id)?;
        let conv = self.inner.conversation(&conv_id).await.map_err(map_err)?;
        match conv {
            None => Ok(None),
            Some(c) => Ok(Some(to_json(&c, "conversation")?)),
        }
    }

    /// Most recent conversation for the workspace, or `null` if none yet.
    #[napi]
    pub async fn last_conversation(&self) -> Result<Option<String>> {
        let conv = self.inner.last_conversation().await.map_err(map_err)?;
        match conv {
            None => Ok(None),
            Some(c) => Ok(Some(to_json(&c, "conversation")?)),
        }
    }

    /// Permanently delete a conversation by id.
    #[napi]
    pub async fn delete_conversation(&self, id: String) -> Result<()> {
        let conv_id = parse_conv_id(&id)?;
        self.inner
            .delete_conversation(&conv_id)
            .await
            .map_err(map_err)
    }

    /// Set a conversation's title.
    #[napi]
    pub async fn rename_conversation(&self, id: String, title: String) -> Result<()> {
        let conv_id = parse_conv_id(&id)?;
        self.inner
            .rename_conversation(&conv_id, title)
            .await
            .map_err(map_err)
    }

    /// Compact (summarise) the agent's context for a conversation. Returns a
    /// JSON-encoded `CompactionResult`.
    #[napi]
    pub async fn compact_conversation(&self, id: String) -> Result<String> {
        let conv_id = parse_conv_id(&id)?;
        let result = self
            .inner
            .compact_conversation(&conv_id)
            .await
            .map_err(map_err)?;
        to_json(&result, "compaction")
    }

    /// Currently-active agent id, or `null` if none has been set.
    #[napi]
    pub async fn get_active_agent(&self) -> Option<String> {
        self.inner
            .get_active_agent()
            .await
            .map(|a| a.as_str().to_string())
    }

    /// Set the active agent for subsequent chat requests.
    #[napi]
    pub async fn set_active_agent(&self, agent_id: String) -> Result<()> {
        self.inner
            .set_active_agent(AgentId::new(agent_id))
            .await
            .map_err(map_err)
    }

    /// Lightweight metadata for all available agents (does not require a
    /// configured provider). Returns JSON-encoded `AgentInfo[]`.
    #[napi]
    pub async fn get_agent_infos(&self) -> Result<String> {
        let agents = self.inner.get_agent_infos().await.map_err(map_err)?;
        to_json(&agents, "agents")
    }

    /// List trajectory events recorded for a conversation. JSON-encoded
    /// `TrajectoryEvent[]` (one row per tool call across every agent in the
    /// conversation tree).
    #[napi]
    pub async fn list_trajectory(&self, conversation_id: String) -> Result<String> {
        let conv_id = parse_conv_id(&conversation_id)?;
        let events = self
            .inner
            .list_trajectory(&conv_id)
            .await
            .map_err(map_err)?;
        to_json(&events, "trajectory")
    }

    /// SDK + crate version string.
    #[napi]
    pub fn version(&self) -> String {
        env!("CARGO_PKG_VERSION").to_string()
    }
}

/// Pull-based handle over the chat event stream.
///
/// Each call to [`ChatStreamHandle::next`] returns the next event JSON-encoded,
/// or `null` when the stream ends. The TS wrapper turns this into an
/// `AsyncIterable<AgentEvent>`. Call [`ChatStreamHandle::cancel`] to abort
/// the in-flight chat and free the underlying tokio task.
#[napi]
pub struct ChatStreamHandle {
    // Wrapped in Option so cancel() can drop the stream — MpscStream's Drop
    // impl closes the receiver and aborts the spawned join handle.
    inner: Arc<AsyncMutex<Option<MpscStream<anyhow::Result<ChatResponse>>>>>,
    conversation_id: String,
}

#[napi]
impl ChatStreamHandle {
    /// Returns the next event as a JSON string, or `null` when the stream ends
    /// (either naturally or because `cancel()` was called).
    #[napi]
    pub async fn next(&self) -> Result<Option<String>> {
        let mut guard = self.inner.lock().await;
        let stream = match guard.as_mut() {
            None => return Ok(None),
            Some(s) => s,
        };
        match stream.next().await {
            None => {
                *guard = None;
                Ok(None)
            }
            Some(Err(e)) => Err(err(format!("agent error: {e:?}"))),
            Some(Ok(resp)) => {
                let wire = WireEvent::from(resp);
                Ok(Some(to_json(&wire, "event")?))
            }
        }
    }

    /// Cancel the in-flight chat. Drops the underlying stream which aborts
    /// the spawned tokio task. Subsequent calls to `next()` return `null`.
    #[napi]
    pub async fn cancel(&self) {
        let mut guard = self.inner.lock().await;
        guard.take();
    }

    #[napi(getter)]
    pub fn conversation_id(&self) -> String {
        self.conversation_id.clone()
    }
}

/// SDK version (top-level convenience).
#[napi]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Generate a fresh conversation id (UUID v4 string).
#[napi]
pub fn new_conversation_id() -> String {
    ConversationId::generate().into_string()
}
