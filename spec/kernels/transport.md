# Kernel: transport

Source of truth: `lean-proofs/Graff/Transport.lean`.

Process kernel, not a Turing machine: finite `Event` / `step`, no tape.
The 96-cell cube is the snapshot. A sub never takes WS; only one cell is
WS (a live root Responses turn). PromptCache isolates the child key; this
kernel is the pipe that child is forbidden from opening. Shape stays a
cube of one observation — fleet topology is not a Shape cell.

The diagram is the projection of the live Python `step`. Emit it with
`python3 spec/conformance.py --diagram transport`.

```mermaid
stateDiagram-v2
  [*] --> Sse
  Blocked --> Sub: markSub
  Blocked --> Ws: setCodexWs 1
  Blocked --> Ws: setHasOut 1
  Blocked --> Sse: setKind anthropic
  Blocked --> Sse: setKind openai
  Blocked --> Ws: setQuiet 0
  Blocked --> Ws: setWsOff 0
  Sse --> Sub: markSub
  Sse --> Blocked: setKind responses
  Sse --> Ws: setKind responses
  Sub --> Blocked: joinRoot
  Sub --> Sse: joinRoot
  Sub --> Ws: joinRoot
  Ws --> Sub: markSub
  Ws --> Blocked: setCodexWs 0
  Ws --> Blocked: setHasOut 0
  Ws --> Sse: setKind anthropic
  Ws --> Sse: setKind openai
  Ws --> Blocked: setQuiet 1
  Ws --> Blocked: setWsOff 1
```
