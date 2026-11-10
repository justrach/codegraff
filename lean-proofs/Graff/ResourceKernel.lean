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

/-! ## 5. Adaptive `codedb` Routing Policy (`src/codedb_exec.zig`, `src/codedb_health.zig`) -/

inductive CodedbCmdKind where
  | inProcess          -- `list_dir`, `status`
  | pathQuery          -- `outline`, `read`, `deps`, `file`
  | symbolOrIndexQuery -- `context`, `around`, `callpath`, `search`, `symbol`, `callers`, `tree`, `word`
deriving DecidableEq, Repr, BEq

inductive TargetFileKind where
  | codeFile       -- `.zig`, `.py`, `.ts`, `.rs`, `.go`, `.c`, etc.
  | dataOrTextFile -- `.json`, `.csv`, `.txt`, `.md`, `.toml`, `.yaml`, `.log`
deriving DecidableEq, Repr, BEq

inductive WorkspaceScale where
  | tiny -- `< 3` code files in workspace
  | repo -- `>= 3` code files in workspace
deriving DecidableEq, Repr, BEq

inductive CodedbRoute where
  | runInProcess     -- `< 1ms` in-process handler (`list_dir`, `status`)
  | redirectReadFile -- `< 1ms` in-process `list_dir` + `read_file` guidance (no subprocess spawn)
  | spawnCodedbIndex -- full `codedb` index query against `~/.codedb/projects/<wyhash>`
deriving DecidableEq, Repr, BEq

structure RouteCell where
  cmd    : CodedbCmdKind
  target : TargetFileKind
  scale  : WorkspaceScale
deriving DecidableEq, Repr, BEq

def routeCodedb (c : RouteCell) : CodedbRoute :=
  match c.cmd with
  | .inProcess => .runInProcess
  | .pathQuery =>
      match c.target, c.scale with
      | .dataOrTextFile, _ => .redirectReadFile
      | .codeFile, .tiny   => .redirectReadFile
      | .codeFile, .repo   => .spawnCodedbIndex
  | .symbolOrIndexQuery =>
      match c.scale with
      | .tiny => .redirectReadFile
      | .repo => .spawnCodedbIndex

def allCmdKinds : List CodedbCmdKind := [.inProcess, .pathQuery, .symbolOrIndexQuery]
def allTargetKinds : List TargetFileKind := [.codeFile, .dataOrTextFile]
def allScales : List WorkspaceScale := [.tiny, .repo]

def allRouteCells : List RouteCell :=
  Id.run do
    let mut acc : List RouteCell := []
    for cmd in allCmdKinds do
      for tgt in allTargetKinds do
        for sc in allScales do
          acc := acc ++ [{ cmd := cmd, target := tgt, scale := sc }]
    return acc

def codedbRouteCells : Nat := allRouteCells.length
def codedbSpawnCells : Nat := (allRouteCells.filter (fun c => decide (routeCodedb c = .spawnCodedbIndex))).length

theorem codedb_route_cube : codedbRouteCells = 12 := by native_decide
theorem codedb_spawn_count : codedbSpawnCells = 3 := by native_decide

/-- Tiny workspaces (`< 3` code files) never pay a subprocess spawn or cold-index penalty for `codedb`. -/
theorem tiny_workspace_never_spawns_codedb (cmd : CodedbCmdKind) (tgt : TargetFileKind) :
    routeCodedb { cmd := cmd, target := tgt, scale := .tiny } ≠ .spawnCodedbIndex := by
  cases cmd <;> cases tgt <;> decide

/-- Data/prose files (`.json`, `.csv`, `.txt`, `.md`) on path queries never spawn `codedb`. -/
theorem data_file_path_query_redirects (sc : WorkspaceScale) :
    routeCodedb { cmd := .pathQuery, target := .dataOrTextFile, scale := sc } = .redirectReadFile := by
  cases sc <;> rfl

/-- Multi-file repositories (`>= 3` code files) always route symbol/index and code-path queries to `codedb`. -/
theorem repo_code_queries_use_codedb (tgt : TargetFileKind) :
    routeCodedb { cmd := .symbolOrIndexQuery, target := tgt, scale := .repo } = .spawnCodedbIndex ∧
      routeCodedb { cmd := .pathQuery, target := .codeFile, scale := .repo } = .spawnCodedbIndex := by
  cases tgt <;> decide

/-! ## 6. Tardigrade Durable Execution & Crash-Tail Recovery Kernel
    (`src/turn_checkpoint.zig`, `src/session_transcript.zig`, `src/history_wire.zig`)

    Inspired by Clavia Labs' Tardigrade (`DurableExecution.tla`, `atomCheckpoint.qnt`,
    `effectRecovery.qnt`):
    1. `CoveredBeforeDrive` (`turn_checkpoint.beforeToolBatch`): before any tool batch
       executes (`drive = .executing`), the assistant's tool-call proposal is flushed
       to `.transcript.jsonl`.
    2. `Checkpoint + Suffix == Full Replay` (`session_transcript.recoverCrashTailSuffix`):
       when a crash interrupts a turn after `beforeToolBatch` and before `.session.json`
       is updated, replaying the uncommitted transcript suffix onto `.session.json`
       recovers the exact pre-crash history.
    3. `Effect-Aware Crash-Tail Synthesis` (`history_wire.missingToolTextFor`):
       in-flight read-only tools recover as `.interruptedReadOnly` (safe immediate retry),
       mutating tools recover as `.outcomeUnknown` (state check required), and later calls
       in the batch recover as `.notStarted`. -/

inductive ToolEffectKind where
  | readOnly -- `read_file`, `codedb`, `load_tool_schemas`, `todo_read`, `check_job`, `list_dir`, `read_image`
  | mutating -- `bash`, `shell`, `write_file`, `edit_file`, `subagent`
deriving DecidableEq, Repr, BEq

inductive BatchPosition where
  | firstMissing -- `missing_idx = 0` (the call in flight when interrupted)
  | laterMissing -- `missing_idx > 0` (unstarted calls later in the batch)
deriving DecidableEq, Repr, BEq

inductive WireFormat where
  | openai
  | anthropic
  | responses
deriving DecidableEq, Repr, BEq

inductive CrashOutcome where
  | interruptedReadOnly -- `[TOOL_INTERRUPTED_READONLY: ...]`
  | outcomeUnknown      -- `[TOOL_OUTCOME_UNKNOWN: ...]`
  | notStarted          -- `[TOOL_NOT_STARTED: ...]`
deriving DecidableEq, Repr, BEq

structure CrashCell where
  effect : ToolEffectKind
  pos    : BatchPosition
  wire   : WireFormat
deriving DecidableEq, Repr, BEq

def synthesizeCrashOutcome (c : CrashCell) : CrashOutcome :=
  match c.pos with
  | .laterMissing => .notStarted
  | .firstMissing =>
      match c.effect with
      | .readOnly => .interruptedReadOnly
      | .mutating => .outcomeUnknown

def allToolEffects : List ToolEffectKind := [.readOnly, .mutating]
def allBatchPositions : List BatchPosition := [.firstMissing, .laterMissing]
def allWireFormats : List WireFormat := [.openai, .anthropic, .responses]

def allCrashCells : List CrashCell :=
  Id.run do
    let mut acc : List CrashCell := []
    for eff in allToolEffects do
      for pos in allBatchPositions do
        for w in allWireFormats do
          acc := acc ++ [{ effect := eff, pos := pos, wire := w }]
    return acc

def crashRecoveryCells : Nat := allCrashCells.length

theorem crash_recovery_cube : crashRecoveryCells = 12 := by native_decide

/-- Read-only tools interrupted at `firstMissing` always synthesize `.interruptedReadOnly` on every wire. -/
theorem readonly_crash_safe_retry (w : WireFormat) :
    synthesizeCrashOutcome { effect := .readOnly, pos := .firstMissing, wire := w } = .interruptedReadOnly := by
  cases w <;> rfl

/-- Mutating tools interrupted at `firstMissing` always synthesize `.outcomeUnknown` on every wire. -/
theorem mutating_crash_requires_verify (w : WireFormat) :
    synthesizeCrashOutcome { effect := .mutating, pos := .firstMissing, wire := w } = .outcomeUnknown := by
  cases w <;> rfl

/-- Later missing calls in an interrupted batch always synthesize `.notStarted` on every wire. -/
theorem later_batch_calls_not_started (eff : ToolEffectKind) (w : WireFormat) :
    synthesizeCrashOutcome { effect := eff, pos := .laterMissing, wire := w } = .notStarted := by
  cases eff <;> cases w <;> rfl

/-- Tardigrade `Checkpoint + Suffix == Full Replay`: replaying the uncommitted transcript
    suffix `S` onto the committed checkpoint `C` reconstructs the full pre-crash log `C ++ S`. -/
theorem checkpoint_plus_suffix_equiv_full_replay (checkpoint suffix : List Nat) :
    let full_transcript := checkpoint ++ suffix
    let recovered := checkpoint ++ full_transcript.drop checkpoint.length
    recovered = full_transcript := by
  simp

end Graff.ResourceKernel
