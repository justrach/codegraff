import { expect, test } from "bun:test";
import {
  isActive,
  mergeServerRows,
  parseMcpConfig,
  removeServer,
  splitCommandLine,
  upsertHttp,
  upsertStdio,
  validRemoteUrl,
  validServerName,
} from "./mcp-servers";

test("valid names and URLs", () => {
  expect(validServerName("deepwiki")).toBe(true);
  expect(validServerName("codegraff_desktop")).toBe(true);
  expect(validServerName("../x")).toBe(false);
  expect(validRemoteUrl("https://mcp.example.com/sse")).toBe(true);
  expect(validRemoteUrl("http://localhost:3000/mcp")).toBe(true);
  expect(validRemoteUrl("http://example.com/mcp")).toBe(false);
});

test("project entries win on name conflict", () => {
  const rows = mergeServerRows(
    { shared: { command: "npx", args: ["-y", "global"] }, onlyUser: { url: "https://user.example/mcp" } },
    { shared: { command: "bun", args: ["local.ts"] } },
  );
  expect(rows.map((row) => `${row.name}:${row.scope}:${row.target}`)).toEqual([
    "onlyUser:user:https://user.example/mcp",
    "shared:local:bun local.ts",
  ]);
});

test("upsert and remove keep other servers", () => {
  let config = parseMcpConfig('{"mcpServers":{"keep":{"command":"echo"}}}');
  config = upsertStdio(config, "files", "npx", ["-y", "@modelcontextprotocol/server-filesystem", "."]);
  config = upsertHttp(config, "deepwiki", "https://mcp.deepwiki.com/mcp");
  expect(Object.keys(config.mcpServers).sort()).toEqual(["deepwiki", "files", "keep"]);
  config = removeServer(config, "files");
  expect(Object.keys(config.mcpServers).sort()).toEqual(["deepwiki", "keep"]);
});

test("active follows the workspace MCP switch and disabled flag", () => {
  const row = { name: "x", kind: "stdio" as const, target: "npx foo", scope: "user" as const, disabled: false };
  expect(isActive(row, true)).toBe(true);
  expect(isActive(row, false)).toBe(false);
  expect(isActive({ ...row, disabled: true }, true)).toBe(false);
});

test("command line split", () => {
  expect(splitCommandLine("  npx  -y  pkg  ")).toEqual({ command: "npx", args: ["-y", "pkg"] });
  expect(splitCommandLine("   ")).toBeNull();
});
