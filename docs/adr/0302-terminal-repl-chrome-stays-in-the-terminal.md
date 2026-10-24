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
separator row with a dim rule, leaving one column free to avoid autowrap.

Standing work uses dim completed items and an emerald active item. Waiting work
remains explicit; styling never changes its state or implies completion. Keep the
bare `›`, editor behavior, scrollback, engine events and ACP unchanged. With
color disabled, omit the divider and all styling sequences.

## Consequences

This creates terminal-cell hierarchy, not native widgets, custom fonts or GPU
rendering. The external fullscreen client remains independent. Existing plain
rendering snapshots and PTY prompt-reflow checks retain the input contract;
rendering tests cover bounded dividers, active-work emphasis and mode priority.
