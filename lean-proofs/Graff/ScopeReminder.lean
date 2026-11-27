/- Mirrors src/task_intent.zig:scopeReminder. The lexical classifier supplies
   the two scope bits. This kernel covers when the engine can emit a reminder
   and which reminder text it can select. -/
namespace Graff.ScopeReminder

inductive Reminder
  | none | originalRequest | repositorySummary
deriving DecidableEq, Repr

def reminder (informational eligible : Bool) (modelCalls toolCalls : Nat)
    (repositorySummary : Bool) : Reminder :=
  if !informational || !eligible || (modelCalls < 4 && toolCalls < 6) then .none
  else if repositorySummary then .repositorySummary else .originalRequest

theorem actionable_never_nudged (eligible : Bool) (models tools : Nat) (repo : Bool) :
    reminder false eligible models tools repo = .none := by
  simp [reminder]

theorem inactive_never_nudged (informational : Bool) (models tools : Nat) (repo : Bool) :
    reminder informational false models tools repo = .none := by
  cases informational <;> simp [reminder]

theorem scope_respected (eligible : Bool) (models tools : Nat) :
    reminder true eligible models tools false ≠ .repositorySummary := by
  unfold reminder
  split <;> decide

theorem either_threshold_suffices (models tools : Nat) (repo : Bool)
    (exhausted : 4 ≤ models ∨ 6 ≤ tools) :
    reminder true true models tools repo =
      (if repo then .repositorySummary else .originalRequest) := by
  rcases exhausted with h | h
  · simp [reminder, Nat.not_lt.mpr h]
  · simp [reminder, Nat.not_lt.mpr h]

def cells : List (Bool × Bool × Nat × Nat × Bool) :=
  [false, true].flatMap fun i =>
  [false, true].flatMap fun e =>
  [3, 4].flatMap fun m =>
  [5, 6].flatMap fun t =>
  [false, true].map fun r => (i, e, m, t, r)

def encode (result : Reminder) : Char :=
  match result with
  | .none => '0'
  | .originalRequest => '1'
  | .repositorySummary => '2'

/-- The Zig unit test checks its production decision against this enumeration. -/
def boundaryFixture : String :=
  String.ofList (cells.map fun (i, e, m, t, r) => encode (reminder i e m t r))

end Graff.ScopeReminder
