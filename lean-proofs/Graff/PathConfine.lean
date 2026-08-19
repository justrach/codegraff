/-
  Path / lease kernel.

  Process kernel, not a Turing machine: finite `Event` / `step`, no tape.
  File tools walk path components (`confinedPath`) and then refuse any
  symlink prefix (`noSymlinkEscape`). `--yolo` does not lift either rule.
  The worktree lease is a separate finite verdict (`ownerVerdict`).

  The 16 lexical paths + 80 lease cells are the snapshot. `Event` / `step`
  is the walk: Empty / Safe / Escaped / Absolute. Escaped and Absolute
  absorb — a subagent does not recover a jail break by taking another
  component. Fleet topology is not a Shape cell; this is the machine
  every child file-tool is forced through.

  Not modelled: OS errno, Windows drive letters, live `/proc` reads.
  Executable port: spec/ref/path_confine.py.
-/

namespace Graff.PathConfine

def slashParts (p : String) : List String :=
  (p.splitOn "/").filter (· ≠ "")

def components (p : String) : List String :=
  slashParts (p.replace "\\" "/")

def confined (p : String) : Bool :=
  if p.isEmpty then false
  else if p.startsWith "/" then false
  else !(components p).contains ".."

def prefixes (p : String) : List String :=
  let rec go (acc : List String) (seen : String) : List String → List String
    | [] => acc
    | c :: cs =>
      let next := if seen.isEmpty then c else seen ++ "/" ++ c
      go (acc ++ [next]) next cs
  go [] "" (slashParts p)

def symlinkSafe (p : String) (links : List String) : Bool :=
  (prefixes p).all fun pre => !links.contains pre

def fileToolOk (p : String) (links : List String) : Bool :=
  confined p && symlinkSafe p links

def destructiveGitAllowed (yolo sub : Bool) : Bool :=
  yolo && !sub

inductive Identities where
  | bothEmpty | recEmpty | mineEmpty | same | differ
deriving DecidableEq, Repr, BEq

inductive Probe where
  | gone | match | mismatch | unknown
deriving DecidableEq, Repr, BEq

inductive OwnerVerdict where
  | self | otherWorktree | liveForeign | liveUnverified | staleDead | staleUnverifiable
deriving DecidableEq, Repr, BEq

structure Lease where
  identities : Identities := .same
  startZero  : Bool := false
  probe      : Probe := .match
  pidSelf    : Bool := false
deriving Repr, BEq

def ownerVerdict (l : Lease) : OwnerVerdict :=
  match l.identities with
  | .bothEmpty | .recEmpty | .mineEmpty => .staleUnverifiable
  | .differ => .otherWorktree
  | .same =>
    if l.startZero then .staleUnverifiable
    else match l.probe with
      | .gone => .staleDead
      | .mismatch => .staleDead
      | .match | .unknown =>
        if l.pidSelf then .self
        else if l.probe == .unknown then .liveUnverified
        else .liveForeign

def warns (v : OwnerVerdict) : Bool :=
  v == .liveForeign || v == .liveUnverified

def allLeases : List Lease :=
  Id.run do
    let mut acc : List Lease := []
    for identities in [Identities.bothEmpty, .recEmpty, .mineEmpty, .same, .differ] do
      for startZero in [false, true] do
        for probe in [Probe.gone, .match, .mismatch, .unknown] do
          for pidSelf in [false, true] do
            acc := acc ++ [{ identities, startZero, probe, pidSelf }]
    return acc

def leaseCells : Nat := allLeases.length
def warnCells : Nat := (allLeases.filter (fun l => warns (ownerVerdict l))).length

theorem lease_cube : leaseCells = 80 := by native_decide

example : confined "src/main.zig" = true := by native_decide
example : confined "" = false := by native_decide
example : confined "/etc/passwd" = false := by native_decide
example : confined "../outside" = false := by native_decide
example : confined "a/../../b" = false := by native_decide
example : confined "a/./b" = true := by native_decide
example : confined "..hidden" = true := by native_decide
example : confined "foo/.." = false := by native_decide

example : fileToolOk "src/a.zig" [] = true := by native_decide
example : fileToolOk "evil/passwd" ["evil"] = false := by native_decide
example : fileToolOk "/etc/passwd" [] = false := by native_decide

example : destructiveGitAllowed true false = true := by native_decide
example : destructiveGitAllowed true true = false := by native_decide
example : destructiveGitAllowed false false = false := by native_decide

example : ownerVerdict {} = .liveForeign := by native_decide
example : ownerVerdict { pidSelf := true } = .self := by native_decide
example : ownerVerdict { identities := .differ } = .otherWorktree := by native_decide
example : ownerVerdict { probe := .gone } = .staleDead := by native_decide
example : ownerVerdict { probe := .mismatch } = .staleDead := by native_decide
example : ownerVerdict { startZero := true } = .staleUnverifiable := by native_decide
example : ownerVerdict { probe := .unknown } = .liveUnverified := by native_decide
example : ownerVerdict { probe := .unknown, pidSelf := true } = .self := by native_decide
example : warns (ownerVerdict {}) = true := by native_decide
example : warns (ownerVerdict { probe := .gone }) = false := by native_decide

theorem yolo_does_not_free_sub (yolo : Bool) :
    destructiveGitAllowed yolo true = false := by
  simp [destructiveGitAllowed]

theorem empty_not_confined : confined "" = false := rfl

/-! The machine. Snapshot predicates above; these are the edges. -/

inductive Walk where
  | empty | safe | escaped | absolute
deriving DecidableEq, Repr, BEq

structure WalkState where
  walk : Walk := .empty
deriving Repr, BEq, DecidableEq

inductive Event where
  | startAbs
  | component (c : String)
deriving DecidableEq, Repr, BEq

def step (s : WalkState) (e : Event) : WalkState :=
  match e with
  | Event.startAbs =>
      if decide (s.walk = Walk.empty) then { walk := Walk.absolute } else s
  | Event.component c =>
      if decide (s.walk = Walk.absolute) then s
      else if decide (s.walk = Walk.escaped) then s
      else if c == ".." then { walk := Walk.escaped }
      else { walk := Walk.safe }

def run (s : WalkState) : List Event → WalkState
  | []      => s
  | e :: es => run (step s e) es

def confinedWalk (s : WalkState) : Bool := decide (s.walk = Walk.safe)

def eventsOf (p : String) : List Event :=
  let cs := (components p).map Event.component
  if p.startsWith "/" then Event.startAbs :: cs else cs

def walkPath (p : String) : WalkState := run {} (eventsOf p)

def samplePaths : List String :=
  ["", "src/main.zig", "a/b/c", "/etc/passwd", "../outside", "a/../../b",
   "a/./b", ".", "foo/..", "..", "..hidden", ".graff/settings.json",
   "a//b", "//etc/passwd", "foo\\..\\bar", "foo/bar/baz"]

def agrees (p : String) : Bool := confined p == confinedWalk (walkPath p)

theorem start_abs_from_empty :
    (step {} Event.startAbs).walk = Walk.absolute := rfl

theorem start_abs_not_from_safe (s : WalkState) (h : s.walk = Walk.safe) :
    step s Event.startAbs = s := by
  simp [step, h]

theorem start_abs_not_from_escaped (s : WalkState) (h : s.walk = Walk.escaped) :
    step s Event.startAbs = s := by
  simp [step, h]

theorem abs_absorbs (s : WalkState) (c : String) (h : s.walk = Walk.absolute) :
    step s (Event.component c) = s := by
  simp [step, h]

theorem escaped_absorbs (s : WalkState) (c : String) (h : s.walk = Walk.escaped) :
    step s (Event.component c) = s := by
  simp [step, h]

theorem empty_walk_not_confined : confinedWalk {} = false := by native_decide

theorem safe_is_confined : confinedWalk { walk := Walk.safe } = true := by native_decide

theorem walk_matches_snapshot : (samplePaths.all agrees) = true := by native_decide

end Graff.PathConfine
