import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, unlinkSync, rmSync, symlinkSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { attachmentReferences } from "./attachment-references";

function fixture(run: (root: string, image: string) => void) {
  const root = mkdtempSync(path.join(os.tmpdir(), "graff-image-references-"));
  try { run(root, path.join(os.tmpdir(), "owned-é.png")); }
  finally { rmSync(root, {recursive:true, force:true}); }
}

test("an independent archive retains its reference after original session removal", () => fixture((root,image) => {
  const current = path.join(root,"chat.session.json"), archive = path.join(root,"archived");
  mkdirSync(archive);
  writeFileSync(current, JSON.stringify({messages:[{text:`@[${image}]`}]}));
  const rotated = path.join(archive,"copy.transcript.1.jsonl");
  writeFileSync(rotated, JSON.stringify({type:"message",content:[{text:`@[${image}]`}]}).replace('é','\\u00e9')+'\n');
  assert.equal(attachmentReferences([root],image),"referenced");
  unlinkSync(current);
  assert.equal(attachmentReferences([root],image),"referenced");
  unlinkSync(rotated);
  assert.equal(attachmentReferences([root],image),"absent");
}));

test("all supplied workspaces participate in the reference decision", () => fixture((root,image) => {
  const other = path.join(root,"other");mkdirSync(other);
  writeFileSync(path.join(other,"chat.session.json"),JSON.stringify({messages:[image]}));
  const empty = path.join(root,"empty");mkdirSync(empty);
  assert.equal(attachmentReferences([empty,other],image),"referenced");
  assert.equal(attachmentReferences([empty],image),"absent");
  assert.equal(attachmentReferences([],image),"unknown");
}));

test("malformed, unrecognized and missing session data cannot prove absence", () => fixture((root,image) => {
  const file = path.join(root,"chat.session.json");writeFileSync(file,'{');
  assert.equal(attachmentReferences([root],image),"unknown");unlinkSync(file);
  writeFileSync(path.join(root,"unrecognized.txt"),'unknown replay format');
  assert.equal(attachmentReferences([root],image),"unknown");
  assert.equal(attachmentReferences([path.join(root,"missing")],image),"unknown");
}));

test("entry and byte limits report uncertainty rather than partial absence", () => fixture((root,image) => {
  writeFileSync(path.join(root,"chat.session.json"),'{}');
  assert.equal(attachmentReferences([root],image,{entries:0,bytes:100}),"unknown");
  assert.equal(attachmentReferences([root],image,{entries:10,bytes:1}),"unknown");
}));

test("symlinked replay directories are not followed or treated as empty", () => fixture((root,image) => {
  symlinkSync(root,path.join(root,"archived"),'dir');
  assert.equal(attachmentReferences([root],image),"unknown");
}));

test("escaped references in object keys remain consumers", () => fixture((root,image) => {
  writeFileSync(path.join(root,"chat.session.json"),JSON.stringify({messages:[],images:{[image]:{kind:'image'}}}).replace('é','\\u00e9'));
  assert.equal(attachmentReferences([root],image),"referenced");
}));

test("invalid scan limits cannot silently disable the bounds", () => fixture((root,image) => {
  assert.equal(attachmentReferences([root],image,{entries:Infinity,bytes:100}),"unknown");
  assert.equal(attachmentReferences([root],image,{entries:10,bytes:NaN}),"unknown");
}));

test("syntactically valid but invalid checkpoint data is unknown", () => fixture((root,image) => {
  writeFileSync(path.join(root,"chat.session.json"),'{}');
  assert.equal(attachmentReferences([root],image),"unknown");
}));
