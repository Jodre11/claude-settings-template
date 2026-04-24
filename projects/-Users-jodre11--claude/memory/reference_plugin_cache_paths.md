---
name: plugin-cache-paths
description: Claude Code plugin storage paths differ by source type — GitHub-sourced personal plugins use marketplaces/ not cache/
type: reference
---
Claude Code stores plugins in two different directories depending on the source type:

- **Official plugins** (from `anthropics/claude-code`): `~/.claude/plugins/cache/claude-plugins-official/<name>/<version>/`
  - Versions are commit hashes (e.g. `841ec5286650`)
- **GitHub-sourced personal plugins** (from `extraKnownMarketplaces` with `"source": "github"`):
  `~/.claude/plugins/marketplaces/<marketplace-name>/plugins/<plugin-name>/`
  - Full repo clone, no version subdirectory — auto-updates on session start

Both types have their `bin/` directory added to PATH automatically. The `marketplaces/` path
is the repo root, so plugin paths include the `plugins/` prefix from the repo structure.

**How to apply:** When referencing installed plugin paths (e.g. in verification prompts or
debugging), use `marketplaces/jodre11-plugins/plugins/<name>/` for personal plugins, not
`cache/jodre11-plugins/<name>/<version>/`.
