---
name: AWS SSO cold-start auth hang
description: Claude Code hangs on cold start due to expired SSO tokens — stale credentials file + preflight/refresh guards fix it
type: project
---

Claude Code (Bedrock) hangs on cold start when SSO tokens have expired. Two root causes identified:

1. **Stale `~/.aws/credentials` file** poisons the AWS SDK credential resolution chain. The SDK
   checks this file before SSO, finds expired STS tokens, and enters a confused state where the
   first auth attempt opens the SSO start page but doesn't pick up the result. Confirmed as the
   primary cause by multiple users in anthropics/claude-code#12421.

2. **No propagation delay handling** — after `aws sso login` completes, the SDK may retry before
   the new token is fully propagated, causing a re-trigger loop.

**Fix (2026-03-30):**
- Removed `~/.aws/credentials` (backed up to `.bak.2026-03-30`) — all auth goes through SSO
- Updated `aws-sso-preflight.sh` to auto-detect and remove stale credentials files on each launch
- Updated `aws-sso-refresh.sh` (the `awsAuthRefresh` handler) with:
  - Skip-if-recently-refreshed guard (120s window)
  - Poll-after-refresh (up to 30s) to confirm credentials work before returning
  - Auto-removal of stale credentials file if it reappears

**Why:** The `~/.aws/credentials` file is created by `aws configure` or various CI tools but serves
no purpose when all auth goes through SSO. Its presence confuses the SDK's credential provider chain.

**How to apply:** If the cold-start hang returns, first check if `~/.aws/credentials` has been
recreated. The preflight/refresh scripts should auto-clean it, but if they don't run (e.g. launching
Claude without the wrapper), the file will persist and cause the same problem.

**Key references:**
- anthropics/claude-code#12421 — auth loop, removing credentials file confirmed as fix
- anthropics/claude-code#28032 — ExpiredTokenException should fast-fail
- anthropics/claude-code#9027 — SSO federation endpoint spamming
