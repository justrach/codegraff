/-
  Hand ladder + the explicit arm. Not `admit`.

  This kernel is `escalation.ladderRung` and the explicit branch of
  `decide` (honour at R2 or above). It is not the learned override, not
  ε-explore, and not `observe` (file tokenizer, session decline counts,
  string scan). Those stay out of the cube.

  Affordability is `Ledger.fits(remaining, fleetFloor(shape))`, the same
  arithmetic as `phase_budget.zig`. It is not a free bool.

  `classOf` here is the reduced-cue *order* of `shapes.classOf`. The live
  string scan is `src/shape_needles.zig`; the fixture consumes that table.

  Executable port: spec/ref/shape.py.
-/

namespace Graff.Shape

inductive Shape where
  | review | research | design | migration | feature | adhoc
deriving DecidableEq, Repr, BEq

inductive TaskClass where
  | bugfix | feature | refactor | review | research | other
deriving DecidableEq, Repr, BEq

inductive Rung where
  | R0 | R0d | R1 | R2 | R3
deriving DecidableEq, Repr, BEq

def shapeCount : Nat := 6

theorem six_shapes : shapeCount = 6 := rfl

def parseShape (s : String) : Shape :=
  if s == "review" then .review
  else if s == "research" then .research
  else if s == "design" then .design
  else if s == "migration" then .migration
  else if s == "feature" then .feature
  else .adhoc

/-- Reduced cues. Precedence only; not the live string scan. -/
structure Cues where
  audit    : Bool := false
  bugfix   : Bool := false
  refactor : Bool := false
  review   : Bool := false
  research : Bool := false
  feature  : Bool := false
deriving Repr, BEq

def classOf (c : Cues) : TaskClass :=
  if c.audit then .review
  else if c.bugfix then .bugfix
  else if c.refactor then .refactor
  else if c.review then .review
  else if c.research then .research
  else if c.feature then .feature
  else .other

theorem audit_beats_bugfix (c : Cues) (h : c.audit = true) :
    classOf c = .review := by
  unfold classOf; rw [h]; rfl

theorem repair_beats_review_word (c : Cues)
    (h₁ : c.audit = false) (h₂ : c.bugfix = true) :
    classOf c = .bugfix := by
  unfold classOf; rw [h₁, h₂]; rfl

theorem no_needles_is_other (c : Cues)
    (h₁ : c.audit = false) (h₂ : c.bugfix = false) (h₃ : c.refactor = false)
    (h₄ : c.review = false) (h₅ : c.research = false) (h₆ : c.feature = false) :
    classOf c = .other := by
  unfold classOf; rw [h₁, h₂, h₃, h₄, h₅, h₆]; rfl

/-- `phase_budget.zig` constants. -/
def costFind : Nat := 4
def costVerify : Nat := 3
def costSynthesize : Nat := 2
def costImplement : Nat := 6
def costDefault : Nat := 3
def minLandingReserve : Nat := 6

def fleetFloor : Shape → Nat
  | .review => 3 * costFind + costVerify + costSynthesize
  | .research => 3 * costFind + costSynthesize
  | .design => 3 * costImplement
  | .feature => costVerify + costImplement + costVerify
  | .migration => 4 * costDefault
  | .adhoc => 3 * costDefault

def landingReserve (cap : Nat) : Nat :=
  Nat.max minLandingReserve (cap / 5)

/-- #390: one call is held back to narrate the run's outcome, so the ladder
    budgets against landing work AND narration (`Ledger.reserve`). -/
def costNarration : Nat := 1

def totalReserve (cap : Nat) : Nat :=
  landingReserve cap + costNarration

/-- `Ledger.fits`. cap = 0 is unlimited. Nat subtraction saturates. -/
def fleetFits (shape : Shape) (remaining cap : Nat) : Bool :=
  if cap = 0 then true
  else decide (remaining - totalReserve cap ≥ fleetFloor shape)

theorem adhoc_floor_lt_design : fleetFloor .adhoc < fleetFloor .design := by native_decide

/-- remaining=30, cap=100 → spendable 9: adhoc (9) fits, design (18) does not. -/
theorem split_admits_adhoc : fleetFits .adhoc 30 100 = true := by native_decide
theorem split_refuses_design : fleetFits .design 30 100 = false := by native_decide

theorem unlimited_fits (s : Shape) : fleetFits s 0 0 = true := by
  cases s <;> native_decide

structure Observables where
  shape        : Shape := .adhoc
  filesLt3     : Bool := true
  widestGe2    : Bool := false
  audit        : Bool := false
  priorFailure : Bool := false
  priorCount   : Nat := 0
  hasVerifier  : Bool := false
  remaining    : Nat := 1000000
  cap          : Nat := 1000000
deriving Repr, BEq

def fleetAffordable (o : Observables) : Bool :=
  fleetFits o.shape o.remaining o.cap

/-- Smallest rung that fits. Precedence, not cost. -/
def ladderRung (o : Observables) : Rung :=
  if o.priorFailure = true ∧ o.audit = false ∧ o.priorCount = 1 ∧ o.filesLt3 = true ∧ o.hasVerifier = true then
    .R0d
  else if (o.audit = true ∨ o.priorFailure = true) ∧ fleetAffordable o = true then
    .R3
  else if o.shape = .research ∧ o.audit = false then
    .R1
  else if o.filesLt3 = false ∧ o.widestGe2 = true ∧ fleetAffordable o = true then
    .R2
  else
    .R0

def level : Rung → Nat
  | .R0 => 0 | .R0d => 1 | .R1 => 2 | .R2 => 3 | .R3 => 4

/-- Explicit arm of `decide` only. Never learned, never explore. -/
def honourExplicit (ladder : Rung) : Rung :=
  if level ladder ≥ 3 then ladder else .R2

theorem honour_preserves_high (r : Rung) (h : 3 ≤ level r) :
    honourExplicit r = r := by
  unfold honourExplicit; simp [h]

theorem honour_lifts_low (r : Rung) (h : level r < 3) :
    honourExplicit r = .R2 := by
  unfold honourExplicit
  have : ¬ (3 ≤ level r) := Nat.not_le_of_gt h
  simp [this]

theorem explicit_at_least_R2 (r : Rung) :
    3 ≤ level (honourExplicit r) := by
  cases r <;> decide

theorem r0d_when (o : Observables)
    (h₁ : o.priorFailure = true) (h₂ : o.audit = false)
    (h₃ : o.priorCount = 1) (h₄ : o.filesLt3 = true)
    (h₅ : o.hasVerifier = true) :
    ladderRung o = .R0d := by
  unfold ladderRung; simp [h₁, h₂, h₃, h₄, h₅]

theorem audit_affordable (o : Observables)
    (h₁ : o.audit = true) (h₂ : fleetAffordable o = true) :
    ladderRung o = .R3 := by
  unfold ladderRung; simp [h₁, h₂]

theorem research_without_escalation (o : Observables)
    (h₁ : o.shape = .research) (h₂ : o.audit = false)
    (h₃ : o.priorFailure = false) :
    ladderRung o = .R1 := by
  unfold ladderRung; simp [h₁, h₂, h₃]

theorem three_files_fleet (o : Observables)
    (h₁ : o.filesLt3 = false) (h₂ : o.widestGe2 = true)
    (h₃ : fleetAffordable o = true) (h₄ : o.audit = false)
    (h₅ : o.priorFailure = false) (h₆ : o.shape = .feature) :
    ladderRung o = .R2 := by
  unfold ladderRung; simp [h₁, h₂, h₃, h₄, h₅, h₆]

theorem small_no_signal_is_R0 (o : Observables)
    (h₁ : o.filesLt3 = true) (h₂ : o.audit = false)
    (h₃ : o.priorFailure = false) (h₄ : o.shape = .feature) :
    ladderRung o = .R0 := by
  unfold ladderRung; simp [h₁, h₂, h₃, h₄]

/-- dry / split (adhoc fits, design does not) / wet. -/
def budgetCells : List (Nat × Nat) :=
  [(0, 100), (30, 100), (1000000, 1000000)]

def allObservables : List Observables :=
  Id.run do
    let mut acc : List Observables := []
    for shape in [Shape.review, .research, .design, .migration, .feature, .adhoc] do
      for filesLt3 in [false, true] do
        for widestGe2 in [false, true] do
          for audit in [false, true] do
            for priorFailure in [false, true] do
              for priorCount in [0, 1, 2] do
                for hasVerifier in [false, true] do
                  for bc in budgetCells do
                    acc := acc ++ [{
                      shape, filesLt3, widestGe2, audit, priorFailure,
                      priorCount, hasVerifier, remaining := bc.1, cap := bc.2 }]
    return acc

def shapeCells : Nat := allObservables.length
def r0Cells : Nat := (allObservables.filter (fun o => ladderRung o == .R0)).length
def r3Cells : Nat := (allObservables.filter (fun o => ladderRung o == .R3)).length

/-- 6 shapes × 2⁵ bools × 3 prior-counts × 3 budgets. -/
theorem shape_cube : shapeCells = 1728 := by native_decide

/-! Concrete cells the harness also checks. -/

example : parseShape "ponder" = .adhoc := by native_decide
example : parseShape "review" = .review := by native_decide
example : classOf {} = .other := by native_decide
example : honourExplicit .R3 = .R3 := by native_decide
example : honourExplicit .R0 = .R2 := by native_decide
example : ladderRung { shape := .feature, filesLt3 := true } = .R0 := by native_decide
example : ladderRung { audit := true, remaining := 1000000, cap := 1000000 } = .R3 := by native_decide
example : ladderRung { audit := true, remaining := 0, cap := 100 } ≠ .R3 := by native_decide
example : ladderRung { shape := .research, filesLt3 := false, widestGe2 := true } = .R1 := by native_decide
example : ladderRung { shape := .research, audit := true, remaining := 1000000, cap := 1000000 } = .R3 := by native_decide
example : ladderRung { filesLt3 := false, widestGe2 := true, remaining := 1000000, cap := 1000000 } = .R2 := by native_decide
example : ladderRung {
    shape := .adhoc, filesLt3 := false, widestGe2 := true,
    remaining := 30, cap := 100 } = .R2 := by native_decide
example : ladderRung {
    shape := .design, filesLt3 := false, widestGe2 := true,
    remaining := 30, cap := 100 } = .R0 := by native_decide
example : ladderRung {
    filesLt3 := true, priorFailure := true, priorCount := 1,
    hasVerifier := true, audit := false } = .R0d := by native_decide
example : ladderRung {
    filesLt3 := true, priorFailure := true, priorCount := 2,
    hasVerifier := true, remaining := 1000000, cap := 1000000 } = .R3 := by native_decide

end Graff.Shape
