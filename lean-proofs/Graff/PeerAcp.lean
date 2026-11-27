/-!
Peer and ACP lifecycle contracts.

The Zig and NanoHarness tests exercise concrete delivery. This model captures
the delivery decisions in `peer_scope.zig`, `peer_idle.zig`, and the
ACP stream's distinction between a tool starting and finishing. File I/O,
string classification, and wire serialization are outside the model.
-/

namespace Graff.PeerAcp

/-- The decision after a request has been classified as session inspection. -/
def admitsPeerWrite (explicitReadOnly inferredAuthorization fyi : Bool) : Bool :=
  !explicitReadOnly && (inferredAuthorization || fyi)

theorem explicit_read_only_blocks_every_peer_write (authorization fyi : Bool) :
    admitsPeerWrite true authorization fyi = false := rfl

inductive TurnState where
  | active | idle | settled | yielded
deriving DecidableEq

inductive Mail where
  | fyi | room | addressed
deriving DecidableEq

/-- Normal mail only. Explicit supervisor control uses a separate rule. -/
def mayWake (turn : TurnState) (mail : Mail) (alreadyExposed : Bool) : Bool :=
  !alreadyExposed && (match turn, mail with
    | .idle, .room | .idle, .addressed | .settled, .addressed => true
    | _, _ => false)

theorem fyi_never_starts_turn (turn : TurnState) (seen : Bool) :
    mayWake turn .fyi seen = false := by
  cases turn <;> cases seen <;> rfl

theorem active_turn_preserves_human_authority (mail : Mail) (seen : Bool) :
    mayWake .active mail seen = false := by
  cases mail <;> cases seen <;> rfl

theorem settled_task_wakes_for_addressed_mail_only (mail : Mail) (seen : Bool) :
    mayWake .settled mail seen = true ↔ mail = .addressed ∧ seen = false := by
  cases mail <;> cases seen <;> decide

theorem yielded_task_waits_for_human (mail : Mail) (seen : Bool) :
    mayWake .yielded mail seen = false := by
  cases mail <;> cases seen <;> rfl

inductive StreamEvent where
  | text | toolStart | terminal | other
deriving DecidableEq

def streamedAnswer (seen : Bool) (event : StreamEvent) : Bool :=
  match event with
  | .text => true
  | .toolStart => false
  | .terminal | .other => seen

/-- Terminal updates and unrelated notices cannot undo streamed answer
delivery regardless of the length or ordering of the remaining updates. -/
theorem terminal_tail_preserves_answer (tail : List StreamEvent) (seen : Bool)
    (noAnswerBoundary : ∀ event ∈ tail, event = .terminal ∨ event = .other) :
    tail.foldl streamedAnswer seen = seen := by
  induction tail with
  | nil => rfl
  | cons event tail ih =>
    have rest : ∀ next ∈ tail, next = .terminal ∨ next = .other := by
      intro next hn
      exact noAnswerBoundary next (List.mem_cons_of_mem _ hn)
    rcases noAnswerBoundary event (by simp) with h | h
    · subst event
      exact ih rest
    · subst event
      exact ih rest

theorem handoff_streams_once (tail : List StreamEvent)
    (statuses : ∀ event ∈ tail, event = .terminal ∨ event = .other) :
    (StreamEvent.toolStart :: .text :: tail).foldl streamedAnswer false = true :=
  terminal_tail_preserves_answer tail true statuses

theorem preamble_does_not_suppress_answer (tail : List StreamEvent)
    (statuses : ∀ event ∈ tail, event = .terminal ∨ event = .other) :
    (StreamEvent.text :: .toolStart :: tail).foldl streamedAnswer false = false :=
  terminal_tail_preserves_answer tail false statuses

/-- The finish for one visible call ID emits status only if the engine's
earlier result or finish did not already close the row. The ID remains in
`acp_tool_terminal.Resolved` for the modeled finish sequence. -/
def closeCall (closed : Bool) : Bool × Nat :=
  if closed then (true, 0) else (true, 1)

def countTerminalUpdates (closed : Bool) : List StreamEvent → Nat
  | [] => 0
  | .terminal :: tail =>
    let (nextClosed, emitted) := closeCall closed
    emitted + countTerminalUpdates nextClosed tail
  | _ :: tail => countTerminalUpdates closed tail

theorem closed_call_never_emits_again (events : List StreamEvent) :
    countTerminalUpdates true events = 0 := by
  induction events with
  | nil => rfl
  | cons event _ ih => cases event <;> simp [countTerminalUpdates, closeCall, ih]

theorem first_terminal_update_closes_call (events : List StreamEvent) :
    countTerminalUpdates false (.terminal :: events) = 1 := by
  simp [countTerminalUpdates, closeCall, closed_call_never_emits_again]

end Graff.PeerAcp
