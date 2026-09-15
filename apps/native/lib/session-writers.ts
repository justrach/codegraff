import type { ChildProcess } from "node:child_process";
import { retireWorker } from "./acp-retire";
import { realpathSync } from "node:fs";
import path from "node:path";

type Writer = { child: ChildProcess; detach: () => void };
type Registry = { writers: Map<string, Set<Writer>>; mutations: Set<string>; closing: WeakMap<ChildProcess, Promise<void>> };
const globalRegistry = globalThis as typeof globalThis & { __graffSessionWriters?: Registry };
const registry = globalRegistry.__graffSessionWriters ??= {
  writers: new Map(), mutations: new Set(), closing: new WeakMap(),
};

function key(file: string): string {
  try { return path.join(realpathSync(path.dirname(file)), path.basename(file)); }
  catch { return path.resolve(file); }
}
export function sessionFile(cwd: string, name: string): string {
  // Resolve cwd before adding the not-yet-created sessions directory.
  let root = cwd;
  try { root = realpathSync(cwd); } catch {}
  return path.join(root, ".graff", "sessions", `${name}.session.json`);
}
export function assertSessionWritable(file: string): void {
  if (registry.mutations.has(key(file))) throw new Error("This saved session is being removed; retry after it finishes");
}

/** Track closing writers until actual exit, not merely until their tab closes. */
export function registerSessionWriter(file: string, child: ChildProcess, detach: () => void): void {
  assertSessionWritable(file);
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  const name = key(file), entry = { child, detach };
  const set = registry.writers.get(name) ?? new Set<Writer>();
  set.add(entry); registry.writers.set(name, set);
  child.once("exit", () => {
    set.delete(entry);
    if (!set.size && registry.writers.get(name) === set) registry.writers.delete(name);
  });
}

/** EOF allows the final save; escalation is only for a worker that won't exit. */
export function closeSessionWriter(child: ChildProcess, graceMs = 5000): Promise<void> {
  const pending = registry.closing.get(child);
  if (pending) return pending;
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return Promise.resolve();
  const promise = retireWorker(child, graceMs, "eof");
  registry.closing.set(child, promise);
  return promise;
}

/** Hold the mutation gate until the file operation completes. A new writer
 * cannot slip in between the old writer's final save and deletion/archive. */
export async function withSessionWritersStopped<T>(file: string, mutate: () => T | Promise<T>): Promise<T> {
  const name = key(file);
  assertSessionWritable(file);
  registry.mutations.add(name);
  try {
    const writers = [...(registry.writers.get(name) ?? [])];
    for (const writer of writers) writer.detach();
    await Promise.all(writers.map(({ child }) => closeSessionWriter(child)));
    return await mutate();
  } finally { registry.mutations.delete(name); }
}
