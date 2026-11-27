/- The complete-line event sequence in src/serve_events.zig. A reader's
   cursor is the next wanted sequence, independent of the writer and socket.
   The model excludes partial lines that Follower.poll keeps on disk. -/

namespace Graff.ServeReplay

inductive Kind where
  | started | progress | success | failure
deriving DecidableEq

structure Event where
  seq : Nat
  kind : Kind

def replay (cursor : Nat) (tape : List Event) : List Event :=
  tape.filter (fun event => decide (cursor ≤ event.seq))

theorem delivered_prefix_never_replayed (cursor : Nat) (delivered : List Event)
    (h : ∀ event ∈ delivered, event.seq < cursor) :
    replay cursor delivered = [] := by
  induction delivered with
  | nil => rfl
  | cons event tail ih =>
    have prior : ¬ cursor ≤ event.seq := Nat.not_le.mpr (h event (by simp))
    have tailEmpty := ih (fun e mem => h e (by simp [mem]))
    simpa [replay, prior] using tailEmpty

theorem reattach_recovers_exact_tail (cursor : Nat) (seen pending : List Event)
    (old : ∀ event ∈ seen, event.seq < cursor)
    (fresh : ∀ event ∈ pending, cursor ≤ event.seq) :
    replay cursor (seen ++ pending) = pending := by
  have keep : replay cursor pending = pending := by
    apply List.filter_eq_self.mpr
    intro event mem
    simp [fresh event mem]
  unfold replay at ⊢
  rw [List.filter_append]
  change replay cursor seen ++ replay cursor pending = pending
  rw [delivered_prefix_never_replayed cursor seen old, List.nil_append, keep]

theorem quiet_then_next_event (cursor : Nat) (seen : List Event)
    (old : ∀ event ∈ seen, event.seq < cursor) (kind : Kind) :
    replay cursor seen = [] ∧
    replay cursor (seen ++ [{seq := cursor, kind}]) = [{seq := cursor, kind}] := by
  refine ⟨delivered_prefix_never_replayed cursor seen old, ?_⟩
  apply reattach_recovers_exact_tail cursor seen _ old
  simp

end Graff.ServeReplay
