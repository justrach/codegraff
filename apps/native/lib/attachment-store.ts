import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, openSync, closeSync, fstatSync, writeFileSync, readFileSync, renameSync, unlinkSync, lstatSync, opendirSync, type Dir } from "node:fs";
import os from "node:os";
import path from "node:path";

type Record = { version: 1; name: string; owner: number; retained: boolean; dev: number; ino: number; size?: number; sha256?: string };
export const attachmentDirectory = path.join(os.tmpdir(), "graff-native-attachments");
function ownerAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== "ESRCH"; }
}

/** Only recorded uploads are removable. Saved-message references are durable;
 * a live desktop owns pending drafts independently of route-server restarts. */
export class AttachmentStore {
  private cursor: Dir | null = null;
  private readonly records: string;
  constructor(readonly directory: string, private readonly owner = 0, private readonly alive = ownerAlive) {
    this.records = path.join(directory, ".ownership");
  }
  private recordPath(name: string) { return path.join(this.records, `${name}.json`); }
  private valid(name: string) { return !!name && path.basename(name) === name && !name.startsWith("."); }
  private save(record: Record) {
    const destination = this.recordPath(record.name), temporary = `${destination}.${randomUUID()}`;
    try {
      writeFileSync(temporary, JSON.stringify(record), { flag: "wx", mode: 0o600 });
      renameSync(temporary, destination);
    } finally { try { unlinkSync(temporary); } catch {} }
  }
  private read(name: string): Record | null {
    if (!this.valid(name)) return null;
    try {
      if (!lstatSync(this.recordPath(name)).isFile()) return null;
      const record = JSON.parse(readFileSync(this.recordPath(name), "utf8")) as Record;
      const file = lstatSync(path.join(this.directory, name));
      return record.version === 1 && record.name === name && typeof record.retained === "boolean" && file.isFile() &&
        file.dev === record.dev && file.ino === record.ino && file.size === record.size &&
        typeof record.sha256 === "string" ? record : null;
    } catch { return null; }
  }
  create(label: string, bytes: Uint8Array): string {
    if (!this.valid(label)) throw new Error("Invalid attachment name");
    mkdirSync(this.records, { recursive: true, mode: 0o700 });
    const name = `${randomUUID()}-${label}`, target = path.join(this.directory, name);
    const descriptor = openSync(target, "wx", 0o600);
    try {
      const file = fstatSync(descriptor);
      try {
        writeFileSync(descriptor, bytes);
        this.save({ version: 1, name, owner: this.owner, retained: false, dev: file.dev, ino: file.ino, size: bytes.byteLength, sha256: createHash("sha256").update(bytes).digest("hex") });
      } catch (error) {
        try {
          const current = lstatSync(target);
          if (current.dev === file.dev && current.ino === file.ino) unlinkSync(target);
        } catch {}
        throw error;
      }
    } finally { closeSync(descriptor); }
    return target;
  }
  retainPrompt(params: unknown) {
    const prompt = (params as { prompt?: unknown } | undefined)?.prompt;
    if (!Array.isArray(prompt)) return;
    for (const part of prompt) {
      if (part?.type !== "text" || typeof part.text !== "string") continue;
      for (const match of part.text.matchAll(/@\[([^\]\n]+)\]/g)) {
        if (path.dirname(match[1]) !== this.directory) continue;
        const record = this.read(path.basename(match[1]));
        if (record && !record.retained) this.save({ ...record, retained: true });
      }
    }
  }
  discard(target: string): boolean {
    if (path.dirname(target) !== this.directory) return false;
    const record = this.read(path.basename(target));
    if (!record || record.retained) return false;
    if (createHash("sha256").update(readFileSync(target)).digest("hex") !== record.sha256) return false;
    unlinkSync(target);
    try { unlinkSync(this.recordPath(record.name)); } catch {}
    return true;
  }
  sweep(limit = 64): number {
    let removed = 0;
    try {
      this.cursor ??= opendirSync(this.records);
      for (let i = 0; i < limit; i++) {
        const entry = this.cursor.readSync();
        if (!entry) { this.close(); break; }
        if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
        const record = this.read(entry.name.slice(0, -5));
        if (!record || record.retained || !Number.isSafeInteger(record.owner) || record.owner <= 1 || this.alive(record.owner)) continue;
        if (this.discard(path.join(this.directory, record.name))) removed++;
      }
    } catch { this.close(); }
    return removed;
  }
  close() { try { this.cursor?.closeSync(); } catch {} this.cursor = null; }
}
const state = globalThis as typeof globalThis & { __graffAttachmentStore?: AttachmentStore };
export function attachmentStore() {
  const owner = Number(process.env.GRAFF_ATTACHMENT_OWNER_PID || 0);
  return state.__graffAttachmentStore ??= new AttachmentStore(attachmentDirectory, Number.isSafeInteger(owner) ? owner : 0);
}
