---
name: Permission explainer workaround
description: permissionExplainerEnabled set to false in ~/.claude.json to work around agent team crash bug (GitHub #49253)
type: project
originSessionId: d32c8cd2-45ea-45bf-a542-80f20c4087b1
---
`permissionExplainerEnabled: false` added to `~/.claude.json` on 2026-04-16 to work around a crash when running the code-review agent team.

**Why:** Claude Code 2.1.111+ crashes (Bun process exit via React reconciler recursion) when a subagent triggers a permission prompt. Tracked in https://github.com/anthropics/claude-code/issues/49253.

**How to apply:** At the start of sessions that use agent teams, check whether #49253 is closed. If it is, remind the user to remove `"permissionExplainerEnabled": false` from `~/.claude.json` and re-enable the feature.
