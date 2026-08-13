#!/usr/bin/env node
import { chmod, copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SDK_ROOT = resolve(HERE, "..");
const REPO_ROOT = resolve(SDK_ROOT, "../..");

const TARGETS = {
  "aarch64-macos": { suffix: "darwin-arm64", os: "darwin", cpu: "arm64", binary: "graff" },
  "x86_64-macos": { suffix: "darwin-x64", os: "darwin", cpu: "x64", binary: "graff" },
  "aarch64-linux": { suffix: "linux-arm64", os: "linux", cpu: "arm64", binary: "graff" },
  "x86_64-linux": { suffix: "linux-x64", os: "linux", cpu: "x64", binary: "graff" },
  "aarch64-windows": { suffix: "win32-arm64", os: "win32", cpu: "arm64", binary: "graff.exe" },
  "x86_64-windows": { suffix: "win32-x64", os: "win32", cpu: "x64", binary: "graff.exe" },
};

function usage(message) {
  if (message) console.error(`error: ${message}`);
  console.error("usage: package-platform.mjs --target <zig-target> --binary <path> --out <dir> [--version <semver>]");
  process.exit(2);
}

function argumentsMap(argv) {
  const values = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) usage("options require values");
    values[key.slice(2)] = value;
  }
  return values;
}

const args = argumentsMap(process.argv.slice(2));
const target = TARGETS[args.target];
if (!target) usage(`unsupported target ${args.target ?? "(missing)"}`);
if (!args.binary) usage("--binary is required");
if (!args.out) usage("--out is required");

const sdkManifest = JSON.parse(await readFile(join(SDK_ROOT, "package.json"), "utf8"));
const generated = await readFile(join(SDK_ROOT, "harness.ts"), "utf8");
const protocol = generated.match(/export const HARNESS_VERSION = "([^"]+)";/)?.[1];
if (!protocol) throw new Error("could not read HARNESS_VERSION from generated harness.ts");
const version = args.version ?? sdkManifest.version;
const packageName = `@codegraff/graff-${target.suffix}`;
const packageDir = resolve(args.out, `graff-${target.suffix}`);
const binaryDir = join(packageDir, "bin");
const binaryDest = join(binaryDir, target.binary);

await rm(packageDir, { recursive: true, force: true });
await mkdir(binaryDir, { recursive: true });
await copyFile(resolve(args.binary), binaryDest);
await chmod(binaryDest, 0o755);
await copyFile(join(REPO_ROOT, "LICENSE"), join(packageDir, "LICENSE"));

const manifest = {
  name: packageName,
  version,
  description: `Native graff executable for ${target.os}-${target.cpu}`,
  graffProtocol: protocol,
  license: "Apache-2.0",
  repository: {
    type: "git",
    url: "git+https://github.com/justrach/codegraff.git",
  },
  os: [target.os],
  cpu: [target.cpu],
  preferUnplugged: true,
  files: ["bin", "README.md", "LICENSE"],
  bin: { graff: `bin/${target.binary}` },
  exports: {
    "./package.json": "./package.json",
    [`./bin/${target.binary}`]: `./bin/${target.binary}`,
  },
};

await writeFile(join(packageDir, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
await writeFile(join(packageDir, "README.md"), `# ${packageName}\n\n` +
  `Platform-specific native executable used by \`@codegraff/sdk\`. ` +
  `Install the SDK instead of depending on this package directly.\n`);

process.stdout.write(`${JSON.stringify({ packageDir, packageName, version, target: args.target, binary: basename(binaryDest) })}\n`);
