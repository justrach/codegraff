import { randomUUID } from "node:crypto";
import { permissionRequest } from "./acp-permission";
import type { ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { StringDecoder } from "node:string_decoder";
type Child = ChildProcessByStdio<Writable, Readable, null>;
type Message = { id?: number | string; method?: string; params?: unknown; result?: unknown; error?: { message?: string } };
type Pending = { resolve(value: unknown): void; reject(error: Error): void; timer: ReturnType<typeof setTimeout>; onLine?: (line: string) => void };

/** Exactly one stdout reader. RPCs never consume another request's notifications. */
export class AcpTransport {
  private permissions = new Map<string, { id: number | string; session: string; options: Set<string> }>();
  clearPermissions() { this.permissions.clear(); }
  respondPermission(token: string, session: string, optionId: string | null): boolean {
    const request = this.permissions.get(token);
    if (!request || request.session !== session || (optionId !== null && !request.options.has(optionId)) || this.failure) return false;
    this.permissions.delete(token);
    const outcome = optionId === null ? { outcome: "cancelled" } : { outcome: "selected", optionId };
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: request.id, result: { outcome } }) + "\n");
    return true;
  }
  private nextId = 1;
  private buffer = "";
  private decoder = new StringDecoder("utf8");
  private pending = new Map<number, Pending>();
  private listeners = new Set<(line: string) => void>();
  private failure: Error | null = null;
  constructor(private child: Child, private notification: (message: Message) => void = () => {}) {
    child.stdout.on("data", chunk => this.feed(this.decoder.write(chunk)));
    child.once("error", error => this.fail(error));
    // stdout may still deliver the final reply after exit, but never after close.
    child.once("close", (code, signal) => this.fail(new Error(`graff acp exited (${code ?? signal})`)));
    child.stdin.on("error", error => this.fail(error));
  }
  private feed(text: string) {
    if (this.failure) return;
    this.buffer += text;
    let newline;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      if (newline > 8 * 1024 * 1024) { this.fail(new Error("ACP line exceeds limit")); return; }
      let line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
      let message: Message;
      try { message = JSON.parse(line); } catch { continue; }
      if (message.method === "session/request_permission" && (typeof message.id === "string" || typeof message.id === "number")) {
        const permission = permissionRequest({ ...message, id: String(message.id) });
        if (permission) {
          const token = randomUUID();
          this.permissions.set(token, { id: message.id, session: permission.sessionId, options: new Set(permission.options.map(o => o.optionId)) });
          message = { ...message, id: token };
          line = JSON.stringify(message);
        }
      }
      if (message.method === "session/update") {
        const params = message.params as { update?: { sessionUpdate?: string } };
        if (params?.update?.sessionUpdate === "gui_turn_end") this.clearPermissions();
      }
      if (message.method) {
        this.notification(message);
        for (const listener of this.listeners) listener(line);
      } else if (typeof message.id === "number") {
        const pending = this.pending.get(message.id); if (!pending) continue;
        this.pending.delete(message.id); clearTimeout(pending.timer);
        if (pending.onLine) { pending.onLine(line); this.listeners.delete(pending.onLine); }
        if (message.error) pending.reject(new Error(message.error.message || "ACP error"));
        else pending.resolve(message.result);
      }
    }
    if (this.buffer.length > 8 * 1024 * 1024) this.fail(new Error("ACP line exceeds limit"));
  }
  private fail(error: Error) {
    if (this.failure) return;
    this.failure = error;
    this.clearPermissions();
    this.buffer = "";
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear(); this.listeners.clear();
  }
  abort(error: Error) { this.fail(error); }
  get usable(): boolean { return this.failure === null; }
  subscribe(fn: (line: string) => void): () => void {
    this.listeners.add(fn);
    return () => { this.listeners.delete(fn); };
  }
  notify(method: string, params?: unknown) {
    if (method === "session/cancel") this.clearPermissions();
    if (this.failure) throw this.failure;
    this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  }
  request(method: string, params?: unknown, timeout = 30000, onLine?: (line: string) => void): Promise<unknown> {
    if (this.failure) return Promise.reject(this.failure);
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id); if (onLine) this.listeners.delete(onLine);
        reject(new Error(`ACP ${method} timed out`));
      }, timeout);
      this.pending.set(id, { resolve, reject, timer, onLine });
      if (onLine) this.listeners.add(onLine);
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    });
  }
}
