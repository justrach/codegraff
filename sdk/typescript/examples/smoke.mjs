// Manual smoke test for @codegraff/sdk.
//
// Requires:
//   - `npm run build` has been run in this directory.
//   - A working .forge.toml in the cwd or globally configured codegraff
//     credentials (since chat hits a real provider).
//
// Run:
//   node examples/smoke.mjs "hello, who are you?"
//
// On success this prints a stream of decoded AgentEvent objects ending in a
// `TaskComplete`. Use it to sanity-check the binding against your local setup.

import { runAgent, version } from "../lib.js";

const prompt = process.argv.slice(2).join(" ") || "reply with the single word OK";

console.log(`@codegraff/sdk version: ${version()}`);
console.log(`prompt: ${prompt}`);
console.log("---");

try {
  for await (const ev of runAgent({ prompt })) {
    if (ev.type === "TaskMessage" && ev.content.kind === "Markdown") {
      process.stdout.write(ev.content.text);
    } else if (ev.type === "TaskComplete") {
      process.stdout.write("\n--- TaskComplete ---\n");
    } else {
      console.log(JSON.stringify(ev));
    }
  }
} catch (e) {
  console.error("agent error:", e);
  process.exit(1);
}
