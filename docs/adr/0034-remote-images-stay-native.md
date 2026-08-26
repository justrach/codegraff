# 0034. Remote images stay native

Status: accepted 2026-08-26

## Context

The edge-safe SDK could send only `{type:"user",text}` through `graff serve`.
Putting base64 bytes in `text` did not make them model-visible pixels: the
synthetic witness in #615 returned the wrong random code. Edge callers cannot
fall back to a local clipboard or path because the harness runs elsewhere.

Graff already had one provider-specific image-message builder for normal and
`ask_user` turns (ADR 0015). The missing boundary was typed transport into that
queue, not a second vision implementation.

## Decision

- JSON `user` and `review` requests accept at most 16 `image_url` or
  `image_base64` parts. URLs must be HTTP(S). Base64 parts must name an
  `image/*` media type, decode successfully, and stay within the existing
  3.7 MB staged-image limit.
- Validate the whole request before staging any part. A rejected or cancelled
  request releases JSON inbox ownership and cannot leak images into the next
  turn.
- Preserve URLs as URLs. Convert URL/base64 parts to Anthropic, Chat
  Completions, or Responses shapes only in `vision.imageMessages`. Never paste
  encoded pixels into prompt text.
- Generate matching TypeScript and Python SDK types from `sdk/generate.py`.
  Remote callers send file bytes as base64; local filesystem paths are not a
  remote wire type.

## Consequences

Cloudflare, browser, and remote Python callers can use the supported SDK
boundary for vision. Text-only models reject image-bearing requests before a
provider call. Provider-side URL fetching retains each provider's URL-access
rules; callers that need deterministic bytes should send base64.

`scripts/test-remote-vision.py` is the opt-in end-to-end witness. On
2026-08-26, `RemoteHarness → graff serve → xai/grok-4.6` read the unpredictable
six-digit PNG code `853765`; unit tests separately lock all three provider wire
shapes and invalid-request atomicity.
