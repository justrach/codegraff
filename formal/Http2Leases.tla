------------------------------- MODULE Http2Leases -------------------------------
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS RetainIdleOnLease, ReuseBeforeEnd
ASSUME /\ RetainIdleOnLease \in BOOLEAN
       /\ ReuseBeforeEnd \in BOOLEAN

Requests == {"first", "second"}
Origins == {"A", "B"}
Sessions == {1, 2, 3}
None == 0
States == {"fresh", "active", "idle", "closed"}

VARIABLES created, requested, lease, idle, state, owner, originOf,
          ended, reusable, lastOccupied
vars == <<created, requested, lease, idle, state, owner, originOf,
          ended, reusable, lastOccupied>>

NoOccupied == [happened |-> FALSE, before |-> None,
               after |-> None, surplus |-> None, surplusClosed |-> FALSE]

Init ==
  /\ created = {}
  /\ requested = {}
  /\ lease = [r \in Requests |-> None]
  /\ idle = None
  /\ state = [s \in Sessions |-> "fresh"]
  /\ owner = [s \in Sessions |-> "none"]
  /\ originOf = [s \in Sessions |-> "none"]
  /\ ended = [s \in Sessions |-> FALSE]
  /\ reusable = [s \in Sessions |-> TRUE]
  /\ lastOccupied = NoOccupied

\* takeIdle removes the slot under the mutex before an active request obtains
\* its lease. A mismatched origin closes that idle session, then dials anew.
Acquire(r, origin) ==
  /\ r \in Requests
  /\ origin \in Origins
  /\ r \notin requested
  /\ LET same == idle # None /\ originOf[idle] = origin
         fresh == Sessions \ created
     IN /\ same \/ fresh # {}
        /\ LET chosen == IF same THEN idle ELSE CHOOSE s \in fresh : TRUE
           IN /\ created' = created \cup {chosen}
              /\ requested' = requested \cup {r}
              /\ lease' = [lease EXCEPT ![r] = chosen]
              /\ idle' = IF same /\ RetainIdleOnLease THEN idle ELSE None
              /\ state' = [s \in Sessions |->
                    IF s = chosen THEN "active"
                    ELSE IF ~same /\ s = idle THEN "closed"
                    ELSE state[s]]
              /\ owner' = [owner EXCEPT ![chosen] = r]
              /\ originOf' = [originOf EXCEPT ![chosen] = origin]
              /\ ended' = [ended EXCEPT ![chosen] = FALSE]
              /\ reusable' = [reusable EXCEPT ![chosen] = TRUE]
  /\ UNCHANGED lastOccupied

\* The stream reader observes END_STREAM before a session may be reused.
MarkEnd(r) ==
  /\ r \in Requests
  /\ lease[r] # None
  /\ ~ended[lease[r]]
  /\ ended' = [ended EXCEPT ![lease[r]] = TRUE]
  /\ UNCHANGED <<created, requested, lease, idle, state, owner,
                 originOf, reusable, lastOccupied>>

\* GOAWAY/non-reusable state must also stop a completed stream from pooling.
MarkUnusable(r) ==
  /\ r \in Requests
  /\ lease[r] # None
  /\ reusable[lease[r]]
  /\ reusable' = [reusable EXCEPT ![lease[r]] = FALSE]
  /\ UNCHANGED <<created, requested, lease, idle, state, owner,
                 originOf, ended, lastOccupied>>

\* Lease.release: a successful session fills an empty slot. If another idle
\* session already won, this request closes only its own surplus session.
Release(r) ==
  /\ r \in Requests
  /\ lease[r] # None
  /\ LET s == lease[r]
         canKeep == reusable[s] /\ (ReuseBeforeEnd \/ ended[s])
         wins == canKeep /\ idle = None
     IN /\ lease' = [lease EXCEPT ![r] = None]
        /\ owner' = [owner EXCEPT ![s] = "none"]
        /\ idle' = IF wins THEN s ELSE idle
        /\ state' = [state EXCEPT ![s] = IF wins THEN "idle" ELSE "closed"]
        /\ lastOccupied' = IF idle # None /\ canKeep
             THEN [happened |-> TRUE, before |-> idle, after |-> idle',
                   surplus |-> s, surplusClosed |-> state'[s] = "closed"]
             ELSE lastOccupied
  /\ UNCHANGED <<created, requested, originOf, ended, reusable>>

\* Cancellation owns only the request's lease; it never reaches the pool's
\* idle pointer or another request's active session.
Cancel(r) ==
  /\ r \in Requests
  /\ lease[r] # None
  /\ LET s == lease[r]
     IN /\ lease' = [lease EXCEPT ![r] = None]
        /\ owner' = [owner EXCEPT ![s] = "none"]
        /\ state' = [state EXCEPT ![s] = "closed"]
  /\ UNCHANGED <<created, requested, idle, originOf,
                 ended, reusable, lastOccupied>>

\* Runtime shutdown detaches and closes the idle session only.
Shutdown ==
  /\ idle # None
  /\ state' = [state EXCEPT ![idle] = "closed"]
  /\ idle' = None
  /\ UNCHANGED <<created, requested, lease, owner, originOf,
                 ended, reusable, lastOccupied>>

Next ==
  \/ \E r \in Requests, o \in Origins : Acquire(r, o)
  \/ \E r \in Requests : MarkEnd(r)
  \/ \E r \in Requests : MarkUnusable(r)
  \/ \E r \in Requests : Release(r)
  \/ \E r \in Requests : Cancel(r)
  \/ Shutdown

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ created \subseteq Sessions
  /\ requested \subseteq Requests
  /\ lease \in [Requests -> Sessions \cup {None}]
  /\ idle \in Sessions \cup {None}
  /\ state \in [Sessions -> States]
  /\ owner \in [Sessions -> Requests \cup {"none"}]
  /\ originOf \in [Sessions -> Origins \cup {"none"}]
  /\ ended \in [Sessions -> BOOLEAN]
  /\ reusable \in [Sessions -> BOOLEAN]
  /\ lastOccupied \in [happened : BOOLEAN, before : Sessions \cup {None},
                       after : Sessions \cup {None}, surplus : Sessions \cup {None},
                       surplusClosed : BOOLEAN]

IdleActiveDisjoint ==
  idle = None \/ (state[idle] = "idle" /\
                   \A r \in Requests : lease[r] # idle)

EveryLeaseOwnsLiveSession ==
  \A r \in Requests : lease[r] = None \/
    (state[lease[r]] = "active" /\ owner[lease[r]] = r /\
      \A other \in Requests \ {r} : lease[other] # lease[r])

OnlyEndedIdle == idle = None \/ ended[idle]

IdleOriginKnown == idle = None \/ originOf[idle] \in Origins

OccupiedWinnerPreserved ==
  ~lastOccupied.happened \/
    (lastOccupied.before = lastOccupied.after /\
     lastOccupied.surplusClosed)

=============================================================================
