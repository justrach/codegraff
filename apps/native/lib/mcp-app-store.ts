import {open, lstat} from "node:fs/promises";
import {constants} from "node:fs";
import {homedir} from "node:os";
import path from "node:path";
import {validAppId} from "./mcp-apps";

export async function readMcpApp(id: string, root = path.join(homedir(), ".graff", "mcp-apps")): Promise<string> {
  if (!validAppId(id)) throw Error("Invalid app id");
  if ((await lstat(root)).isSymbolicLink()) throw Error("Invalid app directory");
  const file = await open(path.join(root, `${id}.html`), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > 18 * 1024 * 1024) throw Error("Invalid app snapshot");
    return await file.readFile("utf8");
  } finally { await file.close(); }
}
