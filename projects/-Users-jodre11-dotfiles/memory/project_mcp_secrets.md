---
name: MCP secrets managed via envchain
description: Datadog MCP keys stored in macOS Keychain via envchain, injected at runtime by wrapper script
type: project
---

MCP server configuration is tracked in `~/dotfiles/mcp/.mcp.json` (Stow-symlinked to `~/.mcp.json`).
Datadog API keys are NOT stored on disk — they live in the macOS Keychain under the `datadog`
envchain namespace and are injected at runtime by `~/dotfiles/scripts/datadog-mcp.sh`.

**Why:** Plain-text API keys in `~/.mcp.json` were a security risk, especially with the file now
tracked in git.

**How to apply:**
- To update Datadog keys: `envchain --set datadog DATADOG_API_KEY DATADOG_APP_KEY`
- Keys are also backed up in a Bitwarden vault secure note ("Datadog MCP Keys")
- The wrapper script sets `DATADOG_SITE=datadoghq.eu` and `exec`s the MCP server
- envchain uses the macOS login keychain — no interactive prompt needed at runtime
