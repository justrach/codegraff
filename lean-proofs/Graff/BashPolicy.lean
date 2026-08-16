/-
  Bash / plan-mode policy: isSimple, escapesCwd, readOnlyAllowed.

  The leftover discrete family in `harness_policy.zig`. A command is
  auto-allowed in plan mode only when it is simple, stays in cwd, and
  matches a read-only seed prefix. Metacharacters smuggle a second
  command; absolute/`~`/`..` tokens leave cwd. `readOnlyExternal` is the
  #64 twin: simple + seed verb + escapes cwd (prompt, do not auto-run).

  Not modelled: live argv quoting, Windows cmd.exe, the mutable approvals
  allow-list. Executable port: spec/ref/bash_policy.py.
-/

namespace Graff.BashPolicy

def isHSpace (c : Char) : Bool := c == ' ' || c == '\t'

def dropWhile (p : Char → Bool) : List Char → List Char
  | [] => []
  | c :: rest => if p c then dropWhile p rest else c :: rest

def trimST (s : String) : String :=
  let cs := dropWhile isHSpace s.toList
  String.ofList (dropWhile isHSpace cs.reverse).reverse

def metas : List Char :=
  [';', '|', '&', '>', '<', '`', '$', '\n', '\r', '\t', Char.ofNat 0]

def isSimple (cmd : String) : Bool :=
  cmd.toList.all fun c => !(metas.contains c)

def tokens (s : String) : List String :=
  ((s.replace "\t" " ").splitOn " ").filter (· ≠ "")

def hasInfix (s needle : String) : Bool :=
  decide ((s.splitOn needle).length > 1)

def tokenEscapes (tok : String) : Bool :=
  if tok.isEmpty then false
  else if tok.front == '/' || tok.front == '~' then true
  else if hasInfix tok "=/" || hasInfix tok "=~" then true
  else (tok.splitOn "/").contains ".."

def escapesCwd (cmd : String) : Bool :=
  (tokens cmd).any tokenEscapes

def nth (s : String) (n : Nat) : Option Char := s.toList[n]?

def matchesPrefix (cmd pref : String) : Bool :=
  cmd.startsWith pref &&
    (cmd.length == pref.length || nth cmd pref.length == some ' ')

def readOnlySeed : List String :=
  ["ls", "cat", "head", "tail", "wc", "grep", "rg", "pwd", "which", "file",
   "git status", "git diff", "git log", "git show"]

def isReadOnlyVerb (cmd : String) : Bool :=
  readOnlySeed.any (matchesPrefix cmd)

def readOnlyAllowed (cmd : String) : Bool :=
  let c := trimST cmd
  if isSimple c = false then false
  else if escapesCwd c = true then false
  else isReadOnlyVerb c

def readOnlyExternal (cmd : String) : Bool :=
  let c := trimST cmd
  isSimple c && escapesCwd c && isReadOnlyVerb c

theorem not_simple_not_allowed (c : String) (h : isSimple (trimST c) = false) :
    readOnlyAllowed c = false := by
  unfold readOnlyAllowed; simp [h]

theorem escapes_not_allowed (c : String)
    (h₁ : isSimple (trimST c) = true) (h₂ : escapesCwd (trimST c) = true) :
    readOnlyAllowed c = false := by
  unfold readOnlyAllowed; simp [h₁, h₂]

theorem external_needs_simple (c : String) (h : isSimple (trimST c) = false) :
    readOnlyExternal c = false := by
  unfold readOnlyExternal; simp [h]

def commands : List String :=
  ["ls -la", "git status", "cat src/main.zig", "  grep foo bar  ",
   "rm -rf x", "cat /etc/passwd", "ls; rm x", "git push",
   "zig build", "zig fmt src", "ls ~/projects", "cat /abs/file",
   "lsof", "echo $(whoami)", "echo `id`", "foo > bar",
   "a && b", "echo $HOME", "cat ../outside", "prog --file=/abs/path",
   "prog --flag=value", "grep foo ./a/b.zig", "", "ls",
   "git status -s", "git statusx", "cat a | sh", "  ls  ",
   "git log", "zig fmt /x.zig", "ls /x; rm y", "grep foo a/../../b"]

def bashCells : Nat := commands.length
def allowedCells : Nat := (commands.filter readOnlyAllowed).length
def externalCells : Nat := (commands.filter readOnlyExternal).length

theorem bash_cube : bashCells = 32 := by native_decide

theorem cube_allowed_implies_simple :
    commands.all (fun c => !(readOnlyAllowed c) || isSimple (trimST c)) := by native_decide

theorem cube_allowed_stays_cwd :
    commands.all (fun c => !(readOnlyAllowed c) || !(escapesCwd (trimST c))) := by native_decide

theorem cube_allowed_is_verb :
    commands.all (fun c => !(readOnlyAllowed c) || isReadOnlyVerb (trimST c)) := by native_decide

theorem cube_external_never_allowed :
    commands.all (fun c => !(readOnlyAllowed c && readOnlyExternal c)) := by native_decide

example : isSimple "ls -la" = true := by native_decide
example : isSimple "ls; rm x" = false := by native_decide
example : isSimple "echo $HOME" = false := by native_decide
example : escapesCwd "cat src/main.zig" = false := by native_decide
example : escapesCwd "cat /etc/passwd" = true := by native_decide
example : escapesCwd "cat ../outside" = true := by native_decide
example : escapesCwd "prog --file=/abs/path" = true := by native_decide
example : escapesCwd "prog --flag=value" = false := by native_decide
example : readOnlyAllowed "ls -la" = true := by native_decide
example : readOnlyAllowed "  grep foo bar  " = true := by native_decide
example : readOnlyAllowed "rm -rf x" = false := by native_decide
example : readOnlyAllowed "zig build" = false := by native_decide
example : readOnlyAllowed "cat /etc/passwd" = false := by native_decide
example : readOnlyExternal "ls ~/projects" = true := by native_decide
example : readOnlyExternal "cat src/main.zig" = false := by native_decide
example : matchesPrefix "lsof" "ls" = false := by native_decide
example : matchesPrefix "ls -la" "ls" = true := by native_decide

end Graff.BashPolicy
