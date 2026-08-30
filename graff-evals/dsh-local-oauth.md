# dsh + local SuperGrok OAuth

Sibling note for the eval-frontier live A/B (`dsh` / `dsh-xai` / `dsh-grok`).
Machine config only — no secret is in this repo.

## What dsh is

[deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness)
(`dsh` 0.1.1-rc.2 here). Official clone on this box: `/tmp/deepseek-harness`
(not vendored). CLI is `~/.local/bin/dsh` → `@deepseek-ai/dsh`.

It has **no SuperGrok login of its own**. Auth is:

| route | credential |
|---|---|
| `dsh-xai` / `dsh-grok` | `XAI_API_KEY` (pi-ai xAI catalog) |
| `dsh-deepseek` | `DEEPSEEK_API_KEY` — **not present**; do not invent one |
| `dsh` (luna) | `OPENAI_API_KEY` — not this hook |

pi-ai *can* store an xAI OAuth grant (`llm-pi-ai/xai`, same public client as
`graff login xai`), but the harness patches name `apiKeyEnv: XAI_API_KEY`,
so a missing env var is `MISSING_CREDENTIAL` even if a grant exists.

## What was attached (this machine)

Same seat graff and grok already use:

- `~/.xai/credentials/graff-oauth.json`
- `~/.grok/auth.json`

```sh
python3 graff-evals/attach-dsh-xai-oauth.py --install
# or: eval "$(python3 graff-evals/attach-dsh-xai-oauth.py --export-env)"
python3 graff-evals/attach-dsh-xai-oauth.py --status
```

That writes `$DSH_HOME/.credentials.yaml` (`0600`): `refs.XAI_API_KEY` plus a
`llm-pi-ai/xai` grant. The `dsh` wrapper and `~/.bashrc` export `XAI_API_KEY`
from the graff file so `run.py` inherits it. Refresh uses `auth.x.ai` and
the same public client id; near-expiry updates the graff file in place.

SuperGrok access tokens also need the **non-secret** routing header
`X-XAI-Token-Auth: xai-grok-cli` (graff sends this for `.login` tokens;
a bare Bearer is for a metered `XAI_API_KEY`). `dsh-xai.yml` and
`dsh-grok.yml` set that header.

## Live A/B

Include **`dsh-xai`** (grok-4.5 — nearest id in dsh's pi-ai catalog).
`dsh-grok` (grok-4.6) is `UNKNOWN_MODEL` on 0.1.1-rc.2. `dsh-deepseek`
stays blocked until a DeepSeek key exists.

```sh
dsh --help
dsh --profile headless --patch graff-evals/dsh-xai.yml "Reply with exactly: pong"
./run.py --harness dsh-xai --task exact-reply
```

Smoke on this box (2026-08-30), SuperGrok OAuth, no secrets:

| harness | result |
|---|---|
| `dsh --help` | 0.1.1-rc.2 usage |
| `dsh-xai` exact-reply | stdout `pong` (~2.4s) |
| `dsh-grok` | `UNKNOWN_MODEL` — catalog has no grok-4.6 |
| `dsh-deepseek` | `MISSING_CREDENTIAL` — no `DEEPSEEK_API_KEY` |
