/-
  Goal / completion kernel (#318, #226, #394).

  This is *harness-done*, not *world-done*. `completionGate` says whether
  `attempt_completion` may be accepted. It does not say the work is correct.

  The checklist is collapsed to what the gate actually reads: none / open /
  all-completed. Empty is none, never done.

  Executable port: spec/ref/goal_loop.py.
-/

namespace Graff.GoalLoop

inductive Seat where
  | root | sub | review
deriving DecidableEq, Repr, BEq

/-- `GoalStatus` plus "no goal". Paused/blocked exist and do not steer. -/
inductive Goal where
  | none | active | paused | blocked | complete
deriving DecidableEq, Repr, BEq

inductive Checklist where
  | none | open | allCompleted
deriving DecidableEq, Repr, BEq

inductive Verdict where
  | accept | refuseOpen | refuseNoPlan
deriving DecidableEq, Repr, BEq

structure State where
  seat      : Seat := .root
  goal      : Goal := .none
  standing  : Bool := false
  checklist : Checklist := .none
  dirty     : Bool := false
  armed     : Bool := false
deriving Repr, BEq

def goalActive (s : State) : Bool :=
  if s.seat ≠ .root then false
  else decide (s.goal = .active)

def allDone : Checklist → Bool
  | .allCompleted => true
  | .none         => false
  | .open         => false

def completionGate (s : State) : Verdict :=
  if !goalActive s then .accept
  else if s.armed then .accept
  else match s.checklist with
    | .open         => .refuseOpen
    | .none         => .refuseNoPlan
    | .allCompleted => .accept

/-- This-process evidence only. A restored all-[x] list is not `dirty`. -/
def checklistFinished (s : State) : Bool :=
  s.dirty && allDone s.checklist

/-- An accepted claim retires a non-standing active goal. Standing records
and keeps steering. -/
def retiresOnAccept (s : State) : Bool :=
  goalActive s && !s.standing

def allStates : List State :=
  Id.run do
    let mut acc : List State := []
    for seat in [Seat.root, .sub, .review] do
      for goal in [Goal.none, .active, .paused, .blocked, .complete] do
        for standing in [false, true] do
          for checklist in [Checklist.none, .open, .allCompleted] do
            for dirty in [false, true] do
              for armed in [false, true] do
                acc := acc ++ [{ seat, goal, standing, checklist, dirty, armed }]
    return acc

def goalCells : Nat := allStates.length
def refuseOpenCells : Nat :=
  (allStates.filter (fun s => completionGate s == .refuseOpen)).length
def refuseNoPlanCells : Nat :=
  (allStates.filter (fun s => completionGate s == .refuseNoPlan)).length

theorem goal_cube : goalCells = 360 := by native_decide
theorem refuse_open_count : refuseOpenCells = 4 := by native_decide
theorem refuse_no_plan_count : refuseNoPlanCells = 4 := by native_decide

/-! General facts. -/

theorem sub_never_refuses (s : State) (h : s.seat = .sub) :
    completionGate s = .accept := by
  unfold completionGate goalActive; rw [h]; rfl

theorem review_never_refuses (s : State) (h : s.seat = .review) :
    completionGate s = .accept := by
  unfold completionGate goalActive; rw [h]; rfl

theorem paused_never_refuses (s : State) (h : s.goal = .paused) :
    completionGate s = .accept := by
  unfold completionGate goalActive
  cases s.seat <;> simp [h]

theorem empty_never_done : allDone .none = false := rfl

theorem open_never_done : allDone .open = false := rfl

theorem finished_needs_dirty (s : State) (h : s.dirty = false) :
    checklistFinished s = false := by
  simp [checklistFinished, h]

theorem standing_does_not_retire (s : State) (h : s.standing = true) :
    retiresOnAccept s = false := by
  simp [retiresOnAccept, h]

theorem armed_accepts (s : State) (h₁ : goalActive s = true) (h₂ : s.armed = true) :
    completionGate s = .accept := by
  unfold completionGate
  simp [h₁, h₂]

/-! Concrete cells the harness also checks. -/

example : completionGate {} = .accept := by native_decide
example : completionGate { goal := .active } = .refuseNoPlan := by native_decide
example : completionGate { goal := .active, checklist := .open } = .refuseOpen := by native_decide
example : completionGate { goal := .active, checklist := .allCompleted } = .accept := by native_decide
example : completionGate { goal := .active, checklist := .open, armed := true } = .accept := by native_decide
example : completionGate { goal := .active, seat := .sub, checklist := .open } = .accept := by native_decide
example : completionGate { goal := .active, seat := .review, checklist := .none } = .accept := by native_decide
example : completionGate { goal := .paused, checklist := .open } = .accept := by native_decide
example : checklistFinished { checklist := .allCompleted, dirty := false } = false := by native_decide
example : checklistFinished { checklist := .allCompleted, dirty := true } = true := by native_decide
example : retiresOnAccept { goal := .active } = true := by native_decide
example : retiresOnAccept { goal := .active, standing := true } = false := by native_decide

/-! Tiny list model for `allDone` / replace, so empty ≠ done is not just an enum. -/

inductive Status where
  | pending | inProgress | completed
deriving DecidableEq, Repr, BEq

structure Item where
  content : String
  status  : Status := .pending
  epoch   : Nat := 1
  retired : Bool := false
deriving Repr, BEq

def live (it : Item) (epoch : Nat) : Bool :=
  decide (it.epoch = epoch) && !it.retired

def openCount : List Item → Nat → Nat
  | [], _          => 0
  | it :: rest, ep =>
      let n := openCount rest ep
      if live it ep && it.status ≠ .completed then n + 1 else n

def hasCurrent : List Item → Nat → Bool
  | [], _          => false
  | it :: rest, ep => live it ep || hasCurrent rest ep

def allDoneItems (items : List Item) (epoch : Nat) : Bool :=
  hasCurrent items epoch && decide (openCount items epoch = 0)

def classify (items : List Item) (epoch : Nat) : Checklist :=
  if openCount items epoch > 0 then .open
  else if hasCurrent items epoch then .allCompleted
  else .none

def mentioned (c : String) : List String → Bool
  | []      => false
  | x :: xs => c == x || mentioned c xs

/-- Empty incoming is rejected; the list must not change. -/
def writeRejected (incoming : List String) : Bool :=
  incoming.isEmpty

example : classify [] 1 = .none := by native_decide
example : classify [{ content := "a", status := .completed, retired := true }] 1 = .none := by native_decide
example : classify [{ content := "a", status := .pending }] 1 = .open := by native_decide
example : classify [{ content := "a", status := .completed }] 1 = .allCompleted := by native_decide
example : classify [{ content := "a", status := .completed }, { content := "b", status := .pending }] 1 = .open := by native_decide
example : allDoneItems [] 1 = false := by native_decide
example : writeRejected [] = true := by native_decide
example : writeRejected ["a"] = false := by native_decide

end Graff.GoalLoop
