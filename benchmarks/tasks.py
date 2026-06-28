"""Shared benchmark tasks: read-only questions about this repo (src/main.zig).

Read-only on purpose, so no agent can look good by editing files. Each tool runs
the SAME prompt. Edit these freely to test other kinds of work.
"""

TASKS = {
    "runEval": (
        "In src/main.zig of this repository, what does the function runEval do, "
        "and which other functions or methods does it call? Answer in 4-5 "
        "sentences. Do not modify any files."
    ),
    "permgate": (
        "In this repository, how does the permission gate decide whether a bash "
        "command needs approval, and what rule lets read-only commands run "
        "without prompting? Name the key function(s) by name. Answer in 4-5 "
        "sentences. Do not modify any files."
    ),
    "providers": (
        "In this repository, list the AI model providers graff supports, and for "
        "each give its wire-format/auth style and the environment variable for "
        "its API key. Be concise. Do not modify any files."
    ),
}
