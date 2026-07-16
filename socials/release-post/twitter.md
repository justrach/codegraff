# graff launch thread (coworker framing)

A nine-post X thread mirroring the LinkedIn launch: Graff as a continual learning coding coworker. Same story beats as socials/release-post/linkedin2.md, cut for X.

Every tweet is 280 characters or fewer. Tweet 1 has no link. Tweet copy contains no em dashes or backticks.

Narrative arc: rented contractors → Yu Xi / different teammate → Graff + continual learning → light footprint / ultracode → subscription logins → fan-out + SDKs → already on the job → CTA → credits.

---

**Tweet 1: hook (167 chars)**

Most AI coding tools feel like rented contractors. Heavy, forgetful, and gone the moment the session ends.

They do not get better the more you work with them. 🧵 (1/9)

---

**Tweet 2: the question (223 chars)**

2/ My friend @yxlyx and I wanted a different kind of teammate.

What if you had a coding coworker who learned from every project, stayed light enough to keep on your machine, and got better the more people worked with them?

---

**Tweet 3: introduce Graff (207 chars)**

3/ That coworker is Graff.

A continual learning coding coworker. It remembers how each run went, scores what worked, and keeps getting sharper at reviewing, researching, implementing, and staying skeptical.

---

**Tweet 4: compounds + footprint (241 chars)**

4/ The more you work with it, the better it gets. Fleet-wide learning across teams is landing next.

And this coworker is absurdly light: about 3 MB on disk, about 25 MB of RAM when focused. Eight ultracode teammates still land around 15 MB.

---

**Tweet 5: subscription logins (215 chars)**

5/ Bring a subscription instead of buying API credits.

graff login codex for ChatGPT. graff login xai for X Premium. graff login kimi for Kimi Code.

Everyone else still works on API fees, or free if you run local.

---

**Tweet 6: fan-out and SDKs (203 chars)**

6/ What else can this coworker do?

Fan work out to sandboxed teammates in parallel, with git worktree isolation for risky changes.

Drive it from your code: pip install codegraff or npm i @codegraff/sdk

---

**Tweet 7: already on the job (189 chars)**

7/ Not another confident chatbot. A coworker that stays small, stays yours, and compounds with experience.

Graff is already on the job behind Lawplain, and a few startups are using it too.

---

**Tweet 8: close and CTA (164 raw chars, about 143 X-weighted)**

8/ Open source. Built in Zig. Docs and the rest of the suite at codegraff.com

github.com/justrach/codegraff

curl -fsSL https://codegraff.com/install-graff.sh | sh

---

**Tweet 9: credits (227 chars)**

9/ Built with @yxlyx and contributors. Thanks to Pranav Pappu, Gabriel Chua, and Stefania Druga.

Learning loop draws on MAP-Elites and Darwin Gödel Machine research by @jeffclune and collaborators.

Bring Graff onto your team.

---

## Card attachments

- Tweet 3: /social/graff-launch-02-learning.png
- Tweet 4: /social/graff-launch-01-size.png
- Tweet 5: /social/graff-launch-03-models-oauth.png
- Tweet 6: /social/graff-launch-04-fanout-worktree-sdk.png
- Tweet 7: /social/graff-launch-02-dogfood.png
- Tweet 8: /social/graff-launch-08-surfaces-cta.png
- Tweet 9: /social/graff-launch-09-credits.png

Optional extras if you want denser media: Tweet 5 can use /social/graff-launch-06-oauth.png instead of 03, and Tweet 6 can swap in /social/graff-launch-07-sdks.png. Prefer one card per tweet.

## Posting notes

- Structure mirrors linkedin2.md: rented contractors (1) -> @yxlyx teammate question (2) -> Graff coworker + learning (3) -> fleet next + footprint / ultracode (4) -> subscription logins (5) -> fan-out + SDKs (6) -> Lawplain proof (7) -> CTA / install (8) -> credits (9).
- Framing: coworker/teammate, not harness-first. Continual learning still leads the product story.
- Honesty: local continual learning ships (archive + score + /agents promote). Fleet-wide = landing next.
- Footprint: ~3 MB disk, ~25 MB focused RAM, ~15 MB for eight ultracode / parallel teammates. ultracode = multi-agent workflow mode.
- Subscription OAuth only: graff login codex, graff login xai, graff login kimi. Sakana Fugu and the rest are API-key / local, not login flows.
- Install one-liner uses install-graff.sh (harness), not install.sh (companion tools).
- Credits match LinkedIn: @yxlyx, Pranav Pappu, Gabriel Chua, Stefania Druga, @jeffclune / MAP-Elites / Darwin Gödel Machine. Tag handles in the X composer where available.

## Source verification map

- Binary and memory methodology: architecture.md and benchmarks/README.md
- ultracode multi-agent mode: src/mainloop.zig, README.md
- Evolutionary / lineage archive: README.md (An evolutionary harness), src/trace.zig
- Local promotion semantics: src/fleet.zig (promoteAgents) and src/commands_session.zig (/agents promote)
- Subscription OAuth: src/oauth.zig, src/cli.zig (codex, xai, kimi)
- Subagents, workflows, worktree: src/subagent.zig, src/schema.zig, src/workflow.zig, src/session_start.zig
- SDK packages: sdk/ts (@codegraff/sdk), sdk/py (codegraff)
- Lawplain uses graff: lawbook/ and root README positioning
