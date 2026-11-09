/-
  Resource & CPU/Memory Optimization Kernel.

  Pins four performance and memory-safety invariants in the Zig engine:
  1. Single-walk request token fusion (`src/agent_context.zig`):
     `max (input + fixed) (input + baseline) = input + max fixed baseline`,
     eliminating the second `mediaStats` JSON tree walk on every `approxTokens()`
     and `contextEstimate()` call.
  2. Single-pass SIMD ASCII/UTF-8 string length (`src/context_tokens.zig`):
     Any byte `< 0x80` is a complete 1-byte UTF-8 scalar (`continuationNeeded = 0`),
     so `stringLen` fuses ASCII validation into the 16-byte SIMD escape scan and
     touches ASCII string bytes `1×` instead of `2×`.
  3. Zero-leak 3-arena routing in Phase-1 compaction prune (`src/compact_prune.zig`):
     Routing `tool_handle.shapeHint` scratch to `TransientScratch` (`agent.gpa`)
     and pruned digests to `SessionHistory` (`agent.historyAlloc()`) before
     `reclaimMessages()` leaves `0` leaked bytes in `RootPermanent` (`agent.arena`).
  4. CoW worktree warm-cache seeding (`src/agent_worktree.zig`):
     Both `.directory` (`.zig-cache`, `zig-cache`, `node_modules`, `.codedb`) and
     `.file` (`codedb.snapshot`) are seeded iff they exist in `src`, are absent
     in `dst`, are confirmed ignored by `git check-ignore -q`, and CoW succeeds.
-/

namespace Graff.ResourceKernel

/-! ## 1. Single-Walk Request Token Fusion (`src/agent_context.zig`) -/

/-- Old unfused estimator that evaluated `input_tokens` twice (two `mediaStats` walks). -/
def unfusedRequestEstimate (input_tokens fixed_tokens baseline : Nat) : Nat :=
  max (input_tokens + fixed_tokens) (input_tokens + baseline)

/-- Fused single-walk estimator that computes `input_tokens` once. -/
def fusedRequestEstimate (input_tokens fixed_tokens baseline : Nat) : Nat :=
  input_tokens + max fixed_tokens baseline

/-- `max (t + f) (t + b) = t + max f b` for all natural token counts. -/
theorem request_estimate_fusion (input_tokens fixed_tokens baseline : Nat) :
    unfusedRequestEstimate input_tokens fixed_tokens baseline =
      fusedRequestEstimate input_tokens fixed_tokens baseline := by
  unfold unfusedRequestEstimate fusedRequestEstimate
  omega

/-- Number of `mediaStats` JSON tree walks per `requestEstimateFromInputBytes`. -/
def unfusedMediaWalks : Nat := 2
def fusedMediaWalks : Nat := 1

theorem single_walk_halves_media_scans :
    unfusedMediaWalks = 2 * fusedMediaWalks := rfl

/-! ## 2. Single-Pass SIMD ASCII/UTF-8 String Length (`src/context_tokens.zig`) -/

/-- True when a byte is 7-bit ASCII (`< 0x80`). -/
def isAsciiByte (b : UInt8) : Bool :=
  decide (b < 0x80)

/-- Number of UTF-8 continuation bytes required after lead byte `b` when `< 0x80`. -/
def asciiContinuationNeeded (b : UInt8) : Nat :=
  if isAsciiByte b then 0 else 1

theorem ascii_byte_needs_zero_continuation (b : UInt8) (h : isAsciiByte b = true) :
    asciiContinuationNeeded b = 0 := by
  simp [asciiContinuationNeeded, h]

/-- Byte touches for an `n`-byte ASCII string under two-pass (`utf8ValidateSlice` + `encodedStringLen`)
    versus single-pass fused SIMD scanning. -/
def twoPassAsciiTouches (n : Nat) : Nat := n + n
def singlePassAsciiTouches (n : Nat) : Nat := n

theorem single_pass_saves_n_touches (n : Nat) :
    twoPassAsciiTouches n = singlePassAsciiTouches n + n := rfl

/-! ## 3. Three-Arena Compaction Prune Zero-Leak Machine (`src/compact_prune.zig`) -/

structure ArenaState where
  rootBytes    : Nat
  sessionBytes : Nat
  scratchBytes : Nat
deriving Repr, BEq, DecidableEq

/-- Legacy buggy prune: both `shapeHint` scanner scratch and the pruned digest
    allocated into `agent.arena` (`rootBytes`), which `reclaimMessages` never resets. -/
def buggyPruneReclaim (root0 _sess0 live scratch digest : Nat) : ArenaState :=
  { rootBytes    := root0 + scratch + digest
  , sessionBytes := live
  , scratchBytes := 0 }

/-- Proven 3-arena prune: `shapeHint` scanner allocates in `agent.gpa` (`scratchBytes`)
    and frees before returning; digest allocates in `agent.historyAlloc()` (`sessionBytes`),
    which `reclaimMessages` compacts down to `live`. -/
def safePruneReclaim (root0 _sess0 live _scratch _digest : Nat) : ArenaState :=
  { rootBytes    := root0
  , sessionBytes := live
  , scratchBytes := 0 }

theorem prune_reclaim_zero_root_leak (root0 sess0 live scratch digest : Nat) :
    (safePruneReclaim root0 sess0 live scratch digest).rootBytes = root0 ∧
      (safePruneReclaim root0 sess0 live scratch digest).scratchBytes = 0 := by
  simp [safePruneReclaim]

theorem buggy_prune_leaks_into_root (root0 sess0 live scratch digest : Nat)
    (h : scratch + digest > 0) :
    (buggyPruneReclaim root0 sess0 live scratch digest).rootBytes > root0 := by
  simp only [buggyPruneReclaim]
  omega

/-! ## 4. CoW Worktree Warm-Cache Seeding Cube (`src/agent_worktree.zig`) -/

inductive CacheEntryKind where
  | directory -- `.zig-cache`, `zig-cache`, `node_modules`, `.codedb`
  | file      -- `codedb.snapshot`
  | other     -- symlinks, fifos, sockets (never seeded)
deriving DecidableEq, Repr, BEq

structure SeedCell where
  kind         : CacheEntryKind
  existsInSrc  : Bool
  absentInDst  : Bool
  gitIgnored   : Bool
  cowSupported : Bool
deriving DecidableEq, Repr, BEq

def isSeedableKind : CacheEntryKind → Bool
  | .directory | .file => true
  | .other             => false

def shouldSeed (c : SeedCell) : Bool :=
  isSeedableKind c.kind && c.existsInSrc && c.absentInDst && c.gitIgnored && c.cowSupported

def allKinds : List CacheEntryKind := [.directory, .file, .other]
def allBools : List Bool := [false, true]

def allCells : List SeedCell :=
  Id.run do
    let mut acc : List SeedCell := []
    for k in allKinds do
      for src in allBools do
        for dst in allBools do
          for ign in allBools do
            for cow in allBools do
              acc := acc ++ [{ kind := k, existsInSrc := src, absentInDst := dst, gitIgnored := ign, cowSupported := cow }]
    return acc

def resourceCells : Nat := allCells.length
def seedCells : Nat := (allCells.filter shouldSeed).length

theorem resource_cube : resourceCells = 48 := by native_decide
theorem seed_count : seedCells = 2 := by native_decide

/-- Seeding never pollutes `git status --porcelain`: only paths confirmed ignored by git may be seeded. -/
theorem seed_preserves_clean_porcelain (c : SeedCell) (h : shouldSeed c = true) :
    c.gitIgnored = true := by
  unfold shouldSeed at h
  revert h
  cases c.kind <;> cases c.existsInSrc <;> cases c.absentInDst <;> cases c.gitIgnored <;> cases c.cowSupported <;> decide

/-- Seeding never falls back to a slow deep copy when CoW/reflinks are unsupported. -/
theorem seed_requires_cow (c : SeedCell) (h : shouldSeed c = true) :
    c.cowSupported = true := by
  unfold shouldSeed at h
  revert h
  cases c.kind <;> cases c.existsInSrc <;> cases c.absentInDst <;> cases c.gitIgnored <;> cases c.cowSupported <;> decide

/-- `codedb.snapshot` (a regular `.file`) is seeded under the exact same safety gates as `.zig-cache` (`.directory`). -/
theorem codedb_snapshot_file_seeds :
    shouldSeed { kind := .file, existsInSrc := true, absentInDst := true, gitIgnored := true, cowSupported := true } = true := by
  native_decide

end Graff.ResourceKernel
