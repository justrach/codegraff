# Anthropic browser sign-in

`graff login anthropic` (alias `graff login ant`) signs in with native PKCE
OAuth. `/login anthropic` and `/login ant` do the same in a running session.
ACP advertises a terminal sign-in method that runs the same command; its
engine reads and refreshes the same credential as the REPL.
`graff login anthropic --refresh` explicitly refreshes an existing Graff login
without opening the browser. Browser sign-in needs the local loopback callback
on port 53692 to be free; it never cancels another application's listener.

After signing in, select the direct route with `graff --model anthropic` or
`/model anthropic`. A signed-in subscription takes precedence over an
`ANTHROPIC_API_KEY` for that route. The API key remains a metered credential;
if a subscription quota wall triggers the existing reserve-key handoff, Graff
announces the billing change and restores API-key authentication.

For an Anthropic Console account billed with API credits, use the separate
`graff login console` command. It retains the SDK-profile flow through the
`ant` CLI. Console profiles are metered credentials, not subscription logins;
they do not receive the subscription-only request adaptations.

## Credentials and compatibility

The browser flow listens on loopback before opening the authorization page,
checks the OAuth state, and exchanges the authorization code with its PKCE
verifier. Graff stores its own credentials at
`~/.anthropic/credentials/graff-oauth.json`, with a private file and directory,
using atomic replacement. It does not import Pi or Claude Code credentials.
Tokens refresh before expiry; a rejected token gets one bounded recovery
attempt through the same engine path on REPL and ACP.

OAuth requests use Bearer authorization and the subscription protocol's beta
headers, system identity preamble, and compatible tool names. Graff still owns
the actual system instructions, conversation, tool execution and cancellation.
Ordinary API-key requests keep their existing headers and prompt format.

## Upstream eligibility

This implements the protocol, not a promise that an account or third-party
application is approved. Anthropic documents prior approval for products that
offer Claude account login or subscription limits. Account eligibility,
permissions, plan limits and upstream protocol changes can prevent access.
API-key access remains supported independently. Offline protocol tests do not
prove live account approval or a successful subscription inference request.

Reference implementations: `badlogic/pi-mono`'s Anthropic OAuth and Messages
adapter; upstream policy: Claude Agent SDK overview and Claude Code
authentication documentation.

## Separate Claude CLI transport

`graff login claude-agent` (ADR 0309) uses the user's installed, signed-in
`claude` binary over its Agent SDK stream-json control protocol rather than
reading Claude Code's credentials. Graff replaces the system prompt by default,
turns off Claude Code's built-in tools, settings files, hooks, memory and
`CLAUDE.md` discovery, strips inherited session variables (including
`CLAUDE_CODE_USER_EMAIL`), and keeps tool execution in Graff. Because
subscription sign-in cannot run under `claude --bare` (`CLAUDE_CODE_SIMPLE=1`),
`claude` itself still prepends its first-turn `<system-reminder>` attachment
containing the signed-in account's `# userEmail`, `# Today's date`, and an
`# Environment` block (working directory, git-repo/worktree status, OS/kernel
version, and shell) before the user prompt. There is no silent CLI fallback
from the direct `anthropic` route.
