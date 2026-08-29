# ACP Registry listing (#613)

Listing is **not a feature of this repo**. The catalog lives in
[`agentclientprotocol/registry`](https://github.com/agentclientprotocol/registry)
and is what Zed's "Install from Registry" (and other ACP clients) reads.

This page is the submit recipe. There is no registry client in graff, and
`graff acp` does not grow one.

Hand-written Zed setup stays in the [README](../README.md#zed-external-agents--acp)
and the host recipe stays [embedding.md](embedding.md). Replace those with
"Install from Registry" only after a listing lands.

## Status

| Piece | Status |
| --- | --- |
| `graff acp` stdio agent | Shipped. Protocol version 1. |
| Mid-turn `session/update` (thought / tool / text) | Shipped (ADR [0032](adr/0032-acp-streams-mid-turn.md), #612). |
| Provider login | `graff login` / keychain / env keys. Not ACP `authenticate`. |
| `initialize.authMethods` | **Shipped.** `graff-login` / `type: "terminal"` / `args: ["login"]`. `authenticate` stays unused — the client re-spawns `graff login`. |
| Registry listing | **Submitted.** [`agentclientprotocol/registry#558`](https://github.com/agentclientprotocol/registry/pull/558) pins tagged **v0.0.280**. |
| `session/load`, `session/request_permission` | Not implemented. Unattended + `--yolo` is the host path. |

A listing in the other repo does not add a registry client here.

## Registry auth

The registry's [AUTHENTICATION.md](https://github.com/agentclientprotocol/registry/blob/main/AUTHENTICATION.md)
accepts only:

- **Agent Auth** — the agent runs OAuth (local callback server + browser).
- **Terminal Auth** — the client re-spawns the binary with setup args (a TUI
  login), then runs the normal ACP command.

`graff login` is Terminal Auth. `initialize` advertises it:

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

Pinned `agent.json` for **v0.0.280** (the listing currently in
[registry#558](https://github.com/agentclientprotocol/registry/pull/558)).
Archives extract as `graff-<target>/graff`; `cmd` is nested. SHA-256 values
are from that release's `SHA256SUMS`:

```json
{
  "id": "graff",
  "name": "graff",
  "version": "0.0.280",
  "description": "Codegraff harness as an ACP agent (graff acp)",
  "repository": "https://github.com/justrach/codegraff",
  "website": "https://codegraff.com",
  "authors": ["Rach Pradhan"],
  "license": "AGPL-3.0-only",
  "distribution": {
    "binary": {
      "darwin-aarch64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.280/graff-aarch64-macos.tar.gz",
        "cmd": "./graff-aarch64-macos/graff",
        "args": ["acp"],
        "sha256": "3fb1d4860338f14445955cab070f187ea9af8fe31cada19a00c2b29cc95c910b"
      },
      "darwin-x86_64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.280/graff-x86_64-macos.tar.gz",
        "cmd": "./graff-x86_64-macos/graff",
        "args": ["acp"],
        "sha256": "3d250cfe44a32367dee1dc55ca9f3eef987cda5b886c68fa3bcc771a07394d45"
      },
      "linux-aarch64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.280/graff-aarch64-linux.tar.gz",
        "cmd": "./graff-aarch64-linux/graff",
        "args": ["acp"],
        "sha256": "fbbf9d37f29eb25b74a95da0b2f523a2c754c776a78d089d96d4fdbcf48e43f5"
      },
      "linux-x86_64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.280/graff-x86_64-linux.tar.gz",
        "cmd": "./graff-x86_64-linux/graff",
        "args": ["acp"],
        "sha256": "7a2412724aa6f0c7bf4a2c5248b0619c331a5a20ffc5a17f0ed95a8f291c1bcd"
      },
      "windows-aarch64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.280/graff-aarch64-windows.tar.gz",
        "cmd": "./graff-aarch64-windows/graff.exe",
        "args": ["acp"],
        "sha256": "ad96fea65acfb650dfa934b0918c3a103bc5d037f63a087c817174b2578ba8f3"
      },
      "windows-x86_64": {
        "archive": "https://github.com/justrach/codegraff/releases/download/v0.0.280/graff-x86_64-windows.tar.gz",
        "cmd": "./graff-x86_64-windows/graff.exe",
        "args": ["acp"],
        "sha256": "25f94952cb0bcfd3d4503cf88379ded5287f8f111aa5a51715a439dd096ec0f1"
      }
    }
  }
}
```

When the next cut ships, bump `version`, archive URLs, `sha256`, and `cmd`
if the tarball layout changes. Do not submit against `/latest/`.

## Not this repo

- No `graff registry` command.
- No fetch of `cdn.agentclientprotocol.com`.
- No `authenticate` implementation (Terminal Auth is out of band).
