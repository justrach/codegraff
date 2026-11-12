/-
  ACP early `initialize` kernel.

  `graff acp` answers the client's `initialize` during boot, at a phase
  boundary, instead of after the root Agent exists. This file models the
  decision and the line bookkeeping around it.

  What it proves:
  (a) `step` over `State` × `Event` (the function `src/acp_early.zig`
      calls): only a booting ACP process with a complete `initialize` first
      line attempts an early answer; the line is taken off stdin only after
      the whole answer was sent; only a taken line is replayed at loop start.
  (b) `Sys` wraps `step` with an abstract stdin queue, stdout and dispatch
      log. Over every boot trace, including traces where the early answer
      fails, the first `initialize` is answered exactly once, the replay
      writes nothing, a non-`initialize` first line is untouched, a failed
      answer consumes nothing, and stdout and the dispatch history equal the
      late path's. This is line bookkeeping: nothing is dropped, duplicated
      or reordered.

  What it assumes (stated, not proved):
  - The response is a function of the request alone (`answerOf`). That the
    engine's answer does not depend on boot state is not shown here.
  - The live dispatch's state is determined by the lines it has handled:
    equal `disp` histories are taken to mean equal dispatch state.
  - A failed early answer leaves nothing on stdout. The Zig code drops what
    it still buffers; bytes the OS accepted before a write error are not
    modelled (the transport is then broken for the late path too).

  What it is NOT:
  - Anything about bytes: framing, CRLF, a BOM, a line longer than the stdin
    buffer, JSON parsing, or how a line is classified.
  - The non-blocking poll, the reader, or the discarding sink.
  - A timing claim (when a boundary runs, or how fast).
  - The cube (c) mirrors the engine's latch table; `early_eq_late` holds by
    the model's construction (last writer wins). That `can_load` matches the
    live dispatch is pinned by a Zig test of `live_can_load`, not here.
  - A refinement proof. The Zig side is checked at fixture level: the
    conformance test (`src/spec_acp_early_init_conformance.zig`) drives the
    real `step` on every table cell and runs the real engine early and late
    on every cube cell. The byte-equality claim rests on that test and on
    `scripts/test-acp-early-init.py`, not on this file.
  Executable port: spec/ref/acp_early_init.py.
-/

namespace Graff.AcpEarlyInit

/-! ## (a) The decision -/

/-- `answering`: the early answer is being written; the line is still on stdin. -/
inductive State where
  | booting | answering | answered | passed | loop
deriving DecidableEq, Repr, BEq

/-- What the shared stdin buffer holds at a check. -/
inductive Line where
  | none | incomplete | initialize | other
deriving DecidableEq, Repr, BEq

/-- `acp` is ACP mode with a clean protocol stdout. `sent ok`: whether the
whole early answer reached the transport. -/
inductive Event where
  | boundary (acp : Bool) (line : Line)
  | sent (ok : Bool)
  | loopStart
deriving DecidableEq, Repr, BEq

/-- `answer`: write the answer, consume nothing. `take`: consume and keep the
line. `replay`: hand the kept line to the loop. -/
inductive Action where
  | none | answer | take | replay
deriving DecidableEq, Repr, BEq

def step : State → Event → State × Action
  | .booting, .boundary false _ => (.passed, .none)
  | .booting, .boundary true .none => (.booting, .none)
  | .booting, .boundary true .incomplete => (.booting, .none)
  | .booting, .boundary true .initialize => (.answering, .answer)
  | .booting, .boundary true .other => (.passed, .none)
  | .answering, .boundary _ _ => (.answering, .none)
  | .answered, .boundary _ _ => (.answered, .none)
  | .passed, .boundary _ _ => (.passed, .none)
  | .loop, .boundary _ _ => (.loop, .none)
  | .answering, .sent true => (.answered, .take)
  | .answering, .sent false => (.passed, .none)
  | .booting, .sent _ => (.booting, .none)
  | .answered, .sent _ => (.answered, .none)
  | .passed, .sent _ => (.passed, .none)
  | .loop, .sent _ => (.loop, .none)
  | .answered, .loopStart => (.loop, .replay)
  | .booting, .loopStart => (.loop, .none)
  | .answering, .loopStart => (.loop, .none)
  | .passed, .loopStart => (.loop, .none)
  | .loop, .loopStart => (.loop, .none)

def allStates : List State := [.booting, .answering, .answered, .passed, .loop]
def allLines : List Line := [.none, .incomplete, .initialize, .other]
def allEvents : List Event :=
  ([false, true].flatMap fun acp => allLines.map fun l => Event.boundary acp l) ++
    [.sent false, .sent true, .loopStart]

/- Sanity check, not a result: the table the fixture exports has 55 cells. -/
example : allStates.length * allEvents.length = 55 := by native_decide

/-- Only a booting process in ACP mode with a complete `initialize` attempts an answer. -/
theorem step_answer_iff :
    allStates.all (fun s => allEvents.all fun e =>
      ((step s e).2 == .answer) == (s == .booting && e == .boundary true .initialize)) = true := by
  native_decide

/-- The line is taken only once the whole answer was sent. -/
theorem step_take_iff :
    allStates.all (fun s => allEvents.all fun e =>
      ((step s e).2 == .take) == (s == .answering && e == .sent true)) = true := by
  native_decide

/-- An answer that failed gives up for good: the loop answers the line. -/
theorem step_failed_passes :
    allStates.all (fun s => allEvents.all fun e =>
      !(s == .answering && e == .sent false) || step s e == (.passed, .none)) = true := by
  native_decide

/-- Only loop start replays, and only after a taken answer. -/
theorem step_replay_iff :
    allStates.all (fun s => allEvents.all fun e =>
      ((step s e).2 == .replay) == (s == .answered && e == .loopStart)) = true := by
  native_decide

/-- Loop start always reaches the loop, and the loop is absorbing. -/
theorem loop_start_reaches_loop (s : State) : (step s .loopStart).1 = .loop := by
  cases s <;> rfl

theorem loop_absorbing (e : Event) : step .loop e = (.loop, .none) := by
  cases e with
  | boundary acp l => cases acp <;> cases l <;> rfl
  | sent ok => cases ok <;> rfl
  | loopStart => rfl

/-- Once answered, no boundary answers again. -/
theorem answered_stays (acp : Bool) (l : Line) :
    step .answered (.boundary acp l) = (.answered, .none) := by
  cases acp <;> cases l <;> rfl

/-! ## (a) The protocol around it -/

/-- A stdin line, tagged with its position. -/
inductive Msg where
  | init (i : Nat)
  | other (i : Nat)
deriving DecidableEq, Repr, BEq

/-- A stdout line answering the request at position `i`. -/
inductive Out where
  | resp (i : Nat)
deriving DecidableEq, Repr, BEq

def answerOf : Msg → Out
  | .init i => .resp i
  | .other i => .resp i

structure Sys where
  st : State
  /-- The first line is complete in the buffer. -/
  avail : Bool
  /-- Unconsumed stdin (the one reader boot and loop share). -/
  input : List Msg
  /-- The consumed `initialize`, kept for the replay. -/
  stash : Option Msg
  /-- Protocol stdout. -/
  out : List Out
  /-- Lines the live dispatch has handled, in order; its state is a fold of these. -/
  disp : List Msg
deriving DecidableEq, Repr

def start (input : List Msg) : Sys := ⟨.booting, false, input, none, [], []⟩

def classify (s : Sys) : Line :=
  if s.avail then
    match s.input with
    | [] => .none
    | .init _ :: _ => .initialize
    | .other _ :: _ => .other
  else .incomplete

inductive BootEv where
  /-- The client's first line becomes complete. -/
  | arrive
  /-- A boot phase boundary checks. If it attempts an answer, the whole
  answer reaches the client iff `ok` (the environment decides). -/
  | boundary (ok : Bool)
deriving DecidableEq, Repr, BEq

/-- An answer attempt: the answer reaches stdout iff `ok`; the line is taken
iff `step` says so. A failed attempt writes nothing (assumption above). -/
def attempt (s : Sys) (st : State) (ok : Bool) : Sys :=
  match step st (.sent ok), s.input with
  | (st', .take), m :: rest =>
    { s with st := st', input := rest, stash := some m,
             out := s.out ++ (if ok then [answerOf m] else []) }
  | (st', _), _ => { s with st := st' }

def bootStep (acp : Bool) (s : Sys) : BootEv → Sys
  | .arrive => { s with avail := true }
  | .boundary ok =>
    match step s.st (.boundary acp (classify s)) with
    | (st, .answer) => attempt s st ok
    | (st, _) => { s with st := st }

def boot (acp : Bool) (s : Sys) : List BootEv → Sys
  | [] => s
  | e :: es => boot acp (bootStep acp s e) es

def loopStart (s : Sys) : Sys :=
  match step s.st .loopStart, s.stash with
  | (st, .replay), some m => { s with st := st, stash := none, disp := s.disp ++ [m] }
  | (st, _), _ => { s with st := st }

def drainFrom (s : Sys) : List Msg → Sys
  | [] => s
  | m :: ms => drainFrom { s with disp := s.disp ++ [m], out := s.out ++ [answerOf m] } ms

def drain (s : Sys) : Sys := drainFrom { s with input := [] } s.input

def runEarly (acp : Bool) (input : List Msg) (tr : List BootEv) : Sys :=
  drain (loopStart (boot acp (start input) tr))

/-- Today's order: no boundary ever looks. -/
def runLate (input : List Msg) : Sys := drain (loopStart (start input))

/-- What boot can have done to the start state. -/
def Inv (input : List Msg) (s : Sys) : Prop :=
  s.disp = [] ∧
  ((s.st = .booting ∨ s.st = .passed) ∧ s.stash = none ∧ s.input = input ∧ s.out = [] ∨
   ∃ i rest, input = .init i :: rest ∧ s.st = .answered ∧ s.stash = some (.init i) ∧
     s.input = rest ∧ s.out = [.resp i])

theorem inv_start (input : List Msg) : Inv input (start input) :=
  ⟨rfl, Or.inl ⟨Or.inl rfl, rfl, rfl, rfl⟩⟩

theorem inv_bootStep (acp : Bool) (input : List Msg) (s : Sys) (e : BootEv)
    (h : Inv input s) : Inv input (bootStep acp s e) := by
  obtain ⟨st, avail, inp, stash, out, disp⟩ := s
  obtain ⟨hd, h⟩ := h
  simp only at hd h
  subst hd
  cases e with
  | arrive =>
    exact ⟨rfl, h⟩
  | boundary ok =>
    rcases h with ⟨hst | hst, hs, hi, ho⟩ | ⟨i, rest, hin, hst, hs, hi, ho⟩
    · subst hst hs hi ho
      cases acp <;> cases avail <;> cases ok <;> rcases inp with _ | ⟨_ | _, _⟩ <;>
        simp [bootStep, attempt, classify, step, Inv, answerOf] <;>
        exact ⟨_, _, ⟨rfl, rfl⟩, rfl, rfl, rfl⟩
    · subst hst hs hi ho
      cases acp <;> simp [bootStep, step, Inv]
    · subst hst hs hi ho hin
      cases acp <;> simp [bootStep, step, Inv] <;> exact ⟨_, _, ⟨rfl, rfl⟩, rfl, rfl, rfl⟩

theorem inv_boot (acp : Bool) (input : List Msg) (tr : List BootEv) :
    ∀ s, Inv input s → Inv input (boot acp s tr) := by
  induction tr with
  | nil => intro s h; exact h
  | cons e es ih => intro s h; exact ih _ (inv_bootStep acp input s e h)

theorem drainFrom_out (s : Sys) (ms : List Msg) :
    (drainFrom s ms).out = s.out ++ ms.map answerOf := by
  induction ms generalizing s with
  | nil => simp [drainFrom]
  | cons m ms ih => simp [drainFrom, ih, List.append_assoc]

theorem drainFrom_disp (s : Sys) (ms : List Msg) :
    (drainFrom s ms).disp = s.disp ++ ms := by
  induction ms generalizing s with
  | nil => simp [drainFrom]
  | cons m ms ih => simp [drainFrom, ih, List.append_assoc]

theorem drain_out (s : Sys) : (drain s).out = s.out ++ s.input.map answerOf := drainFrom_out _ _
theorem drain_disp (s : Sys) : (drain s).disp = s.disp ++ s.input := drainFrom_disp _ _

/-- The late path answers every line once, in order, and dispatches every line. -/
theorem late_out (input : List Msg) : (runLate input).out = input.map answerOf := by
  simp [runLate, drain_out, loopStart, start, step]

theorem late_disp (input : List Msg) : (runLate input).disp = input := by
  simp [runLate, drain_disp, loopStart, start, step]

/-- The loop-start replay writes nothing on stdout. -/
theorem replay_silent (s : Sys) : (loopStart s).out = s.out := by
  unfold loopStart
  split <;> rfl

/-- Early and late write the same stdout, line for line. -/
theorem early_out_eq_late (acp : Bool) (input : List Msg) (tr : List BootEv) :
    (runEarly acp input tr).out = (runLate input).out := by
  have h := inv_boot acp input tr (start input) (inv_start input)
  rw [late_out]
  unfold runEarly
  generalize boot acp (start input) tr = s at h
  obtain ⟨st, avail, inp, stash, out, disp⟩ := s
  obtain ⟨hd, h⟩ := h
  simp only at hd h
  rcases h with ⟨hst | hst, hs, hi, ho⟩ | ⟨i, rest, hin, hst, hs, hi, ho⟩ <;>
    subst hd <;> (try subst hst) <;> (try subst hs) <;> (try subst hi) <;> (try subst ho) <;>
    (try subst hin) <;> simp [drain_out, loopStart, step, answerOf]

/-- Early and late leave the live dispatch with the same history (equal state
under the assumption in the header). -/
theorem early_disp_eq_late (acp : Bool) (input : List Msg) (tr : List BootEv) :
    (runEarly acp input tr).disp = (runLate input).disp := by
  have h := inv_boot acp input tr (start input) (inv_start input)
  rw [late_disp]
  unfold runEarly
  generalize boot acp (start input) tr = s at h
  obtain ⟨st, avail, inp, stash, out, disp⟩ := s
  obtain ⟨hd, h⟩ := h
  simp only at hd h
  rcases h with ⟨hst | hst, hs, hi, ho⟩ | ⟨i, rest, hin, hst, hs, hi, ho⟩ <;>
    subst hd <;> (try subst hst) <;> (try subst hs) <;> (try subst hi) <;> (try subst ho) <;>
    (try subst hin) <;> simp [drain_disp, loopStart, step]

/-- A first `initialize` is answered exactly once on every boot trace, whether
or not an early answer failed along the way. -/
theorem initialize_answered_once (acp : Bool) (i : Nat) (rest : List Msg) (tr : List BootEv)
    (fresh : ∀ m ∈ rest, answerOf m ≠ .resp i) :
    (runEarly acp (.init i :: rest) tr).out.filter (fun o => decide (o = .resp i)) = [.resp i] := by
  rw [early_out_eq_late, late_out]
  simp only [List.map_cons, answerOf, List.filter_cons, decide_true, if_true, List.cons.injEq, true_and]
  rw [List.filter_eq_nil_iff]
  intro o ho
  simp only [List.mem_map] at ho
  obtain ⟨m, hm, rfl⟩ := ho
  simpa using fresh m hm

/-- Boot writes at most the one answer, and never touches the live dispatch. -/
theorem boot_writes_at_most_one (acp : Bool) (input : List Msg) (tr : List BootEv) :
    (boot acp (start input) tr).out.length ≤ 1 ∧ (boot acp (start input) tr).disp = [] := by
  obtain ⟨hd, h⟩ := inv_boot acp input tr (start input) (inv_start input)
  refine ⟨?_, hd⟩
  rcases h with ⟨_, _, _, ho⟩ | ⟨i, rest, _, _, _, _, ho⟩ <;> simp [ho]

/-- A first line that is not `initialize` reaches the loop unchanged. -/
theorem other_first_untouched (acp : Bool) (k : Nat) (rest : List Msg) (tr : List BootEv) :
    (boot acp (start (.other k :: rest)) tr).input = .other k :: rest ∧
    (boot acp (start (.other k :: rest)) tr).stash = none ∧
    (boot acp (start (.other k :: rest)) tr).out = [] := by
  obtain ⟨_, h⟩ := inv_boot acp _ tr (start _) (inv_start (.other k :: rest))
  rcases h with ⟨_, hs, hi, ho⟩ | ⟨i, r, hin, _⟩
  · exact ⟨hi, hs, ho⟩
  · cases hin

/-- A check that sees no complete first line consumes nothing. -/
theorem partial_not_consumed (acp ok : Bool) (s : Sys) (h : s.avail = false) :
    (bootStep acp s (.boundary ok)).input = s.input ∧ (bootStep acp s (.boundary ok)).out = s.out := by
  obtain ⟨st, avail, inp, stash, out, disp⟩ := s
  simp only at h
  subst h
  cases st <;> cases acp <;> simp [bootStep, classify, step]

/-- A check whose answer fails takes nothing off stdin, keeps nothing and
writes nothing, from any state. -/
theorem failed_answer_not_consumed (acp : Bool) (s : Sys) :
    (bootStep acp s (.boundary false)).input = s.input ∧
    (bootStep acp s (.boundary false)).stash = s.stash ∧
    (bootStep acp s (.boundary false)).out = s.out := by
  obtain ⟨st, avail, inp, stash, out, disp⟩ := s
  cases st <;> cases acp <;> cases avail <;> rcases inp with _ | ⟨_ | _, _⟩ <;>
    simp [bootStep, attempt, classify, step]

/-! ## (b) The response cube -/

inductive Pv where
  | missing | v0 | v1 | v2 | v9
deriving DecidableEq, Repr, BEq

def Pv.requested : Pv → Nat
  | .missing => 1 | .v0 => 0 | .v1 => 1 | .v2 => 2 | .v9 => 9

/-- `clientCapabilities.subagents`: absent, an object, or JSON null. -/
inductive Sub where
  | absent | object | null
deriving DecidableEq, Repr, BEq

/-- `clientCapabilities._meta["graff/backgroundSubagents"]`. -/
inductive Bg where
  | absent | yes | no
deriving DecidableEq, Repr, BEq

structure Cell where
  pv : Pv
  gate : Bool
  sub : Sub
  bg : Bg
  canLoad : Bool
  /-- T3 clientInfo + elicitation form + session compaction + v2 terminal auth. -/
  extras : Bool
deriving DecidableEq, Repr, BEq

def allCells : List Cell := Id.run do
  let mut acc : List Cell := []
  for pv in [Pv.missing, .v0, .v1, .v2, .v9] do
    for gate in [false, true] do
      for sub in [Sub.absent, .object, .null] do
        for bg in [Bg.absent, .yes, .no] do
          for canLoad in [false, true] do
            for extras in [false, true] do
              acc := acc ++ [{ pv, gate, sub, bg, canLoad, extras }]
  return acc

/- Sanity check, not a result: the cube has 360 cells. -/
example : allCells.length = 360 := by native_decide

/-- `acp_v2.negotiated`: v2 only behind the gate and on request (ADR 0206). -/
def isV2 (c : Cell) : Bool := c.gate && decide (c.pv.requested ≥ 2)

structure Resp where
  protocolVersion : Nat
  v2Shape : Bool
  canLoad : Bool
  authTerminal : Bool
deriving DecidableEq, Repr, BEq

/-- `respondInitialize`: reads the cell and the dispatch's `can_load`, nothing else. -/
def resp (c : Cell) (canLoad : Bool) : Resp :=
  { protocolVersion := if isV2 c then 2 else 1, v2Shape := isV2 c, canLoad,
    authTerminal := !isV2 c || c.extras }

/-- Process latches plus the dispatch fields `initialize` writes. -/
structure Latch where
  v2 : Bool
  seed : Nat
  t3 : Bool
  elicit : Bool
  compaction : Bool
  subagents : Bool
  bg : Bool
deriving DecidableEq, Repr, BEq

def bootLatch : Latch := ⟨false, 0, false, false, false, false, false⟩

/-- Handling `initialize` with dispatch seed `seed`. The v2 message-id seed
is written only on a v2 connection; every other latch is overwritten. -/
def latch (l : Latch) (c : Cell) (seed : Nat) : Latch :=
  { v2 := isV2 c, seed := if isV2 c then seed else l.seed, t3 := c.extras, elicit := c.extras,
    compaction := c.extras || isV2 c, subagents := !isV2 c && c.sub == .object, bg := c.bg == .yes }

/-- Late: the live dispatch (seed `s`) handles the line and writes the response. -/
def late (l : Latch) (c : Cell) (s : Nat) : Latch × Resp := (latch l c s, resp c c.canLoad)

/-- Early: a scratch dispatch (seed 0) writes the response; the replay on the
live dispatch writes the latches again and its response is discarded. The
response is `resp c c.canLoad` by construction: that the engine's bytes
agree is the Zig conformance test's job, not this model's. -/
def early (l : Latch) (c : Cell) (s : Nat) : Latch × Resp :=
  (latch (latch l c 0) c s, resp c c.canLoad)

/-- The model's latch table is last-writer-wins: a second `initialize` handling
overwrites everything the first one wrote. -/
theorem latch_last_writer_wins (l : Latch) (c : Cell) (s₀ s : Nat) :
    latch (latch l c s₀) c s = latch l c s := by
  unfold latch
  cases isV2 c <;> simp

/-- Early + replay equals late in the model. Immediate from
`latch_last_writer_wins`; it records the design, the Zig test checks it. -/
theorem early_eq_late (l : Latch) (c : Cell) (s : Nat) : early l c s = late l c s := by
  simp [early, late, latch_last_writer_wins]

/- Sanity check, not a result: `early_eq_late` on every cube cell and seed. -/
example :
    allCells.all (fun c => [0, 1, 0x5eed].all fun s => early bootLatch c s == late bootLatch c s) = true := by
  native_decide

/- Sanity check: the draft child-session stream is a v1 shape, so v2 never
latches it (true by the definition of `latch`). -/
example :
    allCells.all (fun c => !(isV2 c && (late bootLatch c 7).1.subagents)) = true := by
  native_decide

/- Sanity check, not a result: 72 cells are gated and ask for ≥ 2. -/
example : (allCells.filter isV2).length = 72 := by native_decide

end Graff.AcpEarlyInit
