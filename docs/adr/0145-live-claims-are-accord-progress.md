# 0145. Live claim snapshots ride Accord progress; the file stays canonical

Status: accepted 2026-09-20

## Context

ADR 0144 pings the owner on conflict. Peers still had to read
`.graff/artifact-claims.json` to see who owns what. Accord already coalesces
replaceable `progress` frames. Putting the *only* copy of a claim on a Unix
socket would drop ownership when the duplex dies (Windows has no Accord;
`GRAFF_ACCORD=0` opts out).

## Decision

Acquire, release, and handoff still persist the JSON ledger. After a successful
write, the same JSON is sent as replaceable Accord `progress` to every live
peer sock. The file is canonical. Accord is the live replica. `GRAFF_ACCORD=0`
and tests skip the replica.

## Consequences

Live sessions see the newest ownership without polling the file. A dead socket
does not free the claim; pid liveness and the ledger still do. Revisit only if
Accord grows a durable store.
