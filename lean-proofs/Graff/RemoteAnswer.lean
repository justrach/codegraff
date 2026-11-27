namespace Graff.RemoteAnswer

inductive Decision where
  | forward | noPrompt | stale
  deriving DecidableEq

/-- The shared HTTP and remote answer gate in src/serve_answer.zig. -/
def decide (awaiting : Bool) (active answer : String) : Decision :=
  if !awaiting then .noPrompt
  else if !active.isEmpty && !answer.isEmpty && active != answer then .stale
  else .forward

theorem staleAnswerRefused (active answer : String)
    (activePresent : active.isEmpty = false) (answerPresent : answer.isEmpty = false)
    (different : active ≠ answer) : decide true active answer = .stale := by
  simp [decide, activePresent, answerPresent, different]

theorem idleAnswerRefused (active answer : String) : decide false active answer = .noPrompt := rfl

theorem forwardedTaggedAnswerMatches (active answer : String)
    (activePresent : active.isEmpty = false) (answerPresent : answer.isEmpty = false)
    (accepted : decide true active answer = .forward) : active = answer := by
  by_cases same : active = answer
  · exact same
  · rw [staleAnswerRefused active answer activePresent answerPresent same] at accepted
    contradiction

def Decision.code : Decision → Char
  | .forward => 'F'
  | .noPrompt => 'N'
  | .stale => 'S'

def table : String :=
  let ids := ["", "old", "current"]
  let codes := [false, true].flatMap fun awaiting =>
    ids.flatMap fun active => ids.map fun answer => (decide awaiting active answer).code
  String.ofList codes ++ "\n"

end Graff.RemoteAnswer
