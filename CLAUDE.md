# Repository instructions

Read `AGENTS.md` first — it is the full contract for working in this repository. The rules below are repeated here because they are non-negotiable.

Worktrees and changes to the GUI must be 1:1 with ACP. A new-chat folder rule, a worktree handoff, or a session cwd that exists only in desktop chrome is not done until the ACP session does the same thing.

## Public tracker: bare minimum, no internals, no attribution

This repository is **public**. Issues, pull requests, commits, comments, and their edit histories are visible to everyone.

- **Never post internal details.** No private-repo paths or links (website, frontend, gateway, zigrepper), no asset or deploy names, no infrastructure or performance numbers, no session/run ids, no trace or transcript excerpts, no local paths (`~/…`), no quoted user messages, no provider/model/account details. Nothing from `.graff/` traces, sessions, or tool results.
- **An issue is the bare minimum**: a generic symptom, the harness's own error text, the root cause in code terms, and the fix. Evidence stays in the conversation, not the tracker. Same for PR bodies and commit messages.
- **No assistant or model-vendor attribution anywhere** — not in issues, PRs, commit messages, or trailers. No OpenAI/Anthropic/Cursor/session links. Commits still use the repository owner's git identity as Author. When graff makes the commit, `Co-Authored-By: Codegraff <blackfloofie@codegraff.com>` is allowed (and is the only allowed trailer). Omit it if the user says not to.
- **If something sensitive was already posted, delete it** (`gh api graphql` `deleteIssue` with the issue's node id from `gh issue view N --json id`); editing is not enough because edit history stays visible. Then tell the user what was exposed and for how long.
