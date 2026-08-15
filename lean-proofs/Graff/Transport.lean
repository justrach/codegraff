/-
  Transport kernel.

  Vendors are not axes. The program switches on `Kind` (3 wire formats)
  and a handful of turn flags. WebSocket is legal on exactly one shape:
  a live root Responses turn that has not fallen back and is not quiet.

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

end Graff.Transport
