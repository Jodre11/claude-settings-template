# Aspire Dashboard via Playwright

## URLs
- **Dashboard**: port changes each restart — ask the user for the current URL
- **API resource**: port may also change — check Aspire dashboard Resources tab
- **Web resource**: port may also change — check Aspire dashboard Resources tab

## Login
- Token-based auth — token printed in console when AppHost starts (UUID format)
- Token changes each restart — ask the user for it
- Fill token into textbox, click "Log in"

## Viewing Structured Logs
1. `playwright-cli open <dashboard-url>/` (ask user for current URL)
2. Fill token (ask user), click Log in
3. Click "Structured" link in left nav (or navigate to `/structuredlogs`)
4. Scroll to bottom: `playwright-cli press End`, then `playwright-cli snapshot`
5. Grep snapshot YAML for entries: `grep -n 'row.*master-data-import-api.*Information\|Warning\|Error'`

## Key Details
- WASM app (`localhost:7001`) requires MSAL auth — can't browse unauthenticated via Playwright
- Snapshot files are large — grep them rather than reading fully
- Snapshot YAML uses `ref=eNN` identifiers for element interaction
- Nav links: Resources (`/`), Console (`/consolelogs`), Structured (`/structuredlogs`), Traces (`/traces`), Metrics (`/metrics`)
