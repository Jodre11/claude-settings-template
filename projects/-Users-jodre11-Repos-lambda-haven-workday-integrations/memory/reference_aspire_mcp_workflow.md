---
name: Aspire MCP local development workflow
description: How to start the Aspire AppHost, access MCP tools, query telemetry, open the dashboard, and shut down — includes non-obvious resource naming quirks
type: reference
originSessionId: 9d32fb2a-f166-4474-941b-7e0d4e973a32
---
## Starting

Run `./scripts/start-aspire.sh` in the background. Wait ~15 seconds for build + startup. The
dashboard URL (with login token) appears in stdout, e.g.:
`https://localhost:17250/login?t=<token>`

## MCP tools

Aspire MCP tools are configured in `.mcp.json` via stdio transport — they become available
automatically once the AppHost is running. Use `ToolSearch` with query `aspire` to load all 14
tool schemas before first use.

## Resource naming quirk

`list_resources` returns resources with a generated suffix (e.g., `account-provisioning-harness-gtnemnyx`).
However, for `list_structured_logs` and `list_traces`, **omit the resource name parameter** to get
all entries — the telemetry data uses a different resource name (`lambda-haven-workday-account-provisioning`)
that doesn't match the Aspire resource ID.

## Telemetry access

- **Structured logs:** `list_structured_logs` (no resource name) — returns severity, source,
  attributes, span/trace IDs, dashboard links
- **Distributed traces:** `list_traces` (no resource name) — appears after handler invocation
- **Per-trace logs:** `list_trace_structured_logs(traceId)` — drill into a specific trace
- **Console logs:** `list_console_logs(resourceName)` — stdout/stderr from the process

## Dashboard

Open in browser: `open "<dashboard_url_from_startup_output>"`

The dashboard has an "Invoke Handler" button that triggers `POST /run` on the Harness.

## Shutting down

```bash
pkill -f "workday-account-provisioning.AppHost"
```
