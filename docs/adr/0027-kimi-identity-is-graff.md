# 0027. Kimi Coding identity is graff, device fields follow kimi-code

Status: accepted 2026-08-25

## Context

[#617](https://github.com/justrach/codegraff/issues/617) is a Windows 5xx on
`graff --model kimi` after a successful `graff login kimi`. The first-party
Kimi CLI on the same machine succeeds.

[MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code)
`packages/oauth/src/identity.ts` sends:

- User-Agent `kimi-code-cli/<semver>`
- `X-Msh-Platform: kimi_code_cli`
- `X-Msh-Device-Name`: hostname
- `X-Msh-Device-Model`: `Windows ${release()} ${arch}` / `macOS ${productVersion} ${arch}`
- `X-Msh-Os-Version`: `os.release()` (kernel), not the Zig OS tag

Moonshot's third-party docs forbid spoofing User-Agent. Graff already used the
Kimi Code OAuth client and `kimi_code_cli` platform (login works). It sent
`User-Agent: graff/<version>` with `X-Msh-Device-Name: graff` and Zig tags
(`windows x86_64`, `os_version=windows`) that do not match kimi-code's Node
shapes. That Windows-only mismatch is the header gap #617 can actually close
without impersonating the first-party CLI.

## Decision

- User-Agent stays `graff/<version>`. Do not send `kimi-code-cli/` or
  `claude-code/`.
- `X-Msh-Platform` stays `kimi_code_cli` because that is the OAuth client
  graff already uses.
- Device headers match kimi-code's field shapes: hostname, Node `os.arch()`
  names (`x64`/`arm64`), `Windows ${release} ${arch}` / `macOS ${product} ${arch}`,
  kernel `os.release()`.

## Cost

A future Kimi allowlist that requires `kimi-code-cli` in User-Agent will still
fail honestly. Spoofing would be a membership violation; this ADR forbids it.
