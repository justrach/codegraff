import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";

export type ConsumerState = "active" | "inactive" | "unknown";
const validPid = (pid: number | undefined): pid is number => Number.isSafeInteger(pid) && pid! > 1;

/** Append before handing a path to a worker. Never erase another consumer. */
export function enrollAttachmentConsumer(root: string, pid?: number): void {
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const value = validPid(pid) ? pid : null;
  const name = value === null ? "unknown" : createHash("sha256").update(String(value)).digest("hex");
  try { writeFileSync(path.join(root, name + ".json"), JSON.stringify({ pid: value }), { flag: "wx", mode: 0o600 }); }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
}

/** Inactivity covers enrolled processes only. It is not a collection lock or
 * proof that no other surface has acquired the path. PID reuse preserves data. */
export function attachmentConsumers(root: string, owner: number, alive: (pid: number) => boolean): ConsumerState {
  try {
    if (!validPid(owner)) return "unknown";
    if (alive(owner)) return "active";
    const names = readdirSync(root);
    if (!names.length || names.length > 256 || names.includes("unknown.json")) return "unknown";
    let unknown = false;
    for (const name of names) {
      const file = path.join(root, name), stat = lstatSync(file);
      if (!stat.isFile() || stat.size > 1024) { unknown = true; continue; }
      const { pid } = JSON.parse(readFileSync(file, "utf8"));
      if (!validPid(pid) || name !== createHash("sha256").update(String(pid)).digest("hex") + ".json") {
        unknown = true; continue;
      }
      if (alive(pid)) return "active";
    }
    return unknown ? "unknown" : "inactive";
  } catch { return "unknown"; }
}
