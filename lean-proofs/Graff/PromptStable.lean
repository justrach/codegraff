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

/-!
  Section 2: Multi-provider compaction cache fork (`src/cache_fork.zig`, `src/http_headers.zig`).
  Formalizes when a compaction summary or `#391` pre-compaction memory note may fork
  the root agent's warm prefix (`system + tools + messages`) and share the root
  `prompt_cache_key` partition.
-/

inductive ForkWire where
  | anthropicClaude
  | anthropicOther
  | openai
  | responses
  | interactions
deriving DecidableEq, Repr, BEq

inductive ToolTail where
  | none
  | answered
  | unanswered
deriving DecidableEq, Repr, BEq

structure ForkCell where
  wire       : ForkWire
  withinTtl  : Bool
  fitsWindow : Bool
  tail       : ToolTail
deriving DecidableEq, Repr, BEq

def wireSupportsFork : ForkWire → Bool
  | .anthropicClaude | .openai => true
  | .anthropicOther | .responses | .interactions => false

def warmFork (c : ForkCell) : Bool :=
  wireSupportsFork c.wire && c.withinTtl && c.fitsWindow && decide (c.tail ≠ .unanswered)

def sharesRootKey (label : String) (forking : Bool) : Bool :=
  decide (label = "main") || decide (label = "btw") || (decide (label = "note") && forking)

def allForkWires : List ForkWire :=
  [.anthropicClaude, .anthropicOther, .openai, .responses, .interactions]

def allToolTails : List ToolTail :=
  [.none, .answered, .unanswered]

def allForkCells : List ForkCell :=
  Id.run do
    let mut acc : List ForkCell := []
    for w in allForkWires do
      for ttl in [false, true] do
        for fit in [false, true] do
          for t in allToolTails do
            acc := acc ++ [{ wire := w, withinTtl := ttl, fitsWindow := fit, tail := t }]
    return acc

theorem fork_cube_count :
    allForkCells.length = 60 ∧ (allForkCells.filter warmFork).length = 4 := by
  native_decide

theorem unanswered_tool_never_forks (c : ForkCell) (h : c.tail = .unanswered) :
    warmFork c = false := by
  simp [warmFork, h]

theorem overflow_never_forks (c : ForkCell) (h : c.fitsWindow = false) :
    warmFork c = false := by
  simp [warmFork, h]

theorem expired_ttl_never_forks (c : ForkCell) (h : c.withinTtl = false) :
    warmFork c = false := by
  simp [warmFork, h]

theorem unsupported_wire_never_forks (c : ForkCell) (h : wireSupportsFork c.wire = false) :
    warmFork c = false := by
  simp [warmFork, h]

theorem fork_iff_all_safe (c : ForkCell) :
    warmFork c = true ↔
      (c.wire = .anthropicClaude ∨ c.wire = .openai) ∧
      c.withinTtl = true ∧
      c.fitsWindow = true ∧
      c.tail ≠ .unanswered := by
  cases c with
  | mk w ttl fit tl =>
    cases w <;> cases ttl <;> cases fit <;> cases tl <;> decide

theorem note_shares_root_key (forking : Bool) :
    sharesRootKey "note" forking = forking := by
  cases forking <;> native_decide

/-- `mcp_preload.namedServers` must never run on a synthetic compaction request:
    `persists_note` names `peer_message` in prose, which would otherwise preload
    `peer_message` into `tools` on the summary call and invalidate the forked prefix. -/
def preloadEligible (sub compactionRequest : Bool) (callsThisTurn : Nat) : Bool :=
  !sub && !compactionRequest && decide (callsThisTurn ≤ 1)

theorem compaction_never_preloads_tools (sub : Bool) (calls : Nat) :
    preloadEligible sub true calls = false := by
  simp [preloadEligible]

/-!
  Section 3: Dirty-worktree-safe edit contract (`src/edit_contract.zig`).
  A snapshot combines `hasPorcelain`, the status line hash, and the content digest
  of dirty/untracked files (`#dirty-digest`). Editing an already-dirty file changes
  `contentHash` and satisfies the contract, whereas leaving a dirty worktree
  untouched keeps the snapshot equal and fails the contract.
-/

structure TreeDigest where
  hasPorcelain : Bool
  statusHash   : Nat
  contentHash  : Nat
deriving DecidableEq, Repr, BEq

def contractUnmet (contracted : Bool) (before after : TreeDigest) : Bool :=
  if !contracted then false
  else if !after.hasPorcelain then true
  else decide (before = after)

theorem uncontracted_always_passes (b a : TreeDigest) :
    contractUnmet false b a = false := by
  rfl

theorem clean_after_fails_contract (b a : TreeDigest) (h : a.hasPorcelain = false) :
    contractUnmet true b a = true := by
  simp [contractUnmet, h]

theorem untouched_dirty_fails_contract (d : TreeDigest) :
    contractUnmet true d d = true := by
  cases hp : d.hasPorcelain <;> simp [contractUnmet, hp]

theorem dirty_edit_satisfies_contract (b a : TreeDigest)
    (hp : a.hasPorcelain = true) (hc : b.contentHash ≠ a.contentHash) :
    contractUnmet true b a = false := by
  have hne : b ≠ a := by
    intro heq
    apply hc
    rw [heq]
  simp [contractUnmet, hp, hne]

/-!
  Section 4: Bounded background-job `OutputRing` (`src/job_ring.zig`).
  Proves that `readStep` immediately reclaims all consumed prefix bytes (`nextLen = 0,
  nextCursor = 0`) and that `capStep` strictly bounds unread bytes at `≤ cap`.
-/

structure RingStep where
  nextLen    : Nat
  nextCursor : Nat
  dropped    : Bool
  compacted  : Bool
deriving DecidableEq, Repr, BEq

def capStep (bufLen cursor cap : Nat) : RingStep :=
  let vc := Nat.min cursor bufLen
  if bufLen - vc ≤ cap then
    { nextLen := bufLen, nextCursor := vc, dropped := false, compacted := false }
  else
    let adv := bufLen - cap
    if adv ≥ cap ∧ cap > 0 then
      { nextLen := cap, nextCursor := 0, dropped := true, compacted := true }
    else
      { nextLen := bufLen, nextCursor := adv, dropped := true, compacted := false }

def readStep (bufLen cursor : Nat) : Nat × Nat × Nat :=
  (bufLen - Nat.min cursor bufLen, 0, 0)

theorem consumed_bytes_reclaimed (bufLen cursor : Nat) :
    (readStep bufLen cursor).2 = (0, 0) := by
  rfl

theorem unread_bounded_by_cap (bufLen cursor cap : Nat) :
    (capStep bufLen cursor cap).nextLen - (capStep bufLen cursor cap).nextCursor ≤ cap := by
  by_cases h1 : bufLen - Nat.min cursor bufLen ≤ cap
  · simp [capStep, h1]
  · by_cases h2 : bufLen - cap ≥ cap ∧ cap > 0
    · simp [capStep, h1, h2]
    · simp [capStep, h1, h2]
      omega

theorem total_buf_bounded_by_two_cap (bufLen cursor cap : Nat)
    (_h : cap > 0) (_hb : bufLen - Nat.min cursor bufLen > cap) :
    (capStep bufLen cursor cap).nextLen < 2 * cap := by
  have h1 : ¬(bufLen - Nat.min cursor bufLen ≤ cap) := by omega
  by_cases h2 : bufLen - cap ≥ cap ∧ cap > 0
  · simp [capStep, h1, h2]
  · simp [capStep, h1, h2]
    omega

end Graff.PromptStable
