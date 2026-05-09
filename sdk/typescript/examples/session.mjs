// Multi-turn session example.
//
// Run:
//   node examples/session.mjs
//
// Demonstrates that a single GraffSession reuses one conversationId across
// `.send()` calls so the agent retains memory of the prior turn.

import { GraffSession } from "../lib.js";

const session = new GraffSession();

async function turn(prompt) {
  console.log(`\n>>> ${prompt}`);
  for await (const ev of session.send(prompt)) {
    if (ev.type === "TaskMessage" && ev.content.kind === "Markdown") {
      process.stdout.write(ev.content.text);
    } else if (ev.type === "TaskComplete") {
      process.stdout.write("\n");
    }
  }
  console.log(`(conversationId = ${session.conversationId})`);
}

await turn("my name is rach. remember it.");
await turn("what name did i tell you?");
await session.close();
