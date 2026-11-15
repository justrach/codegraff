# Hard policies

Operators can restrict harness capabilities in the protected workspace file
`.harness/settings.json`. Policies are enforced in the engine, not by asking the
model to follow a prompt. Root agents follow their selected workspace; children
retain an immutable ancestor policy ceiling, including line REPL and ACP sessions.

```json
{
  "policies": [
    {"action": "provider.use", "resource": "*", "effect": "deny"},
    {"action": "provider.use", "resource": "local", "effect": "allow"},
    {"action": "tool.use", "resource": "shell", "effect": "deny"},
    {"action": "mcp.use", "resource": "production-*", "effect": "deny"},
    {"action": "skill.use", "resource": "deploy*", "effect": "deny"},
    {"action": "plugin.use", "resource": "unreviewed-*", "effect": "deny"},
    {"action": "websearch.use", "resource": "*", "effect": "deny"}
  ]
}
```

Replace the illustrative provider and plugin IDs with installed IDs. Each
statement has exactly `action`, `resource`, and `effect`. Resources are
case-sensitive full-name matches: `*` matches any sequence, including empty;
other characters are literal (there is no regex, `?`, or glob escaping).
Actions are exact names, not patterns. Effect is `allow` or `deny`.

Rules run in order; the **last matching rule wins within that action**.
Unmatched capabilities are unchanged. A missing file, absent `policies`, or an
empty array preserves existing defaults. An allow only clears this policy gate:
it never overrides another action's denial, read-only or plan mode, approvals,
sandboxing, MCP consent/schema loading, protected settings, budget limits, or
other unconditional security checks. For example, allowing `tool.use` on an MCP
function does not override `mcp.use` denying its server.

## Actions and resources

| Action | Resource | Enforcement |
| --- | --- | --- |
| `provider.use` | Resolved provider ID, not model name or URL | Check the actual request route on every request/rebuild, including fallback; RLM `llm_query` also checks its provider before sending. |
| `tool.use` | Tool function name; hosted tool type for server-executed tools | Root/child admission before meta dispatch, execution backstop before native/RLM execution, and wire-catalog filtering. |
| `mcp.use` | Raw server ID from MCP configuration | Before server startup and before calls, including RLM; a tool's escaped wire name does not replace its raw server identity. |
| `skill.use` | Canonical discovered skill name | Discovery/list filtering and a fresh check before named body loads, including already-cached skill entries. |
| `plugin.use` | Plugin ID | Plugin discovery and runtime plugin execution. |
| `websearch.use` | Provider ID (`codex` or `xai` on implemented hosted routes) | Remove hosted `web_search` and xAI `x_search` before sending the Responses tools payload, after hosted tools are spliced in. |

The shell family (`shell`, `bash`, `bash_output`, `bash_kill`) is one capability.
A denial on any family name restricts every spelling, including legacy RLM
calls. To re-enable it after a deny, override the same resource(s) you denied;
an allow for a different alias cannot sidestep the restriction.

`websearch.use` covers the harness's real hosted search integrations, not an
invented universal search API. MCP-based search is controlled with `mcp.use`
and/or its qualified `tool.use` name. `webfetch`, arbitrary shell HTTP clients,
and network activity inside a plugin are not magically classified as search:
restrict those capabilities separately when required.

## Invalid policy and updates

Malformed JSON, a non-array `policies`, unknown actions, missing/extra statement
fields, invalid effects/resources, unreadable settings, or an oversized file
fail closed. Errors name `.harness/settings.json` and, for individual statement
errors, the zero-based `policies[N]` to fix. Resources must be nonempty, at most
512 bytes, and free of control characters; at most 1024 statements and a 1 MiB
settings file are supported. The whole array is validated before any allow can
apply. JSON duplicate keys are rejected.

Local configuration is read afresh from each agent's selected workspace at
checks. Children additionally retain an immutable snapshot of their ancestors'
restrictions, captured before isolation: missing child settings or local allows
cannot lift an ancestor denial. Grandchildren inherit the same ceiling, and
detached workers own their snapshots. Explicit root workspace changes or later
root edits do not replace ceilings in existing children; new children capture
the updated root policy.

There is no permanent local allow cache keyed only by a relative filename, or
timestamp/size-only cache that misses atomic replacement or same-size edits.
Policies do not cancel an operation already admitted/running when the operator
changed them.

Only the operator should edit this file. Existing protected-write checks still
block model file tools from changing harness policy; policies are not a
replacement for OS isolation against an already-authorized arbitrary shell or
external program. An operator who grants unrestricted shell execution also
grants that program filesystem access under the existing sandbox.

Catalog filtering is defense in depth, not the security boundary: an old
conversation can still contain previously advertised descriptions or loaded
skill text. Execution/body-load checks apply current local policy and inherited
ceilings, so a historical
catalog or an RLM/meta call cannot grant a newly denied capability. Policies do
not erase instructions already in a model's context or retract external work
already started. Native GUI focus behavior and external harness-internal tools
remain governed by their existing mechanisms, not by a claim of universal
interception.
