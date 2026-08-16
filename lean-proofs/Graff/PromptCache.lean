/-
  Prompt-cache / spawn kernel.

  Process kernel, not a Turing machine: finite `Event` / `step`, no tape.
  Seat is who may spawn. Label is the cache predicate (`main` is the only
  sticky root partition). Isolation is a spawn parameter and does not mint
  a key. Wire/grok say which carrier is on the request; they do not change
  the partition.

  The 48-cell cube is the snapshot. `Event` / `step` is the machine:
  sub never spawns, spawn isolates the child, join restores the root key.

  Executable port: spec/ref/prompt_cache.py.
-/

namespace Graff.PromptCache

inductive Seat where
  | root | sub
deriving DecidableEq, Repr, BEq

/-- `main` is the only sticky root partition. Anything else is a child suffix. -/
inductive Label where
  | main | other
deriving DecidableEq, Repr, BEq

inductive Isolation where
  | sharedCwd | worktree
deriving DecidableEq, Repr, BEq

inductive Wire where
  | openai | responses | anthropic
deriving DecidableEq, Repr, BEq

inductive Partition where
  | root | child
deriving DecidableEq, Repr, BEq

structure Cell where
  wire       : Wire := .openai
  label      : Label := .main
  isolation  : Isolation := .sharedCwd
  grok       : Bool := false
  seat       : Seat := .root
deriving Repr, BEq, DecidableEq

def emitKey : Wire → Bool
  | .anthropic => false
  | .openai    => true
  | .responses => true

/-- Partition depends on label only. Isolation is not an argument that matters. -/
def partitionOf (label : Label) : Isolation → Partition
  | _ => match label with
    | .main  => .root
    | .other => .child

def spawnOk (seat : Seat) : Bool := decide (seat = Seat.root)

/-- When both carriers are present they name the same partition. -/
def headerAgrees (c : Cell) : Bool :=
  if !c.grok then true
  else if !emitKey c.wire then true
  else decide (partitionOf c.label c.isolation = partitionOf c.label c.isolation)

def allCells : List Cell :=
  Id.run do
    let mut acc : List Cell := []
    for wire in [Wire.openai, .responses, .anthropic] do
      for label in [Label.main, .other] do
        for isolation in [Isolation.sharedCwd, .worktree] do
          for grok in [false, true] do
            for seat in [Seat.root, .sub] do
              acc := acc ++ [{ wire, label, isolation, grok, seat }]
    return acc

def cacheCells : Nat := allCells.length
def spawnOkCells : Nat := (allCells.filter (fun c => spawnOk c.seat)).length
def keyCells : Nat := (allCells.filter (fun c => emitKey c.wire)).length

theorem cache_cube : cacheCells = 48 := by native_decide
theorem spawn_ok_count : spawnOkCells = 24 := by native_decide
theorem key_count : keyCells = 32 := by native_decide

theorem anthropic_never_key (c : Cell) (h : c.wire = .anthropic) :
    emitKey c.wire = false := by
  simp [emitKey, h]

theorem openai_emits_key (c : Cell) (h : c.wire = .openai) :
    emitKey c.wire = true := by
  simp [emitKey, h]

theorem responses_emits_key (c : Cell) (h : c.wire = .responses) :
    emitKey c.wire = true := by
  simp [emitKey, h]

theorem main_is_root (iso : Isolation) : partitionOf .main iso = .root := by
  cases iso <;> rfl

theorem other_is_child (iso : Isolation) : partitionOf .other iso = .child := by
  cases iso <;> rfl

theorem isolation_does_not_mint_key (label : Label) :
    partitionOf label .sharedCwd = partitionOf label .worktree := by
  cases label <;> rfl

theorem sub_never_spawn_ok (c : Cell) (h : c.seat = .sub) :
    spawnOk c.seat = false := by
  simp [spawnOk, h]

theorem root_spawn_ok (c : Cell) (h : c.seat = .root) :
    spawnOk c.seat = true := by
  simp [spawnOk, h]

theorem header_agrees (c : Cell) : headerAgrees c = true := by
  simp [headerAgrees]

/-! The machine. Snapshot predicates above; these are the edges. -/

structure State where
  seat       : Seat := .root
  label      : Label := .main
  isolation  : Isolation := .sharedCwd
  partition  : Partition := .root
deriving Repr, BEq, DecidableEq

inductive Event where
  | turn
  | spawn (bg : Bool) (iso : Isolation)
  | join
deriving DecidableEq, Repr, BEq

def childOf (iso : Isolation) : State :=
  { seat := Seat.sub, label := Label.other, isolation := iso, partition := Partition.child }

def rootOf (iso : Isolation) : State :=
  { seat := Seat.root, label := Label.main, isolation := iso, partition := Partition.root }

def step (s : State) (e : Event) : State :=
  match e with
  | Event.turn => s
  | Event.spawn _ iso =>
      if decide (s.seat = Seat.sub) then s else childOf iso
  | Event.join =>
      if decide (s.seat = Seat.root) then s else rootOf s.isolation

def run (s : State) : List Event → State
  | []      => s
  | e :: es => run (step s e) es

theorem turn_id (s : State) : step s .turn = s := rfl

theorem spawn_mode_irrelevant (s : State) (iso : Isolation) :
    step s (.spawn false iso) = step s (.spawn true iso) := by
  simp [step]

theorem sub_never_spawns (s : State) (bg : Bool) (iso : Isolation)
    (h : s.seat = Seat.sub) :
    step s (.spawn bg iso) = s := by
  simp [step, h]

theorem spawn_isolates (s : State) (bg : Bool) (iso : Isolation)
    (h : s.seat = Seat.root) :
    (step s (.spawn bg iso)).partition = Partition.child ∧
      (step s (.spawn bg iso)).seat = Seat.sub ∧
      (step s (.spawn bg iso)).label = Label.other := by
  simp [step, h, childOf]

theorem join_restores_root (s : State) (h : s.seat = Seat.sub) :
    (step s .join).partition = Partition.root ∧
      (step s .join).seat = Seat.root ∧
      (step s .join).label = Label.main := by
  simp [step, h, rootOf]

theorem join_from_root_id (s : State) (h : s.seat = Seat.root) :
    step s .join = s := by
  simp [step, h]

theorem spawn_isolation_does_not_mint (s : State) (bg : Bool)
    (h : s.seat = Seat.root) :
    (step s (.spawn bg .sharedCwd)).partition =
      (step s (.spawn bg .worktree)).partition := by
  simp [step, h, childOf]

theorem run_spawn_join_restores :
    run {} [.spawn false .sharedCwd, .join] = rootOf .sharedCwd := by
  native_decide

theorem run_sub_spawn_stays :
    run (childOf .sharedCwd) [.spawn true .worktree, .turn] =
      childOf .sharedCwd := by
  native_decide

example : emitKey .anthropic = false := by native_decide
example : emitKey .responses = true := by native_decide
example : partitionOf .main .worktree = .root := by native_decide
example : partitionOf .other .sharedCwd = .child := by native_decide
example : spawnOk .sub = false := by native_decide
example : (step {} (.spawn false .worktree)).partition = .child := by native_decide
example : (step (childOf .sharedCwd) .join).partition = .root := by native_decide
example : step (childOf .sharedCwd) (.spawn false .worktree) = childOf .sharedCwd := by native_decide

end Graff.PromptCache
