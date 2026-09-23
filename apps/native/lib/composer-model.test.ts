import { test, expect } from "bun:test";
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { modelChoices } from "./acp-client";
import { liveComposerKey, paneComposerKey, pillFromAcp, resolveComposerModel, sameModels, rememberChatCatalog, sharedModelChoices, startWithSelectedModel } from "./composer-model";

test("ACP startup waits for this workspace's catalog and keeps the selected route", async () => {
  const calls: string[] = [];
  const catalog = [
    { key: "xiaomi/mimo-v2.6-pro-ultraspeed", name: "MiMo", provider: "codegraff" },
    { key: "mimo-v2.6-pro-ultraspeed", name: "MiMo Direct", provider: "xiaomi" },
  ];
  const load = async () => { calls.push("catalog"); return catalog; };
  const start = async (model?: string) => { calls.push(`start:${model}`); return model; };
  expect(await startWithSelectedModel(catalog[0].key, [], load, start)).toBe("codegraff/xiaomi/mimo-v2.6-pro-ultraspeed");
  expect(calls).toEqual(["catalog", "start:codegraff/xiaomi/mimo-v2.6-pro-ultraspeed"]);
  expect(await startWithSelectedModel(catalog[1].key, catalog, load, start)).toBe("xiaomi/mimo-v2.6-pro-ultraspeed");
  expect(calls.filter(call => call === "catalog")).toHaveLength(1);
  await expect(startWithSelectedModel("saved-legacy-model", [], async () => [], start)).rejects.toThrow("Could not verify model");
  expect(calls).toHaveLength(3);
  expect(await startWithSelectedModel(undefined, [], load, start)).toBeUndefined();
  expect(calls.at(-1)).toBe("start:undefined");
});

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

test("sameModels ignores a new array of the same rows", () => {
  const row = { key: "running-live", name: "running-live" };
  expect(sameModels([row], [{ ...row }])).toBe(true);
  expect(sameModels([row], [{ key: "other", name: "other" }])).toBe(false);
});

test("catalog refresh keeps changes to effort, fast mode, and capability metadata", () => {
  const row = { key: "gpt-example", name: "gpt-example", effort: "medium", fast: false, effortLevels: ["low", "medium"] };
  expect(sameModels([row], [{ ...row, effort: "high" }])).toBe(false);
  expect(sameModels([row], [{ ...row, fast: true }])).toBe(false);
  expect(sameModels([row], [{ ...row, effortLevels: ["low", "medium", "high"] }])).toBe(false);
});

test("two chats using the same model retain independent effort and fast settings", () => {
  const first = [{ key: "gpt-example", name: "gpt-example", effort: "low", fast: false, effortLevels: ["low", "high"] }];
  const second = [{ ...first[0], effort: "high", fast: true }];
  const catalogs = rememberChatCatalog(rememberChatCatalog({}, 1, first), 2, second);
  expect(catalogs[1][0].effort).toBe("low");
  expect(catalogs[2][0].effort).toBe("high");
  expect(catalogs[1][0].fast).toBe(false);
  expect(sharedModelChoices(second)[0].effort).toBeUndefined();
  expect(sharedModelChoices(second)[0].fast).toBeUndefined();
  expect(sharedModelChoices(second)[0].effortLevels).toEqual(["low", "high"]);
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
  if (req.method === 'initialize') send({id:req.id,result:{protocolVersion:1}});
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
