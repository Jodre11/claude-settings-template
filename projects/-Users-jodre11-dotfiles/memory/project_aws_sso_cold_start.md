---
name: AWS SSO device flow redirect failure on cold browser session
description: First aws sso login of the day fails to complete OAuth callback when browser SSO session is stale — redirect goes to portal instead of localhost listener
type: project
originSessionId: ea72f1e8-e6ab-43ae-bb4a-ee05fb83cdf3
---
## The One Problem

The first `aws sso login` device flow after a cold browser SSO session fails to complete the
localhost OAuth callback redirect, even though SSO authentication itself succeeds.

## Solved (Background)

A stale `~/.aws/credentials` file was poisoning the SDK credential chain (anthropics/claude-code#12421).
This was fixed 2026-03-30 by auto-removing it in both `aws-sso-preflight.sh` and `aws-sso-refresh.sh`.
The preflight script also handles normal cold starts (new sessions with expired tokens) correctly.
These are **solved problems** — do not revisit.

## Unsolved: Cold Browser Session + Device Auth Redirect

### The Broken Flow

1. Claude is running in a tmux session from earlier in the day.
2. Overnight, the SSO token expires. The browser's SSO session is also stale.
3. Claude hits `ExpiredTokenException` → `awsAuthRefresh` hook fires `aws-sso-refresh.sh`.
4. Script runs `aws sso login --profile claude-code`.
5. CLI starts a local HTTP server (e.g. `127.0.0.1:53811`) and opens the browser to the device
   authorisation URL.
6. Browser SSO session is cold → AWS Identity Center requires full re-authentication.
7. User authenticates successfully through the IdP login flow.
8. **Redirect goes to the portal start page** (`havenholidays.awsapps.com/start/#/?tab=accounts`)
   instead of the localhost callback (`127.0.0.1:<port>/oauth/callback?code=...&state=...`).
9. Local HTTP listener never receives the OAuth callback. `aws sso login` hangs/times out.
   The running Claude session has no valid credentials.

### Why the Next Session Works

10. User starts a new Claude session.
11. `aws-sso-preflight.sh` runs `aws sso login` again.
12. Browser SSO session is now **warm** (refreshed as a side effect of step 7).
13. AWS skips re-authentication → device consent screen → redirect to localhost completes.
14. Token written, Claude launches fine.

The second session isn't doing anything special. It reaps the side effect of the failed first attempt.

### Root Cause

The device authorisation flow relies on the browser preserving the redirect target (localhost
callback URL) through the entire SSO authentication chain. When the browser session is warm, this
is a single consent-and-redirect hop. When the session is cold and requires full re-authentication,
the redirect chain passes through the IdP login flow, and the localhost callback URL is lost. AWS
Identity Center falls back to its default post-login destination: the portal start page.

The OAuth `state` parameter and redirect URI are associated with the device flow, but the IdP
login flow that interrupts it doesn't carry them through.

**Why:** This is the recurring problem we keep arriving back at after tinkering with the auth
scripts. Previous sessions have gone through multiple cycles of adjustments and ended up here.
The stale credentials and preflight fixes are done — this redirect issue is the only remaining
problem.

**How to apply:** Any proposed fix must ensure the first-of-the-day device flow completes its
OAuth callback even when the browser SSO session is cold, without breaking the already-working
flows (preflight on new sessions, mid-session refresh with warm browser sessions).

**Key references:**
- anthropics/claude-code#12421 — stale credentials file (solved)
- anthropics/claude-code#28032 — ExpiredTokenException should fast-fail
- anthropics/claude-code#9027 — SSO federation endpoint spamming
