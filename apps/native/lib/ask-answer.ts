/** Shared `ask_user` answer rules for the native card and ACP route. */

export type AnswerParams = {
  callId?: unknown;
  text?: unknown;
  cancelled?: unknown;
};

export type ValidAnswer = {
  callId: string;
  text: string;
  cancelled: boolean;
};

export function validateAnswer(params: AnswerParams | undefined): { ok: true; value: ValidAnswer } | { ok: false; error: string } {
  const callId = typeof params?.callId === "string" ? params.callId.trim() : "";
  if (!callId) return { ok: false, error: "call_id is required" };
  const cancelled = params?.cancelled === true;
  const text = typeof params?.text === "string" ? params.text.trim() : "";
  if (!cancelled && !text) return { ok: false, error: "empty answer" };
  return { ok: true, value: { callId, text, cancelled } };
}

/** First delivery of this call wins; repeats are acknowledged, not re-notified. */
export function rememberAnswer(delivered: Set<string>, callId: string): "first" | "repeat" {
  if (delivered.has(callId)) return "repeat";
  delivered.add(callId);
  return "first";
}

export async function readAnswerResponse(response: Response): Promise<{ callId: string }> {
  const body = await response.json().catch(() => ({})) as { ok?: unknown; callId?: unknown; error?: unknown };
  if (!response.ok || body.ok !== true || typeof body.callId !== "string" || !body.callId) {
    const detail = typeof body.error === "string" && body.error ? body.error : "Could not send the answer";
    throw new Error(detail);
  }
  return { callId: body.callId };
}
