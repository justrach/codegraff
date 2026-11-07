# 0302. Terminal REPL chrome stays in the terminal renderer

## Context

A native UI toolkit provides windows and GPU rendering, not terminal cells.
Replacing the line REPL with a native window would change how it is launched,
its scrollback and its input contract. ADR 0245 already separates the external
fullscreen client from this repository's line REPL.

## Decision

Refine the existing terminal sinks rather than introducing a graphical toolkit
or another frontend. The status strip emphasizes session identity and operational
modes while keeping workspace and usage metadata quiet. Mode labels take width
priority over workspace metadata. A colored terminal replaces the existing blank
separator row with a faint rule and short amber leading edge, leaving one
column free to avoid autowrap. In color, separate the model and operational modes
from right-aligned, muted metadata; preserve the same width priorities. Plain
output stays compact and unpadded.

Use Harness's Codegraff Dark foreground palette: amber `#e8a33d`, cream
`#edeae2`, warm muted `#9a9384` and faint `#5c564b`, with coral errors and sage
success. Keep the legacy ANSI palette available for compatibility. Theme roles
also color attachment chips; no editor path hard-codes the former accent.
Do not change the terminal's background, font, or persistent settings.

Standing work uses muted completed and pending items, with a solid amber marker
and bold text for the active item. Plain output keeps its existing state glyphs. Waiting work
remains explicit; styling never changes its state or implies completion. Keep the
bare `›`, editor behavior, scrollback, engine events and ACP unchanged. With
color disabled, omit the divider and all styling sequences.

## Consequences

This creates terminal-cell hierarchy, not native widgets, custom fonts or GPU
rendering. The external fullscreen client remains independent. Existing plain
rendering snapshots and PTY prompt-reflow checks retain the input contract;
rendering tests cover bounded dividers, active-work emphasis and mode priority.
