import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { reviewState, reviewDiff } from "./git-review";
test("shared review includes staged, unstaged, new and deleted files without shell path interpretation", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'graff-review-'));
  const git = (...args: string[]) => execFileSync('git', args, { cwd: root, stdio: 'ignore' });
  try {
    git('init'); git('config','user.name','Test'); git('config','user.email','test@example.invalid');
    writeFileSync(path.join(root,'a.txt'),'old\n'); writeFileSync(path.join(root,'removed.txt'),'gone\n'); git('add','.'); git('commit','-m','initial');
    writeFileSync(path.join(root,'a.txt'),'staged\n'); git('add','a.txt'); writeFileSync(path.join(root,'a.txt'),'working\n'); git('rm','removed.txt');
    writeFileSync(path.join(root,'new file.txt'),'new\n');
    const all = await reviewState(root);
    assert.deepEqual(all.files.map(f => f.path), ['a.txt','new file.txt','removed.txt']);
    assert.match(await reviewDiff(root,'a.txt'), /\+working/);
    assert.match(await reviewDiff(root,'a.txt','staged'), /\+staged/);
    assert.match(await reviewDiff(root,'removed.txt'), /-gone/);
    assert.match(await reviewDiff(root,'new file.txt'), /\+new/);
    await assert.rejects(reviewDiff(root,'../private'), /relative workspace/);
  } finally { rmSync(root,{recursive:true,force:true}); }
});
test("a repository without commits displays both untracked and staged first files", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'graff-review-first-'));
  try {
    execFileSync('git', ['init', '-q', root]);
    writeFileSync(path.join(root, 'first.txt'), 'first line\n');
    assert.match(await reviewDiff(root, 'first.txt'), /\+first line/);
    assert.equal((await reviewState(root)).files.length, 1);
    execFileSync('git', ['add', 'first.txt'], { cwd: root });
    assert.match(await reviewDiff(root, 'first.txt'), /\+first line/);
    assert.match(await reviewDiff(root, 'first.txt', 'staged'), /\+first line/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
test("numstat retains tabs in file names", async () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'graff-review-tabs-'));
  try {
    execFileSync('git', ['init', '-q', root]);
    writeFileSync(path.join(root, 'with\ttab.txt'), 'first\nsecond\n');
    execFileSync('git', ['add', '.'], { cwd: root });
    const state = await reviewState(root, 'staged');
    assert.equal(state.files[0].path, 'with\ttab.txt');
    assert.equal(state.totalAdd, 2);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
