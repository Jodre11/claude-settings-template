---
name: Always update both settings.json and allow-permissions hook together
description: New Bash permissions must be added to both settings.json permissions.allow AND allow-permissions.sh hook in the same commit
type: feedback
---

When adding a new Bash command to the allowed list, always update both:
1. `~/.claude/settings.json` → `permissions.allow` array
2. `~/.claude/hooks/allow-permissions.sh` → `case` statement

**Why:** Subagents and teammates inherit hooks but not `permissions.allow`
(anthropics/claude-code#18950). If only `settings.json` is updated, the main
session allows the command but subagents/teammates still prompt for it.

**How to apply:** Make both changes in the same commit. If you see a permission
prompt for a command that should be allowed, check both files are in sync.
