---
name: Session init hook
description: SessionStart hook captures session_id UUID, creates temp dir, renames tmux session, injects CLAUDE_TEMP_DIR into context
type: project
originSessionId: 5bf0f026-ba82-43b7-8c4d-4c116b4bebf7
---
Replaced the fragile `pane-title-changed` tmux mechanism and manual three-word-slug temp directory convention with a `SessionStart` hook (`hooks/session-init.sh`). Implemented 2026-04-22.

**What it does:**
- Reads `session_id` (UUID) from the SessionStart stdin JSON
- Creates `/tmp/claude-<session_id>/` automatically
- Renames the tmux session to the first 8 chars of the UUID
- Injects `CLAUDE_SESSION_ID` and `CLAUDE_TEMP_DIR` into conversation context via `additionalContext`

**Why:** The old approach relied on extracting the three-word slug (e.g. `modular-napping-aho`) from plan file paths and watching terminal title changes. Claude Code kept rewriting the terminal title, causing tmux session name flickering and rogue entries in `tls`. The UUID is immutable per session.

**How to apply:**
- Use `CLAUDE_TEMP_DIR` from context for all temp file paths — don't construct paths manually
- Pass the resolved `CLAUDE_TEMP_DIR` value in subagent prompts
- The `/tmp/claude-*` glob pattern in permissions and guard hooks still works unchanged
- Changes span three repos: `claude-settings-template`, `claude-settings`, and `dotfiles`
