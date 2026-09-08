import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const nativeRoot = fileURLToPath(new URL("..", import.meta.url));
const mib = value => Math.round(value / 1048576 * 100) / 100;
if (process.argv[2] === "--worker") {
  const [mode, payloadFile, decoderFile] = process.argv.slice(3);
  const { sessionFromResponse } = await import(pathToFileURL(decoderFile));
  sessionFromResponse({ name: "warm", messages: [] });
  global.gc();
  const before = process.memoryUsage();
  let payload = readFileSync(payloadFile, "utf8");
  const payloadBytes = Buffer.byteLength(payload);
  const started = performance.now();
  let peakHeap = 0;
  const decode = () => {
    const response = JSON.parse(payload);
    peakHeap = process.memoryUsage().heapUsed;
    const loaded = sessionFromResponse(response);
    peakHeap = Math.max(peakHeap, process.memoryUsage().heapUsed);
    return loaded;
  };
  const loaded = decode();
  const loadParseMs = performance.now() - started;
  payload = null;
  global.gc();
  const after = process.memoryUsage();
  console.log(JSON.stringify({ mode, payloadBytes, messages: loaded.messages.length, loadParseMs,
    peakHeapDeltaMiB: mib(peakHeap - before.heapUsed), retainedHeapDeltaMiB: mib(after.heapUsed - before.heapUsed),
    rssMiB: mib(after.rss), rssDeltaMiB: mib(after.rss - before.rss) }));
} else {
  const output = path.resolve(nativeRoot, "../../zig-out/performance");
  mkdirSync(output, { recursive: true });
  const decoder = path.join(output, "session-decoder.mjs");
  // Compile the real browser decoder, without importing server-only APIs into
  // the isolated V8 workers. Both paths use this identical decoder module.
  execFileSync("bun", ["build", "lib/sessions.ts", "--target=node", "--format=esm", `--outfile=${decoder}`], { cwd: nativeRoot, stdio: "ignore" });
  const { transcriptFromMessages, sessionFromResponse } = await import(pathToFileURL(decoder));
  const messages = [];
  const toolBody = Array.from({ length: 950 }, (_, index) => `diagnostic ${index}: checked source row with a reproducible synthetic value`).join("\n");
  for (let turn = 0; turn < 80; turn++) {
    messages.push({ role: "user", content: [{ type: "text", text: `Inspect sample ${turn}.` }, { type: "image", data: "aGVsbG8=".repeat(1000) }] },
      { role: "assistant", tool_calls: [{ id: `read-${turn}`, function: { name: "read_file", arguments: JSON.stringify({ path: `sample-${turn}.txt` }) } }] },
      { role: "tool", tool_call_id: `read-${turn}`, content: `Read sample ${turn} successfully.\n${toolBody}` },
      { role: "assistant", content: `Sample ${turn} has been checked.` });
  }
  const meta = { name: "example", title: "Example", model: "demo", provider: null, updatedMs: 0, size: 0 };
  const baseline = { ...meta, messages }, candidate = { ...meta, presentation: "transcript-v1", transcript: transcriptFromMessages(messages, meta.model) };
  if (JSON.stringify(sessionFromResponse(baseline)) !== JSON.stringify(sessionFromResponse(candidate))) throw Error("Transcript parity failed");
  const files = { baseline: path.join(output, "session-baseline.json"), candidate: path.join(output, "session-candidate.json") };
  writeFileSync(files.baseline, JSON.stringify(baseline)); writeFileSync(files.candidate, JSON.stringify(candidate));
  const results = [];
  for (let run = 0; run < 3; run++) for (const mode of run % 2 ? ["candidate", "baseline"] : ["baseline", "candidate"]) {
    const raw = execFileSync(process.execPath, ["--expose-gc", fileURLToPath(import.meta.url), "--worker", mode, files[mode], decoder], { encoding: "utf8" });
    const row = { run: run + 1, ...JSON.parse(raw) }; results.push(row); console.log(JSON.stringify(row));
  }
  const median = (mode, key) => results.filter(row => row.mode === mode).map(row => row[key]).sort((a, b) => a - b)[1];
  const report = { scenario: "80 saved turns containing tool output and image data; identical visible transcript, three isolated V8 process pairs.",
    measurement: "Serialized response bytes and browser-side JSON parse/transcript conversion measured in Node V8. Forced GC retains only the displayed conversation. Synthetic library evidence, not desktop process RAM or network compression.",
    summary: Object.fromEntries(["baseline", "candidate"].map(mode => [mode, Object.fromEntries(["payloadBytes", "loadParseMs", "peakHeapDeltaMiB", "retainedHeapDeltaMiB", "rssMiB"].map(key => [key, median(mode, key)]))])), results };
  writeFileSync(path.join(output, "session-memory.json"), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report.summary));
}
