// Fetch-only access to existing Codegraff Fleet sandboxes; no local processes.
export interface SandboxExecResult { exitCode: number; result: string }
export interface SandboxRequestOptions { signal?: AbortSignal }
export interface SandboxExecOptions extends SandboxRequestOptions { timeoutSeconds?: number; cwd?: string }
export interface CodegraffSandboxAttachOptions {
  /** A cg_sk_ key, sent only in the gateway Authorization header. */
  token: string;
  /** May bridge requests locally; this client still constructs only gateway HTTPS URLs. */
  fetch?: typeof fetch;
}
export interface CodegraffSandboxOptions extends CodegraffSandboxAttachOptions, SandboxRequestOptions {
  autoStopMinutes?: number;
}
export interface CodegraffSandbox {
  readonly id: string;
  /** Aborting stops HTTP waiting, not the remote command. Destroy the VM to stop it. */
  exec(command: string, options?: SandboxExecOptions): Promise<SandboxExecResult>;
  upload(path: string, text: string, options?: SandboxRequestOptions): Promise<void>;
  /** Downloads UTF-8 text; binary files are rejected. */
  download(path: string, options?: SandboxRequestOptions): Promise<string>;
  /** Independent of create/operation signals. Call in finally to end billing. */
  destroy(): Promise<void>;
}
export type SandboxErrorCode = "invalid_argument" | "http" | "network" | "invalid_response" |
  "response_too_large" | "output_too_large" | "file_too_large" | "aborted" | "timeout" | "destroyed";
/** Deliberately excludes request data, response bodies, URLs, IDs, and error causes. */
export class SandboxError extends Error {
  readonly name = "SandboxError";
  constructor(
    readonly code: SandboxErrorCode,
    readonly status?: number,
    /** An attach failure exposed an ID, but its best-effort DELETE failed. */
    readonly cleanupFailed = false,
  ) {
    super(`Sandbox error: ${code}${status === undefined ? "" : ` (${status})`}`);
  }
}
const ORIGIN = "https://gateway.codegraff.com";
const COMMAND_LIMIT = 8 * 1024;
const FILE_LIMIT = 64 * 1024;
const OUTPUT_LIMIT = 64 * 1024;
const RESPONSE_LIMIT = 128 * 1024;
const REQUEST_MS = 45_000;
const CREATE_MS = 90_000;
const CLEANUP_MS = 5_000;
const encoder = new TextEncoder();
const object = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const validId = (value: unknown): value is string =>
  typeof value === "string" && /^[a-zA-Z0-9_-]{1,256}$/.test(value);
function fail(code: SandboxErrorCode): never { throw new SandboxError(code); }
function integer(value: number, minimum: number, maximum: number): number {
  if (!Number.isInteger(value) || value < minimum || value > maximum) fail("invalid_argument");
  return value;
}
function textBytes(value: string, limit: number, code: SandboxErrorCode): Uint8Array {
  // Check code units first so an oversized input is not copied just to reject it.
  if (typeof value !== "string" || value.length > limit) fail(code);
  const bytes = encoder.encode(value);
  if (bytes.length > limit) fail(code);
  return bytes;
}
function validPath(path: string): void {
  textBytes(path, 4096, "invalid_argument");
  if (!path || /[\x00-\x1f\x7f]/.test(path)) fail("invalid_argument");
}
function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}
function fromBase64(value: unknown): string {
  if (typeof value !== "string") fail("invalid_response");
  if (value.length > 4 * Math.ceil(FILE_LIMIT / 3)) fail("file_too_large");
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    fail("invalid_response");
  }
  let binary: string;
  try { binary = atob(value); } catch { return fail("invalid_response"); }
  if (binary.length > FILE_LIMIT) fail("file_too_large");
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  try { return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes); }
  catch { return fail("invalid_response"); }
}
function abortable<T>(work: Promise<T>, signal: AbortSignal, reason: () => SandboxError): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => { signal.removeEventListener("abort", abort); reject(reason()); };
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
    work.then(
      value => { signal.removeEventListener("abort", abort); resolve(value); },
      () => { signal.removeEventListener("abort", abort); reject(signal.aborted ? reason() : new SandboxError("network")); },
    );
  });
}
async function responseBytes(response: Response, signal: AbortSignal, reason: () => SandboxError): Promise<Uint8Array> {
  if (!response.body) return new Uint8Array(0);
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let length = 0;
  try {
    while (true) {
      const part = await abortable(reader.read(), signal, reason);
      if (part.done) break;
      length += part.value.byteLength;
      if (length > RESPONSE_LIMIT) fail("response_too_large");
      chunks.push(part.value);
    }
  } catch (error) {
    void reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(length);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  return bytes;
}
interface Reply { status: number; ok: boolean; payload: unknown; empty: boolean }
const endpoint = (id: string) => `/${encodeURIComponent(id)}`;
const check = (reply: Reply) => { if (!reply.ok) throw new SandboxError("http", reply.status); };
function transport(options: CodegraffSandboxAttachOptions) {
  if (!options || typeof options.token !== "string" || options.token.length > 4096 ||
      !/^cg_sk_[A-Za-z0-9_-]+$/.test(options.token) ||
      (options.fetch !== undefined && typeof options.fetch !== "function")) fail("invalid_argument");
  const token = options.token;
  const fetcher = options.fetch ?? globalThis.fetch;
  async function request(
    method: "POST" | "DELETE", path: string, body?: Record<string, unknown>,
    signal?: AbortSignal, milliseconds = REQUEST_MS,
  ): Promise<Reply> {
    if (signal?.aborted) fail("aborted");
    const controller = new AbortController();
    let timedOut = false;
    const reason = () => new SandboxError(timedOut ? "timeout" : "aborted");
    const abort = () => controller.abort();
    signal?.addEventListener("abort", abort, { once: true });
    if (signal?.aborted) abort();
    const timer = setTimeout(() => { timedOut = true; controller.abort(); }, milliseconds);
    try {
      if (controller.signal.aborted) throw reason();
      const headers = new Headers({ authorization: `Bearer ${token}` });
      if (body !== undefined) headers.set("content-type", "application/json");
      // Workers supports manual redirects, not the browser's error mode.
      // Non-2xx replies fail below; bearer credentials never follow redirects.
      const init = {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal, redirect: "manual" as const,
      };
      const pending = fetcher(`${ORIGIN}/v1/sandboxes${path}`, init);
      // An injected fetch may ignore abort. Stop waiting anyway and discard late bodies.
      void pending.then(response => {
        if (controller.signal.aborted) void response.body?.cancel().catch(() => {});
      }, () => {});
      const response = await abortable(pending, controller.signal, reason);
      const bytes = await responseBytes(response, controller.signal, reason);
      if (controller.signal.aborted) throw reason();
      let payload: unknown;
      try { payload = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)); }
      catch { payload = undefined; }
      return { status: response.status, ok: response.ok, payload, empty: bytes.length === 0 };
    } catch (error) {
      if (controller.signal.aborted) throw reason();
      if (error instanceof SandboxError) throw error;
      throw new SandboxError("network");
    } finally {
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
    }
  }
  async function remove(id: string, milliseconds = REQUEST_MS): Promise<void> {
    const reply = await request("DELETE", endpoint(id), undefined, undefined, milliseconds);
    if (reply.status !== 404) check(reply);
  }
  return { request, remove };
}
/**
 * Uses only the fixed public HTTPS gateway, with redirects disabled and no retries.
 * The create signal applies only to creation; later calls have their own signals.
 * Requests wait at most 45s (creation 90s, independent cleanup 5s). An exec may
 * keep running after that HTTP deadline; always destroy in a caller-owned finally.
 * Commands: 8 KiB UTF-8; files/output: 64 KiB; streamed response bodies: 128 KiB.
 */
export async function createCodegraffSandbox(options: CodegraffSandboxOptions): Promise<CodegraffSandbox> {
  const api = transport(options);
  const autoStopMinutes = integer(options.autoStopMinutes ?? 5, 1, 30);
  const created = await api.request("POST", "", { provider: "fleet", autoStopMinutes }, options.signal, CREATE_MS);
  const payload = created.payload;
  const id = object(payload) && validId(payload.id) ? payload.id : undefined;
  const attachedId = object(payload) && object(payload.error) && validId(payload.error.sandboxId)
    ? payload.error.sandboxId : undefined;
  const createError = !created.ok ? new SandboxError("http", created.status)
    : !id || (object(payload) && "error" in payload) ? new SandboxError("invalid_response")
    : options.signal?.aborted ? new SandboxError("aborted") : undefined;
  if (createError) {
    // Fleet may allocate successfully and then fail attachment. Never leave that ID
    // billed just because the caller aborted: this DELETE has its own deadline.
    const cleanupId = attachedId ?? id;
    let cleanupFailed = false;
    if (cleanupId) {
      try { await api.remove(cleanupId, CLEANUP_MS); } catch { cleanupFailed = true; }
    }
    throw new SandboxError(createError.code, createError.status, cleanupFailed);
  }
  // The successful create branch above guarantees a validated, path-safe ID.
  return sandboxClient(id as string, api);
}
/** Reattach without HTTP or allocation, e.g. to destroy a stored ID from an alarm. */
export function attachCodegraffSandbox(id: string, options: CodegraffSandboxAttachOptions): CodegraffSandbox {
  if (!validId(id)) fail("invalid_argument");
  return sandboxClient(id, transport(options));
}
function sandboxClient(sandboxId: string, { request, remove }: ReturnType<typeof transport>): CodegraffSandbox {
  let destroyed = false;
  let destroying: Promise<void> | undefined;
  const live = () => { if (destroyed || destroying) fail("destroyed"); };
  return {
    id: sandboxId,
    async exec(command, { signal, timeoutSeconds = 30, cwd = "/tmp" } = {}) {
      live();
      validPath(cwd);
      textBytes(command, COMMAND_LIMIT, "invalid_argument");
      if (!command.trim()) fail("invalid_argument");
      integer(timeoutSeconds, 1, 60);
      const reply = await request("POST", `${endpoint(sandboxId)}/exec`, {
        command, cwd, timeoutSeconds,
      }, signal);
      check(reply);
      const result = reply.payload;
      if (!object(result) || typeof result.exitCode !== "number" || !Number.isSafeInteger(result.exitCode) ||
          typeof result.result !== "string") fail("invalid_response");
      textBytes(result.result, OUTPUT_LIMIT, "output_too_large");
      return { exitCode: result.exitCode, result: result.result };
    },
    async upload(path, text, { signal } = {}) {
      live();
      validPath(path);
      const bytes = textBytes(text, FILE_LIMIT, "file_too_large");
      const reply = await request("POST", `${endpoint(sandboxId)}/upload`, {
        path, contentBase64: base64(bytes),
      }, signal);
      check(reply);
      if (!reply.empty && (!object(reply.payload) || "error" in reply.payload)) fail("invalid_response");
    },
    async download(path, { signal } = {}) {
      live();
      validPath(path);
      const reply = await request("POST", `${endpoint(sandboxId)}/download`, { path }, signal);
      check(reply);
      if (!object(reply.payload)) fail("invalid_response");
      return fromBase64(reply.payload.contentBase64);
    },
    async destroy() {
      if (destroyed) return;
      if (destroying) return destroying;
      destroying = remove(sandboxId).then(() => { destroyed = true; });
      try { await destroying; } finally { destroying = undefined; }
    },
  };
}
