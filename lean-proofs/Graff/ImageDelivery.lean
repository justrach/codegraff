/-
  Image delivery kernel.

  Process kernel, not a Turing machine: finite `Event` / `step`, no tape.
  Two machines, one for each way pixels reach a model request.

  `Inbox` is the registry's image queue (src/image_inbox.zig). A tool batch
  stages images; the batch checkpoint flushes them into the next request.
  The old machine was this one with a single slot: the second image of a
  batch got a successful result that said "not attached". Here every staged
  image is delivered once, in order, or refused out loud. Nothing else.

  `Attach` is the prompt's attachment trailer (src/attachment_refs.zig). A
  ref the prompt names is staged as an image block, or keeps its line in the
  text. The file tools' gate is a function of the path alone: no event of
  this machine widens it.

  The 102 admit cells are the snapshot. Not modelled: base64 bytes, the
  provider's wire shape, which thread finishes a read first.
  Executable port: the `Model` in src/image_inbox.zig, run against the
  queue over every sequence of six events.
-/

namespace Graff.ImageDelivery

/-! The inbox. An image is its id and its size. -/

structure Image where
  id   : Nat
  size : Nat
deriving DecidableEq, Repr, BEq

structure Limits where
  slots  : Nat := 16
  budget : Nat := 24
deriving DecidableEq, Repr, BEq

structure Inbox where
  queue     : List Image := []
  delivered : List (List Image) := []
  refused   : List Image := []
deriving DecidableEq, Repr, BEq

inductive Event where
  | stage (img : Image)
  | flush
deriving DecidableEq, Repr, BEq

def bytes (q : List Image) : Nat := (q.map (·.size)).sum

def admits (l : Limits) (q : List Image) (img : Image) : Bool :=
  decide (q.length < l.slots) && decide (bytes q + img.size ≤ l.budget)

def step (l : Limits) (s : Inbox) : Event → Inbox
  | .stage img =>
      if admits l s.queue img then { s with queue := s.queue ++ [img] }
      else { s with refused := s.refused ++ [img] }
  | .flush =>
      if s.queue.isEmpty then s
      else { s with queue := [], delivered := s.delivered ++ [s.queue] }

def run (l : Limits) (s : Inbox) : List Event → Inbox
  | []      => s
  | e :: es => run l (step l s e) es

/-- Every image the inbox took, delivered or still waiting, oldest first. -/
def accepted (s : Inbox) : List Image := s.delivered.flatten ++ s.queue

def staged : List Event → List Image
  | [] => []
  | .stage img :: es => img :: staged es
  | .flush :: es => staged es

/-! Edges. -/

theorem flush_keeps_accepted (l : Limits) (s : Inbox) :
    accepted (step l s .flush) = accepted s := by
  by_cases h : s.queue = [] <;> simp [step, accepted, h]

theorem flush_empties (l : Limits) (s : Inbox) :
    (step l s .flush).queue = [] := by
  by_cases h : s.queue = [] <;> simp [step, h]

theorem flush_refuses_nothing (l : Limits) (s : Inbox) :
    (step l s .flush).refused = s.refused := by
  by_cases h : s.queue = [] <;> simp [step, h]

/-- A staged image is accepted or refused. There is no third edge. -/
theorem stage_accepts_or_refuses (l : Limits) (s : Inbox) (img : Image) :
    (accepted (step l s (.stage img)) = accepted s ++ [img] ∧
      (step l s (.stage img)).refused = s.refused) ∨
    (accepted (step l s (.stage img)) = accepted s ∧
      (step l s (.stage img)).refused = s.refused ++ [img]) := by
  by_cases h : admits l s.queue img = true <;> simp [step, accepted, h]

theorem refused_only_when_no_room (l : Limits) (s : Inbox) (img : Image)
    (h : (step l s (.stage img)).refused ≠ s.refused) :
    admits l s.queue img = false := by
  by_cases ha : admits l s.queue img = true
  · simp [step, ha] at h
  · simpa using ha

theorem admitted_is_queued_last (l : Limits) (s : Inbox) (img : Image)
    (h : admits l s.queue img = true) :
    (step l s (.stage img)).queue = s.queue ++ [img] := by
  simp [step, h]

/-! Whole runs. -/

/-- Nothing is lost and nothing is invented: after any run, the images that
    were accepted plus the images that were refused number exactly the images
    that were staged. -/
theorem every_image_accounted (l : Limits) (es : List Event) (s : Inbox) :
    (accepted (run l s es)).length + (run l s es).refused.length =
      (accepted s).length + s.refused.length + (staged es).length := by
  induction es generalizing s with
  | nil => simp [run, staged]
  | cons e es ih =>
    rw [run, ih]
    cases e with
    | flush =>
      rw [flush_keeps_accepted, flush_refuses_nothing]
      simp [staged]
    | stage img =>
      rcases stage_accepts_or_refuses l s img with ⟨ha, hr⟩ | ⟨ha, hr⟩ <;>
        simp [ha, hr, staged] <;> omega

/-- The queue never exceeds its slots. -/
theorem queue_within_slots (l : Limits) (es : List Event) (s : Inbox)
    (h : s.queue.length ≤ l.slots) : (run l s es).queue.length ≤ l.slots := by
  induction es generalizing s with
  | nil => simpa [run] using h
  | cons e es ih =>
    rw [run]
    apply ih
    cases e with
    | flush => rw [flush_empties]; simp
    | stage img =>
      by_cases ha : admits l s.queue img = true
      · have hs := admitted_is_queued_last l s img ha
        simp [admits] at ha
        rw [hs]; simp; omega
      · simpa [step, ha] using h

/-- Nor its byte budget. -/
theorem queue_within_budget (l : Limits) (es : List Event) (s : Inbox)
    (h : bytes s.queue ≤ l.budget) : bytes (run l s es).queue ≤ l.budget := by
  induction es generalizing s with
  | nil => simpa [run] using h
  | cons e es ih =>
    rw [run]
    apply ih
    cases e with
    | flush => rw [flush_empties]; simp [bytes]
    | stage img =>
      by_cases ha : admits l s.queue img = true
      · have hs := admitted_is_queued_last l s img ha
        simp [admits] at ha
        rw [hs]; simp [bytes] at *; omega
      · simpa [step, ha] using h

/-- A flush that ends a run delivers everything that was accepted: the
    queue is empty and `accepted` is exactly what the requests received. -/
theorem flush_delivers_all (l : Limits) (es : List Event) (s : Inbox) :
    (run l s (es ++ [.flush])).queue = [] ∧
    (run l s (es ++ [.flush])).delivered.flatten = accepted (run l s es) := by
  have hrun : run l s (es ++ [.flush]) = step l (run l s es) .flush := by
    induction es generalizing s with
    | nil => simp [run]
    | cons e es ih => simp [run, ih]
  rw [hrun]
  refine ⟨flush_empties l _, ?_⟩
  have h := flush_keeps_accepted l (run l s es)
  unfold accepted at h
  rw [flush_empties] at h
  simpa [accepted] using h

/-- The batch the issue reports: images staged into an empty inbox that has
    room for all of them arrive together, in the order staged, in one request. -/
theorem batch_in_one_request (l : Limits) (imgs : List Image)
    (hslots : imgs.length ≤ l.slots) (hbytes : bytes imgs ≤ l.budget)
    (hne : imgs ≠ []) :
    run l {} (imgs.map .stage ++ [.flush]) =
      { queue := [], delivered := [imgs], refused := [] } := by
  have key : ∀ (rest pre : List Image),
      (pre ++ rest).length ≤ l.slots → bytes (pre ++ rest) ≤ l.budget →
      run l { queue := pre } (rest.map .stage) = { queue := pre ++ rest } := by
    intro rest
    induction rest with
    | nil => intro pre _ _; simp [run]
    | cons img rest ih =>
      intro pre hs hb
      have hlen : pre.length < l.slots := by
        simp at hs; omega
      have hfit : bytes pre + img.size ≤ l.budget := by
        simp [bytes] at hb ⊢; omega
      have hadm : admits l pre img = true := by
        simp [admits, hlen, hfit]
      have hstep : step l { queue := pre } (.stage img) = { queue := pre ++ [img] } := by
        simp [step, hadm]
      simp only [List.map_cons, run, hstep]
      have := ih (pre ++ [img]) (by simpa using hs) (by simpa using hb)
      simpa using this
  have hq := key imgs [] (by simpa using hslots) (by simpa using hbytes)
  have hrun : run l {} (imgs.map .stage ++ [.flush]) =
      step l (run l {} (imgs.map .stage)) .flush := by
    generalize imgs.map Event.stage = es
    generalize ({} : Inbox) = s
    induction es generalizing s with
    | nil => simp [run]
    | cons e es ih => simp [run, ih]
  rw [hrun, hq]
  cases imgs with
  | nil => exact absurd rfl hne
  | cons a as => simp [step]

/-! The defect, as a cell. One slot is the machine graff shipped. -/

def before : Image := { id := 1, size := 1 }
def after  : Image := { id := 2, size := 1 }
def comparison : List Event := [.stage before, .stage after, .flush]

def oneSlot : Limits := { slots := 1 }

theorem one_slot_drops_the_second :
    run oneSlot {} comparison =
      { queue := [], delivered := [[before]], refused := [after] } := by native_decide

theorem queue_delivers_both :
    run {} {} comparison =
      { queue := [], delivered := [[before, after]], refused := [] } := by native_decide

/-- A refused image is not gone: staged again after the flush, it is taken. -/
theorem refused_then_retried :
    (run oneSlot {} (comparison ++ [.stage after, .flush])).delivered =
      [[before], [after]] := by native_decide

/-! Snapshot: fill level × bytes already queued × size of the next image. -/

inductive Verdict where
  | queued | full | overBudget
deriving DecidableEq, Repr, BEq

/-- The verdict `Queue.admit` returns, with the slot check first. -/
def verdict (l : Limits) (len used size : Nat) : Verdict :=
  if len ≥ l.slots then .full
  else if used + size > l.budget then .overBudget
  else .queued

def fillLevels : List Nat := List.range 17
def usedLevels : List Nat := [0, 12, 24]
def sizeLevels : List Nat := [1, 13]

def admitCells : List (Nat × Nat × Nat) :=
  fillLevels.flatMap fun len =>
    usedLevels.flatMap fun used => sizeLevels.map fun size => (len, used, size)

def deliveryCells : Nat := admitCells.length
def queuedCells : Nat :=
  (admitCells.filter fun (len, used, size) => verdict {} len used size == .queued).length
def fullCells : Nat :=
  (admitCells.filter fun (len, used, size) => verdict {} len used size == .full).length

theorem delivery_cube : deliveryCells = 102 := by native_decide
theorem queued_cells : queuedCells = 48 := by native_decide
theorem full_cells : fullCells = 6 := by native_decide

/-- The verdict and the machine's edge are the same decision. -/
theorem verdict_matches_admits (l : Limits) (q : List Image) (img : Image) :
    verdict l q.length (bytes q) img.size = .queued ↔ admits l q img = true := by
  unfold verdict admits
  by_cases h1 : q.length ≥ l.slots
  · have : ¬ q.length < l.slots := by omega
    simp [h1, this]
  · have h1' : q.length < l.slots := by omega
    by_cases h2 : bytes q + img.size > l.budget
    · have : ¬ bytes q + img.size ≤ l.budget := by omega
      simp [h1, h1', h2, this]
    · have : bytes q + img.size ≤ l.budget := by omega
      simp [h1, h1', h2, this]

/-! The attachment trailer. -/

/-- What graff can know about a ref when the prompt arrives. -/
structure Ref where
  path    : String
  isImage : Bool
deriving DecidableEq, Repr, BEq

structure Prompt where
  /-- Refs still named in the text the model reads. -/
  trailer : List Ref := []
  /-- Refs staged as image blocks on this request. -/
  blocks  : List Ref := []
deriving DecidableEq, Repr, BEq

def stageable (vision : Bool) (r : Ref) : Bool := vision && r.isImage

/-- One ref of the trailer is promoted: staged, or left in the text. -/
def promote (vision : Bool) (p : Prompt) (r : Ref) : Prompt :=
  if stageable vision r then { p with blocks := p.blocks ++ [r] }
  else { p with trailer := p.trailer ++ [r] }

def promoteAll (vision : Bool) (refs : List Ref) : Prompt :=
  refs.foldl (promote vision) {}

/-- The file tools' gate. It reads the path and nothing else: the prompt's
    refs are not an argument, so no promotion can open a path to a tool. -/
def toolMayRead (confined : String → Bool) (path : String) : Bool := confined path

theorem promote_splits (vision : Bool) (refs : List Ref) (p : Prompt) :
    (refs.foldl (promote vision) p).blocks = p.blocks ++ refs.filter (stageable vision) ∧
    (refs.foldl (promote vision) p).trailer =
      p.trailer ++ refs.filter (fun r => !stageable vision r) := by
  induction refs generalizing p with
  | nil => simp
  | cons r rs ih =>
    simp only [List.foldl_cons]
    rcases ih (promote vision p r) with ⟨hb, ht⟩
    rw [hb, ht]
    unfold promote
    by_cases h : stageable vision r <;> simp [h]

theorem filter_splits_length {α : Type} (p : α → Bool) (xs : List α) :
    (xs.filter p).length + (xs.filter fun x => !p x).length = xs.length := by
  induction xs with
  | nil => rfl
  | cons x xs ih =>
    by_cases hx : p x <;> simp [List.filter, hx] <;> omega

/-- Every ref ends in exactly one place: an image block, or its line. -/
theorem ref_staged_or_kept (vision : Bool) (refs : List Ref) :
    (promoteAll vision refs).blocks.length + (promoteAll vision refs).trailer.length =
      refs.length := by
  have h := promote_splits vision refs {}
  unfold promoteAll
  rw [h.1, h.2]
  simpa using filter_splits_length (stageable vision) refs

/-- Only a ref the prompt named is ever staged, and only if it is an image. -/
theorem staged_were_named_images (vision : Bool) (refs : List Ref) (r : Ref)
    (h : r ∈ (promoteAll vision refs).blocks) : r ∈ refs ∧ r.isImage = true := by
  have hs := (promote_splits vision refs {}).1
  unfold promoteAll at h
  rw [hs] at h
  simp [stageable] at h
  exact ⟨h.1, h.2.2⟩

/-- A model that cannot see stages nothing: every ref keeps its line. -/
theorem text_only_stages_nothing (refs : List Ref) :
    (promoteAll false refs).blocks = [] ∧ (promoteAll false refs).trailer = refs := by
  have h := promote_splits false refs {}
  unfold promoteAll
  rw [h.1, h.2]
  simp [stageable]

/-- An upload outside the working directory stays closed to the file tools.
    The gate takes no `Prompt`: whatever was promoted, the answer is the
    path's own. -/
theorem upload_stays_confined (confined : String → Bool) (path : String)
    (houtside : confined path = false) : toolMayRead confined path = false := by
  simpa [toolMayRead] using houtside

def upload : Ref := { path := "/uploads/ab12-shot.png", isImage := true }
def notes  : Ref := { path := "/uploads/cd34-notes.txt", isImage := false }

example : promoteAll true [upload, notes] = { trailer := [notes], blocks := [upload] } := by
  native_decide
example : promoteAll false [upload, notes] = { trailer := [upload, notes], blocks := [] } := by
  native_decide

end Graff.ImageDelivery
