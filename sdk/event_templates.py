"""TypeScript event declarations shared with the SDK generator."""

STDIO_EVENTS = """export type Event =
  | { seq: number; type: "text"; text: string }
  | { seq: number; type: "reasoning"; text: string }
  | { seq: number; type: "started"; provider: string; model: string }
  | { seq: number; type: "model_call_started"; provider: string; model: string }
  | { seq: number; type: "model_call_finished"; provider: string; model: string; ok: boolean; ms: number }
  | { seq: number; type: "tool_call"; name: string; input: Record<string, unknown> }
  | { seq: number; type: "tool_call_started"; name: string; input: Record<string, unknown> }
  | { seq: number; type: "tool_rejected"; name: string; reason: "budget" | "duplicate" | string; input: Record<string, unknown>; message: string }
  | { seq: number; type: "ask_user"; call_id: string; question: string; input: Record<string, unknown> }
  | { seq: number; type: "tool_result"; name: string; is_error: boolean; text: string }
  | { seq: number; type: "tool_call_finished"; name: string; is_error: boolean; ms: number }
  | { seq: number; type: "agent_usage"; id: string; ok: boolean; duration_ms: number; tool_calls: number; context_tokens: number; cache_read_tokens: number }
  | { seq: number; type: "finalizing" }
  | { seq: number; type: "session_recap"; text: string; status: "needs_input" | "completed" | "failed"; source: "heuristic" | "model" }
  | { seq: number; type: "turn"; text: string; context_tokens: number; cost_usd: number; input_tokens: number; uncached_input_tokens: number; cache_read_tokens: number; output_tokens: number; api_calls: number; usage_complete?: boolean; missing_usage_calls?: number; unreported_failed_attempts?: number; subscription_calls: number; unpriced_calls: number; complete?: boolean; metadata_complete?: boolean }
  | { seq: number; type: "system_prompt"; ok: boolean; append: boolean; chars: number }
  | { seq: number; type: "model"; ok: boolean; provider: string; model: string; context: number; note: string }
  | { seq: number; type: "compact"; ok: boolean; chars: number }
  | { seq: number; type: "effort"; ok: boolean; level: string; applies: boolean }
  | { seq: number; type: "score"; ok: boolean; prompt_sha: string }
  | { seq: number; type: "error"; message: string };"""

REMOTE_EVENTS = """export type Event =
  | { seq: number; type: "text"; text: string }
  | { seq: number; type: "reasoning"; text: string }
  | { seq: number; type: "started"; provider: string; model: string }
  | { seq: number; type: "model_call_started"; provider: string; model: string }
  | { seq: number; type: "model_call_finished"; provider: string; model: string; ok: boolean; ms: number }
  | { seq: number; type: "tool_call"; name: string; input: Record<string, unknown> }
  | { seq: number; type: "tool_call_started"; name: string; input: Record<string, unknown> }
  | { seq: number; type: "tool_rejected"; name: string; reason: "budget" | "duplicate" | string; input: Record<string, unknown>; message: string }
  | { seq: number; type: "ask_user"; call_id: string; question: string; input: Record<string, unknown> }
  | { seq: number; type: "tool_result"; name: string; is_error: boolean; text: string }
  | { seq: number; type: "tool_call_finished"; name: string; is_error: boolean; ms: number }
  | { seq: number; type: "agent_usage"; id: string; ok: boolean; duration_ms: number; tool_calls: number; context_tokens: number; cache_read_tokens: number }
  | { seq: number; type: "finalizing" }
  | { seq: number; type: "session_recap"; text: string; status: "needs_input" | "completed" | "failed"; source: "heuristic" | "model" }
  | { seq: number; type: "turn"; text: string; context_tokens: number; cost_usd: number; input_tokens: number; uncached_input_tokens: number; cache_read_tokens: number; output_tokens: number; api_calls: number; usage_complete?: boolean; missing_usage_calls?: number; unreported_failed_attempts?: number; subscription_calls: number; unpriced_calls: number; complete?: boolean; metadata_complete?: boolean }
  | { seq: number; type: "system_prompt"; ok: boolean; append: boolean; chars: number }
  | { seq: number; type: "model"; ok: boolean; provider: string; model: string; context: number; note: string }
  | { seq: number; type: "compact"; ok: boolean; chars: number }
  | { seq: number; type: "effort"; ok: boolean; level: string; applies: boolean }
  | { seq: number; type: "score"; ok: boolean; prompt_sha: string }
  | { seq: number; type: "error"; message: string };"""

