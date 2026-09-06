import type { ChildProcessByStdio } from "node:child_process";
import type { Readable, Writable } from "node:stream";
import { StringDecoder } from "node:string_decoder";
type Child = ChildProcessByStdio<Writable, Readable, null>;
type Message = { id?: number; method?: string; params?: unknown; result?: unknown; error?: { message?: string } };
type Pending = { resolve(value: unknown): void; reject(error: Error): void; timer: ReturnType<typeof setTimeout>; onLine?: (line: string) => void };

/** Exactly one stdout reader. RPCs never consume another request's notifications. */
export class AcpTransport {
  private nextId = 1;
  private buffer = "";
  private decoder = new StringDecoder("utf8");
  private pending = new Map<number, Pending>();
  private listeners = new Set<(line: string) => void>();
  private failure: Error | null = null;
  constructor(private child: Child, private notification: (message: Message) => void = () => {}) {
    child.stdout.on("data", chunk => this.feed(this.decoder.write(chunk)));
    child.once("error", error => this.fail(error));
    child.once("exit", (code, signal) => this.fail(new Error(`graff acp exited (${code ?? signal})`)));
    child.stdin.on("error", error => this.fail(error));
  }
  private feed(text: string) {
    this.buffer += text;
    if (this.buffer.length > 8 * 1024 * 1024) { this.fail(new Error("ACP line exceeds limit")); return; }
    let newline;
    while ((newline = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
      let message: Message;
      try { message = JSON.parse(line); } catch { continue; }
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
  }
  private fail(error: Error) {
    this.failure = error;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear(); this.listeners.clear();
  }
  notify(method: string, params?: unknown) {
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
