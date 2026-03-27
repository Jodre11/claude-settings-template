---
name: Granted removed from system
description: Granted (AWS credential manager) fully uninstalled — caused auth loops with Claude Code Bedrock
type: project
---

Granted v0.38.0 was fully removed on 2026-03-27 after it caused auth loops with Claude Code's
Bedrock integration.

**Why:** The `credential_process` approach fired on every AWS credential request, not just expired
ones. Combined with unreliable macOS Keychain caching in Granted, this opened multiple browser
tabs per session. The pre-flight SSO check in the `claude()` wrapper is simpler and reliable.

**How to apply:** Do not reinstall Granted or add `credential_process` to `~/.aws/config` for
Claude Code. If Granted is needed for other AWS workflows in future, the auth loop issue must
be resolved first (likely a Granted caching bug with the macOS keychain backend).

Removed: Homebrew formula + tap, `assume` alias from `.zshenv`, `~/.granted/` config directory,
standalone binaries from `/usr/local/bin/`, `Bash(granted:*)` permission from dotfiles
settings.local.json.
