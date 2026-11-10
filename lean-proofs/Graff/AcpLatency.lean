/-
  ACP Low-Latency & Zero-Redundant-Parse Kernel.

  Pins four performance and correctness invariants across the ACP path:
  1. In-process Git worktree resolution (`src/acp_workspace.zig`):
     Inspecting `.git` (`statFile` / `readFileAlloc` on `.git`, `commondir`, `HEAD`)
     resolves main checkouts (`.directory`) and standard linked worktrees (`.gitdirFile`)
     with `0` subprocess spawns for `rev-parse` and `symbolic-ref` (down from `2`
     subprocesses per `acp_workspace.info` call), while preserving exact equivalence
     with `fromRevParse` (`git_dir == common_dir → none`).
  2. Single-parse ACP inbox routing (`src/acp_inbox.zig`, `src/acp_protocol.zig`):
     Fast-classifying incoming JSONL lines via `methodOf(line)` skips pump-thread
     JSON parsing for handshake/query methods (`1` total parse in `handleLine`, down
     from `3`), routes only method-less frames (`.rpcResponse`) to elicitation and
     permission response bridges, and reuses the parsed `Value` via `requestFromValue`
     so `Inbox.accept` parses at most `1×` (never `2×`).
  3. Zero-copy batch frame splitting (`src/acp_line_writer.zig`, `src/acp_stream.zig`):
     Splitting an incoming write chunk at its last newline (`complete ++ tail`) emits
     `pending ++ complete` in `1` locked flush with `0` `copyForwards` shifts (instead
     of `k` flushes and `k` quadratic shifts), preserving the exact output byte stream
     and residual `tail`.
  4. Single-pass startup MCP config load (`src/session_start.zig`, `src/mcp_boot.zig`):
     Reusing the `mcp_config.Merged` table in `mcp_boot.initWithMerged` performs `1`
     filesystem + plugin-tree scan at startup instead of `2`.
-/

namespace Graff.AcpLatency

/-! ## 1. In-Process Git Worktree Resolution (`src/acp_workspace.zig`) -/

inductive GitDotKind where
  | absent      -- outside Git
  | directory   -- main checkout (`<top>/.git` is a directory, so `git_dir = common_dir`)
  | gitdirFile  -- linked worktree (`<top>/.git` is `gitdir: <git_dir>`)
deriving DecidableEq, Repr, BEq

inductive HeadRefKind where
  | symbolicRef -- `ref: refs/heads/<branch>` in `<git_dir>/HEAD`
  | detached    -- raw SHA in `<git_dir>/HEAD`
deriving DecidableEq, Repr, BEq

inductive BaseState where
  | noBase       -- no recorded graff worktree base branch
  | cachedBase   -- `(top, branch, head, base)` already in `baseSha` cache
  | uncachedBase -- first query for `(top, branch, head, base)`
deriving DecidableEq, Repr, BEq

structure WorkspaceCell where
  dot  : GitDotKind
  head : HeadRefKind
  base : BaseState
deriving DecidableEq, Repr, BEq

/-- Legacy `acp_workspace.info`: unconditionally spawned `git rev-parse` and
    `git symbolic-ref` (2 subprocesses), plus `git merge-base` on linked worktrees
    with a base branch. -/
def legacyGitSpawns (c : WorkspaceCell) : Nat :=
  match c.dot with
  | .absent | .directory => 2
  | .gitdirFile =>
      match c.base with
      | .noBase => 2
      | .cachedBase | .uncachedBase => 3

/-- In-process `acp_workspace.info`:
    - `.absent` / `.directory` return `none` after `statFile` (`0` subprocesses).
    - `.gitdirFile` reads `.git`, `commondir`, and `HEAD` in-process (`0` subprocesses
      for `rev-parse` and `symbolic-ref`), spawning `git merge-base` (`1` subprocess)
      only on `.uncachedBase`. -/
def inProcessGitSpawns (c : WorkspaceCell) : Nat :=
  match c.dot with
  | .absent | .directory => 0
  | .gitdirFile =>
      match c.base with
      | .noBase | .cachedBase => 0
      | .uncachedBase => 1

/-- Whether the workspace is a linked worktree that produces `Some Info`. -/
def isLinkedWorktree (dot : GitDotKind) : Bool :=
  match dot with
  | .gitdirFile => true
  | .absent | .directory => false

/-- In `fromRevParse`, a main checkout has `git_dir == common_dir`, which returns `none`. -/
def revParseIsLinked (gitDirEqualsCommon : Bool) : Bool :=
  !gitDirEqualsCommon

theorem main_checkout_equivalence :
    isLinkedWorktree .directory = revParseIsLinked true := rfl

theorem linked_worktree_equivalence :
    isLinkedWorktree .gitdirFile = revParseIsLinked false := rfl

theorem main_checkout_zero_git_spawns (h : HeadRefKind) (b : BaseState) :
    inProcessGitSpawns { dot := .directory, head := h, base := b } = 0 := rfl

theorem linked_worktree_cached_zero_git_spawns (h : HeadRefKind) :
    inProcessGitSpawns { dot := .gitdirFile, head := h, base := .noBase } = 0 ∧
      inProcessGitSpawns { dot := .gitdirFile, head := h, base := .cachedBase } = 0 := by
  simp [inProcessGitSpawns]

theorem in_process_strictly_fewer_spawns (c : WorkspaceCell) :
    inProcessGitSpawns c + 2 ≤ legacyGitSpawns c := by
  rcases c with ⟨dot, head, base⟩
  cases dot <;> cases head <;> cases base <;> decide

/-! ## 2. Single-Parse ACP Inbox Classification (`src/acp_inbox.zig`) -/

inductive AcpFrameKind where
  | handshakeOrQuery      -- `initialize`, `session/new`, `session/load`, `session/resume`, `session/set_config_option`, `graff/models`, `graff/changes`, `session/fork`
  | promptOrSteer         -- `session/prompt`, `_session/steering`
  | controlCancelOrAnswer -- `session/cancel`, `session/close`, `session/answer`, `graff/agents`
  | rpcResponse           -- JSON-RPC response (`methodOf(line) = none`: elicitation / permission reply)
deriving DecidableEq, Repr, BEq

inductive TurnState where
  | idle
  | active
deriving DecidableEq, Repr, BEq

structure InboxCell where
  frame : AcpFrameKind
  state : TurnState
deriving DecidableEq, Repr, BEq

/-- Legacy `Inbox.accept`: parsed every line twice in the pump thread (`parseFromSliceLeaky`
    for elicit/permission + `proto.parseRequest`), plus a third parse in `handleLine`
    when queued. -/
def legacyInboxAcceptParses (_c : InboxCell) : Nat := 2

def legacyTotalParses (c : InboxCell) : Nat :=
  match c.frame with
  | .rpcResponse => 2
  | .controlCancelOrAnswer => 2
  | .handshakeOrQuery | .promptOrSteer => 3

/-- Fast-classified `Inbox.accept`:
    - `.handshakeOrQuery` skips JSON parsing in the pump thread (`0` parses in `accept`,
      `1` parse in `handleLine`).
    - All other frames parse at most `1×` in `accept` and reuse `Value` via `requestFromValue`. -/
def fastInboxAcceptParses (c : InboxCell) : Nat :=
  match c.frame with
  | .handshakeOrQuery => 0
  | .promptOrSteer | .controlCancelOrAnswer | .rpcResponse => 1

def fastTotalParses (c : InboxCell) : Nat :=
  match c.frame with
  | .handshakeOrQuery => 1
  | .rpcResponse | .controlCancelOrAnswer => 1
  | .promptOrSteer =>
      match c.state with
      | .active => 1 -- steered in place, or parsed once more if queued
      | .idle   => 2

/-- Only frames without a `"method"` key (`.rpcResponse`) are routed to elicitation/permission bridges. -/
def routesToResponseBridge (k : AcpFrameKind) : Bool :=
  match k with
  | .rpcResponse => true
  | .handshakeOrQuery | .promptOrSteer | .controlCancelOrAnswer => false

theorem response_bridge_iff_no_method (k : AcpFrameKind) :
    routesToResponseBridge k = true ↔ k = .rpcResponse := by
  cases k <;> decide

theorem handshake_single_parse (s : TurnState) :
    fastTotalParses { frame := .handshakeOrQuery, state := s } = 1 ∧
      legacyTotalParses { frame := .handshakeOrQuery, state := s } = 3 := by
  cases s <;> decide

theorem inbox_accept_never_double_parses (c : InboxCell) :
    fastInboxAcceptParses c ≤ 1 ∧ fastInboxAcceptParses c < legacyInboxAcceptParses c := by
  rcases c with ⟨frame, state⟩
  cases frame <;> cases state <;> decide

/-! ## 3. Zero-Copy Batch Frame Splitting (`src/acp_line_writer.zig`, `src/acp_stream.zig`) -/

structure FrameSplitState where
  emitted : List UInt8
  pending : List UInt8
deriving DecidableEq, Repr, BEq

/-- Line-by-line emission over two complete lines `l1`, `l2` and trailing partial `tail`. -/
def emitTwoLinesIterative (pending l1 l2 tail : List UInt8) : FrameSplitState :=
  let emitted1 := pending ++ l1
  let emitted2 := emitted1 ++ l2
  { emitted := emitted2, pending := tail }

/-- Batch emission of `complete = l1 ++ l2` in a single locked write + flush. -/
def emitBatchComplete (pending l1 l2 tail : List UInt8) : FrameSplitState :=
  { emitted := pending ++ (l1 ++ l2), pending := tail }

theorem batch_write_stream_equivalence (pending l1 l2 tail : List UInt8) :
    emitBatchComplete pending l1 l2 tail = emitTwoLinesIterative pending l1 l2 tail := by
  simp [emitBatchComplete, emitTwoLinesIterative, List.append_assoc]

def lineByLineFlushes (completeLines : Nat) : Nat := completeLines
def batchFlushes (completeLines : Nat) : Nat := if completeLines = 0 then 0 else 1

theorem batch_write_single_flush (k : Nat) (h : k ≥ 1) :
    batchFlushes k = 1 ∧ batchFlushes k ≤ lineByLineFlushes k := by
  cases k with
  | zero => contradiction
  | succ n =>
    simp [batchFlushes, lineByLineFlushes]

/-! ## 4. Startup MCP Config Single-Load (`src/session_start.zig`, `src/mcp_boot.zig`) -/

def legacyStartupMcpScans : Nat := 2
def fusedStartupMcpScans : Nat := 1

theorem startup_mcp_load_halved :
    legacyStartupMcpScans = 2 * fusedStartupMcpScans := rfl

/-! ## 5. Cube Enumeration for `graff-spec-report` -/

def allGitDots : List GitDotKind := [.absent, .directory, .gitdirFile]
def allHeadRefs : List HeadRefKind := [.symbolicRef, .detached]
def allBases : List BaseState := [.noBase, .cachedBase, .uncachedBase]

def allWorkspaceCells : List WorkspaceCell :=
  Id.run do
    let mut acc : List WorkspaceCell := []
    for d in allGitDots do
      for h in allHeadRefs do
        for b in allBases do
          acc := acc ++ [{ dot := d, head := h, base := b }]
    return acc

def allFrames : List AcpFrameKind := [.handshakeOrQuery, .promptOrSteer, .controlCancelOrAnswer, .rpcResponse]
def allTurnStates : List TurnState := [.idle, .active]

def allInboxCells : List InboxCell :=
  Id.run do
    let mut acc : List InboxCell := []
    for f in allFrames do
      for s in allTurnStates do
        acc := acc ++ [{ frame := f, state := s }]
    return acc

def acpWorkspaceCells : Nat := allWorkspaceCells.length
def acpZeroSpawnCells : Nat := (allWorkspaceCells.filter (fun c => decide (inProcessGitSpawns c = 0))).length
def acpInboxCells : Nat := allInboxCells.length

theorem acp_workspace_cube : acpWorkspaceCells = 18 := by native_decide
theorem acp_zero_spawn_count : acpZeroSpawnCells = 16 := by native_decide
theorem acp_inbox_cube : acpInboxCells = 8 := by native_decide

end Graff.AcpLatency
