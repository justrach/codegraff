import {open, lstat} from "node:fs/promises";
import {constants} from "node:fs";
import {homedir} from "node:os";
import path from "node:path";
import {validAppId} from "./mcp-apps";

/** Read one bounded HTML snapshot. The id is an opaque 32-hex name we wrote
 *  ourselves — never a caller-supplied path — and the open refuses to follow
 *  a symlink out of the snapshot directory. */
async function readSnapshot(id: string, root: string): Promise<string> {
  if (!validAppId(id)) throw Error("Invalid snapshot id");
  if ((await lstat(root)).isSymbolicLink()) throw Error("Invalid snapshot directory");
  const file = await open(path.join(root, `${id}.html`), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 18 * 1024 * 1024) throw Error("Invalid snapshot");
    return await file.readFile("utf8");
  } finally { await file.close(); }
}

/** An MCP server's declared app view (ADR 0091), saved by the engine. */
export function readMcpApp(id: string, root = path.join(homedir(), ".graff", "mcp-apps")): Promise<string> {
  return readSnapshot(id, root);
}

/** A page the model drew for the user (`render_html`). Its own directory so
 *  the two kinds stay tellable apart on disk, the same guards either way. */
export function readView(id: string, root = path.join(homedir(), ".graff", "views")): Promise<string> {
  return readSnapshot(id, root);
}
