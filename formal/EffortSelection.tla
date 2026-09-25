----------------------------- MODULE EffortSelection -----------------------------
EXTENDS Integers, FiniteSets, TLC

\* A finite abstraction of one Agent's jev_effort_pending. Worker completions
\* may arrive after invalidation; only the owner may change reasoning effort.
CONSTANTS MaxGen, MutateStaleGuard
ASSUME MaxGen \in Nat \ {0}
ASSUME MutateStaleGuard \in BOOLEAN

Routes == {"routeA", "routeB", "binaryRoute", "unsupported"}
Efforts == {"none", "low", "medium", "high", "xhigh", "ultra"}
NoRoute == "unset"
NoEffort == "unset"
Phases == {"idle", "flight", "selected"}
Boundaries == {"nextRequest", "normalExit"}

Levels(r) ==
    IF r = "binaryRoute" THEN {"none", "high"}
    ELSE IF r = "routeA" \/ r = "routeB"
         THEN {"low", "medium", "high", "xhigh", "ultra"}
         ELSE {}
Eligible(r) == r # "unsupported"
Attempt == [tok : 1..MaxGen, route : Routes]

VARIABLES phase, gen, currentRoute, effort, ownerEffort,
          pendingGen, pendingRoute, pendingEffort, selectionOrigin,
          attempts, manualFence, lastWriter, lastJevGen,
          lastJevRoute, lastJevEffort, lastBoundary
vars == <<phase, gen, currentRoute, effort, ownerEffort,
          pendingGen, pendingRoute, pendingEffort, selectionOrigin,
          attempts, manualFence, lastWriter, lastJevGen,
          lastJevRoute, lastJevEffort, lastBoundary>>

Init ==
    /\ phase = "idle"
    /\ gen = 0
    /\ currentRoute = "routeA"
    /\ effort = "medium"
    /\ ownerEffort = "medium"
    /\ pendingGen = -1
    /\ pendingRoute = NoRoute
    /\ pendingEffort = NoEffort
    /\ selectionOrigin = -1
    /\ attempts = {}
    /\ manualFence = -1
    /\ lastWriter = "initial"
    /\ lastJevGen = -1
    /\ lastJevRoute = NoRoute
    /\ lastJevEffort = NoEffort
    /\ lastBoundary = "none"

\* Pending.begin: an idle slot admits one request and stamps its generation.
Begin ==
    /\ phase = "idle"
    /\ gen < MaxGen
    /\ Eligible(currentRoute)
    /\ gen' = gen + 1
    /\ phase' = "flight"
    /\ pendingGen' = gen + 1
    /\ pendingRoute' = currentRoute
    /\ pendingEffort' = NoEffort
    /\ selectionOrigin' = -1
    /\ attempts' = attempts \cup {[tok |-> gen + 1, route |-> currentRoute]}
    /\ UNCHANGED <<currentRoute, effort, ownerEffort, manualFence,
                    lastWriter, lastJevGen, lastJevRoute, lastJevEffort,
                    lastBoundary>>

\* A completion carries the token and route copied by its worker. The
\* mutation removes only Pending.commit's token equality check, leaving its
\* phase check and the separate route/allowlist checks unchanged.
Complete(a, choice) ==
    LET accepted == phase = "flight" /\ (MutateStaleGuard \/ a.tok = gen)
    IN
    /\ a \in attempts
    /\ choice \in Levels(a.route)
    /\ attempts' = attempts \ {a}
    /\ phase' = IF accepted THEN "selected" ELSE phase
    /\ pendingEffort' = IF accepted THEN choice ELSE pendingEffort
    /\ selectionOrigin' = IF accepted THEN a.tok ELSE selectionOrigin
    /\ UNCHANGED <<gen, currentRoute, effort, ownerEffort,
                    pendingGen, pendingRoute, manualFence, lastWriter,
                    lastJevGen, lastJevRoute, lastJevEffort, lastBoundary>>

\* Pending.abort on a failed/invalid Jev response. A late abort cannot clear
\* a newer admission.
Abort(a) ==
    /\ a \in attempts
    /\ attempts' = attempts \ {a}
    /\ phase' = IF phase = "flight" /\ a.tok = gen THEN "idle" ELSE phase
    /\ UNCHANGED <<gen, currentRoute, effort, ownerEffort,
                    pendingGen, pendingRoute, pendingEffort, selectionOrigin,
                    manualFence, lastWriter, lastJevGen, lastJevRoute,
                    lastJevEffort, lastBoundary>>

\* Pending.invalidate is reached by manual /effort or ACP configuration,
\* provider/model replacement, cancellation, and turn error. The worker may
\* still complete later, so attempts is deliberately not cleared.
Invalidate(kind, route, choice) ==
    /\ kind \in {"manual", "route", "cancel", "error"}
    /\ gen < MaxGen
    /\ (IF kind = "route" THEN route \in Routes ELSE route = currentRoute)
    /\ (IF kind = "manual" THEN choice \in Levels(currentRoute)
        ELSE choice = effort)
    /\ gen' = gen + 1
    /\ phase' = "idle"
    /\ currentRoute' = route
    /\ effort' = choice
    /\ ownerEffort' = choice
    /\ pendingGen' = -1
    /\ pendingRoute' = NoRoute
    /\ pendingEffort' = NoEffort
    /\ selectionOrigin' = -1
    /\ manualFence' = IF kind = "manual" THEN gen + 1 ELSE manualFence
    /\ lastWriter' = IF kind = "manual" THEN "ownerManual" ELSE lastWriter
    /\ UNCHANGED <<attempts, lastJevGen, lastJevRoute,
                    lastJevEffort, lastBoundary>>

\* Pending.take + effort_route.allows on the owning thread. Both the next
\* request boundary and normal turn exit use this transition. A route change
\* before take consumes the selection without applying it.
OwnerBoundaryKind(kind) ==
    LET allowed == pendingRoute = currentRoute
                   /\ pendingEffort \in Levels(currentRoute)
    IN
    /\ kind \in Boundaries
    /\ phase = "selected"
    /\ phase' = "idle"
    /\ effort' = IF allowed THEN pendingEffort ELSE effort
    /\ ownerEffort' = IF allowed THEN pendingEffort ELSE ownerEffort
    /\ lastWriter' = IF allowed THEN "ownerJev" ELSE lastWriter
    /\ lastJevGen' = IF allowed THEN selectionOrigin ELSE lastJevGen
    /\ lastJevRoute' = IF allowed THEN currentRoute ELSE lastJevRoute
    /\ lastJevEffort' = IF allowed THEN pendingEffort ELSE lastJevEffort
    /\ lastBoundary' = kind
    /\ UNCHANGED <<gen, currentRoute, pendingGen, pendingRoute,
                    pendingEffort, selectionOrigin, attempts, manualFence>>

OwnerBoundary == \E kind \in Boundaries : OwnerBoundaryKind(kind)
Next ==
    \/ Begin
    \/ \E a \in Attempt : \E choice \in Efforts : Complete(a, choice)
    \/ \E a \in Attempt : Abort(a)
    \/ \E kind \in {"manual", "route", "cancel", "error"} :
          \E route \in Routes : \E choice \in Efforts :
              Invalidate(kind, route, choice)
    \/ OwnerBoundary

TypeOK ==
    /\ phase \in Phases
    /\ gen \in 0..MaxGen
    /\ currentRoute \in Routes
    /\ effort \in Efforts
    /\ ownerEffort \in Efforts
    /\ pendingGen \in {-1} \cup 1..MaxGen
    /\ pendingRoute \in Routes \cup {NoRoute}
    /\ pendingEffort \in Efforts \cup {NoEffort}
    /\ selectionOrigin \in {-1} \cup 1..MaxGen
    /\ attempts \subseteq Attempt
    /\ manualFence \in {-1} \cup 1..MaxGen
    /\ lastWriter \in {"initial", "ownerManual", "ownerJev"}
    /\ lastJevGen \in {-1} \cup 1..MaxGen
    /\ lastJevRoute \in Routes \cup {NoRoute}
    /\ lastJevEffort \in Efforts \cup {NoEffort}
    /\ lastBoundary \in Boundaries \cup {"none"}

\* A first admission keeps the slot until commit, abort, or invalidation.
ActiveAdmissionIsCurrent == phase = "idle" \/ pendingGen = gen
\* Ghost provenance makes a late worker's selection observable to TLC even
\* though the Zig Pending stores only the chosen effort.
SelectedOriginIsCurrent == phase # "selected" \/ selectionOrigin = gen
\* A manual change fences all older work; only a newly admitted Jev call may
\* subsequently supersede it.
ManualWins == lastWriter # "ownerJev" \/ lastJevGen > manualFence
\* Worker completions and aborts never mutate the owner's reasoning field.
OwnerOnlyWritesEffort == effort = ownerEffort
AllowedJevApplication ==
    lastWriter # "ownerJev" \/ lastJevEffort \in Levels(lastJevRoute)

Spec == Init /\ [][Next]_vars /\ WF_vars(OwnerBoundary)
SelectedEventuallyConsumed == [](phase = "selected" ~> phase = "idle")
================================================================================
