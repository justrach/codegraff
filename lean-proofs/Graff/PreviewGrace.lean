namespace Graff.PreviewGrace

structure Empty where
  timestamp : Nat
  listeners : Nat

structure Grace where
  first : Nat := 0
  last : Nat := 0
  listeners : Nat := 0

/-- Mirrors the positive timestamp state in src/preview_consumers.zig. -/
def observe (state : Grace) (snapshot : Option Empty) (period : Nat) : Grace × Bool :=
  match snapshot with
  | none => ({}, false)
  | some current =>
    let first := if state.last == 0 || state.listeners != current.listeners ||
      current.timestamp < state.last || current.timestamp - state.last > 10000
      then current.timestamp else state.first
    (⟨first, current.timestamp, current.listeners⟩,
      period != 0 && current.timestamp - first ≥ period)

theorem changedListenerMustWait (state : Grace) (now listeners period : Nat)
    (different : state.listeners ≠ listeners) :
    (observe state (some ⟨now, listeners⟩) period).2 = false := by
  cases period <;> simp [observe, different]

theorem unknownClearsGrace (state : Grace) (period : Nat) :
    observe state none period = ({}, false) := rfl

def exampleTrace : List (Option Empty) :=
  [some ⟨10000, 1⟩, some ⟨13000, 1⟩, some ⟨15000, 2⟩,
   some ⟨17000, 2⟩, none, some ⟨21000, 2⟩, some ⟨26000, 2⟩]

def outcomes (state : Grace) : List (Option Empty) → List Char
  | [] => []
  | observation :: rest =>
    let (next, expire) := observe state observation 4000
    (if expire then 'T' else 'F') :: outcomes next rest

def table : String := String.ofList (outcomes {} exampleTrace) ++ "\n"

end Graff.PreviewGrace
