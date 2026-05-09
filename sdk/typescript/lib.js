// Public surface for @codegraff/sdk.
//
// `index.js` and the platform .node addon are produced by napi-rs at build
// time and expose the raw building blocks (GraffApi, ChatStreamHandle,
// version(), newConversationId()). This module wraps them in three ergonomic
// shapes:
//
//   - runAgent(opts)         => AsyncIterable<AgentEvent>   (one-shot)
//   - new GraffSession(opts) => session.send() returns AsyncIterable
//                               (multi-turn, persists conversationId)
//   - Graff.init(cwd)        => long-lived instance with the conversation
//                               management surface (list / get / delete /
//                               rename / compact / agents / trajectory).

const native = require("./index.js");

const { GraffApi, ChatStreamHandle, version, newConversationId } = native;

/** Pull events off a ChatStreamHandle and yield decoded objects. Calls
 *  cancel() on `return()` (e.g. when the caller breaks out of `for await`)
 *  so the underlying tokio task is aborted. */
async function* iterateHandle(handle) {
  try {
    while (true) {
      const raw = await handle.next();
      if (raw == null) return;
      yield JSON.parse(raw);
    }
  } finally {
    await handle.cancel();
  }
}

/** Run a single chat turn against the codegraff agent. Spins up a fresh
 *  GraffApi rooted at `opts.cwd` per call. To preserve state across calls,
 *  reuse a Graff or GraffSession instance instead. */
async function* runAgent(opts) {
  if (!opts || typeof opts.prompt !== "string") {
    throw new TypeError("runAgent: { prompt: string } is required");
  }
  const api = await GraffApi.init(opts.cwd ?? process.cwd());
  const handle = await api.chat({
    prompt: opts.prompt,
    conversationId: opts.conversationId,
    model: opts.model,
  });
  yield { type: "ConversationStarted", conversationId: handle.conversationId };
  yield* iterateHandle(handle);
}

/** Multi-turn session. Reuses one GraffApi instance and the same
 *  conversationId across `.send()` calls so the agent retains memory. */
class GraffSession {
  constructor(opts = {}) {
    this._opts = opts;
    this._cwd = opts.cwd ?? process.cwd();
    this._conversationId = opts.conversationId;
    // Internal: when the session is created via `Graff.session()`, the
    // existing GraffApi is passed in to avoid double-initialising the
    // workspace. Treat as private; not part of the public TS type.
    this._apiPromise = opts._api ? Promise.resolve(opts._api) : null;
  }

  get conversationId() {
    return this._conversationId;
  }

  _api() {
    if (!this._apiPromise) {
      this._apiPromise = GraffApi.init(this._cwd);
    }
    return this._apiPromise;
  }

  async *send(prompt) {
    if (typeof prompt !== "string") {
      throw new TypeError("GraffSession.send: prompt must be a string");
    }
    const api = await this._api();
    const handle = await api.chat({
      prompt,
      conversationId: this._conversationId,
      model: this._opts.model,
    });
    if (!this._conversationId) {
      this._conversationId = handle.conversationId;
    }
    yield* iterateHandle(handle);
  }

  async close() {
    this._apiPromise = null;
  }
}

/** Long-lived Graff instance. Wraps a single GraffApi and exposes the
 *  conversation / agent management surface with parsed return values. */
class Graff {
  constructor(api) {
    this._api = api;
  }

  static async init(cwd = process.cwd()) {
    return new Graff(await GraffApi.init(cwd));
  }

  /** Run a chat turn. Mirrors `runAgent` but reuses this Graff's GraffApi. */
  async *chat(opts) {
    if (!opts || typeof opts.prompt !== "string") {
      throw new TypeError("Graff.chat: { prompt: string } is required");
    }
    const handle = await this._api.chat({
      prompt: opts.prompt,
      conversationId: opts.conversationId,
      model: opts.model,
    });
    yield { type: "ConversationStarted", conversationId: handle.conversationId };
    yield* iterateHandle(handle);
  }

  /** Build a multi-turn session that shares this Graff's underlying GraffApi. */
  session(opts = {}) {
    return new GraffSession({ ...opts, _api: this._api });
  }

  // ── Auth (BYOK) ──────────────────────────────────────────────────────────

  /** Upsert an API key credential for a provider. After this returns, any
   *  subsequent `chat()` whose model belongs to this provider authenticates
   *  with the supplied key. `extraParams` is an optional list of [name,
   *  value] pairs for providers that need URL parameters alongside the
   *  key (e.g. Vertex AI's project + location). */
  upsertCredential(providerId, apiKey, extraParams) {
    return this._api.upsertCredential(providerId, apiKey, extraParams);
  }

  /** Remove a provider's credential. Mirrors `graff provider logout`. */
  removeCredential(providerId) {
    return this._api.removeCredential(providerId);
  }

  // ── Conversation management ─────────────────────────────────────────────

  async listConversations(limit) {
    return JSON.parse(await this._api.listConversations(limit));
  }

  async getConversation(id) {
    const j = await this._api.getConversation(id);
    return j == null ? null : JSON.parse(j);
  }

  async lastConversation() {
    const j = await this._api.lastConversation();
    return j == null ? null : JSON.parse(j);
  }

  deleteConversation(id) {
    return this._api.deleteConversation(id);
  }

  renameConversation(id, title) {
    return this._api.renameConversation(id, title);
  }

  async compactConversation(id) {
    return JSON.parse(await this._api.compactConversation(id));
  }

  // ── Agents ──────────────────────────────────────────────────────────────

  getActiveAgent() {
    return this._api.getActiveAgent();
  }

  setActiveAgent(agentId) {
    return this._api.setActiveAgent(agentId);
  }

  async getAgentInfos() {
    return JSON.parse(await this._api.getAgentInfos());
  }

  // ── Trajectory ──────────────────────────────────────────────────────────

  async listTrajectory(conversationId) {
    return JSON.parse(await this._api.listTrajectory(conversationId));
  }

  version() {
    return this._api.version();
  }
}

module.exports = {
  // High-level
  Graff,
  GraffSession,
  runAgent,
  // Helpers
  newConversationId,
  version,
  // Low-level passthroughs (rarely needed)
  GraffApi,
  ChatStreamHandle,
};
