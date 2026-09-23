------------------------------ MODULE AsyncTools ------------------------------
EXTENDS Naturals, FiniteSets, TLC

\* A finite abstraction of the owner-thread async tool state. IDs stand for
\* original response call IDs, not tool names or synthesized result IDs.
CONSTANTS IDs, BypassJoin, BypassDedup, BypassBarrier
ASSUME /\ IDs # {}
       /\ IsFiniteSet(IDs)
       /\ BypassJoin \in BOOLEAN
       /\ BypassDedup \in BOOLEAN
       /\ BypassBarrier \in BOOLEAN

VARIABLES partial, complete, admitted, running, done, joined,
          history, delivered, announced, presented, admittedAtBarrier, executionCount,
          historyCount, deliveryCount, barrier, hostedSeen, response,
          failed, cancelled, reset, nextRequest, fallback

vars == <<partial, complete, admitted, running, done, joined,
          history, delivered, announced, presented, admittedAtBarrier, executionCount,
          historyCount, deliveryCount, barrier, hostedSeen, response,
          failed, cancelled, reset, nextRequest, fallback>>

Init ==
  /\ partial = {}
  /\ complete = {}
  /\ admitted = {}
  /\ running = {}
  /\ done = {}
  /\ joined = {}
  /\ history = {}
  /\ delivered = {}
  /\ announced = {}
  /\ presented = {}
  /\ admittedAtBarrier = {}
  /\ executionCount = [i \in IDs |-> 0]
  /\ historyCount = [i \in IDs |-> 0]
  /\ deliveryCount = [i \in IDs |-> 0]
  /\ barrier = FALSE
  /\ hostedSeen = FALSE
  /\ response = FALSE
  /\ failed = FALSE
  /\ cancelled = FALSE
  /\ reset = FALSE
  /\ nextRequest = FALSE
  /\ fallback = FALSE

\* output_item.added and incomplete deltas never dispatch. A complete item
\* can arrive without a prior added event; only the complete item is admitted.
Partial(i) ==
  /\ i \in IDs
  /\ ~response /\ ~failed /\ ~cancelled /\ ~reset
  /\ i \notin partial
  /\ partial' = partial \cup {i}
  /\ UNCHANGED <<complete, admitted, running, done, joined, history,
                 delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen,
                 response, failed, cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

\* A hosted schema-discovery item neither dispatches nor closes admission.
HostedDiscovery ==
  /\ ~hostedSeen /\ ~response /\ ~failed /\ ~cancelled
  /\ hostedSeen' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, response, failed,
                 cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

\* A synchronous, unknown, or ineligible predecessor closes the early
\* admission prefix. Already admitted work remains owned and must be joined.
SynchronousPredecessor ==
  /\ ~barrier /\ ~response /\ ~failed /\ ~cancelled
  /\ barrier' = TRUE
  /\ admittedAtBarrier' = admitted
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, hostedSeen, response, failed,
                 cancelled, reset, nextRequest, fallback>>

CompleteEligible(i) ==
  /\ i \in IDs
  /\ (BypassBarrier \/ ~barrier) /\ ~response /\ ~failed /\ ~cancelled /\ ~reset
  /\ executionCount[i] < 2
  /\ BypassDedup \/ i \notin admitted
  /\ complete' = complete \cup {i}
  /\ admitted' = admitted \cup {i}
  /\ running' = running \cup {i}
  /\ announced' = announced \cup {i}
  /\ executionCount' = [executionCount EXCEPT ![i] = @ + 1]
  /\ UNCHANGED <<partial, done, joined, history, delivered, presented,
                 historyCount, deliveryCount, barrier, hostedSeen, response,
                 failed, cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

WorkerDone(i) ==
  /\ i \in running /\ ~reset
  /\ running' = running \ {i}
  /\ done' = done \cup {i}
  /\ UNCHANGED <<partial, complete, admitted, joined, history, delivered,
                 announced, presented, executionCount, historyCount,
                 deliveryCount, barrier, hostedSeen, response, failed,
                 cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

ResponseComplete ==
  /\ ~response /\ ~failed /\ ~cancelled /\ ~reset
  /\ response' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen, failed,
                 cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

\* The owner awaits every future after the response and before runTools.
Join(i) ==
  /\ response /\ ~cancelled /\ ~reset
  /\ i \in done \ joined
  /\ joined' = joined \cup {i}
  /\ UNCHANGED <<partial, complete, admitted, running, done, history,
                 delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen, response,
                 failed, cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

\* duplicateItem allows the first final item into history and drops repeats.
\* Repeated claim() invocations are deliberately absent: they return cached
\* results, so the property is single execution/history/delivery, not claim.
HistoryItem(i) ==
  /\ response /\ ~cancelled /\ ~reset /\ i \in admitted
  /\ historyCount[i] < 2
  /\ BypassDedup \/ i \notin history
  /\ history' = history \cup {i}
  /\ historyCount' = [historyCount EXCEPT ![i] = @ + 1]
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 delivered, announced, presented, executionCount,
                 deliveryCount, barrier, hostedSeen, response, failed,
                 cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

Deliver(i) ==
  /\ response /\ ~cancelled /\ ~reset
  /\ i \in joined \cap history
  /\ i \notin delivered
  /\ delivered' = delivered \cup {i}
  /\ presented' = presented \cup {i}
  /\ deliveryCount' = [deliveryCount EXCEPT ![i] = @ + 1]
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, announced, executionCount, historyCount, barrier,
                 hostedSeen, response, failed, cancelled, reset, nextRequest,
                 fallback, admittedAtBarrier>>

\* No next model request until owned work and its original-ID result have
\* been joined/delivered. BypassJoin is the deliberate negative mutation.
NextRequest ==
  /\ response /\ ~failed /\ ~cancelled /\ ~reset /\ ~nextRequest
  /\ BypassJoin \/ (admitted \subseteq joined /\ admitted \subseteq delivered)
  /\ nextRequest' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen, response,
                 failed, cancelled, reset, fallback, admittedAtBarrier>>

TransportFailure ==
  /\ ~response /\ ~failed /\ ~cancelled /\ ~reset
  /\ failed' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen, response,
                 cancelled, reset, nextRequest, fallback, admittedAtBarrier>>

\* Retry/fallback is available only if no async work was ever admitted.
Fallback ==
  /\ failed /\ admitted = {} /\ ~fallback /\ ~reset
  /\ fallback' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen, response,
                 failed, cancelled, reset, nextRequest, admittedAtBarrier>>

Cancel ==
  /\ ~cancelled /\ ~reset /\ ~nextRequest
  /\ cancelled' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, running, done, joined,
                 history, delivered, announced, presented, executionCount,
                 historyCount, deliveryCount, barrier, hostedSeen, response,
                 failed, reset, nextRequest, fallback, admittedAtBarrier>>

\* Future.cancel joins before the owned state can be freed. Announced UI
\* entries receive a terminal canceled result if not already presented.
CancelAndReset ==
  /\ (cancelled \/ failed) /\ ~reset
  /\ running' = {}
  /\ joined' = admitted
  /\ presented' = announced
  /\ reset' = TRUE
  /\ UNCHANGED <<partial, complete, admitted, done, history, delivered,
                 announced, executionCount, historyCount, deliveryCount,
                 barrier, hostedSeen, response, failed, cancelled,
                 nextRequest, fallback, admittedAtBarrier>>

Next ==
  \/ \E i \in IDs : Partial(i) \/ CompleteEligible(i) \/ WorkerDone(i)
                    \/ Join(i) \/ HistoryItem(i) \/ Deliver(i)
  \/ HostedDiscovery \/ SynchronousPredecessor \/ ResponseComplete
  \/ NextRequest \/ TransportFailure \/ Fallback \/ Cancel \/ CancelAndReset

TypeOK ==
  /\ \A s \in {partial, complete, admitted, running, done, joined,
                history, delivered, announced, presented, admittedAtBarrier} : s \subseteq IDs
  /\ executionCount \in [IDs -> 0..2]
  /\ historyCount \in [IDs -> 0..2]
  /\ deliveryCount \in [IDs -> 0..2]
  /\ \A b \in {barrier, hostedSeen, response, failed, cancelled,
                reset, nextRequest, fallback} : b \in BOOLEAN

OnlyCompleteItemsRun == admitted \subseteq complete
AtMostOnceExecution == \A i \in IDs : executionCount[i] <= 1
AtMostOnceHistory == \A i \in IDs : historyCount[i] <= 1
AtMostOnceDelivery == \A i \in IDs : deliveryCount[i] <= 1
JoinedBeforeNextRequest == nextRequest =>
  (admitted \subseteq joined /\ admitted \subseteq delivered)
NoLiveWorkerAfterReset == reset => running = {}
NoReplayAfterAdmission == admitted # {} => ~fallback
DeliveryHasOriginalAdmission == delivered \subseteq admitted \cap history
NoLateAdmission == barrier => admitted = admittedAtBarrier

\* Fair worker completion, owner join, history assembly, and delivery imply
\* normal progress. Cancellation may terminate that obligation instead.
FairProgress ==
  /\ \A i \in IDs : WF_vars(WorkerDone(i))
  /\ \A i \in IDs : WF_vars(Join(i))
  /\ \A i \in IDs : WF_vars(HistoryItem(i))
  /\ \A i \in IDs : WF_vars(Deliver(i))
  /\ WF_vars(NextRequest)
NormalEventuallyDelivers ==
  \A i \in IDs : (response /\ i \in admitted) ~> (i \in delivered \/ cancelled)

Spec == Init /\ [][Next]_vars /\ FairProgress
=============================================================================
