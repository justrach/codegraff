/-
  Transport kernel.

  Process kernel, not a Turing machine: finite `Event` / `step`, no tape.
  Vendors are not axes. The program switches on `Kind` (3 wire formats)
  and a handful of turn flags. WebSocket is legal on exactly one shape:
  a live root Responses turn that has not fallen back and is not quiet.

  The 96-cell cube is the snapshot. `Event` / `step` is the machine:
  a sub never takes WS; joining a non-responses turn does not grant it.
  PromptCache isolates the child's cache key; this kernel is the pipe
  that child is forbidden from opening. Fleet topology is not a Shape
  cell — Shape stays a cube of one observation.

  Matches `transport_gate.eligible` / `agent_ws.wsEligible`.
  Executable port: spec/ref/transport.py.
-/

namespace Graff.Transport

inductive Kind where
  | anthropic
  | openai
  | responses
deriving DecidableEq, Repr, BEq

inductive Auth where
  | xApiKey
  | bearer
deriving DecidableEq, Repr, BEq

inductive Pipe where
  | ws
  | sse
deriving DecidableEq, Repr, BEq

/-- One attempt to talk to a provider. Defaults are the common case
(OpenAI-wire, root, WS allowed, live stream) — still not WS, because
the kind is not `responses`. -/
structure Turn where
  kind    : Kind := .openai
  isSub   : Bool := false
  codexWs : Bool := true
  wsOff   : Bool := false
  hasOut  : Bool := true
  quiet   : Bool := false
deriving Repr, BEq

/-- `agent_ws.wsEligible`, written as a chain so illegal cells are obvious. -/
def eligible (t : Turn) : Bool :=
  if t.kind ≠ .responses then false
  else if t.isSub then false
  else if !t.codexWs then false
  else if t.wsOff then false
  else if !t.hasOut then false
  else if t.quiet then false
  else true

def pipe (t : Turn) : Pipe :=
  if eligible t then .ws else .sse

/-- Held-socket idle: strictly past the limit (equal keeps the socket). -/
def idleExpired (now used limit : Int) : Bool := now - used > limit

/-!  General facts: a whole family of vendor × flag worlds is empty. -/

theorem anthropic_never_ws (t : Turn) (h : t.kind = .anthropic) :
    eligible t = false := by
  unfold eligible; rw [h]; rfl

theorem openai_never_ws (t : Turn) (h : t.kind = .openai) :
    eligible t = false := by
  unfold eligible; rw [h]; rfl

theorem sub_never_ws (t : Turn) (h : t.isSub = true) :
    eligible t = false := by
  unfold eligible; cases t.kind <;> simp [h]

theorem quiet_never_ws (t : Turn) (h : t.quiet = true) :
    eligible t = false := by
  unfold eligible; cases t.kind <;> simp [h]

theorem ws_off_never_ws (t : Turn) (h : t.wsOff = true) :
    eligible t = false := by
  unfold eligible; cases t.kind <;> simp [h]

theorem flag_off_never_ws (t : Turn) (h : t.codexWs = false) :
    eligible t = false := by
  unfold eligible; cases t.kind <;> simp [h]

theorem no_out_never_ws (t : Turn) (h : t.hasOut = false) :
    eligible t = false := by
  unfold eligible; cases t.kind <;> simp [h]

def allTurns : List Turn :=
  Id.run do
    let mut acc : List Turn := []
    for kind in [Kind.anthropic, .openai, .responses] do
      for isSub in [false, true] do
        for codexWs in [false, true] do
          for wsOff in [false, true] do
            for hasOut in [false, true] do
              for quiet in [false, true] do
                acc := acc ++ [{ kind, isSub, codexWs, wsOff, hasOut, quiet }]
    return acc

def transportCells : Nat := allTurns.length
def wsCells : Nat := (allTurns.filter eligible).length

theorem transport_cube : transportCells = 96 := by native_decide
theorem one_ws_cell : wsCells = 1 := by native_decide

/-!  The one inhabited WS cell, and the default turn (openai root) is SSE. -/

example : eligible {} = false := by native_decide
example : pipe {} = .sse := by native_decide
example : eligible { kind := .responses } = true := by native_decide
example : pipe { kind := .responses } = .ws := by native_decide
example : eligible { kind := .responses, isSub := true } = false := by native_decide
example : eligible { kind := .responses, quiet := true } = false := by native_decide
example : eligible { kind := .responses, wsOff := true } = false := by native_decide
example : eligible { kind := .anthropic, codexWs := true, hasOut := true } = false := by native_decide
example : idleExpired 100 0 100 = false := by native_decide
example : idleExpired 101 0 100 = true := by native_decide

/-! The machine. Snapshot predicates above; these are the edges. -/

inductive Event where
  | setKind (k : Kind)
  | markSub
  | joinRoot
  | setCodexWs (b : Bool)
  | setWsOff (b : Bool)
  | setHasOut (b : Bool)
  | setQuiet (b : Bool)
deriving DecidableEq, Repr, BEq

def withKind (t : Turn) (k : Kind) : Turn :=
  { kind := k, isSub := t.isSub, codexWs := t.codexWs, wsOff := t.wsOff, hasOut := t.hasOut, quiet := t.quiet }

def withSub (t : Turn) (sub : Bool) : Turn :=
  { kind := t.kind, isSub := sub, codexWs := t.codexWs, wsOff := t.wsOff, hasOut := t.hasOut, quiet := t.quiet }

def withCodexWs (t : Turn) (b : Bool) : Turn :=
  { kind := t.kind, isSub := t.isSub, codexWs := b, wsOff := t.wsOff, hasOut := t.hasOut, quiet := t.quiet }

def withWsOff (t : Turn) (b : Bool) : Turn :=
  { kind := t.kind, isSub := t.isSub, codexWs := t.codexWs, wsOff := b, hasOut := t.hasOut, quiet := t.quiet }

def withHasOut (t : Turn) (b : Bool) : Turn :=
  { kind := t.kind, isSub := t.isSub, codexWs := t.codexWs, wsOff := t.wsOff, hasOut := b, quiet := t.quiet }

def withQuiet (t : Turn) (b : Bool) : Turn :=
  { kind := t.kind, isSub := t.isSub, codexWs := t.codexWs, wsOff := t.wsOff, hasOut := t.hasOut, quiet := b }

def step (t : Turn) (e : Event) : Turn :=
  match e with
  | Event.setKind k => withKind t k
  | Event.markSub => withSub t true
  | Event.joinRoot => withSub t false
  | Event.setCodexWs b => withCodexWs t b
  | Event.setWsOff b => withWsOff t b
  | Event.setHasOut b => withHasOut t b
  | Event.setQuiet b => withQuiet t b

def run (t : Turn) : List Event → Turn
  | []      => t
  | e :: es => run (step t e) es

theorem mark_sub_never_ws (t : Turn) :
    eligible (step t Event.markSub) = false := by
  cases t.kind <;> simp [step, withSub, eligible]

theorem set_anthropic_never_ws (t : Turn) :
    eligible (step t (Event.setKind Kind.anthropic)) = false := by
  simp [step, withKind, eligible]

theorem set_openai_never_ws (t : Turn) :
    eligible (step t (Event.setKind Kind.openai)) = false := by
  simp [step, withKind, eligible]

theorem not_responses_never_ws (t : Turn) (h : t.kind ≠ Kind.responses) :
    eligible t = false := by
  unfold eligible
  simp [h]

theorem join_non_responses_never_ws (t : Turn) (h : t.kind ≠ Kind.responses) :
    eligible (step t Event.joinRoot) = false :=
  not_responses_never_ws (step t Event.joinRoot) (by simpa [step, withSub] using h)

theorem quiet_step_never_ws (t : Turn) :
    eligible (step t (Event.setQuiet true)) = false := by
  cases t.kind <;> simp [step, withQuiet, eligible]

end Graff.Transport
