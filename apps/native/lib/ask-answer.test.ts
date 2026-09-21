import { expect, test } from "bun:test";
import { readAnswerResponse, rememberAnswer, validateAnswer } from "./ask-answer";

test("rejects a missing call_id and an empty non-cancelled answer", () => {
  expect(validateAnswer({ text: "Mint" }).ok).toBe(false);
  expect(validateAnswer({ callId: "q1", text: "   " }).ok).toBe(false);
  expect(validateAnswer({ callId: "q1", text: "", cancelled: false }).ok).toBe(false);
  expect(validateAnswer({ callId: "q1", cancelled: true }).ok).toBe(true);
  const ok = validateAnswer({ callId: "q1", text: " Mint " });
  expect(ok).toEqual({ ok: true, value: { callId: "q1", text: "Mint", cancelled: false } });
});

test("repeated delivery of the same call_id is idempotent", () => {
  const delivered = new Set<string>();
  expect(rememberAnswer(delivered, "q1")).toBe("first");
  expect(rememberAnswer(delivered, "q1")).toBe("repeat");
  expect(rememberAnswer(delivered, "q2")).toBe("first");
});

test("success requires an acknowledged call_id; transport failures stay errors", async () => {
  await expect(readAnswerResponse(new Response(JSON.stringify({ ok: true, callId: "q1" }), { status: 200 }))).resolves.toEqual({ callId: "q1" });
  await expect(readAnswerResponse(new Response(JSON.stringify({ ok: true }), { status: 200 }))).rejects.toThrow("Could not send the answer");
  await expect(readAnswerResponse(new Response(JSON.stringify({ error: "notify failed" }), { status: 503 }))).rejects.toThrow("notify failed");
});
