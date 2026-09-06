import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";

// A transient ACP query: no session/new, prompt, MCP processes, or resident agent.
const queries = new Map<string, { expires: number; result: Promise<unknown> }>();
export function readModelCatalog(cwd: string): Promise<unknown> {
  const cached = queries.get(cwd);
  if (cached && cached.expires > Date.now()) return cached.result;
  const result = new Promise<unknown>((resolve, reject) => {
    const directory = mkdtempSync(path.join(os.tmpdir(), "graff-models-"));
    const config = path.join(directory, "mcp.json");
    writeFileSync(config, '{"mcpServers":{}}');
    const candidate = path.resolve(process.cwd(), "../../zig-out/bin/graff");
    const binary = process.env.GRAFF_BIN || (existsSync(candidate) ? candidate : "graff");
    const child = spawn(binary, ["acp"], { cwd, stdio: ["pipe", "pipe", "ignore"],
      env: { ...process.env, GRAFF_MCP_CONFIG: config } });
    let output = "", settled = false;
    const finish = (error?: Error, value?: unknown) => {
      if (settled) return; settled = true; clearTimeout(timer);
      child.stdin.end(); if (child.exitCode === null) child.kill("SIGTERM");
      rmSync(directory, { recursive: true, force: true });
      if (error) reject(error); else resolve(value);
    };
    const timer = setTimeout(() => finish(new Error("graff model catalog timed out")), 20000);
    child.once("error", error => finish(error));
    child.once("exit", () => finish(new Error("graff exited before returning its model catalog")));
    child.stdout.on("data", chunk => {
      output += chunk.toString();
      if (output.length > 4 * 1024 * 1024) return finish(new Error("Model catalog exceeds limit"));
      let newline;
      while ((newline = output.indexOf("\n")) >= 0) {
        const line = output.slice(0, newline); output = output.slice(newline + 1);
        try {
          const reply = JSON.parse(line);
          if (reply.id === 2) finish(reply.error ? new Error(reply.error.message) : undefined, reply.result);
        } catch { /* ACP diagnostics are not results. */ }
      }
    });
    child.stdin.on("error", error => finish(error));
    child.stdin.write('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}\n{"jsonrpc":"2.0","id":2,"method":"graff/models"}\n');
  });
  queries.set(cwd, { expires: Date.now() + 10000, result });
  void result.catch(() => queries.delete(cwd));
  if (queries.size > 16) queries.delete(queries.keys().next().value!);
  return result;
}
