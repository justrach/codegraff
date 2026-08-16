#!/usr/bin/env node
import { createInterface } from "node:readline";

let seq = 0;
let active = null;
const emit = (event) => process.stdout.write(JSON.stringify({ seq: ++seq, ...event }) + "\n");
const turn = (text) => emit({
  type: "turn", text, context_tokens: 42, cost_usd: 0.012,
  input_tokens: 10, uncached_input_tokens: 4, cache_read_tokens: 6,
  output_tokens: 3, api_calls: 2, subscription_calls: 1,
  unpriced_calls: 0, complete: true, metadata_complete: true,
});

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  switch (request.type) {
    case "user":
    case "review":
      if (request.text === "die") process.exit(7);
      active = request.text;
      emit({ type: "started", provider: "fake", model: "fake" });
      if (request.text === "slow") return;
      if (request.text === "ask") {
        emit({ type: "ask_user", call_id: "ask-1", question: "continue?", options: ["yes"] });
        return;
      }
      setTimeout(() => {
        turn(`${request.type}:${request.text}`);
        active = null;
      }, 15);
      return;
    case "answer":
      if (active !== "ask") return;
      emit({ type: "tool_result", name: "ask_user", is_error: false, text: request.text });
      turn(`answered:${request.text}`);
      active = null;
      return;
    case "cancel":
      if (active === null) return;
      emit({ type: "error", message: "turn cancelled" });
      active = null;
      return;
    case "set_model":
      if (request.model === "bad") emit({ type: "error", message: "bad model" });
      else emit({ type: "model", ok: true, provider: request.provider, model: request.model, context: 1000, note: "" });
      return;
    case "set_effort":
      emit({ type: "effort", ok: true, level: request.level, applies: true });
      return;
    case "compact":
      emit({ type: "compact", ok: true, chars: 12 });
      return;
    case "set_system_prompt":
      emit({ type: "system_prompt", ok: true, append: !!request.append, chars: request.text.length });
      return;
    case "score":
      emit({ type: "score", ok: true, prompt_sha: request.prompt_sha });
      return;
    default:
      emit({ type: "error", message: `unexpected request ${request.type}` });
  }
});
