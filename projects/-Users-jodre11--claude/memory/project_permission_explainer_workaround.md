---
name: Permission explainer workaround
description: permissionExplainerEnabled set to false in ~/.claude.json to work around agent team crash bug (GitHub #49253)
type: project
---
**Resolved 2026-04-21.** `permissionExplainerEnabled: false` was added to `~/.claude.json` on 2026-04-16 to work around a Bun crash (#49253). The fix shipped in v2.1.114 (duplicate of #49865). The workaround was removed on 2026-04-21 (v2.1.116).
