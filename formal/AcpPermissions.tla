----------------------------- MODULE AcpPermissions -----------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC

\* Two workers may reuse both the saved session name and server request ID.
CONSTANTS BypassTokenOwner, BypassCancelGuard, BypassTokenConsume
ASSUME /\ BypassTokenOwner \in BOOLEAN
       /\ BypassCancelGuard \in BOOLEAN
       /\ BypassTokenConsume \in BOOLEAN

Generations == {1, 2}
Tokens == {"old", "new"}
NoToken == "none"
Choices == {"once", "always", "reject"}
NoChoice == "none"
ServerStates == {"idle", "pending", "denied", "granted"}
Owner(t) == IF t = "old" THEN 1 ELSE 2
TokenFor(g) == IF g = 1 THEN "old" ELSE "new"

VARIABLES gen, asked, server, offeredAlways, cancelled,
          activeToken, issued, delivered, used,
          wire, grants
vars == <<gen, asked, server, offeredAlways, cancelled,
          activeToken, issued, delivered, used, wire, grants>>

EmptyWire == [present |-> FALSE, token |-> NoToken, choice |-> NoChoice,
              route |-> 1, serverId |-> 1]

Init ==
  /\ gen = 1
  /\ asked = {}
  /\ server = "idle"
  /\ offeredAlways = FALSE
  /\ cancelled = FALSE
  /\ activeToken = NoToken
  /\ issued = {}
  /\ delivered = {}
  /\ used = [t \in Tokens |-> 0]
  /\ wire = EmptyWire
  /\ grants = <<>>

\* Bridge.ask admits one permission request at a time. We bound this model to
\* one request per generation; both use server ID 1 and session name "saved".
ServerAsk(always) ==
  /\ always \in BOOLEAN
  /\ server = "idle"
  /\ gen \notin asked
  /\ asked' = asked \cup {gen}
  /\ server' = "pending"
  /\ offeredAlways' = always
  /\ cancelled' = FALSE
  /\ UNCHANGED <<gen, activeToken, issued, delivered, used, wire, grants>>

\* The stdout reader creates a fresh, transport-local token. GUI notification
\* is separate; a response cannot be sent merely because stdout was parsed.
FrontendReceive ==
  /\ server = "pending"
  /\ activeToken = NoToken
  /\ TokenFor(gen) \notin issued
  /\ activeToken' = TokenFor(gen)
  /\ issued' = issued \cup {TokenFor(gen)}
  /\ UNCHANGED <<gen, asked, server, offeredAlways, cancelled,
                 delivered, used, wire, grants>>

GuiDeliver ==
  /\ activeToken \in Tokens
  /\ activeToken \notin delivered
  /\ delivered' = delivered \cup {activeToken}
  /\ UNCHANGED <<gen, asked, server, offeredAlways, cancelled,
                 activeToken, issued, used, wire, grants>>

\* Route lookup chooses the current worker, then respondPermission looks up
\* the token in precisely that transport. A stale GUI event may use an old
\* token with the repeated session and server ID, but must not be sent.
FrontendRespond(t, route, choice) ==
  /\ t \in issued
  /\ route \in Generations
  /\ choice \in Choices
  /\ wire.present = FALSE
  /\ t \in delivered
  /\ IF BypassTokenConsume THEN used[t] < 2 ELSE used[t] = 0
  /\ route = gen
  /\ IF BypassTokenOwner THEN TRUE ELSE activeToken = t /\ Owner(t) = route
  /\ choice # "always" \/ offeredAlways
  /\ wire' = [present |-> TRUE, token |-> t, choice |-> choice,
               route |-> route, serverId |-> 1]
  /\ used' = [used EXCEPT ![t] = @ + 1]
  /\ activeToken' = IF BypassTokenConsume THEN activeToken
                     ELSE IF activeToken = t THEN NoToken ELSE activeToken
  /\ UNCHANGED <<gen, asked, server, offeredAlways, cancelled,
                 issued, delivered, grants>>

\* Untrusted/malformed ACP input may carry an unoffered choice. The frontend
\* does not produce this action; it exercises the bridge's own allowlist.
InjectUnoffered ==
  /\ server = "pending"
  /\ ~offeredAlways
  /\ wire.present = FALSE
  /\ wire' = [present |-> TRUE, token |-> NoToken, choice |-> "always",
               route |-> gen, serverId |-> 1]
  /\ UNCHANGED <<gen, asked, server, offeredAlways, cancelled,
                 activeToken, issued, delivered, used, grants>>

\* The GUI can retire a delivered token before server cancellation is read.
FrontendCancel ==
  /\ activeToken \in Tokens
  /\ activeToken' = NoToken
  /\ UNCHANGED <<gen, asked, server, offeredAlways, cancelled,
                 issued, delivered, used, wire, grants>>

\* Bridge.cancel / inbox EOF retires the pending request and wakes ask.
ServerCancel ==
  /\ server = "pending"
  /\ server' = "denied"
  /\ cancelled' = TRUE
  /\ UNCHANGED <<gen, asked, offeredAlways, activeToken,
                 issued, delivered, used, wire, grants>>

\* A valid response already accepted by the bridge can authorize execution
\* before a later cancel. This model does not claim cancel undoes that work.
ServerAccept ==
  /\ wire.present
  /\ LET sameWorker == wire.route = gen
         offered == wire.choice # "always" \/ offeredAlways
         mayGrant == sameWorker /\ offered /\ wire.choice # "reject"
                     /\ (IF BypassCancelGuard THEN TRUE
                         ELSE server = "pending" /\ ~cancelled)
     IN /\ server' = IF mayGrant THEN "granted"
                       ELSE IF sameWorker /\ server = "pending" THEN "denied"
                       ELSE server
        /\ grants' = IF mayGrant
                     THEN Append(grants,
                          [generation |-> gen, token |-> wire.token,
                           tokenOwner |-> IF wire.token = NoToken THEN 0 ELSE Owner(wire.token),
                           choice |-> wire.choice, offered |-> offered,
                           pending |-> server = "pending",
                           wasCancelled |-> cancelled,
                           route |-> wire.route])
                     ELSE grants
  /\ wire' = EmptyWire
  /\ UNCHANGED <<gen, asked, offeredAlways, cancelled,
                 activeToken, issued, delivered, used>>

\* A new worker has its own stdin and bridge. A late frame for the prior
\* process remains addressed to that process, even if ID/session repeat.
Restart ==
  /\ gen = 1
  /\ gen' = 2
  /\ server' = "idle"
  /\ offeredAlways' = FALSE
  /\ cancelled' = FALSE
  /\ activeToken' = NoToken
  /\ UNCHANGED <<asked, issued, delivered, used, wire, grants>>

Next ==
  \/ \E a \in BOOLEAN : ServerAsk(a)
  \/ FrontendReceive
  \/ GuiDeliver
  \/ \E t \in Tokens, r \in Generations, c \in Choices : FrontendRespond(t, r, c)
  \/ InjectUnoffered
  \/ FrontendCancel
  \/ ServerCancel
  \/ ServerAccept
  \/ Restart

Spec == Init /\ [][Next]_vars

TypeOK ==
  /\ gen \in Generations
  /\ asked \subseteq Generations
  /\ server \in ServerStates
  /\ offeredAlways \in BOOLEAN
  /\ cancelled \in BOOLEAN
  /\ activeToken \in Tokens \cup {NoToken}
  /\ issued \subseteq Tokens
  /\ delivered \subseteq issued
  /\ used \in [Tokens -> {0, 1, 2}]
  /\ wire.present \in BOOLEAN
  /\ wire.token \in Tokens \cup {NoToken}
  /\ wire.choice \in Choices \cup {NoChoice}
  /\ wire.route \in Generations
  /\ wire.serverId = 1
  /\ grants \in Seq([generation : Generations, token : Tokens \cup {NoToken},
                      tokenOwner : {0, 1, 2}, choice : Choices,
                      offered : BOOLEAN, pending : BOOLEAN,
                      wasCancelled : BOOLEAN, route : Generations])

StaleTransportNeverGrants ==
  \A i \in 1..Len(grants) :
    grants[i].token = NoToken \/
      (grants[i].tokenOwner = grants[i].generation /\
       grants[i].route = grants[i].generation)

CancelNeverGrantsLate ==
  \A i \in 1..Len(grants) : grants[i].pending /\ ~grants[i].wasCancelled

UnofferedNeverGrants ==
  \A i \in 1..Len(grants) : grants[i].offered

TokenConsumedAtMostOnce == \A t \in Tokens : used[t] <= 1

=============================================================================
