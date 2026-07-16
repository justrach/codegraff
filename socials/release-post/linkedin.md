# graff launch post (LinkedIn)

A single-post LinkedIn version of the graff launch, mirroring the X thread. LinkedIn renders no markdown, so the post text below is plain (no bold, no backticks). First line is the hook that shows before the "...more" fold. Every claim verified against source; same honesty guardrails as the thread.

---

Most coding agents are a few hundred megabytes of runtime that forget everything the moment you close them. We built the opposite.

Today we are launching graff: a continual learning coding harness that ships as a single native binary a couple of megabytes in size, starts in milliseconds, and runs in tens of MB of RAM.

Here is what it does:

→ Runs any model. 15 providers are built in (Anthropic, OpenAI, DeepSeek, xAI Grok, Kimi, MiniMax, GLM, Sakana Fugu, Fireworks and more), plus local models via MLX on Apple Silicon and LM Studio. One flag swaps the model, and /fallback hops to another provider when one goes down.

→ Logs in, no key-hunting. "graff login codex" signs you into ChatGPT and runs Codex over OpenAI's Responses API. "graff login xai" runs real OAuth into your Grok account, with tokens that refresh themselves.

→ Fans out. It spawns sandboxed subagents that run in parallel and report back, composed by a workflow tool into phased or pipelined fleets, with git worktree isolation for risky work.

→ Drives from your own code. Official SDKs on PyPI (pip install codegraff) and npm (npm i @codegraff/sdk), with the same typed API in both.

The part we are most excited about is the continual learning.

graff keeps an archive of every run and scores how it went, then keeps the best version of its own prompt for each kind of work: reviewing, researching, implementing, staying skeptical. Run /agents promote and it gets better the more you use it. Fleet-wide learning across everyone's runs, sharing only the prompt and a signed score and never your code, is landing next.

It has been a collaboration from day one, built with new contributors like yxlyx, and it stands on the shoulders of giants: the MAP-Elites and Darwin-Gödel-Machine research from Jeff Clune and others.

Built in Zig. Available as a CLI, a desktop app, an iOS companion, and a built-in REPL.

Try it: github.com/justrach/codegraff

What would you want a coding agent to learn first?

#AI #DeveloperTools #OpenSource #CodingAgents #Zig #ContinualLearning

---

## Posting notes

- The hook (first line) is ~130 chars so it lands fully before LinkedIn's "...more" fold on mobile.
- Plain text on purpose: LinkedIn renders no markdown, so no bold/backticks. Commands are set off with quotes; arrows (→) and hashtags are literal unicode that LinkedIn shows fine.
- To actually tag people, retype the @ mentions in the LinkedIn composer and pick their profiles (yxlyx, Jeff Clune). Plain names here will not auto-link.
- Same honesty guardrails as the thread: the continual-learning claim is the shipped local loop (archive + scored fitness + /agents promote). It does NOT claim an evolved agent beat a baseline on held-out benchmarks (no such result in the repo). Fleet-wide learning is framed as "landing next," not live. Grok is real OAuth login only, not keyless inference (xAI still account-gates api.x.ai). Size is the ReleaseFast/shipped build (~3 MB), not the stale 1.7 MB figure.
- Swap in a nicer install one-liner/site if you have one, and trim hashtags to taste (3 to 5 perform best on LinkedIn).
