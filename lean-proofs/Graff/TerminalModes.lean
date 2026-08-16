/-
  Terminal-mode lifecycle (the tuiguard invariant, grok-build's ModeTracker
  as a kernel): a TUI session is a stream of DEC private-mode ops and kitty
  keyboard pushes/pops; restore must return every mode to the TERMINAL
  DEFAULT and the kitty depth to zero, with the alt-screen leave (1049)
  ordered last so nothing paints on the user's real screen.

  Modes 7 (autowrap) and 25 (cursor visible) default ON — their restore
  direction is `set`, everything else restores by `reset`. Kitty pops floor
  at zero (grok-build floors the same way, so over-popping cannot go
  negative). The two concrete theorems at the bottom pin graff's ACTUAL
  enable/restore byte sequences (TUI/run.zig enable_seq, TUI/restore.zig
  seq) as op lists: their composition is balanced, and restore leaves the
  alt-screen last.

  Executable port: spec/ref/terminal_modes.py (also the semantics behind
  scripts/tui-pty-guard.py). Impl anchor: TUI/spec_terminal_modes_conformance.zig
  parses the real constants and diffs them against the fixture.
-/

namespace Graff.TerminalModes

inductive Op
  | set (n : Nat) | reset (n : Nat) | push | pop
deriving DecidableEq, Repr

def defaultOn : List Nat := [7, 25]

/-- Last-op-wins mode map plus the kitty push/pop depth (floored at 0). -/
def setFinal (m : List (Nat × Bool)) (n : Nat) (v : Bool) : List (Nat × Bool) :=
  (n, v) :: m.filter (fun p => p.1 ≠ n)

def step (s : List (Nat × Bool) × Nat) : Op → List (Nat × Bool) × Nat
  | .set n => (setFinal s.1 n true, s.2)
  | .reset n => (setFinal s.1 n false, s.2)
  | .push => (s.1, s.2 + 1)
  | .pop => (s.1, s.2 - 1)

def fold (ops : List Op) : List (Nat × Bool) × Nat := ops.foldl step ([], 0)

def isDefault (n : Nat) (v : Bool) : Bool := v == defaultOn.contains n

/-- Modes whose final state differs from the terminal default. -/
def deviations (m : List (Nat × Bool)) : List Nat :=
  (m.filter fun p => !isDefault p.1 p.2).map (·.1)

def balanced (ops : List Op) : Bool :=
  let (m, d) := fold ops
  (deviations m).isEmpty && d == 0

/-- Restore for a session: pop the kitty depth, flip every deviant mode back
    to its default, and leave the alt-screen (1049) LAST. -/
def restoreOps (ops : List Op) : List Op :=
  let (m, d) := fold ops
  let devs := deviations m
  let flips := (devs.filter (· ≠ 1049)).map fun n =>
    if defaultOn.contains n then Op.set n else Op.reset n
  let alt : List Op := if devs.contains 1049 then [.reset 1049] else []
  (List.replicate d .pop) ++ flips ++ alt

/-- graff's boot sequence (TUI/run.zig enable_seq) as ops, in byte order. -/
def graffEnable : List Op :=
  [.set 1049, .reset 25, .set 2004, .set 1000, .set 1003, .set 1006, .reset 7, .push]

/-- graff's restore sequence (TUI/restore.zig seq) as ops, in byte order.
    (The non-DEC `ESC[>4;0m` modifyOtherKeys reset carries no mode number
    and is outside this model, exactly as in the executable port.) -/
def graffRestore : List Op :=
  [.reset 2026, .pop, .set 7, .reset 1006, .reset 1003, .reset 1000, .reset 2004, .set 25, .reset 1049]

/-- Kitty pops floor at zero: over-popping can never underflow the depth. -/
theorem pop_floors : (fold [.pop, .pop, .push]).2 = 1 := by decide

/-- An untouched terminal is balanced (byte transparency's base case). -/
theorem empty_balanced : balanced [] = true := by decide

/-- THE lifecycle theorem, on the real sequences: booting graff's TUI and
    running its restore returns the terminal exactly to defaults. -/
theorem graff_lifecycle_balanced : balanced (graffEnable ++ graffRestore) = true := by decide

/-- The restore's final op leaves the alt-screen — nothing may paint after. -/
theorem graff_restore_alt_last : graffRestore.getLast? = some (.reset 1049) := by decide

/-- restore of a restored session is a no-op list (grok-build's
    byte-transparency e2e, as a theorem on the model). -/
theorem restore_idempotent :
    restoreOps (graffEnable ++ graffRestore) = [] := by decide

/-- The generated restore also balances the real boot state — the model's
    restoreOps and graff's committed sequence agree on the outcome. -/
theorem generated_restore_balances :
    balanced (graffEnable ++ restoreOps graffEnable) = true := by decide

end Graff.TerminalModes
