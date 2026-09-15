import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync, existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { generateTitle, generatedTitle } from "./generate-title";

test("only one explicit successful title record is accepted", () => {
  assert.equal(generatedTitle('retry 1/6 · ConnectionRefused\n'), null);
  assert.equal(generatedTitle('(title generation failed)\n'), null);
  assert.equal(generatedTitle('{"type":"title_result","title":null}\n'), null);
  assert.equal(generatedTitle('{"type":"title_result","title":"a"}\n{"type":"title_result","title":"b"}'), null);
  assert.equal(generatedTitle('notice\n{"type":"title_result","title":"Fix café navigation"}\nwarning: cleanup'), 'Fix café navigation');
});

async function fixture(source: string, verify: (binary: string, cwd: string) => Promise<void>) {
  const cwd = mkdtempSync(path.join(os.tmpdir(), "graff-title-result-"));
  const binary = path.join(cwd, "graff");
  writeFileSync(binary, '#!/usr/bin/env node\n' + source, {mode:0o700});
  try { await verify(binary, cwd); } finally { rmSync(cwd, {recursive:true, force:true}); }
}

test("a diagnostic line cannot complete the request before a valid title and exit", async () => {
  await fixture(`const fs=require('node:fs');
    if(!process.argv.includes('--json'))process.exit(2);
    console.log('retry 1/6 · ConnectionRefused');
    setTimeout(()=>{console.log(JSON.stringify({type:'title_result',title:'Server lifecycle'}));fs.writeFileSync('finished','yes');},40);`, async (binary,cwd) => {
    assert.equal(await generateTitle(binary, "task", cwd), "Server lifecycle");
    assert(existsSync(path.join(cwd,"finished")));
  });
});

test("a valid-looking result from a failed process is rejected", async () => {
  await fixture(`console.log(JSON.stringify({type:'title_result',title:'Wrong success'}));process.exitCode=1;`, async (binary,cwd) => {
    assert.equal(await generateTitle(binary,"task",cwd), null);
  });
});

test("hanging title generation times out without accepting partial output", async () => {
  await fixture(`console.log(JSON.stringify({type:'title_result',title:'Not finished'}));setInterval(()=>{},1000);`, async (binary,cwd) => {
    assert.equal(await generateTitle(binary,"task",cwd,100), null);
  });
});
