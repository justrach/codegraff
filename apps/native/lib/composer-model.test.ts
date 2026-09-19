import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { modelChoices } from "./acp-client";
import {
  catalogMayWriteChatModel,
  catalogMayWriteGlobalKey,
  liveComposerKey,
  modelDisplayName,
  paneComposerKey,
  pillFromAcp,
  resolveComposerModel,
  sameModels,
  shouldConfirmModelSwitch,
} from "./composer-model";

test("the pill keeps an unknown live key instead of catalog[0]", () => {
  const decoy = { key: "catalog-zero", name: "catalog-zero" };
  const pill = resolveComposerModel([decoy], "running-live");
  expect(pill.key).toBe("running-live");
  expect(pill.name).toBe("running-live");
});

test("a tab with an agent does not inherit another chat's global pick", () => {
  expect(liveComposerKey(undefined, "catalog-zero", true)).toBeUndefined();
  expect(liveComposerKey("running-live", "catalog-zero", true)).toBe("running-live");
  expect(liveComposerKey(undefined, "catalog-zero", false)).toBe("catalog-zero");
});

test("a pending pick owns the pane pill until the new agent answers", () => {
  expect(paneComposerKey("glm-5.3-flash", "glm-5.3-flash", true, { chatId: 2, key: "grok-4.6" }, 2)).toBe("grok-4.6");
  expect(paneComposerKey("glm-5.3-flash", "glm-5.3-flash", true, { chatId: 2, key: "grok-4.6" }, 1)).toBe("glm-5.3-flash");
});

test("catalog refresh does not overwrite a pending pick or the global inherit", () => {
  expect(catalogMayWriteChatModel(2, { chatId: 2 })).toBe(false);
  expect(catalogMayWriteChatModel(1, { chatId: 2 })).toBe(true);
  expect(catalogMayWriteChatModel(1, null)).toBe(true);
  expect(catalogMayWriteGlobalKey(true)).toBe(false);
  expect(catalogMayWriteGlobalKey(false)).toBe(true);
});

test("a chat with history or a running turn confirms before respawn", () => {
  expect(shouldConfirmModelSwitch(1, false)).toBe(true);
  expect(shouldConfirmModelSwitch(0, true)).toBe(true);
  expect(shouldConfirmModelSwitch(0, false)).toBe(false);
  expect(modelDisplayName([{ key: "a", name: "Alpha" }], "a")).toBe("Alpha");
  expect(modelDisplayName([], null)).toBe("the current model");
});

test("sameModels ignores a new array of the same rows", () => {
  const row = { key: "running-live", name: "running-live" };
  expect(sameModels([row], [{ ...row }])).toBe(true);
  expect(sameModels([row], [{ key: "other", name: "other" }])).toBe(false);
});

function askAcpModels(binary: string, model: string): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const child = spawn(binary, ["acp", "--model", model], { stdio: ["pipe", "pipe", "ignore"] });
    let output = "";
    let settled = false;
    const finish = (error?: Error, value?: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.stdin.end();
      if (child.exitCode === null) child.kill("SIGTERM");
      if (error) reject(error);
      else resolve(value);
    };
    const timer = setTimeout(() => finish(new Error("ACP graff/models timed out")), 3500);
    child.once("error", (error) => finish(error));
    child.once("exit", () => finish(new Error("ACP exited before graff/models")));
    child.stdout.on("data", (chunk) => {
      output += chunk.toString();
      let newline;
      while ((newline = output.indexOf("\n")) >= 0) {
        const line = output.slice(0, newline);
        output = output.slice(newline + 1);
        try {
          const reply = JSON.parse(line);
          if (reply.id === 2) finish(reply.error ? new Error(reply.error.message ?? "graff/models failed") : undefined, reply.result);
        } catch { /* ACP diagnostics are not results. */ }
      }
    });
    child.stdin.on("error", (error) => finish(error));
    child.stdin.write('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}\n{"jsonrpc":"2.0","id":2,"method":"graff/models"}\n');
  });
}

test("the composer pill matches graff/models current from the ACP worker", async () => {
  const temp = mkdtempSync(path.join(os.tmpdir(), "graff-acp-pill-"));
  const binary = path.join(temp, "agent.cjs");
  writeFileSync(binary, `#!/usr/bin/env node
const readline = require('node:readline');
const args = process.argv.slice(2);
const model = args.includes('--model') ? args[args.indexOf('--model') + 1] : 'catalog-zero';
const send = value => console.log(JSON.stringify(value));
readline.createInterface({input:process.stdin}).on('line', line => {
  const req = JSON.parse(line);
  if (req.method === 'initialize') send({id:req.id,result:{}});
  if (req.method === 'graff/models') send({id:req.id,result:{
    models: [
      {name:'catalog-zero',provider:'plan',authenticated:true,context:1,cost:'plan',current:false},
      {name:model,provider:'local',authenticated:false,context:1,cost:'local',current:true}
    ],
    current: {model, provider:'local'}
  }});
}).on('close', () => process.exit(0));
`, { mode: 0o700 });
  try {
    const result = await askAcpModels(binary, "running-live");
    const { models, current } = modelChoices(result as Parameters<typeof modelChoices>[0]);
    expect(current).toBe("running-live");
    const pill = pillFromAcp(models, current, "catalog-zero", true);
    expect(pill.key).toBe(current);
    expect(pill.key).not.toBe("catalog-zero");
  } finally {
    rmSync(temp, { recursive: true, force: true });
  }
});
