# 0074. GUI skills and portable themes

Status: accepted

## Decision

Desktop-specific skills live with the GUI. The composer offers them through
explicit `@` and `$` mentions. The GUI's ACP adapter loads only the selected
skill and appends its instructions to that request. The engine's built-in
skills, terminal commands, and ordinary ACP clients remain unchanged.

Theme files are versioned JSON palettes under the user's themes directory.
The GUI validates bounded files and applies allowlisted color, font, and corner
settings. Themes cannot supply scripts, arbitrary CSS, remote fonts or URLs.
Appearance lists saved themes while open; selecting one stores a local
preference. Creating a theme does not select it automatically. Built-in
choices reset custom overrides, and imports cannot overwrite existing ids.

## Consequences

Agents can customize the desktop using ordinary file tools without editing
or rebuilding the application. The skill and its schema ship with the GUI.
The GUI owns discovery, validation, presentation and prompt context; the
engine continues to own coding and tool execution. Cached theme values make
the selected palette available before the first paint. No idle file polling
is needed when Appearance is closed.
