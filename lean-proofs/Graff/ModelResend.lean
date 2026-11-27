/-!
  Models the suppression gates in agent_request.zig, agent_ws.zig and
  agent_stream_h2.zig. The initial request is outside the retry sequence.
  Protocol negotiation before a body send does not itself resend a model input.
-/
namespace Graff.ModelResend

inductive Action where
  | negotiate
  | retry
  | fallbackAfterSend
  deriving DecidableEq

def admitted (noResends : Bool) (action : Action) : Bool :=
  match action with
  | .negotiate => true
  | .retry | .fallbackAfterSend => !noResends

def resends (noResends : Bool) : List Action → Nat
  | [] => 0
  | action :: rest =>
      (if action ≠ .negotiate ∧ admitted noResends action = true then 1 else 0)
        + resends noResends rest

theorem strict_one_attempt (plan : List Action) :
    1 + resends true plan = 1 := by
  have noResend (actions : List Action) : resends true actions = 0 := by
    induction actions with
    | nil => rfl
    | cons action rest ih => cases action <;> simp [resends, admitted, ih]
  simp [noResend]

/-- The run budget admits both regular requests and standalone compaction.
    Each list entry represents one admitted logical call's potential resends. -/
def attempts (noResends : Bool) : List (List Action) → Nat
  | [] => 0
  | call :: rest => (1 + resends noResends call) + attempts noResends rest

theorem strict_preserves_logical_ceiling (calls : List (List Action))
    (limit : Nat) (admittedCalls : calls.length ≤ limit) :
    attempts true calls ≤ limit := by
  have equalCalls (plans : List (List Action)) : attempts true plans = plans.length := by
    induction plans with
    | nil => rfl
    | cons plan rest ih =>
      simp [attempts, strict_one_attempt, ih, Nat.add_comm]
  simpa [equalCalls] using admittedCalls

inductive Preflight where
  | resolved
  | recoverable
  | sameOriginDnsFailed
  deriving DecidableEq

/-- The turn entry point returns the terminal compaction resolver error.
    Other outcomes may reach the ordinary request with its own budget. -/
def attemptsAfterPreflight (preflight : Preflight) (spent nextBudget : Nat) : Nat :=
  if preflight = .sameOriginDnsFailed then spent else spent + nextBudget

theorem dns_failure_cannot_restart_request (spent nextBudget : Nat) :
    attemptsAfterPreflight .sameOriginDnsFailed spent nextBudget = spent := by
  simp [attemptsAfterPreflight]

example : attemptsAfterPreflight .recoverable 1 6 = 7 := rfl

end Graff.ModelResend
