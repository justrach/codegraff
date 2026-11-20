# 0351. Prefer RLM for supported work

Status: accepted

[0140](0140-rlm-is-listed-when-available.md) makes RLM available from the first turn, but availability alone can lead the model to start a shell process for work RLM already handles.

Lead with a narrow preference in the shared RLM tool description, not in the always-on system prompt. Prefer one RLM call for independent reads, JSON row counts, and field projection. Keep direct tools and the shell available for builds, tests, Git commands, and transforms RLM cannot express. Keep `--old` and `--no-rlm` unchanged. Forcing tool choice or rewriting shell commands would interfere with legitimate fallbacks.
