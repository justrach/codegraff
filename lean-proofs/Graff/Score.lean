/-
  Score maintenance: when a fitness row is filed, and in which cell.

  This kernel is the discrete gate in front of the archive, not HMAC and
  not the file tokenizer. A score is *maintained* (filed, comparable) iff
  the fleet is on, the stage/phase resolves to a canonical slot, and the
  run carries a signal. Off-vocabulary titles stay uncelled — they still
  run, they do not accrue. An all-fail or unreached stage files nothing
  (a 0 would poison the cell mean).

  Matches `pipeline_score.stageScore` / `captureStage`'s predicates,
  `shapes.canonicalSlot` / `route_policy.roleOf`, and
  `scoring.normalizeOutboundScore`. HMAC, `observe`, and providerClass
  price fallback are out of the cube.

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

def hasSignal : Signal → Bool
  | .clean | .someOk => true
  | .unreached | .allFail | .overflow => false

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

theorem uncelled_not_comparable (c : Cell) (h : c.slot = Slot.none) :
    sameCell c c = false := by
  unfold sameCell celled; simp [h]

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

end Graff.Score
