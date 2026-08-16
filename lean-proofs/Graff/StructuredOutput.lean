/-
  Structured-output carrier ladder (#543): which server-visible carrier a
  set --output-schema rides, per wire format, learned degrade state (sox),
  and whether real tools occupy the request.

  openai chat: json_schema until the provider rejects it (sox learned via
  the request() quirk ladder); degraded, the tools-off formatting turn
  carries the schema as a structured_output TOOL (dsh's pattern, forced by
  instruction, never tool_choice — thinking modes reject forcing), while a
  turn with real tools falls back to json_object. anthropic: no
  response_format exists at all — the tool is the only server carrier and
  the prompt always embeds the schema. responses: native text.format.

  The invariant of record is never_silent: before 9e2da0a the anthropic
  wire dropped a set schema with no error — the exact bug class this
  kernel now makes unrepresentable.

  Executable port: spec/ref/structured_output.py. Impl:
  src/agent_request_body.zig + agent_request_body_responses.zig
  (schemaAwarePrompt / writeStructuredOutputTool / writeAnthropicStructuredTool).
-/

namespace Graff.StructuredOutput

inductive Wire
  | anthropic | openai | responses
deriving DecidableEq, Repr

inductive Carrier
  | none | jsonSchema | jsonObject | toolOpenai | toolAnthropic | textFormat
deriving DecidableEq, Repr

/-- The server-visible carrier of the schema for one request.
    Args: wire, schema present, sox (json_schema was rejected), real tools present. -/
def carrier : Wire → Bool → Bool → Bool → Carrier
  | _, false, _, _ => .none
  | .responses, true, _, _ => .textFormat
  | .openai, true, false, _ => .jsonSchema
  | .openai, true, true, true => .jsonObject
  | .openai, true, true, false => .toolOpenai
  | .anthropic, true, _, true => .none
  | .anthropic, true, _, false => .toolAnthropic

/-- Whether the system prompt embeds the schema text (schemaAwarePrompt's
    embedded-schema branch). Tools presence never changes the prompt. -/
def promptSchema : Wire → Bool → Bool → Bool
  | _, false, _ => false
  | .anthropic, true, _ => true
  | .openai, true, sox => sox
  | .responses, true, _ => false

/-- #543's invariant of record: a set schema is NEVER silent — some
    server-visible carrier exists, or the prompt itself embeds the schema. -/
theorem never_silent (w : Wire) (sox tools : Bool) :
    carrier w true sox tools ≠ .none ∨ promptSchema w true sox = true := by
  cases w <;> cases sox <;> cases tools <;> decide

/-- The learned degrade is a chat-wire quirk: sox changes nothing elsewhere. -/
theorem sox_only_on_chat (w : Wire) (tools : Bool) (h : w ≠ .openai) :
    carrier w true true tools = carrier w true false tools := by
  cases w <;> cases tools <;> first | decide | exact absurd rfl h

/-- Once a provider rejected json_schema, it is never sent again. -/
theorem no_json_schema_after_rejection (w : Wire) (tools : Bool) :
    carrier w true true tools ≠ .jsonSchema := by
  cases w <;> cases tools <;> decide

/-- No schema, no artifacts: the axis is byte-silent when unused. -/
theorem absent_schema_is_silent (w : Wire) (sox tools : Bool) :
    carrier w false sox tools = .none ∧ promptSchema w false sox = false := by
  cases w <;> cases sox <;> cases tools <;> decide

/-- The anthropic wire embeds the schema in the prompt unconditionally —
    even when real tools displace the structured_output tool, nothing is lost. -/
theorem anthropic_always_teaches (sox : Bool) :
    promptSchema .anthropic true sox = true := by
  cases sox <;> decide

end Graff.StructuredOutput
