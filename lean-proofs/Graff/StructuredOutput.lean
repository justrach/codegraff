/-
  Structured-output carrier ladder (#543 / #550): which server-visible
  carrier a set --output-schema rides, per wire format, learned degrade
  state (sox), and whether real tools occupy the request.

  openai chat: json_schema until the provider rejects it (sox learned via
  the request() quirk ladder); degraded, the tools-off formatting turn
  carries the schema as a structured_output TOOL (dsh's pattern, forced by
  instruction, never tool_choice — thinking modes reject forcing), while a
  turn with real tools falls back to json_object.

  anthropic: provider id `anthropic` tries native output_config.format
  json_schema on the tools-off formatting turn (#550, kimi-code prior art).
  A learned sox flag (output_config rejected) falls back to the
  structured_output tool. minimax / kimi-anthropic stay on the tool
  (modelled here as sox). Real tools never carry a grammar (ADR 0001).

  responses: native text.format.

  The invariant of record is never_silent on the formatting turn: before
  9e2da0a the anthropic wire dropped a set schema with no error. An
  anthropic tools turn may be silent — the two-phase split holds the
  schema for the formatting call.

  Executable port: spec/ref/structured_output.py. Impl:
  src/agent_request_body.zig + agent_request_body_responses.zig
  (schemaAwarePrompt / writeAnthropicSchema / writeAnthropicOutputConfig).
-/

namespace Graff.StructuredOutput

inductive Wire
  | anthropic | openai | responses
deriving DecidableEq, Repr

inductive Carrier
  | none | jsonSchema | jsonObject | toolOpenai | toolAnthropic | textFormat | outputConfig
deriving DecidableEq, Repr

/-- The server-visible carrier of the schema for one request.
    Args: wire, schema present, sox (native schema was rejected), real tools present. -/
def carrier : Wire → Bool → Bool → Bool → Carrier
  | _, false, _, _ => .none
  | .responses, true, _, _ => .textFormat
  | .openai, true, false, _ => .jsonSchema
  | .openai, true, true, true => .jsonObject
  | .openai, true, true, false => .toolOpenai
  | .anthropic, true, _, true => .none
  | .anthropic, true, false, false => .outputConfig
  | .anthropic, true, true, false => .toolAnthropic

/-- Whether the system prompt embeds the schema JSON (schemaAwarePrompt's
    cannot-enforce / tool-mode branch). Native Anthropic uses the light
    prompt; sox (fallback) embeds. Tools presence never changes the prompt. -/
def promptSchema : Wire → Bool → Bool → Bool
  | _, false, _ => false
  | .anthropic, true, sox => sox
  | .openai, true, sox => sox
  | .responses, true, _ => false

/-- A set schema is never silent on the formatting turn. An anthropic
    tools turn may be — ADR 0001 forbids a grammar there; the two-phase
    split holds the schema for the next call. -/
theorem never_silent (w : Wire) (sox tools : Bool) :
    carrier w true sox tools ≠ .none ∨ promptSchema w true sox = true ∨
      (w = .anthropic ∧ tools = true) := by
  cases w <;> cases sox <;> cases tools <;> decide

/-- The learned degrade does not touch the Responses wire. -/
theorem sox_leaves_responses_alone (tools : Bool) :
    carrier .responses true true tools = carrier .responses true false tools := by
  cases tools <;> decide

/-- #550: native Anthropic formatting uses output_config; sox falls back to the tool. -/
theorem sox_degrades_anthropic_native :
    carrier .anthropic true false false = .outputConfig ∧
      carrier .anthropic true true false = .toolAnthropic := by
  decide

/-- ADR 0001: no schema grammar on an anthropic tools turn. -/
theorem no_grammar_on_anthropic_tools (sox : Bool) :
    carrier .anthropic true sox true = .none := by
  cases sox <;> decide

/-- Once a provider rejected json_schema / output_config, it is never sent again. -/
theorem no_json_schema_after_rejection (w : Wire) (tools : Bool) :
    carrier w true true tools ≠ .jsonSchema ∧
      carrier w true true tools ≠ .outputConfig := by
  cases w <;> cases tools <;> decide

/-- No schema, no artifacts: the axis is byte-silent when unused. -/
theorem absent_schema_is_silent (w : Wire) (sox tools : Bool) :
    carrier w false sox tools = .none ∧ promptSchema w false sox = false := by
  cases w <;> cases sox <;> cases tools <;> decide

/-- Tool-mode fallback still embeds the schema so a rejected output_config
    cannot go silent. -/
theorem anthropic_fallback_teaches :
    promptSchema .anthropic true true = true := by
  decide

/-- Native Anthropic uses the light prompt (server enforces on the formatting turn). -/
theorem anthropic_native_prompt_is_light :
    promptSchema .anthropic true false = false := by
  decide

end Graff.StructuredOutput
