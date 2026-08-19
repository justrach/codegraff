/-
  Prompt-stable kernel (what may touch the prefix after pin).

  OpenGauss's "Prompt Caching Must Not Break": do not alter past context,
  do not rewrite the toolset, do not reload memory or rebuild the system
  prompt mid-session. The only allowed rewrite is compression.

  We keep that cut and name the two explicit busts we do allow
  (`set_system_prompt`, a `/goal` standing-line change) plus the one
  graff-only keep: an append-only tools tail (#476). Mid-array rewrite
  is still illegal. Skills and folded schemas land in history.

  Anthropic `cache_control` placement is a never-kernel (vendor bytes).

  Executable port: spec/ref/prompt_stable.py.
-/

namespace Graff.PromptStable

/-- Mid-session events that can land in history or the prefix. -/
inductive Event where
  | turn | skillInject | schemaLoad
  | toolsetAppend | toolsetRewrite
  | clockTick | memoryReload
  | setSystemPrompt | standingChange | compact
deriving DecidableEq, Repr, BEq

inductive Land where
  | history | prefix
deriving DecidableEq, Repr, BEq

inductive Verdict where
  | keep | bust | illegal
deriving DecidableEq, Repr, BEq

def land : Event → Land
  | .turn | .skillInject | .schemaLoad => .history
  | _ => .prefix

def verdict : Event → Verdict
  | .turn | .skillInject | .schemaLoad | .toolsetAppend | .compact => .keep
  | .setSystemPrompt | .standingChange => .bust
  | .clockTick | .toolsetRewrite | .memoryReload => .illegal

structure Cell where
  event : Event
  land  : Land
deriving Repr, BEq, DecidableEq

/-- Keep only when the event lands in its measured seat and is a keep. -/
def keep (c : Cell) : Bool :=
  decide (land c.event = c.land) && decide (verdict c.event = .keep)

def allEvents : List Event :=
  [.turn, .skillInject, .schemaLoad, .toolsetAppend, .toolsetRewrite,
   .clockTick, .memoryReload, .setSystemPrompt, .standingChange, .compact]

def allCells : List Cell :=
  Id.run do
    let mut acc : List Cell := []
    for e in allEvents do
      for l in [Land.history, .prefix] do
        acc := acc ++ [{ event := e, land := l }]
    return acc

def stableCells : Nat := allCells.length
def keepCells : Nat := (allCells.filter keep).length

theorem stable_cube : stableCells = 20 := by native_decide
theorem keep_count : keepCells = 5 := by native_decide

theorem history_keeps (e : Event) (h : land e = .history) :
    keep { event := e, land := .history } = decide (verdict e = .keep) := by
  simp [keep, h]

theorem skill_in_prefix_misses :
    keep { event := .skillInject, land := .prefix } = false := by native_decide

theorem clock_in_prefix_illegal :
    verdict .clockTick = .illegal ∧
      keep { event := .clockTick, land := .prefix } = false := by native_decide

theorem rewrite_illegal :
    verdict .toolsetRewrite = .illegal := by native_decide

theorem append_keeps_prefix :
    keep { event := .toolsetAppend, land := .prefix } = true := by native_decide

theorem compact_keeps :
    keep { event := .compact, land := .prefix } = true := by native_decide

/-! The machine. Snapshot predicates above; these are the edges. -/

structure State where
  pinned : Bool := false
  frozen : Bool := false
deriving Repr, BEq, DecidableEq

inductive StepEvent where
  | start
  | ev (e : Event)
deriving DecidableEq, Repr, BEq

def isKeep (e : Event) : Bool := decide (verdict e = .keep)

def step (s : State) (e : StepEvent) : State :=
  match e with
  | StepEvent.start =>
      if s.pinned then s else { pinned := true, frozen := true }
  | StepEvent.ev ev =>
      if !s.pinned then s
      else if isKeep ev then
        if decide (ev = Event.compact) then { s with frozen := true } else s
      else { s with frozen := false }

def run (s : State) : List StepEvent → State
  | []      => s
  | e :: es => run (step s e) es

def hitOk (s : State) : Bool := s.pinned && s.frozen

theorem start_pins :
    (step {} .start).pinned = true ∧ (step {} .start).frozen = true := by
  simp [step]

theorem history_id (s : State) :
    step s (.ev .turn) = s ∨ !s.pinned := by
  cases s.pinned <;> simp [step, isKeep, verdict]

theorem skill_id :
    step (step {} .start) (.ev .skillInject) = step {} .start := by
  native_decide

theorem append_id :
    step (step {} .start) (.ev .toolsetAppend) = step {} .start := by
  native_decide

theorem compact_repins :
    hitOk (run {} [.start, .ev .setSystemPrompt, .ev .compact]) = true := by
  native_decide

theorem set_system_busts :
    hitOk (run {} [.start, .ev .setSystemPrompt]) = false := by
  native_decide

theorem standing_busts :
    hitOk (run {} [.start, .ev .standingChange]) = false := by
  native_decide

theorem clock_busts :
    hitOk (run {} [.start, .ev .clockTick]) = false := by
  native_decide

theorem rewrite_busts :
    hitOk (run {} [.start, .ev .toolsetRewrite]) = false := by
  native_decide

theorem memory_reload_busts :
    hitOk (run {} [.start, .ev .memoryReload]) = false := by
  native_decide

/-- Gauss must-nots plus skill/schema/append/turn/compact stay on the HIT. -/
theorem maximizing_walk :
    hitOk (run {} [
      .start, .ev .turn, .ev .skillInject, .ev .schemaLoad,
      .ev .toolsetAppend, .ev .compact]) = true := by
  native_decide

example : verdict .skillInject = .keep := by native_decide
example : land .skillInject = .history := by native_decide
example : verdict .clockTick = .illegal := by native_decide
example : keep { event := .compact, land := .history } = false := by native_decide

end Graff.PromptStable
