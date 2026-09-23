# 0181. ACP load replays a saved conversation in its workspace

Status: accepted 2026-09-23

## Context

The live ACP process returned a temporary protocol session ID while saving
under a different conversation name. A new client process could not use the
standard v1 `session/load` request to recover that conversation. The desktop
already has a startup `--resume` path, but an external ACP client needs a
stable ID and a protocol replay.

## Decision

The live ACP `session/new` ID is the saved conversation basename. Only the
live CLI advertises `loadSession`; the in-process embed has no durable store
and continues to advertise false. `session/load` accepts a validated basename
from the selected workspace, restores provider-native history, and replays
human messages, assistant messages, and saved tool calls/results from the
retained append-only transcript as ACP v1
updates before responding. An invocation with no saved result replays as a
failed historical call. Loading never reruns a tool or reconnects a shell job.

Malformed, missing, and workspace-mismatched IDs receive JSON-RPC errors.
The request cannot use a filesystem path as its session ID or discover a
same-named save in another workspace.

## Consequences

Clients can reload a conversation in a new ACP process and then prompt using
the restored provider context. GUI startup `--resume` remains a separate path.
The offline two-process fixture in `scripts/test-acp-session-load.py` checks
replay, follow-up context, and rejection of stale shell handles.
