# graff launch post (LinkedIn)

Final coworker framing for LinkedIn. Continual learning + tiny footprint lead. Plain text only. Same honesty guardrails as linkedin.md / twitter.md.

---

Most AI coding tools feel like rented contractors. Heavy, forgetful, and gone the moment the session ends. They do not get better the more you work with them.

My friend Yu Xi Lim and I wanted a different kind of teammate.

What if you had a coding coworker who learned from every project, stayed light enough to keep on your machine, and got better the more people worked with them?

That coworker is Graff.

Today we are introducing Graff: a continual learning coding coworker. It remembers how each run went, scores what worked, and keeps getting sharper at reviewing, researching, implementing, and staying skeptical. The more you work with it, the better it gets. Fleet-wide learning across teams is landing next, so the more people who hire graff onto their stack, the better the whole crew gets.

And this coworker is absurdly light. About 3 MB on disk. About 25 MB of RAM when focused. Spin up eight parallel teammates (with ultracode) and you are still around 15 MB total. Starts in milliseconds. Lightweight, powerful, and fast. Built in Zig.

A few providers actually let you bring a subscription instead of buying API credits. ChatGPT, xAI / X Premium, and Kimi Code are the ones that do: "graff login codex", "graff login xai", or "graff login kimi". Everyone else still works (Anthropic, OpenAI API, DeepSeek, MiniMax, GLM, Sakana Fugu, local MLX / LM Studio, and more), but those run on normal API fees (or if they have coding access), or free if you run local.

What else can this coworker do:

• Fan work out to sandboxed teammates in parallel, with git worktree isolation for risky changes
• Plug into your own systems via SDKs on PyPI and npm (https://lnkd.in/gNGxyCes)

The goal is not another confident chatbot on your team. It is a coworker that stays small, stays yours, and compounds with experience.

And Graff is already on the job. It is the coding harness behind Lawplain, and a few startups are using it too.

Open source at https://lnkd.in/gegjqJpb, with docs and the rest of the suite at https://codegraff.com.

We are building an ecosystem around this teammate, not a one-off demo.

Longer walkthrough from my AIE talk: https://lnkd.in/gYwbWBid

This is only day one. More is coming, including automated coding reviews where you pick the model (DeepSeek V4 Pro and friends).

A full PR review can already land around $0.41: https://lnkd.in/gZJizN6E

It stands on the shoulders of giants: the MAP-Elites and Darwin-Gödel-Machine research from Jeff Clune, Cong Lu, Shengran Hu, and others. Huge thanks to Pranav Pappu, Gabriel Chua, and Stefania Druga for contributing along the way.

Bring Graff onto your team, tell us what breaks, and reach out to Yu Xi or me.

curl -fsSL https://lnkd.in/gSkDvbRh | bash

https://codegraff.com

#AI #DeveloperTools #OpenSource #CodingAgents #ContinualLearning

---

## Posting notes

- Framing: Graff as coworker/teammate for LinkedIn; "coding harness" kept once for Lawplain accuracy.
- Flow: rented contractor hook → Yu Xi Lim question → coworker + continual learning → tiny footprint / ultracode team → subscription logins → capabilities → proof/ecosystem/AIE → reviews → credits → hire CTA + install.
- Honesty: local continual learning ships (archive + score + /agents promote). Fleet-wide = landing next. Footprint: ~3 MB disk, ~25 MB focused RAM, ~15 MB for 8 parallel subagents (ultracode = multi-agent workflow mode).
- Subscription OAuth that actually exist in src/cli.zig / src/oauth.zig: graff login codex, graff login xai, graff login kimi (plus bare graff login for a codegraff key). Sakana Fugu is an API-key provider (FUGU_API_KEY), not a login flow — keep it in the "everyone else" list, not the subscription sentence.
- Cost example: ~$0.41 from merjs#100 ($0.409 billed; fusion → mimo-v2.5-pro). DeepSeek V4 Pro = selectable option.
- Install one-liner short link should resolve to the harness installer (codegraff.com/install-graff.sh), not the companion tools installer (codegraff.com/install.sh).
- Credits: Yu Xi Lim co-builder; Jeff Clune / Cong Lu / Shengran Hu for MAP-Elites / DGM lineage; Pranav Pappu, Gabriel Chua, Stefania Druga thanked. Tag people in the LinkedIn composer (names here will not auto-link).
- Credit commas smoothed for LinkedIn readability.
