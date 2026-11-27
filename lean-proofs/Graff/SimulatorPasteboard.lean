/-
  This models the preflight decision in sim_pasteboard.zig. It does not
  model shell parsing, concurrent external launches, or macOS sync.
  The emitted table is also exercised by the production Zig decision.
-/

namespace Graff.SimulatorPasteboard

inductive Gui where
  | running | stopped | unknown
  deriving DecidableEq

inductive Decision where
  | readPref | isolated | unknown
  deriving DecidableEq

def preflight : Gui → Bool → Decision
  | .running, _ => .readPref
  | .stopped, true => .readPref
  | .stopped, false => .isolated
  | .unknown, _ => .unknown

theorem compound_launch_never_uses_closed_gui_as_isolation (gui : Gui) :
    preflight gui true ≠ .isolated := by
  cases gui <;> decide

theorem only_known_closed_headless_is_isolated (gui : Gui) (opensGui : Bool) :
    preflight gui opensGui = .isolated ↔ gui = .stopped ∧ opensGui = false := by
  cases gui <;> cases opensGui <;> decide

def guiLabel : Gui → String
  | .running => "running"
  | .stopped => "stopped"
  | .unknown => "unknown"

def decisionLabel : Decision → String
  | .readPref => "read-pref"
  | .isolated => "isolated"
  | .unknown => "unknown"

def table : String := String.join <|
  [.running, .stopped, .unknown].flatMap fun gui =>
    [false, true].map fun opensGui =>
      let command := if opensGui then "opens-gui" else "closed-command"
      s!"{guiLabel gui}\t{command}\t{decisionLabel (preflight gui opensGui)}\n"

end Graff.SimulatorPasteboard
