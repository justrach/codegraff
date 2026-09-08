import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Run with Node. Separate processes prevent either plugin's global caches from
// contaminating the other's retained-heap measurement. No desktop/model calls.
const nativeRoot = fileURLToPath(new URL("..", import.meta.url));
if (process.argv[2] === "--worker") {
  const mode = process.argv[3];
  const { code } = mode === "baseline" ? await import("@streamdown/code") : await import("../lib/code-highlighter.ts");
  const themes = code.getThemes();
  const highlight = source => new Promise(resolve => {
    const result = code.highlight({ code: source, language: "typescript", themes }, resolve);
    if (result) resolve(result);
  });
  await highlight("const warm = true;");
  global.gc();
  const before = process.memoryUsage(), started = performance.now();
  const source = Array.from({ length: 300 }, (_, index) => `export const record${index} = {name: "entry${index}", enabled: true, size: ${index}};`).join("\n");
  let calls = 0, peakHeap = before.heapUsed;
  for (let length = 100; length < source.length; length += 80) {
    await highlight(source.slice(0, length)); calls++;
    peakHeap = Math.max(peakHeap, process.memoryUsage().heapUsed);
  }
  await highlight(source); calls++;
  const durationMs = performance.now() - started;
  global.gc();
  const after = process.memoryUsage();
  const mib = value => Math.round(value / 1048576 * 100) / 100;
  console.log(JSON.stringify({ mode, calls, sourceCharacters: source.length, durationMs: Math.round(durationMs),
    beforeHeapMiB: mib(before.heapUsed), retainedHeapMiB: mib(after.heapUsed), retainedHeapDeltaMiB: mib(after.heapUsed - before.heapUsed),
    peakHeapMiB: mib(peakHeap), rssMiB: mib(after.rss), rssDeltaMiB: mib(after.rss - before.rss), cache: code.stats?.() ?? null }));
  code.dispose?.();
} else {
  const results = [];
  for (let run = 0; run < 3; run++) {
    for (const mode of run % 2 ? ["candidate", "baseline"] : ["baseline", "candidate"]) {
      const output = execFileSync(process.execPath, ["--expose-gc", "--experimental-strip-types", fileURLToPath(import.meta.url), "--worker", mode], { cwd: nativeRoot, encoding: "utf8" });
      const row = { run: run + 1, ...JSON.parse(output.trim()) }; results.push(row); console.log(JSON.stringify(row));
    }
  }
  const median = (mode, key) => results.filter(row => row.mode === mode).map(row => row[key]).sort((a, b) => a - b)[1];
  const report = { scenario: "One 300-line TypeScript fence, streamed in 80-character prefixes, three isolated process pairs.",
    measurement: "Actual installed Shiki and prior plugin. Forced GC measures retained Node heap; process RSS includes allocator reserve. This is a library regression workload, not desktop RAM or display performance.",
    summary: Object.fromEntries(["baseline", "candidate"].map(mode => [mode, Object.fromEntries(["retainedHeapDeltaMiB", "peakHeapMiB", "rssMiB", "durationMs"].map(key => [key, median(mode, key)]))])), results };
  const output = path.resolve(nativeRoot, "../../zig-out/performance/code-memory.json");
  mkdirSync(path.dirname(output), { recursive: true }); writeFileSync(output, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report.summary));
}
