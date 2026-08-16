/-
  Goal / completion kernel (#318, #226, #394).

  This is *harness-done*, not *world-done*. `completionGate` says whether
  `attempt_completion` may be accepted. It does not say the work is correct.

  The checklist is collapsed to what the gate actually reads: none / open /
  all-completed. Empty is none, never done.

  Process kernel, not a Turing machine (finite `Event` / `step`, no tape).
  The 360-cell cube is the snapshot of that machine: refuse arms, a second
  attempt accepts, standing has no retire edge, and `checklistFinished` is
  unreachable without `write allCompleted`. GoalLoop is the worked example;
  cube kernels stay cubes.

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
deriving Repr, BEq, DecidableEq

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

/-! The machine. Snapshot predicates above; these are the edges. -/

/-- Discrete harness actions. Seat is configuration, not an event.
    Empty `todo_write` is `write .none` and is a no-op. World-done is not here. -/
inductive Event where
  | setGoal (standing : Bool)
  | pause
  | resume
  | clear
  | write (c : Checklist)
  | attempt
deriving DecidableEq, Repr, BEq

/-- Live work being replaced. Complete/none adopt the current checklist. -/
def liveGoal : Goal → Bool
  | .active | .paused | .blocked => true
  | .none | .complete => false

def setActive (s : State) (standing : Bool) (reset : Bool) : State :=
  if reset then
    { seat := s.seat, goal := Goal.active, standing := standing, checklist := Checklist.none, dirty := false, armed := false }
  else
    { s with goal := Goal.active, standing := standing, armed := false }

def step (s : State) (e : Event) : State :=
  match e with
  | Event.setGoal standing => setActive s standing (liveGoal s.goal)
  | Event.pause => if decide (s.goal = Goal.active) then { s with goal := Goal.paused } else s
  | Event.resume => if decide (s.goal = Goal.paused) then { s with goal := Goal.active } else s
  | Event.clear => { seat := s.seat, goal := Goal.none, standing := false, checklist := Checklist.none, dirty := false, armed := false }
  | Event.write c => if decide (c = Checklist.none) then s else { s with checklist := c, dirty := true, armed := false }
  | Event.attempt =>
      match completionGate s with
      | Verdict.refuseOpen => { s with armed := true }
      | Verdict.refuseNoPlan => { s with armed := true }
      | Verdict.accept =>
          if retiresOnAccept s then { s with armed := false, goal := Goal.complete } else { s with armed := false }

def run (s : State) : List Event → State
  | []      => s
  | e :: es => run (step s e) es

def writesDone : Event → Bool
  | Event.write .allCompleted => true
  | _                         => false

def noDoneWrite : List Event → Bool
  | []      => true
  | e :: es => !writesDone e && noDoneWrite es

/-! Missing-edge / path facts. Same propositions as the snapshot theorems. -/

theorem write_none_id (s : State) : step s (.write .none) = s := by
  simp [step]

theorem write_open_never_finished (s : State) :
    checklistFinished (step s (.write .open)) = false := by
  simp [step, checklistFinished, allDone]

theorem standing_attempt_preserves_goal (s : State) (h : s.standing = true) :
    (step s .attempt).goal = s.goal := by
  simp [step]
  cases completionGate s <;> simp [standing_does_not_retire s h]

theorem sub_attempt_preserves_goal (s : State) (h : s.seat = .sub) :
    (step s .attempt).goal = s.goal := by
  have hg : completionGate s = .accept := sub_never_refuses s h
  have hr : retiresOnAccept s = false := by simp [retiresOnAccept, goalActive, h]
  simp [step, hg, hr]

theorem review_attempt_preserves_goal (s : State) (h : s.seat = .review) :
    (step s .attempt).goal = s.goal := by
  have hg : completionGate s = .accept := review_never_refuses s h
  have hr : retiresOnAccept s = false := by simp [retiresOnAccept, goalActive, h]
  simp [step, hg, hr]

theorem paused_attempt_preserves_goal (s : State) (h : s.goal = .paused) :
    (step s .attempt).goal = s.goal := by
  have hg : completionGate s = .accept := paused_never_refuses s h
  have hr : retiresOnAccept s = false := by simp [retiresOnAccept, goalActive, h]
  simp [step, hg, hr]

theorem refuse_arms (s : State)
    (h : completionGate s = .refuseOpen ∨ completionGate s = .refuseNoPlan) :
    (step s .attempt).armed = true ∧ (step s .attempt).goal = s.goal := by
  cases h with
  | inl h => simp [step, h]
  | inr h => simp [step, h]

theorem attempt_keeps_list (s : State) :
    (step s .attempt).checklist = s.checklist ∧
      (step s .attempt).dirty = s.dirty := by
  simp [step]
  cases completionGate s <;> simp
  split <;> simp

theorem setGoal_preserves_unfinished (s : State) (standing : Bool)
    (h0 : checklistFinished s = false) :
    checklistFinished (step s (.setGoal standing)) = false := by
  simp [step, setActive]
  cases liveGoal s.goal
  · simpa [checklistFinished] using h0
  · simp [checklistFinished, allDone]

theorem unfinished_step (s : State) (e : Event)
    (h0 : checklistFinished s = false) (hw : writesDone e = false) :
    checklistFinished (step s e) = false := by
  cases e with
  | setGoal b => exact setGoal_preserves_unfinished s b h0
  | pause =>
      simp [step]
      split <;> simpa [checklistFinished] using h0
  | resume =>
      simp [step]
      split <;> simpa [checklistFinished] using h0
  | clear => simp [step, checklistFinished, allDone]
  | write c =>
      match c with
      | .none => simpa [write_none_id] using h0
      | .open => simp [step, checklistFinished, allDone]
      | .allCompleted => simp [writesDone] at hw
  | attempt =>
      have k := attempt_keeps_list s
      simp [checklistFinished] at h0 ⊢
      rw [k.1, k.2]; exact h0

theorem no_done_write_never_finished (s : State) (es : List Event)
    (h0 : checklistFinished s = false) (hw : noDoneWrite es = true) :
    checklistFinished (run s es) = false := by
  induction es generalizing s with
  | nil => simpa [run] using h0
  | cons e rest ih =>
      simp only [run]
      cases hwe : writesDone e
      · have hr : noDoneWrite rest = true := by
          simp [noDoneWrite, hwe] at hw; exact hw
        exact ih (step s e) (unfinished_step s e h0 hwe) hr
      · simp [noDoneWrite, hwe] at hw

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

/-! Traces of `step`. Double-check = refuse then accept; standing has no retire. -/

example : (run {} [.setGoal false, .attempt]).armed = true := by native_decide
example : (run {} [.setGoal false, .attempt]).goal = .active := by native_decide
example : (run {} [.setGoal false, .attempt, .attempt]).goal = .complete := by native_decide
example : (run {} [.setGoal true, .attempt, .attempt]).goal = .active := by native_decide
example : (run {} [.setGoal false, .write .allCompleted, .attempt]).goal = .complete := by native_decide
example : (run {} [.setGoal true, .write .allCompleted, .attempt]).goal = .active := by native_decide
example : checklistFinished (run {} [.setGoal false, .write .open, .attempt]) = false := by native_decide

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
