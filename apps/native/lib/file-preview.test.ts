import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, open, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { filePreview, MAX_PREVIEW } from "./file-preview";
test("large previews are bounded and retain full file size; binary contents stay hidden", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'graff-preview-'));
  try {
    const name = path.join(root, 'large.log');
    const fd = await open(name, 'w');
    await fd.write(Buffer.alloc(MAX_PREVIEW, 65)); await fd.truncate(512 * 1024 * 1024); await fd.close();
    const preview = await filePreview(name);
    assert.equal(preview.size, 512 * 1024 * 1024);
    assert.equal(preview.text.length, MAX_PREVIEW); assert.equal(preview.truncated, true);
    await writeFile(name, Buffer.from([0, 1, 2]));
    assert.equal((await filePreview(name)).text, '');
  } finally { await rm(root, { recursive: true, force: true }); }
});
