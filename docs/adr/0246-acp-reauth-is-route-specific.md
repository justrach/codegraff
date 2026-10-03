# 0246. ACP reauthentication recovery identifies the exact credential route

Status: accepted 2026-10-03

## Context

A terminal ChatGPT authentication rejection was an ACP internal error with
only a human-readable message. Clients could not reliably offer sign-in or
choose its credential store. ADR 0229 makes this distinction important:
`graff login codex` signs into `chatgpt-new`, not the legacy Codex CLI store.
Renewal rejection is not repaired by giving a client a login action.

## Decision

Carry fixed recovery metadata from a parsed Responses authentication failure,
after the existing bounded recovery attempts, without changing retries or
provider fallback. Only login-sourced `chatgpt-new` and `codex` credentials
qualify. Known non-auth error codes take precedence over message wording;
quota, server, transport and request-id expiry errors remain generic failures.

ACP v1 `session/prompt` returns `error.code = -32000` and `error.data`:

```json
{
  "kind": "reauth_required",
  "provider": "chatgpt-new",
  "login": { "command": "graff", "args": ["login", "chatgpt-new"] }
}
```

A legacy `codex` failure instead names `provider: "codex"` and
`login: {"command":"codex","args":["login"]}`. Its host must retain the
same `CODEX_HOME` when launching that command. The new route reads Graff's
`credentials/chatgpt-new.json`; the legacy route reads Codex CLI `auth.json`.

ACP v2 has already accepted the prompt: the same object travels on the failed
idle `state_update` in `_meta["graff/reauth"]`, alongside `graff/error`, with
`stopReason: "_error"`. Other errors keep their existing payload.

Recovery metadata contains only fixed route and command names, never raw
OAuth errors, account details, credential paths or tokens. Clear it at each
prompt/request so an old authentication failure cannot annotate a later one.

## Consequences

Clients can offer an explicit, host-side sign-in action without parsing error
text or writing the wrong store. Sign-in is out-of-band; the ACP worker and
conversation remain usable for another prompt. Clients must not silently
change a saved Codex session to the new route, automatically execute arbitrary
commands from other agents, or infer that renewal now works from this signal.
The signal identifies a rejected model credential, not the permanent/transient
cause of the preceding refresh attempt.
