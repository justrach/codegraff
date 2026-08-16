/-
  Score maintenance: when a fitness row is filed, and in which cell.

  This kernel is the discrete gate in front of the archive, not HMAC and
  not the file tokenizer. A score is *maintained* (filed, comparable) iff
  the fleet is on, the stage/phase resolves to a canonical slot, and the
  run carries a signal. Off-vocabulary titles stay uncelled — they still
  run, they do not accrue. An all-fail or unreached stage files nothing
  (a 0 would poison the cell mean).

  `stageScore` is the same function the harness uses (millipoints). The
  Signal cube is just the five counts that function classifies. First-word
  titles and the providerClass needle table pin the other two cell axes;
  the price fallback is out of the cube (those models stay `.unknown`).

  Matches `pipeline_score.stageScore` / `captureStage`'s predicates,
  `shapes.canonicalSlot` / `route_policy.roleOf`,
  `scoring.normalizeOutboundScore`, and the needle half of
  `scoring.providerClass`. HMAC, `observe`, and price fallback are out.

  Executable port: spec/ref/score.py.
-/

namespace Graff.Score

inductive Slot where
  | find | verify | synthesize | sweep | variants | build
  | transform | scope | implement | review
  | none
deriving DecidableEq, Repr, BEq

inductive Signal where
  | unreached | allFail | overflow | clean | someOk
deriving DecidableEq, Repr, BEq

inductive Tier where
  | frontier | mid | small | unknown
deriving DecidableEq, Repr, BEq

inductive Niche where
  | reviewer | researcher | implementer | skeptic | empty | custom
deriving DecidableEq, Repr, BEq

def canonicalSlots : List Slot :=
  [Slot.find, .verify, .synthesize, .sweep, .variants, .build,
   .transform, .scope, .implement, .review]

theorem ten_slots : canonicalSlots.length = 10 := rfl

theorem none_not_canonical : canonicalSlots.contains Slot.none = false := by native_decide

/-- Label wins; empty label falls back to the niche word. `roleOf`. -/
def roleOf (label niche : Slot) : Slot :=
  if label = Slot.none then niche else label

theorem role_prefers_label (l n : Slot) (h : l ≠ Slot.none) :
    roleOf l n = l := by
  unfold roleOf; simp [h]

theorem role_fallback (n : Slot) : roleOf Slot.none n = n := by
  unfold roleOf; rfl

theorem both_none_uncelled : roleOf Slot.none Slot.none = Slot.none := rfl

/-- Zig/Python `stageScore`, in millipoints. None = no signal. -/
def stageScore (attempted ok : Nat) : Option Nat :=
  if attempted == 0 || ok == 0 || decide (ok > attempted) then none
  else some (ok * 1000 / attempted)

/-- The five counts the filing cube feeds `stageScore`. -/
def signalCounts : Signal → Nat × Nat
  | .unreached => (0, 0)
  | .allFail => (1, 0)
  | .overflow => (1, 2)
  | .clean => (2, 2)
  | .someOk => (3, 2)

def hasSignal : Signal → Bool
  | .clean | .someOk => true
  | .unreached | .allFail | .overflow => false

theorem signal_is_stageScore (s : Signal) :
    hasSignal s = (stageScore (signalCounts s).1 (signalCounts s).2).isSome := by
  cases s <;> native_decide

theorem stage_unreached : stageScore 0 0 = none := rfl
theorem stage_all_fail : stageScore 1 0 = none := rfl
theorem stage_overflow : stageScore 1 2 = none := by native_decide
theorem stage_clean : stageScore 2 2 = some 1000 := rfl
theorem stage_fraction : stageScore 5 4 = some 800 := rfl

theorem stage_bound {a o : Nat} (_ha : a ≠ 0) (ho : o ≤ a) :
    o * 1000 / a ≤ 1000 := by
  have : o * 1000 ≤ a * 1000 := Nat.mul_le_mul_right 1000 ho
  exact Nat.div_le_of_le_mul this

theorem stage_signals_le (s : Signal) (n : Nat)
    (h : stageScore (signalCounts s).1 (signalCounts s).2 = some n) :
    n ≤ 1000 := by
  cases s <;> simp [stageScore, signalCounts] at h <;> subst h <;> decide

/-- Filed iff fleet on, a canonical slot, and a real signal. -/
def files (fleet : Bool) (label niche : Slot) (sig : Signal) : Bool :=
  fleet = true && decide (roleOf label niche ≠ Slot.none) && hasSignal sig = true

theorem fleet_off_never_files (l n : Slot) (s : Signal) :
    files false l n s = false := by
  unfold files; rfl

theorem uncelled_never_files (s : Signal) :
    files true Slot.none Slot.none s = false := by
  unfold files roleOf; simp

theorem no_signal_never_files (l n : Slot)
    (s : Signal) (h : hasSignal s = false) :
    files true l n s = false := by
  unfold files; simp [h]

theorem clean_celled_files (l n : Slot) (h : roleOf l n ≠ Slot.none) :
    files true l n Signal.clean = true := by
  unfold files hasSignal; simp [h]

/-- The Signal enum is not a second source of truth: filing asks `stageScore`. -/
theorem files_iff_stage (fleet : Bool) (l n : Slot) (s : Signal) :
    files fleet l n s =
      (fleet && decide (roleOf l n ≠ Slot.none) &&
        (stageScore (signalCounts s).1 (signalCounts s).2).isSome) := by
  unfold files
  have h := signal_is_stageScore s
  simp [h]

/-- A comparable MAP-Elites cell needs a slot. Tier/niche name the cell;
    they do not decide whether a row is filed. -/
def celled (slot : Slot) : Bool := decide (slot ≠ Slot.none)

theorem none_not_celled : celled Slot.none = false := by native_decide
theorem find_is_celled : celled Slot.find = true := by native_decide

structure Cell where
  niche : Niche := .reviewer
  tier  : Tier := .mid
  slot  : Slot := .find
deriving Repr, BEq

/-- v2: niche + tier + slot are the cell. Replay into another axis is a
    different cell. Uncelled rows are not comparable. -/
def sameCell (a b : Cell) : Bool :=
  celled a.slot = true && celled b.slot = true &&
    decide (a.niche = b.niche) && decide (a.tier = b.tier) && decide (a.slot = b.slot)

theorem change_slot_breaks_cell (c : Cell)
    (h₁ : c.slot = Slot.find) :
    sameCell c { c with slot := Slot.verify } = false := by
  unfold sameCell; simp [h₁]

theorem change_tier_breaks_cell (c : Cell)
    (h₁ : c.tier = Tier.mid) :
    sameCell c { c with tier := Tier.frontier } = false := by
  unfold sameCell; simp [h₁]

theorem change_niche_breaks_cell (c : Cell)
    (h₁ : c.niche = Niche.reviewer) :
    sameCell c { c with niche := Niche.skeptic } = false := by
  unfold sameCell; simp [h₁]

theorem uncelled_not_comparable (c : Cell) (h : c.slot = Slot.none) :
    sameCell c c = false := by
  unfold sameCell celled; simp [h]

/-- A filed row is always celled: maintenance never writes an uncelled mean. -/
theorem files_implies_celled (f : Bool) (l n : Slot) (s : Signal)
    (h : files f l n s = true) : celled (roleOf l n) = true := by
  revert h
  unfold files celled
  cases decide (roleOf l n ≠ Slot.none) <;> simp

/-- Discrete samples of `normalizeOutboundScore`. Result is millipoints
    in [0,1000] so we stay in Nat. HMAC is out of the model. -/
inductive ScaleSample where
  | neg | nan | zero | half | one | fortyThree | hundred | over
deriving DecidableEq, Repr, BEq

def normalize : ScaleSample → Option Nat
  | .zero => some 0
  | .half => some 500
  | .one => some 1000
  | .fortyThree => some 430
  | .hundred => some 1000
  | .neg | .nan | .over => none

def accepted (s : ScaleSample) : Bool := (normalize s).isSome

theorem unit_interval_accepted :
    accepted .zero = true ∧ accepted .half = true ∧ accepted .one = true := by
  native_decide

theorem one_not_divided : normalize .one = some 1000 := rfl
theorem pct_divides : normalize .fortyThree = some 430 := rfl
theorem reject_over : normalize .over = none := rfl
theorem reject_neg : normalize .neg = none := rfl
theorem reject_nan : normalize .nan = none := rfl

theorem accepted_in_unit (s : ScaleSample) (n : Nat) (h : normalize s = some n) :
    n ≤ 1000 := by
  cases s <;> simp [normalize] at h <;> subst h <;> decide

/-- First-word titles. The scanner itself is in Zig; these are the
    load-bearing cases: first word, not substring, and a leading non-ASCII
    byte aborts (otherwise a later English word would steal the cell). -/
inductive Title where
  | find | findBugs | synthesize | verify | reviewFindings
  | transform | sweepPadded | ponder | codeReview | empty | cjkReview
deriving DecidableEq, Repr, BEq

def titleSlot : Title → Slot
  | .find | .findBugs => .find
  | .synthesize => .synthesize
  | .verify => .verify
  | .reviewFindings => .review
  | .transform => .transform
  | .sweepPadded => .sweep
  | .ponder | .codeReview | .empty | .cjkReview => .none

def allTitles : List Title :=
  [.find, .findBugs, .synthesize, .verify, .reviewFindings,
   .transform, .sweepPadded, .ponder, .codeReview, .empty, .cjkReview]

def titleCells : Nat := allTitles.length

theorem title_cube : titleCells = 11 := rfl

/-- Substring would make this `find`. First word keeps it `review`. -/
theorem first_word_not_substring : titleSlot .reviewFindings = Slot.review := rfl

/-- First word is `code`, which is not a slot — the round stays uncelled. -/
theorem later_slot_word_does_not_cell : titleSlot .codeReview = Slot.none := rfl

/-- A leading non-ASCII byte refuses the scan; the label is uncelled. -/
theorem cjk_leading_uncelled : titleSlot .cjkReview = Slot.none := rfl

theorem off_vocab_titles_uncelled :
    titleSlot .ponder = Slot.none ∧ titleSlot .empty = Slot.none := by native_decide

/-- Needle half of `providerClass`. Most-specific first. Price fallback
    is out: unmatched models stay `.unknown` and are not a maintained tier. -/
inductive Model where
  | opus | gpt55 | sol | terra | luna | deepseekPro | grok43
  | haiku | geminiFlash | sonnet | unknown | grokBuild | mimo
  | minimax | deepseekFlash | gemini3
deriving DecidableEq, Repr, BEq

def modelId : Model → String
  | .opus => "claude-opus-4-8"
  | .gpt55 => "gpt-5.5"
  | .sol => "gpt-5.6-sol"
  | .terra => "gpt-5.6-terra"
  | .luna => "gpt-5.6-luna"
  | .deepseekPro => "deepseek-v4-pro"
  | .grok43 => "grok-4.3"
  | .haiku => "claude-haiku-4-5"
  | .geminiFlash => "gemini-3-flash"
  | .sonnet => "claude-sonnet-4-6"
  | .unknown => "some-unknown-model"
  | .grokBuild => "grok-build"
  | .mimo => "mimo-v2.5"
  | .minimax => "minimax-m3"
  | .deepseekFlash => "deepseek-v4-flash"
  | .gemini3 => "gemini-3"

def needles : List (String × Tier) :=
  [("haiku", .small), ("flash", .small), ("-mini", .small),
   ("lite", .small), ("nano", .small), ("terra", .mid), ("luna", .small),
   ("opus", .frontier), ("gpt-5", .frontier), ("deepseek-v4", .frontier),
   ("grok-4", .frontier), ("glm-5", .frontier), ("kimi-k2", .frontier),
   ("minimax-m", .frontier), ("mimo-v2.5-pro", .frontier), ("fugu", .frontier),
   ("gemini-3", .frontier), ("sonnet", .mid)]

def hasInfix (s needle : String) : Bool :=
  decide ((s.splitOn needle).length > 1)

def needleTier (id : String) : Option Tier :=
  (needles.find? (fun n => hasInfix id n.1)).map (·.2)

def classOf (m : Model) : Tier :=
  (needleTier (modelId m)).getD .unknown

def allModels : List Model :=
  [.opus, .gpt55, .sol, .terra, .luna, .deepseekPro, .grok43,
   .haiku, .geminiFlash, .sonnet, .unknown, .grokBuild, .mimo,
   .minimax, .deepseekFlash, .gemini3]

def classCells : Nat := allModels.length

theorem class_cube : classCells = 16 := rfl

/-- Specific markers precede the families they sit in. -/
theorem flash_beats_family : classOf .geminiFlash = Tier.small := by native_decide
theorem terra_beats_family : classOf .terra = Tier.mid := by native_decide
theorem luna_beats_family : classOf .luna = Tier.small := by native_decide
theorem deepseek_flash_small : classOf .deepseekFlash = Tier.small := by native_decide

theorem fallback_unknown : classOf .unknown = Tier.unknown := by native_decide
theorem fallback_grok_build : classOf .grokBuild = Tier.unknown := by native_decide
theorem fallback_mimo : classOf .mimo = Tier.unknown := by native_decide

def knownTier : Tier → Bool
  | .frontier | .mid | .small => true
  | .unknown => false

/-- Price-fallback models are not a maintained cell in this kernel. -/
theorem fallback_not_known_tier (m : Model) (h : classOf m = Tier.unknown) :
    knownTier (classOf m) = false := by
  simp [h, knownTier]

theorem needle_models_known :
    (allModels.filter (fun m => classOf m != .unknown)).all
      (fun m => knownTier (classOf m)) := by native_decide

/-- A maintained cell needs a known tier. Unknown (price fallback) is
    not comparable here — the live function assigns a price bucket, and
    that assignment is out of the cube. -/
def maintainedCell (c : Cell) : Bool :=
  celled c.slot && knownTier c.tier

theorem uncelled_not_maintained (c : Cell) (h : c.slot = Slot.none) :
    maintainedCell c = false := by
  unfold maintainedCell celled; simp [h]

theorem unknown_tier_not_maintained (c : Cell) (h : c.tier = Tier.unknown) :
    maintainedCell c = false := by
  unfold maintainedCell knownTier; simp [h]

theorem mid_find_maintained :
    maintainedCell {} = true := by native_decide

structure FileCase where
  fleet : Bool
  label : Slot
  niche : Slot
  sig   : Signal
deriving Repr, BEq

def allSlots : List Slot :=
  [Slot.find, .verify, .synthesize, .sweep, .variants, .build,
   .transform, .scope, .implement, .review, .none]

def allSignals : List Signal :=
  [Signal.unreached, .allFail, .overflow, .clean, .someOk]

def allFileCases : List FileCase :=
  Id.run do
    let mut acc : List FileCase := []
    for fleet in [false, true] do
      for label in allSlots do
        for niche in allSlots do
          for sig in allSignals do
            acc := acc ++ [{ fleet, label, niche, sig }]
    return acc

def scoreCells : Nat := allFileCases.length
def filedCells : Nat :=
  (allFileCases.filter (fun c => files c.fleet c.label c.niche c.sig)).length

/-- 2 fleets × 11 slots × 11 niches × 5 signals. -/
theorem score_cube : scoreCells = 1210 := by native_decide

/-- Fleet-on × 120 celled (label, niche) pairs × 2 live signals. -/
theorem filed_count : filedCells = 240 := by native_decide

/-- Every filed cell of the cube is celled, fleet-on, and has a stageScore. -/
theorem cube_filed_is_celled :
    allFileCases.all (fun c =>
      !(files c.fleet c.label c.niche c.sig) ||
        celled (roleOf c.label c.niche)) := by native_decide

theorem cube_filed_fleet_on :
    allFileCases.all (fun c =>
      !(files c.fleet c.label c.niche c.sig) || c.fleet) := by native_decide

theorem cube_filed_has_stage :
    allFileCases.all (fun c =>
      !(files c.fleet c.label c.niche c.sig) ||
        (stageScore (signalCounts c.sig).1 (signalCounts c.sig).2).isSome) := by
  native_decide

theorem cube_files_iff_stage :
    allFileCases.all (fun c =>
      files c.fleet c.label c.niche c.sig ==
        (c.fleet && decide (roleOf c.label c.niche ≠ Slot.none) &&
          (stageScore (signalCounts c.sig).1 (signalCounts c.sig).2).isSome)) := by
  native_decide

/-! Concrete cells the harness also checks. -/

example : files true Slot.transform Slot.none Signal.clean = true := by native_decide
example : files true Slot.none Slot.transform Signal.clean = true := by native_decide
example : files true Slot.none Slot.none Signal.clean = false := by native_decide
example : files true Slot.transform Slot.none Signal.allFail = false := by native_decide
example : files true Slot.transform Slot.none Signal.unreached = false := by native_decide
example : files true Slot.transform Slot.none Signal.overflow = false := by native_decide
example : files false Slot.transform Slot.none Signal.clean = false := by native_decide
example : roleOf Slot.none Slot.transform = Slot.transform := by native_decide
example : roleOf Slot.review Slot.find = Slot.review := by native_decide
example : sameCell {} { slot := Slot.verify } = false := by native_decide
example : classOf .opus = Tier.frontier := by native_decide
example : classOf .haiku = Tier.small := by native_decide
example : classOf .sonnet = Tier.mid := by native_decide
example : classOf .minimax = Tier.frontier := by native_decide
example : titleSlot .findBugs = Slot.find := by native_decide
example : titleSlot .sweepPadded = Slot.sweep := by native_decide

end Graff.Score
