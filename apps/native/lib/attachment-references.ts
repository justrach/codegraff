import { closeSync, fstatSync, lstatSync, openSync, opendirSync, readSync } from "node:fs";
import path from "node:path";

export type ReferenceState = "referenced" | "absent" | "unknown";
export type ReferenceLimits = { entries: number; bytes: number };
const defaults: ReferenceLimits = { entries: 256, bytes: 32 * 1024 * 1024 };
const checkpoint = /\.session\.json$/;
const transcript = /\.transcript(?:\.1)?\.jsonl$/;

function mentions(value: unknown, name: string): boolean {
  if (typeof value === "string") return value.includes(name);
  if (Array.isArray(value)) return value.some(item => mentions(item, name));
  if (value && typeof value === "object") return Object.entries(value).some(([key,item]) => key.includes(name) || mentions(item, name));
  return false;
}

/** Inspect every supplied managed session directory, including archives.
 * This proves absence only within those scopes. Callers must separately prove
 * scope completeness and exclude live writers before using it for cleanup. */
export function attachmentReferences(directories: readonly string[], target: string, limits: ReferenceLimits = defaults): ReferenceState {
  if (!directories.length || !path.isAbsolute(target) ||
      !Number.isSafeInteger(limits.entries) || limits.entries < 0 ||
      !Number.isSafeInteger(limits.bytes) || limits.bytes < 0) return "unknown";
  const name = path.basename(target);
  if (!name || name === "." || name === "..") return "unknown";
  let remainingEntries = limits.entries, remainingBytes = limits.bytes, uncertain = false;
  const pending = [...new Set(directories.map(directory => path.resolve(directory)))];
  while (pending.length) {
    const directory = pending.pop()!;
    try {
      if (!lstatSync(directory).isDirectory()) { uncertain = true; continue; }
      const entries = opendirSync(directory);
      try {
        for (;;) {
          const entry = entries.readSync();
          if (!entry) break;
          if (--remainingEntries < 0) return "unknown";
          const file = path.join(directory, entry.name), stat = lstatSync(file);
          if (stat.isDirectory()) { pending.push(file); continue; }
          if (!stat.isFile()) { uncertain = true; continue; }
          const isCheckpoint = checkpoint.test(entry.name), isTranscript = transcript.test(entry.name);
          if (!isCheckpoint && !isTranscript) { uncertain = true; continue; }
          if (stat.size > remainingBytes) return "unknown";
          remainingBytes -= stat.size;
          const descriptor = openSync(file, "r");
          let bytes: Buffer;
          try {
            const opened = fstatSync(descriptor);
            if (!opened.isFile() || opened.dev !== stat.dev || opened.ino !== stat.ino || opened.size !== stat.size) { uncertain = true; continue; }
            bytes = Buffer.alloc(stat.size);
            let offset = 0;
            while (offset < bytes.length) {
              const count = readSync(descriptor, bytes, offset, bytes.length - offset, offset);
              if (!count) break;
              offset += count;
            }
            const after = fstatSync(descriptor);
            if (offset !== bytes.length || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) { uncertain = true; continue; }
          } finally { closeSync(descriptor); }
          const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
          const records = isCheckpoint ? [JSON.parse(text)] : text.split("\n").filter(line => line.trim()).map(line => JSON.parse(line));
          const shaped = records.every(record => record && typeof record === "object" && !Array.isArray(record) &&
            (isCheckpoint ? Array.isArray(record.messages) : typeof record.type === "string" || typeof record.role === "string"));
          if (!shaped) { uncertain = true; continue; }
          if (records.some(record => mentions(record, name))) return "referenced";
        }
      } finally { entries.closeSync(); }
    } catch { uncertain = true; }
  }
  return uncertain ? "unknown" : "absent";
}
