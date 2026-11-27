/-! Outcome accounting for the paired first-completion evaluation. The external
    executable grader supplies scores; this model only proves classification
    properties and does not verify the recovery implementation or the agent. -/
namespace Graff.FirstCompletion

inductive Stop where
  | claimed | noClaim | budget | timeout | protocolError
  deriving DecidableEq

inductive Grade where
  | pass | fail | unavailable
  deriving DecidableEq

structure Outcome where
  stop : Stop
  grade : Grade

def correct (run : Outcome) : Prop :=
  run.stop = .claimed ∧ run.grade = .pass

def falseCompletion (run : Outcome) : Prop :=
  run.stop = .claimed ∧ run.grade ≠ .pass

def rescued (first later : Outcome) : Prop :=
  falseCompletion first ∧ correct later

def regressed (first later : Outcome) : Prop :=
  correct first ∧ later.grade ≠ .pass

theorem unavailableGradeCannotPass (run : Outcome) (h : run.grade = .unavailable) :
    ¬ correct run := by
  intro result
  cases h.symm.trans result.2

theorem noClaimCannotBeRescueBaseline (first later : Outcome) (h : first.stop ≠ .claimed) :
    ¬ rescued first later := by
  intro result
  exact h result.1.1

theorem correctFirstCannotBeRescued (first later : Outcome) (h : correct first) :
    ¬ rescued first later := by
  intro result
  exact result.1.2 h.2

theorem rescuesAndRegressionsAreDisjoint (first later : Outcome) :
    ¬ (rescued first later ∧ regressed first later) := by
  intro result
  exact correctFirstCannotBeRescued first later result.2.1 result.1

end Graff.FirstCompletion
