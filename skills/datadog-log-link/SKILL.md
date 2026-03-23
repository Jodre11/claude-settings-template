---
name: datadog-log-link
description: Generate Datadog Log Explorer URLs from natural language queries
user-invocable: true
arguments: Free-form natural language describing the service, environment, time range, and optional filters
---

# Datadog Log Link Generator

Generate a working Datadog Log Explorer URL from a natural language query.

## Input

`$ARGUMENTS` — free-form text. Examples:
- `staging sweeper logs from the last hour`
- `errors in the file sweeper today`
- `service:stepfunction env:production last 30 minutes`
- `coupa integration logs between 13:00 and 13:05 UTC`

## Procedure

### 1. Parse the request

Extract from `$ARGUMENTS`:
- **Service identifier** — exact (`service:lambda-haven-finance-aot-file-sweeper`) or fuzzy (`sweeper`, `file sweeper`, `coupa integration`)
- **Environment** — `dev`/`development`, `staging`/`stage`, `prod`/`production`
- **Time range** — relative (`last 15 minutes`, `last hour`, `today`) or absolute (`from 07:55 to 08:00`, `between 13:00 and 13:05 UTC`)
- **Status filter** — `errors` → `status:error`, `warnings` → `status:warn`
- **Sort preference** — explicit (`ascending`/`descending`) or inferred (see defaults in step 5)
- **Any additional free text** to include in the query

### 2. Resolve service name (if fuzzy)

If the service name is NOT an exact `service:xxx` facet, call the Datadog MCP tool to find matching services:

```
mcp__datadog__get_all_services(from=<epoch_seconds>, to=<epoch_seconds>, query="*", limit=1000)
```

Use a time window that covers the requested period. Match the user's fuzzy term against the returned service names (substring/contains match). If ambiguous (multiple plausible matches), ask the user to clarify.

### 3. Map environment names

| User says                | Datadog `env:` value |
|--------------------------|----------------------|
| `dev`, `development`     | `development`        |
| `staging`, `stage`       | `staging`            |
| `prod`, `production`     | `production`         |

### 4. Compute time range in epoch milliseconds

Use bash to convert times to epoch **milliseconds** (not seconds).

**Relative examples (macOS):**
```bash
# "last 15 minutes" → from_ts
echo $(( $(date -v-15M +%s) * 1000 ))
# "now" → to_ts
echo $(( $(date +%s) * 1000 ))
```

**Absolute examples (macOS):**
```bash
echo $(( $(date -j -f "%Y-%m-%d %H:%M:%S" "2026-02-18 07:55:00" +%s) * 1000 ))
```

**"today":** midnight UTC today for `from_ts`, now for `to_ts`:
```bash
echo $(( $(date -u -j -f "%Y-%m-%d %H:%M:%S" "$(date -u +%Y-%m-%d) 00:00:00" +%s) * 1000 ))
```

CRITICAL: `from_ts` and `to_ts` are **milliseconds** in the URL. The MCP tools use **seconds**. Always multiply by 1000.

### 5. Determine sort order

| Scenario                                          | Default sort | Rationale                       |
|---------------------------------------------------|--------------|---------------------------------|
| Bounded historical window (both start and end known) | `asc`        | Read execution flow start-to-finish |
| Open-ended / "latest" / "last N minutes"          | `desc`       | Most recent first               |
| User explicitly requests                          | Their choice |                                 |

### 6. Construct the URL

Template — **every parameter is required** for reliability:

```
https://app.datadoghq.eu/logs?query={URL_ENCODED_QUERY}&cols=host%2Cservice&index=%2A&messageDisplay=inline&stream_sort=time%2C{SORT}&viz=stream&from_ts={FROM_MS}&to_ts={TO_MS}&live=false
```

| Param            | Value                              | Notes                                          |
|------------------|------------------------------------|-------------------------------------------------|
| `query`          | URL-encoded Datadog query          | e.g. `service%3Amy-service%20env%3Astaging`     |
| `cols`           | `host%2Cservice`                   | Useful default columns                          |
| `index`          | `%2A`                              | All indexes                                     |
| `messageDisplay` | `inline`                           | Compact log view                                |
| `stream_sort`    | `time%2Casc` or `time%2Cdesc`      | Per sort defaults above                         |
| `viz`            | `stream`                           | Log list view                                   |
| `from_ts`        | Epoch milliseconds                 | Start of window                                 |
| `to_ts`          | Epoch milliseconds                 | End of window                                   |
| `live`           | `false`                            | **CRITICAL** — see rules below                  |

### 7. Return the URL

Output the constructed URL to the user. Do **NOT** attempt to open or verify via Playwright (authentication is unreliable in the MCP browser).

## Critical Rules

1. **ALWAYS set `live=false`** — Without it, Datadog silently replaces the absolute `from_ts`/`to_ts` with a relative "Past 30 Seconds" window, returning 0 results.

2. **Timestamps are milliseconds in URLs** — The MCP tools return epoch seconds. URL params need epoch milliseconds. Always `× 1000`.

3. **Do NOT use `@attribute` paths in the query** — Attributes like `@lambda.request_id` are not searchable as free text in the Log Explorer UI. Only use known indexed facets: `service:`, `env:`, `status:`, `source:`, `host:`. If the user wants to filter by a specific attribute (e.g. a request ID), use the MCP tools to narrow the time window first, then provide a time-bounded URL with just the indexed facets.

4. **Datadog site is EU** — Always use `app.datadoghq.eu`, never `app.datadoghq.com`.

5. **URL-encode the query** — Spaces → `%20`, colons are fine unencoded in query values but encode the overall query parameter properly.