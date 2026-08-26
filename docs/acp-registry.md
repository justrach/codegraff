# ACP Registry listing (#613)

Listing is **not a feature of this repo**. The catalog lives in
[`agentclientprotocol/registry`](https://github.com/agentclientprotocol/registry)
and is what Zed's "Install from Registry" (and other ACP clients) reads.

This page is the submit recipe. There is no registry client in graff, and
`graff acp` does not grow one.

Hand-written Zed setup stays in the [README](../README.md#zed-external-agents--acp)
and the host recipe stays [embedding.md](embedding.md). Replace those with
"Install from Registry" only after a listing lands.

## What already ships here

| Piece | Status |
| --- | --- |
| `graff acp` stdio agent | Shipped. Protocol version 1. |
| Mid-turn `session/update` (thought / tool / text) | Shipped (ADR [0032](adr/0032-acp-streams-mid-turn.md), #612). |
| Provider login | `graff login` / keychain / env keys. Not ACP `authenticate`. |
| `initialize.authMethods` | **Missing.** Registry CI requires at least one method with `type: "agent"` or `type: "terminal"`. |
| `session/load`, `session/request_permission` | Not implemented. Unattended + `--yolo` is the host path. |

A stale comment on #613 said #612 was still open. It is not: streaming is on
the tagged v0.0.279 cut. The remaining blocker for a listing is protocol auth.

## Registry auth (the actual blocker)

The registry's [AUTHENTICATION.md](https://github.com/agentclientprotocol/registry/blob/main/AUTHENTICATION.md)
accepts only:

- **Agent Auth** — the agent runs OAuth (local callback server + browser).
- **Terminal Auth** — the client re-spawns the binary with setup args (a TUI
  login), then runs the normal ACP command.

`graff login` is already Terminal Auth in product terms. Listing still fails
until `initialize` advertises it, for example:

```json
{
  "authMethods": [
    {
      "id": "graff-login",
      "name": "graff login",
      "description": "Interactive terminal login (codegraff / Codex / Kimi)",
      "type": "terminal",
      "args": ["login"]
    }
  ]
}
```

Do not invent Agent Auth that duplicates `graff login`. Do not add env-var
auth to satisfy the registry — it is not one of the two accepted types.

CI on the registry repo runs
`python3 .github/workflows/verify_agents.py --auth-check` and rejects an
agent whose `initialize` omits `authMethods`.

## Submit recipe (other repo)

1. Fork `agentclientprotocol/registry`.
2. Add a directory whose name equals `id` (suggested: `graff/`).
3. Put `agent.json` (schema: [agent.schema.json](https://github.com/agentclientprotocol/registry/blob/main/agent.schema.json))
   and a **16×16 monochrome** `icon.svg` that uses only `currentColor` /
   `none` / `inherit` fills. Hardcoded colors fail CI.
4. Open a PR there. Versions must be pinned (no `/latest/`, no `@latest`).
   GitHub Releases + a `repository` URL let the registry bump the tag hourly.

Draft `agent.json` for the next cut that advertises Terminal Auth (URLs and
sha256 must match a real release; do not submit against `/latest/`):

```json
{
  "id": "graff",
  "name": "graff",
  "version": "0.0.279",
  "description": "Codegraff harness as an ACP agent (graff acp)",
  "repository": "https://github.com/justrach/codegraff",
  "website": "https://codegraff.com",
  "authors": ["Rach Pradhan"],
  "license": "AGPL-3.0-only",
  "distribution": {
    "binary": {
      "darwin-aarch64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.279/graff-aarch64-macos.tar.gz",
        "cmd": "./graff",
        "args": ["acp"]
      },
      "darwin-x86_64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.279/graff-x86_64-macos.tar.gz",
        "cmd": "./graff",
        "args": ["acp"]
      },
      "linux-aarch64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.279/graff-aarch64-linux.tar.gz",
        "cmd": "./graff",
        "args": ["acp"]
      },
      "linux-x86_64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.279/graff-x86_64-linux.tar.gz",
        "cmd": "./graff",
        "args": ["acp"]
      },
      "windows-aarch64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.279/graff-aarch64-windows.tar.gz",
        "cmd": "./graff.exe",
        "args": ["acp"]
      },
      "windows-x86_64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.279/graff-x86_64-windows.tar.gz",
        "cmd": "./graff.exe",
        "args": ["acp"]
      }
    }
  }
}
```

Pin `sha256` from that release's `SHA256SUMS` before the PR. Archive layout
is sometimes flat (`graff` at the tarball root) and sometimes nested
(`graff-<target>/graff`); `cmd` must match what the installer extracts.

Until `authMethods` is on the wire, this draft is documentation, not a
submission.

## Not this repo

- No `graff registry` command.
- No fetch of `cdn.agentclientprotocol.com`.
- No change to `src/acp.zig` on this continuation cut for listing.
