# Architecture

## Naming and legacy Forge compatibility

Graff is the user-facing product name for the CLI and related tooling. New product copy, help text, installer output, diagnostics, and user-visible service messages should use **Graff** or `graff`.

Some Forge names intentionally remain in the architecture for compatibility, migration safety, and attribution to the original team that built the system. Do not rename these surfaces unless a migration plan explicitly preserves existing users, configs, scripts, extensions, and agent workflows.

### Compatibility surfaces that intentionally keep Forge names

- `FORGE_*` environment variables, including `FORGE_BIN`, remain supported. The shell integration currently maps `FORGE_BIN` to the `graff` executable by default, so existing shell setups can continue to work without renaming user environment variables.
- `.forge`, `.forge.toml`, and `~/.forge` remain the canonical compatibility paths. The config reader still resolves `FORGE_CONFIG`, then the legacy `~/forge` directory when present, and finally `~/.forge`.
- Internal crate, module, package, and type names such as `forge_main`, `ForgeConfig`, and `ForgeAPI` remain internal architecture names. They are not product copy and should not be renamed as part of user-facing branding cleanup.
- The built-in implementation agent id remains `forge`. This preserves existing commands such as `:agent forge`, config files, slash-command aliases, and workflows that target the default implementation agent.
- The VS Code marketplace extension id remains `ForgeCode.forge-vscode`. Marketplace identifiers are externally registered integration ids and should remain stable even when UI copy says Graff.
- Legacy zsh setup markers such as `# >>> forge initialize >>>` and `# <<< forge initialize <<<` remain recognized for migration. New setup blocks should use Graff markers, but old markers must continue to be detected and upgraded safely.
- Generated, distribution, and untracked release artifacts may still contain historical Forge references. Treat these as build or release outputs unless they are regenerated from source as part of a release process.

### Attribution

The codebase descends from ForgeCode, and some Forge naming remains as a deliberate acknowledgement of the main team that originally built the foundation. Graff should be the public product name going forward, while retained Forge identifiers document lineage, preserve compatibility, and avoid unnecessary churn in stable internal APIs.

### Guideline for future changes

When adding or editing user-facing text, prefer Graff. When touching existing Forge identifiers, first decide whether the string is product copy or a stable compatibility surface. Product copy should become Graff; stable compatibility surfaces should remain Forge unless the change includes a backwards-compatible migration.
