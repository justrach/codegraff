import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { readModelCatalog } from "./model-catalog-server";

test("a pending catalog request stays single-flight beyond the completed-result TTL", async () => {
  const cwd = mkdtempSync(path.join(os.tmpdir(), "graff-catalog-cache-"));
  const binary = path.join(cwd, "agent.cjs");
  writeFileSync(binary, `#!/usr/bin/env node
require('node:readline').createInterface({input:process.stdin}).on('line', line => {
  const request=JSON.parse(line);
  if(request.method==='graff/models') setTimeout(() => console.log(JSON.stringify({id:request.id,result:{models:[]}})), 40);
});
`, { mode: 0o700 });
  const previous = process.env.GRAFF_BIN;
  const now = Date.now;
  process.env.GRAFF_BIN = binary;
  try {
    const first = readModelCatalog(cwd);
    Date.now = () => now() + 11000;
    const second = readModelCatalog(cwd);
    Date.now = now;
    expect(second).toBe(first);
    expect(await first).toEqual({ models: [] });
    expect(readModelCatalog(cwd)).toBe(first);
  } finally {
    Date.now = now;
    if (previous === undefined) delete process.env.GRAFF_BIN; else process.env.GRAFF_BIN = previous;
    rmSync(cwd, { recursive: true, force: true });
  }
});
