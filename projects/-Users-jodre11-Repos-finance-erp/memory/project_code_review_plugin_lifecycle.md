---
name: Code-review plugin lifecycle fix
description: Approved plan to fix agent team shutdown/cleanup in the code-review plugin — implementation pending in claude-code-plugins repo
type: project
originSessionId: 527dfd54-b809-46ae-a341-2a912e414b71
---
Plan approved 2026-04-21 at `/Users/jodre11/.claude/plans/proud-doodling-wirth.md`.

Work done this session (already applied, not yet committed):
- Removed `permissionExplainerEnabled: false` from `~/.claude.json` (crash bug #49253 fixed in v2.1.114)
- Restored `model: sonnet` to 9 reviewer agents, `model: opus` to code-review-team (Bedrock model bugs closed)

Implementation still pending (start in a new session from the claude-code-plugins repo):
1. Rewrite Step 6 in `includes/agent-team-review.md` with proper shutdown sequence
2. Add Step 8 to `skills/review-gh-pr/SKILL.md` for cleanup
3. Add cleanup reminder to `commands/pre-review.md`
4. Prime teammate prompts with shutdown protocol
5. Add `Bash(tmux kill-pane *)` to `~/.claude/settings.json` permissions
6. Commit model: sonnet changes already applied to agent definitions

Bugs to file against Claude Code:
- `isActive` persists after teammate shutdown (TeamDelete fails on dead processes)
- No force-shutdown for mid-turn teammates
- Dual ribbon + tmux pane display with `teammateMode: "auto"` (investigate first)

**How to apply:** Start a new session in `/Users/jodre11/Repos/claude-code-plugins`, reference the plan file, and implement.