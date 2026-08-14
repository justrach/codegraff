#!/usr/bin/env node
import { readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const version = process.argv[2];
if (!version || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
  console.error("usage: set-version.mjs <semver>");
  process.exit(2);
}

const path = join(ROOT, "package.json");
const manifest = JSON.parse(await readFile(path, "utf8"));
manifest.version = version;
for (const name of Object.keys(manifest.optionalDependencies ?? {})) {
  if (name.startsWith("@codegraff/graff-")) manifest.optionalDependencies[name] = version;
}
await writeFile(path, `${JSON.stringify(manifest, null, 2)}\n`);
