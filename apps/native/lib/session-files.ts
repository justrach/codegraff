import { randomUUID } from "node:crypto";
import { constants, copyFileSync, existsSync, linkSync, lstatSync, mkdirSync, unlinkSync } from "node:fs";
import path from "node:path";

const SESSION_EXT = ".session.json", TRANSCRIPT_EXT = ".transcript.jsonl";

/** The harness appends the full transcript beside the resumable checkpoint.
 * Both are saved conversation data, even when compaction removes older turns
 * from the checkpoint. Call only after the session's writers have exited. */
export function savedSessionFiles(file: string): string[] {
  if (!file.endsWith(SESSION_EXT)) throw new Error("Invalid saved session path");
  const files = [file];
  const transcript = file.slice(0, -SESSION_EXT.length) + TRANSCRIPT_EXT;
  try {
    const stat = lstatSync(transcript);
    if (!stat.isFile()) throw new Error("Saved transcript is not a regular file");
    files.push(transcript);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  if (!lstatSync(file).isFile()) throw new Error("Saved session is not a regular file");
  return files;
}

export function deleteSavedSession(file: string): void {
  // Keep the indexed checkpoint until companion removal succeeds. A failed
  // cleanup remains discoverable and retryable through the same DELETE route.
  for (const source of savedSessionFiles(file).reverse()) unlinkSync(source);
}

export function archiveSavedSession(file: string): string {
  const sources = savedSessionFiles(file);
  const directory = path.join(path.dirname(file), "archived");
  mkdirSync(directory, { recursive: true });
  const stem = path.basename(file).slice(0, -SESSION_EXT.length);
  const extensions = sources.map(source => source.endsWith(SESSION_EXT) ? SESSION_EXT : TRANSCRIPT_EXT);
  let targetStem = stem;
  if (extensions.some(ext => existsSync(path.join(directory, targetStem + ext)))) targetStem += `.${randomUUID()}`;
  const targets = extensions.map(ext => path.join(directory, targetStem + ext));
  const created: string[] = [];
  try {
    // Exclusive links cannot overwrite an earlier archive, even if another
    // process creates a destination after the collision check. Link every
    // companion before retiring either source, so a failure preserves the pair.
    for (let i = 0; i < sources.length; i++) {
      try { linkSync(sources[i], targets[i]); }
      catch (error) {
        if (!["EXDEV", "EPERM", "ENOTSUP", "EOPNOTSUPP"].includes((error as NodeJS.ErrnoException).code ?? "")) throw error;
        // Removable and network filesystems may not support hard links.
        // Exclusive copy preserves the same no-overwrite archive contract.
        copyFileSync(sources[i], targets[i], constants.COPYFILE_EXCL);
      }
      created.push(targets[i]);
    }
  } catch (error) {
    for (const target of created) unlinkSync(target);
    throw error;
  }
  for (const source of [...sources].reverse()) unlinkSync(source);
  return targets[0];
}
