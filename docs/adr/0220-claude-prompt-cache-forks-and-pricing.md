# 0220. Claude prompt cache: compaction forks, turn-boundary TTL, 1-hour pricing, effort as shown

Status: accepted 2026-09-30

## Context

On the Anthropic API, graff marks two cache breakpoints: the system block
(which caches tools and system together) and the last block of the last
message. Hot context arrives as appended messages, and nothing edits history
between compactions. An audit against the prompt-caching contract found
these gaps:

- **Compaction paid full price for history the cache already held.** The
  note to self (#391) and the handoff summary each re-send the whole history.
  Neither kept the conversation's prefix: both dropped the tools, the note
  swapped in its own system prompt, and the summary cut old tool outputs to
  stubs. Each request re-read the history at the input price and wrote it
  back at 1.25x, and no later request ever read that entry. With a 1M window
  and compaction at 80%, that is two full-price passes over roughly 800K
  tokens. The note's system-prompt refresh also ran before the summary, so a
  fork could not have matched the prefix anyway.
- **An idle turn boundary bought the 1-hour TTL.** #1320 asks for the hour
  when the previous request began 3+ minutes ago. After a user idles past 5
  minutes the prefix has already expired, so the turn's first request
  rewrites all of it, and at 1 hour it paid 2x instead of 1.25x. The model is
  usually fast within the turn, so no later request needs that entry.
- **1-hour writes were priced at 1.25x.** Anthropic bills them at 2x.
  `usage.cache_creation` gives the split.
- **The effort graff showed was not the one that ran.** graff left effort off
  at its default (`medium`). On Sonnet 5.5 and Fable 5.1 the API's default is
  `high`. The Sonnet rung also runs titles and recaps, so one-line tasks ran
  at `high`.
- **One breakpoint on the messages.** A breakpoint finds an earlier entry by
  walking back at most 20 blocks. On 5.5-era models, one assistant turn that
  interleaves thinking with many parallel tool calls can add more than that.

## Decision

- **Compaction forks the conversation when the cache holds it**
  (`cache_fork.zig`). A fork is used when all of these hold:
  - The provider is the Anthropic API.
  - This agent's last request began inside the TTL it asked for.
  - No overflow is being recovered.
  - The history does not end on an unanswered tool call.
  - The previous summary attempt was usable.
  - The whole history, plus its reply, fits the window.

  In a fork, the note and the summary send the conversation's own tools,
  system prompt, thinking, effort and speed. Every message goes verbatim, with
  the instruction appended as the last user message. The note's persona leads
  its instruction. The summary sees the whole history, and nothing is trimmed.
  The note's system-prompt refresh runs after the summary, which keeps the
  cached prompt. Without a fork it runs before, as it did.
- **Otherwise the old shape runs without breakpoints.** A compaction request
  that shares no prefix gets no `cache_control`. This covers Anthropic and
  Anthropic models through OpenRouter. It is sent uncached (1x) instead of
  written (1.25x).
- **Separate model latency from the returning user's idle signal** (#1898).
  The #1320 rule is unchanged within a turn, and a turn-opening request still
  inherits the last model gap. An interactive root conversation also asks for
  the hour when it has at least two clean human user turns and either:
  - Its turn-opening request gap is between 5 and 55 minutes inclusive; or
  - The previous context meter is at least 64,000 tokens, even without a
    previous request timestamp (as can happen at an ACP turn boundary).

  The idle decision is latched throughout the turn: a fast tool follow-up
  must not downgrade its final breakpoints before the next user pause. Tool
  results, peer wakes, and provenance-marked notifications are not human
  turns. Subs, unattended one-shots, and isolated compaction requests do not
  acquire this idle premium. Both REPL and ACP use this shared request policy.
- **1-hour writes are billed at 2x** on metered seats. A price row that
  states its own write multiplier is billed as the row says.
- **5.5-era models get graff's effort as shown**, `medium` included.
  Titles and recaps run at `low`. Older models keep their own default at
  graff's default, so their sessions do not move.
- **A second breakpoint** marks the user message before the last one. That is
  where the previous request wrote its entry. Breakpoints cost nothing, and
  a write is billed only for the tokens past the hit.

## Consequences

- A compaction on a warm cache reads the history instead of rewriting it:
  roughly 0.05x of input on Opus 5.5 and 0.1x on Sonnet 5.5, instead of
  2.25x for the two passes combined. A fork that fails to produce a summary
  falls back to the old shape on the next attempt.
- The summarizer now sees full tool outputs and the recent suffix. That
  suffix is also kept verbatim after compaction.
- Sessions on Sonnet 5.5 and Fable 5.1 at graff's default now run at
  `medium`, which is lower than before.
- The original turn-boundary rule avoided paying 2x for a cold prefix but
  ignored the *next* pause. After observing a useful pause, retaining the hour
  can trade the next full 1.25x rewrite for a cache read. The current rewrite
  still costs 2x; it cannot retroactively recover an expired entry. A request
  gap includes model runtime, so it is a conservative predictor rather than
  an exact measurement of human idle. The 55-minute bound leaves headroom
  under the hour; a longer observed gap alone does not justify an upgrade.
- Returning interactive contexts above 64k anticipate a pause even when their
  request clock is fresh. This deliberately pays the hour premium for large
  conversations that never pause or never return. The first prompt and small
  conversations without an observed useful gap keep the cheaper default.
  This heuristic survives frontend request-clock resets without a global
  cross-session idle-history cache. It does not guarantee provider-side cache
  promotion on a read; the requested TTL, not an assumed hit, is the contract.
- Not done yet:
  - Exact user-idle measurements across process restarts, and proactive
    `max_tokens: 0` refreshes.
  - Mid-session system-prompt changes (goal, recorded constraints, `/strict`,
    `/ultracode`) as mid-conversation system messages.
  - Tool changes as inline tool additions.
  - A lower compaction point for 1M windows.
