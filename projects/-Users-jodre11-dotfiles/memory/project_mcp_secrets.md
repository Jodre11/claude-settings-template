---
name: MCP secrets via dotenv file
description: Datadog MCP keys stored in ~/.config/datadog/env (chmod 600), sourced at runtime by wrapper script
type: project
originSessionId: 896abf0f-d3d9-4630-87c0-06c64819a9ee
---
MCP server configuration is tracked in `~/dotfiles/mcp/.mcp.json` (Stow-symlinked to `~/.mcp.json`).
Datadog API keys are stored in `~/.config/datadog/env` (chmod 600, not tracked in git) and sourced
at runtime by `~/dotfiles/scripts/datadog-mcp.sh`.

**Why:** envchain was removed — environment variables from the keychain didn't reliably pass
through tmux sessions, making MCP server startup inconsistent. A plain dotenv file with strict
permissions is simpler and works predictably regardless of session context.

**How to apply:**
- To update Datadog keys: edit `~/.config/datadog/env` (sets `DD_API_KEY` and `DD_APP_KEY`)
- Keys are also backed up in a Bitwarden vault secure note ("Datadog MCP Keys")
- The wrapper script exports as `DATADOG_API_KEY`/`DATADOG_APP_KEY`, sets `DATADOG_SITE=datadoghq.eu`, and `exec`s the MCP server
