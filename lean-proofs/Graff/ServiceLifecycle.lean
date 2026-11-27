import Std

namespace Graff.ServiceLifecycle

/-- Manager transaction: the operator's definition, loaded job, and client state. -/
structure Service where
  definition : Option Nat
  loaded : Option Nat
  clientPort : Option Nat
  deriving DecidableEq, Repr

def stage (before : Service) (port : Nat) : Service :=
  { before with definition := some port, loaded := some port }

def rollback (before staged : Service) : Service :=
  { staged with definition := before.definition, loaded := before.loaded }

def finish (before : Service) (candidate : Nat) (ready : Bool) : Service :=
  let staged := stage before candidate
  if ready then { staged with clientPort := some candidate } else rollback before staged

theorem failedFreshLeavesNoJob (candidate : Nat) :
    finish ⟨none, none, none⟩ candidate false = ⟨none, none, none⟩ := rfl

theorem failedReplacementRetainsPreviousAndClient (before : Service) (candidate : Nat) :
    finish before candidate false = before := rfl

theorem readyReplacementPublishesConsistentPort (before : Service) (candidate : Nat) :
    finish before candidate true = ⟨some candidate, some candidate, some candidate⟩ := rfl

def stop (service : Service) : Service :=
  { service with definition := none, loaded := none }

theorem stopPreservesClientsAndIsIdempotent (service : Service) :
    (stop service).clientPort = service.clientPort ∧ stop (stop service) = stop service := by
  cases service
  exact ⟨rfl, rfl⟩

/-- The connection-keyed grant map, abstracted by its membership predicate. -/
structure Grants where
  armed : Bool
  live : Nat → Bool

def claim (grants : Grants) (connection : Nat) : Grants :=
  if grants.live connection || !grants.armed then grants
  else ⟨false, fun key => key == connection || grants.live key⟩

def close (grants : Grants) (connection : Nat) : Grants :=
  { grants with live := fun key => key != connection && grants.live key }

def revoke (_ : Grants) : Grants := ⟨false, fun _ => false⟩

theorem closedConnectionLosesGrant (grants : Grants) (key : Nat) :
    (close grants key).live key = false := by simp [close]

theorem closePreservesOtherActiveGrant (grants : Grants) {ended other : Nat}
    (distinct : other ≠ ended) : (close grants ended).live other = grants.live other := by
  simp [close, distinct]

theorem claimingFirstActionConsumesArmWithoutAffectingOther (grants : Grants)
    {owner other : Nat} (different : other ≠ owner) (armed : grants.armed = true)
    (first : grants.live owner = false) :
    (claim grants owner).armed = false ∧ (claim grants owner).live owner = true ∧
    (claim grants owner).live other = grants.live other := by
  simp [claim, armed, first, different]

theorem globalRevokeClearsAllAfterClaim (grants : Grants) (key : Nat) :
    (revoke (claim grants key)).live key = false ∧ (revoke (claim grants key)).armed = false :=
  ⟨rfl, rfl⟩

/-- The production guard treats unknown inventory as absence of stop authority. -/
structure Inventory where
  activeConsumers : Nat
  observedAt : Nat
  emptySince : Option Nat
  generation : Nat
  fullCoverage : Bool

def canStop (pinned : Bool) (now grace freshness generation : Nat)
    (inventory : Option Inventory) : Bool :=
  !pinned && grace != 0 && generation != 0 &&
  (match inventory with
   | some ⟨0, sampleTime, some since, id, true⟩ =>
      id == generation && decide (since ≤ sampleTime ∧ sampleTime ≤ now ∧ now - sampleTime ≤ freshness ∧ grace ≤ sampleTime - since)
   | _ => false)

theorem disappearanceIsNotStopAuthority (now grace freshness generation : Nat) :
    canStop false now grace freshness generation none = false := by
  simp [canStop]

theorem activeConsumerProtectsProcess (n sampleTime generation now grace freshness : Nat) (since : Option Nat)
    (coverage : Bool) :
    canStop false now grace freshness generation (some ⟨n + 1, sampleTime, since, generation, coverage⟩) = false := by
  simp [canStop]

theorem recycledProcessProtected (now grace freshness generation id sampleTime since : Nat) (different : id ≠ generation) :
    canStop false now grace freshness generation (some ⟨0, sampleTime, some since, id, true⟩) = false := by
  simp [canStop, different]

theorem reconnectRestartsGrace (now grace freshness generation sampleTime since : Nat) (short : sampleTime - since < grace) :
    canStop false now grace freshness generation (some ⟨0, sampleTime, some since, generation, true⟩) = false := by
  have tooSoon : ¬ grace ≤ sampleTime - since := Nat.not_le.mpr short
  simp [canStop, tooSoon]

end Graff.ServiceLifecycle
