#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SDK_ROOT = resolve(HERE, "..");
const npmCli = process.env.npm_execpath;
if (!npmCli) throw new Error("run this smoke through `npm run test:packed`");
const PLATFORM_PACKAGES = {
  "darwin-arm64": "@codegraff/graff-darwin-arm64",
  "darwin-x64": "@codegraff/graff-darwin-x64",
  "linux-arm64": "@codegraff/graff-linux-arm64",
  "linux-x64": "@codegraff/graff-linux-x64",
  "win32-arm64": "@codegraff/graff-win32-arm64",
  "win32-x64": "@codegraff/graff-win32-x64",
};
const ALL_TARGETS = [
  ["aarch64-macos", "@codegraff/graff-darwin-arm64"],
  ["x86_64-macos", "@codegraff/graff-darwin-x64"],
  ["aarch64-linux", "@codegraff/graff-linux-arm64"],
  ["x86_64-linux", "@codegraff/graff-linux-x64"],
  ["aarch64-windows", "@codegraff/graff-win32-arm64"],
  ["x86_64-windows", "@codegraff/graff-win32-x64"],
];

function option(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? undefined : process.argv[index + 1];
}

function run(file, args, cwd, env = process.env) {
  return execFileSync(file, args, { cwd, env, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] });
}

function npmRun(args, cwd) {
  return run(process.execPath, [npmCli, ...args], cwd);
}

function pack(directory, destination) {
  const output = npmRun(["pack", directory, "--pack-destination", destination, "--json", "--silent"], SDK_ROOT);
  const result = JSON.parse(output);
  if (result.length !== 1 || !result[0].filename) throw new Error(`unexpected npm pack output: ${output}`);
  return join(destination, result[0].filename);
}

const temp = await mkdtemp(join(tmpdir(), "codegraff-sdk-packed-"));
try {
  const packages = join(temp, "packages");
  const tarballs = join(temp, "tarballs");
  const consumer = join(temp, "consumer");
  const emptyPath = join(temp, "empty-path");
  await Promise.all([packages, tarballs, consumer, emptyPath].map((path) => mkdir(path, { recursive: true })));

  const suppliedBinary = option("--binary");
  if (process.platform === "win32" && !suppliedBinary) {
    throw new Error("Windows packed smoke requires --binary pointing to a real graff.exe");
  }
  const sourceBinary = suppliedBinary ? resolve(suppliedBinary) : join(temp, "fake-graff");
  if (!suppliedBinary) {
    const fixture = await readFile(join(SDK_ROOT, "test-fixtures", "fake-graff.mjs"), "utf8");
    await writeFile(sourceBinary, fixture.replace(/^#!.*$/m, `#!${process.execPath}`));
    await chmod(sourceBinary, 0o755);
  }

  const nativeTarballs = {};
  for (const [target, packageName] of ALL_TARGETS) {
    const output = run(process.execPath, [
      join(HERE, "package-platform.mjs"),
      "--target", target,
      "--binary", sourceBinary,
      "--out", packages,
    ], SDK_ROOT);
    const { packageDir } = JSON.parse(output);
    nativeTarballs[packageName] = pack(packageDir, tarballs);
  }
  const sdkTarball = pack(SDK_ROOT, tarballs);

  const manifest = {
    private: true,
    type: "module",
    dependencies: { "@codegraff/sdk": `file:${sdkTarball}` },
    optionalDependencies: Object.fromEntries(
      Object.entries(nativeTarballs).map(([name, path]) => [name, `file:${path}`]),
    ),
  };
  await writeFile(join(consumer, "package.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  npmRun(["install", "--ignore-scripts", "--no-audit", "--no-fund"], consumer);

  const smoke = `
import { Harness } from "@codegraff/sdk";
const harness = Harness.init({ env: { ...process.env, PATH: process.env.CLEAN_PATH, Path: process.env.CLEAN_PATH, GRAFF_NO_TELEMETRY: "1" } });
try {
  ${suppliedBinary ? "await harness.setEffort(\"low\");" : "const text = await harness.ask(\"out-of-box\"); if (text !== \"user:out-of-box\") throw new Error(`unexpected reply: \${text}`);"}
} finally {
  await harness.close();
}
console.log("packed SDK resolved and ran its optional native package with no graff on PATH");
`;
  await writeFile(join(consumer, "smoke.mjs"), smoke);
  const output = run(process.execPath, [join(consumer, "smoke.mjs")], consumer, {
    ...process.env,
    CLEAN_PATH: emptyPath,
  });
  process.stdout.write(output);

  const packageName = PLATFORM_PACKAGES[`${process.platform}-${process.arch}`];
  if (!packageName) throw new Error(`test does not support ${process.platform}-${process.arch}`);
  const require = createRequire(join(consumer, "package.json"));
  const nativeManifestPath = require.resolve(`${packageName}/package.json`);
  const nativeManifest = JSON.parse(await readFile(nativeManifestPath, "utf8"));
  nativeManifest.graffProtocol = "incompatible-test-version";
  await writeFile(nativeManifestPath, `${JSON.stringify(nativeManifest, null, 2)}\n`);
  await writeFile(join(consumer, "mismatch.mjs"), `
import { Harness } from "@codegraff/sdk";
try {
  Harness.init({ env: { ...process.env, PATH: process.env.CLEAN_PATH, Path: process.env.CLEAN_PATH } });
  throw new Error("expected protocol mismatch");
} catch (error) {
  if (!String(error).includes("uses graff protocol incompatible-test-version")) throw error;
}
console.log("packed SDK rejects an incompatible optional native package");
`);
  process.stdout.write(run(process.execPath, [join(consumer, "mismatch.mjs")], consumer, {
    ...process.env,
    CLEAN_PATH: emptyPath,
  }));
} finally {
  await rm(temp, { recursive: true, force: true });
}
