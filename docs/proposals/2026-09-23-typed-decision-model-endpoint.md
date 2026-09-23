# RFC: Serve Jev as a typed-decision model

Status: proposed — 2026-09-23

## Problem

Jev accepts a state and typed questions and returns structured answers, probabilities, and confidence. That is a different contract from a chat or Responses model, which generates assistant messages and tool calls. Exposing Jev as another selectable chat model would advertise capabilities it does not have and force callers to parse or invent text that the model never produces.

We want clients to be able to buy and use Jev through the same authenticated inference service without turning it into an automatic router for other models.

## Proposal

Add a dedicated, non-streaming `POST /v1/systemone` endpoint. Use the existing service credential for caller authentication and a separately configured upstream secret for provider authentication. The request and successful response should retain Jev's native shape:

```json
{
  "model": "jev-latest",
  "state": "A short situation to evaluate",
  "questions": {
    "route": {
      "type": "choice",
      "instructions": "Which route fits this situation?",
      "criteria": { "simple": "Direct handling", "review": "Needs review" }
    }
  }
}
```

The response preserves the upstream `model`, `answers`, and `usage` fields, including Choice/Score confidence and option probabilities. Support Choice, Score, and Noul as native question types. Questions in one call remain one upstream evaluation; the service must not serialize them into multiple calls or reinterpret their outputs as generated prose.

This is a **separate API capability**, not a new alias on `/v1/chat/completions` or `/v1/responses`. Reject those endpoints for Jev with a clear capability error. If a model listing includes Jev, mark the typed-decision endpoint/capability so generic chat clients do not offer it as a coding model. A typed SDK method can follow the endpoint; the coding-agent model picker should not select Jev as the conversational engine.

## Gateway behavior

- Authenticate and apply the same account/key budget and abuse controls as other paid inference endpoints. Bound state, question count, and serialized request size before forwarding; reject malformed question shapes without an upstream call.
- Reserve a bounded estimated cost before forwarding and settle from the upstream `usage` fields. Jev's published input-token-only price is an upstream cost basis, **not automatically a customer price**; confirm the current rate and choose a customer rate/margin before launch. Do not silently make the endpoint free or let missing usage bypass settlement.
- Keep the upstream API key in the service's secret store, never in source, logs, public responses, or the model catalog. If the secret is missing, fail with a sanitized service-unavailable error.
- Forward only the caller's explicitly submitted state and questions to Jev. Document that this sends the submitted data to another provider. Do not forward conversation history, tool output, repository contents, or file paths on behalf of a coding session unless the caller explicitly submits them to this endpoint.
- Return typed answers unchanged except for any established public error-sanitization rules. Preserve per-question ids. Do not treat `confidence` as an authorization decision or hide uncertainty; policy thresholds belong to the calling application.
- Support ordinary JSON request/response first. No SSE, WebSocket, tool execution, conversation state, or prompt-cache claim in this RFC.

## Non-goals

- No automatic reasoning-effort changes or cross-model routing. That is a separate, opt-in product question.
- No drop-in replacement for an LLM-powered coding agent. Jev does not generate chat text, code, or tool calls.
- No change to the local-only data boundary of repository inspection/edit tools. A coding tool must not start shipping working data to a remote decision API merely because this endpoint exists.

## Alternatives considered

1. **Advertise Jev as a Chat Completions/Responses model:** rejected; the wire and return type are incompatible, and generic clients would mis-handle the result.
2. **Use Jev only internally as a reasoning router:** rejected for this RFC; it adds hidden data egress and a new cost/latency hop while denying callers direct access to the typed answers.
3. **Expose a typed endpoint first:** preferred; it is explicit to callers and keeps the native semantics intact.

## Acceptance criteria

- A caller with a valid service key can send one mixed Choice/Score/Noul request and receive typed answers, confidence/probabilities where defined, and upstream usage under the same question ids.
- Invalid body, oversized state, unavailable upstream secret, upstream failure, insufficient credit, and key-budget failure have bounded, sanitized responses; no key or submitted state appears in errors/logs.
- Reservation and settlement tests cover successful usage, missing/invalid usage, and client disconnect; a concurrent-request test cannot overspend one balance.
- Capability discovery and docs make clear that Jev is not a chat/coding model; Chat Completions and Responses reject its alias rather than fabricating text.
- A synthetic end-to-end smoke test confirms the native endpoint and billed usage. No real customer or repository data is needed for the test.

## Open questions

- What public alias and capability metadata should model discovery expose for typed-decision models?
- What customer price, minimum charge, and request-size limits preserve margin for small evaluations?
- Should the first release pass through the upstream model version or pin a dated version while retaining a stable public alias?
