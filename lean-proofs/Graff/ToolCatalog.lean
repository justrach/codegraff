/-
  Tool-catalog kernel.

  Which built-in names a seat may advertise, and which hallucinated calls
  layer 2 must refuse. Executable port: spec/ref/tool_catalog.py.
-/

import Graff.Util

namespace Graff.ToolCatalog
open Graff.Util

/-- Process-global gates that select a catalog. `isSub` is the seat, not a
CLI flag: a child never sees meta tools or `subagent`. -/
structure Flags where
  noLocal     : Bool := false
  lean        : Bool := false
  imagegen    : Bool := false
  clockSleep  : Bool := false
  learnLoaded : Bool := false
  isSub       : Bool := false
deriving Repr, BEq

def localTools : List String :=
  ["bash", "bash_output", "bash_kill", "read_file", "edit_file",
   "write_file", "codedb", "imagegen"]

def leanTools : List String :=
  ["bash", "read_file", "edit_file", "write_file", "codedb",
   "subagent", "attempt_completion", "load_tool_schemas"]

def optionalTools : List String :=
  ["imagegen"]

def baseTools : List String :=
  ["bash", "bash_output", "bash_kill", "read_file", "edit_file",
   "write_file", "webfetch", "skill", "codedb"]

def metaTools : List String :=
  ["todo_write", "todo_read", "eval", "note_constraint", "ask_user",
   "attempt_completion", "load_tool_schemas", "clock_sleep"]

def rootExtras : List String :=
  ["subagent", "workflow", "agent_output", "learn_candidate", "peer_message",
   "workspace"]

def filterKeep (keep : String → Bool) : List String → List String
  | []      => []
  | x :: xs => if keep x then x :: filterKeep keep xs else filterKeep keep xs

def appendIf (cond : Bool) (extra : List String) (xs : List String) : List String :=
  if cond then xs ++ extra else xs

def chosenRoot (f : Flags) : List String :=
  let dropClock := !f.clockSleep
  let dropLearn := !f.learnLoaded
  filterKeep (fun n =>
      !(dropClock && n == "clock_sleep") &&
      !(dropLearn && n == "learn_candidate"))
    (baseTools ++ metaTools ++ rootExtras)

def chosenSub : List String := baseTools

def chosen (f : Flags) : List String :=
  if f.isSub then chosenSub else chosenRoot f

def withAvailable (f : Flags) (xs : List String) : List String :=
  appendIf f.imagegen optionalTools xs

def filterLocal (f : Flags) (xs : List String) : List String :=
  if f.noLocal then filterKeep (fun n => !mem n localTools) xs else xs

def filterLean (f : Flags) (xs : List String) : List String :=
  if f.lean && !f.isSub then filterKeep (fun n => mem n leanTools) xs else xs

def catalog (f : Flags) : List String :=
  filterLean f (filterLocal f (withAvailable f (chosen f)))

def advertised (f : Flags) (name : String) : Bool :=
  mem name (catalog f)

def isOptional (name : String) : Bool := mem name optionalTools
def isLocal    (name : String) : Bool := mem name localTools

def blocked (f : Flags) (name : String) : Bool :=
  (f.noLocal && isLocal name) || (isOptional name && !f.imagegen)

/-- The flag cube. Lean counts it; the theorem pins the number. -/
def allFlags : List Flags :=
  Id.run do
    let mut acc : List Flags := []
    for noLocal in [false, true] do
      for lean in [false, true] do
        for imagegen in [false, true] do
          for clockSleep in [false, true] do
            for learnLoaded in [false, true] do
              for isSub in [false, true] do
                acc := acc ++ [{ noLocal, lean, imagegen, clockSleep, learnLoaded, isSub }]
    return acc

def catalogCells : Nat := allFlags.length

theorem catalog_cube : catalogCells = 64 := by native_decide

/-- Exhaustive over the cube Lean built. These are real ∀-on-the-finite-space
claims, not one-off examples. -/
theorem cube_imagegen_off :
    (allFlags.filter (fun f => !f.imagegen)).all
      (fun f => !advertised f "imagegen") = true := by native_decide

theorem cube_no_local_drops_bash :
    (allFlags.filter (fun f => f.noLocal)).all
      (fun f => !advertised f "bash") = true := by native_decide

theorem cube_sub_never_subagent :
    (allFlags.filter (fun f => f.isSub)).all
      (fun f => !advertised f "subagent") = true := by native_decide

theorem cube_webfetch_survives_no_local_unless_lean :
    (allFlags.filter (fun f => f.noLocal && !(f.lean && !f.isSub))).all
      (fun f => advertised f "webfetch") = true := by native_decide

theorem cube_unique :
    allFlags.all (fun f => unique (catalog f)) = true := by native_decide

example : mem "webfetch" localTools = false := by native_decide
example : mem "imagegen" localTools = true := by native_decide
example : mem "imagegen" leanTools = false := by native_decide
example : mem "subagent" leanTools = true := by native_decide
example : unique (baseTools ++ metaTools ++ rootExtras) = true := by native_decide

example : catalog {} =
    (baseTools ++
      ["todo_write", "todo_read", "eval", "note_constraint", "ask_user",
       "attempt_completion", "load_tool_schemas"] ++
      ["subagent", "workflow", "agent_output", "peer_message"]) := by native_decide

example : catalog { imagegen := true } =
    catalog {} ++ ["imagegen"] := by native_decide

example : advertised { noLocal := true } "bash" = false := by native_decide
example : advertised { noLocal := true } "webfetch" = true := by native_decide
example : advertised { noLocal := true, imagegen := true } "imagegen" = false := by native_decide
example : advertised { lean := true, imagegen := true } "imagegen" = false := by native_decide
example : advertised { isSub := true } "subagent" = false := by native_decide
example : blocked { imagegen := false } "imagegen" = true := by native_decide
example : blocked { lean := true } "todo_write" = false := by native_decide

end Graff.ToolCatalog
