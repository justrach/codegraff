/-
  Prompt-prefix kernel (how the cache HIT is earned).

  PromptCache is the key/spawn machine: who emits `prompt_cache_key`,
  that a sub never spawns, that join restores the root partition.

  This kernel is the bytes that sit under that key. Codex's rule: the
  old prompt must be an exact prefix of the new one. Wording is out of
  Lean. The discrete axes are what kind of catalog rides in the prefix
  and whether it is pinned once.

  Names + triggers only. No bodies. No `file:` paths (they move when a
  plugin version changes and bust the first cache hash). Pin once at
  session start. `skill` load / list / rescan do not rewrite the prefix.

  Executable port: spec/ref/prompt_prefix.py.
-/

namespace Graff.PromptPrefix

/-- What may ride in the cached system-prompt prefix. -/
inductive Catalog where
  | namesOnly | withBodies | withPaths
deriving DecidableEq, Repr, BEq

/-- Rebuild-every-turn is how you bust the prefix. -/
inductive Pin where
  | once | everyRebuild
deriving DecidableEq, Repr, BEq

def prefixOk : Catalog → Bool
  | .namesOnly => true
  | .withBodies => false
  | .withPaths => false

def pinOk : Pin → Bool
  | .once => true
  | .everyRebuild => false

structure Cell where
  catalog : Catalog := .namesOnly
  pin     : Pin := .once
deriving Repr, BEq, DecidableEq

/-- The only cacheable cell: names + triggers, pinned once. -/
def cacheable (c : Cell) : Bool := prefixOk c.catalog && pinOk c.pin

def allCells : List Cell :=
  Id.run do
    let mut acc : List Cell := []
    for catalog in [Catalog.namesOnly, .withBodies, .withPaths] do
      for pin in [Pin.once, .everyRebuild] do
        acc := acc ++ [{ catalog, pin }]
    return acc

def prefixCells : Nat := allCells.length
def hitCells : Nat := (allCells.filter cacheable).length

theorem prefix_cube : prefixCells = 6 := by native_decide
theorem only_one_hit_cell : hitCells = 1 := by native_decide

theorem names_once_hits :
    cacheable { catalog := .namesOnly, pin := .once } = true := by native_decide

/-- Maximize iff the measured cell. The other five cells are the busts. -/
theorem maximize_iff (c : Cell) :
    cacheable c = true ↔ (c.catalog = .namesOnly ∧ c.pin = .once) := by
  cases c.catalog <;> cases c.pin <;> native_decide

theorem bodies_never_hit (p : Pin) :
    cacheable { catalog := .withBodies, pin := p } = false := by
  cases p <;> native_decide

theorem paths_never_hit (p : Pin) :
    cacheable { catalog := .withPaths, pin := p } = false := by
  cases p <;> native_decide

theorem rebuild_never_hits (c : Catalog) :
    cacheable { catalog := c, pin := .everyRebuild } = false := by
  cases c <;> native_decide

/-! The machine. Snapshot predicates above; these are the edges. -/

structure State where
  pinned        : Bool := false
  catalog       : Catalog := .namesOnly
  prefixFrozen  : Bool := false
deriving Repr, BEq, DecidableEq

inductive Event where
  | start (cat : Catalog)
  | skillLoad
  | skillList
  | rescan
  | turn
  | rebuildIntoPrefix (cat : Catalog)
deriving DecidableEq, Repr, BEq

def step (s : State) (e : Event) : State :=
  match e with
  | Event.start cat =>
      if s.pinned then s
      else { pinned := true, catalog := cat, prefixFrozen := true }
  | Event.skillLoad | Event.skillList | Event.rescan | Event.turn => s
  | Event.rebuildIntoPrefix cat =>
      if !s.pinned then { pinned := true, catalog := cat, prefixFrozen := true }
      else if decide (cat = s.catalog) then s
      else { s with catalog := cat, prefixFrozen := false }

def run (s : State) : List Event → State
  | []      => s
  | e :: es => run (step s e) es

def hitOk (s : State) : Bool :=
  s.prefixFrozen && prefixOk s.catalog && s.pinned

theorem start_pins (c : Catalog) :
    (step {} (.start c)).pinned = true ∧
      (step {} (.start c)).prefixFrozen = true ∧
      (step {} (.start c)).catalog = c := by
  simp [step]

theorem start_is_once (c d : Catalog) :
    step (step {} (.start c)) (.start d) = step {} (.start c) := by
  simp [step]

theorem skill_load_id (s : State) : step s .skillLoad = s := rfl
theorem skill_list_id (s : State) : step s .skillList = s := rfl
theorem rescan_id (s : State) : step s .rescan = s := rfl
theorem turn_id (s : State) : step s .turn = s := rfl

theorem skill_events_keep_prefix (c : Catalog) :
    let s := step {} (.start c)
    run s [.skillLoad, .skillList, .rescan, .turn] = s := by
  native_decide

/-- The live session: pin names-only, then skill/list/rescan/turn still HIT. -/
theorem maximizing_walk :
    hitOk (run {} [.start .namesOnly, .skillLoad, .skillList, .rescan, .turn]) = true := by
  native_decide

theorem names_start_hits :
    hitOk (step {} (.start .namesOnly)) = true := by native_decide

theorem paths_start_misses :
    hitOk (step {} (.start .withPaths)) = false := by native_decide

theorem rebuild_that_changes_busts :
    hitOk (run {} [.start .namesOnly, .rebuildIntoPrefix .withPaths]) = false := by
  native_decide

theorem rebuild_same_catalog_stays :
    hitOk (run {} [.start .namesOnly, .rebuildIntoPrefix .namesOnly]) = true := by
  native_decide

example : prefixOk .namesOnly = true := by native_decide
example : prefixOk .withBodies = false := by native_decide
example : pinOk .once = true := by native_decide
example : cacheable { catalog := .namesOnly, pin := .everyRebuild } = false := by native_decide
example : (step {} (.start .namesOnly)).prefixFrozen = true := by native_decide
example : step (step {} (.start .namesOnly)) .skillLoad = step {} (.start .namesOnly) := by native_decide

end Graff.PromptPrefix
