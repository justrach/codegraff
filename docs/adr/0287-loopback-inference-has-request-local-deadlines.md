# 0287. Loopback inference has request-local deadlines

Status: accepted 2026-10-17

## Context

Local inference can spend longer on prefill or generation than a managed
endpoint. A short first-frame or HTTP-header watchdog ends a healthy local
turn before any response arrives (#1643). Increasing shared watchdog globals
would also slow recovery for unrelated remote requests.

## Decision

Detect loopback hosts from the parsed endpoint URL, not the model name or a
hostname substring. Give their default streaming silence, HTTP-header wait,
and nonstreaming request a ten-minute allowance. Streaming prose still uses
the reconnect ladder, starting at a quarter of that allowance.

Keep explicitly configured stream, first-frame and nonstreaming deadlines,
and shortened embedded/test deadlines. Compute each allowance per request;
never change process-wide budgets. Apply this in the shared engine HTTP/1.1,
HTTP/2 and nonstreaming paths, so REPL and ACP receive the same behavior.

## Consequences

An unresponsive loopback server can take longer to time out; cancellation
remains active throughout. Remote endpoints retain their existing recovery
budgets. Private-network addresses are not assumed local: callers can set the
existing deadline overrides for those endpoints.
