---
name: AWS SSO cold-start auth hang
description: Claude Code hangs on cold start due to expired SSO tokens — pre-flight check added to claude() wrapper
type: project
---

Claude Code (Bedrock) hangs for ~2.5 minutes on cold start when the SSO access token has expired overnight. Root cause is Claude Code GitHub issues #28032 (exponential backoff on expired tokens) and #18396 (in-memory credential cache not invalidated after refresh).

**Fix (2026-03-27):** Added `~/.claude/scripts/aws-sso-preflight.sh` — a local-only SSO cache check that runs before Claude Code launches via the `claude()` wrapper in `.zshrc`. Opens one browser tab for `aws sso login` only when the token is actually expired.

**Why:** The AWS SDK's built-in retry logic wastes ~2.5 min on expired tokens that will never self-heal. The pre-flight sidesteps this entirely.

**How to apply:** If the cold-start hang returns, check that the preflight script is still executable and that the `claude()` wrapper calls it. The `awsAuthRefresh` script (`aws-sso-refresh.sh`) remains as a mid-session fallback.

**Failed approach:** `credential_process = granted credential-process --profile claude-code --auto-login` caused an auth loop — Granted fires on every credential request, not just expired ones, compounded by unreliable macOS Keychain caching. Granted has been fully uninstalled and the `credential_process` line removed from `~/.aws/config`.
