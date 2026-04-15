---
name: Claude Code features to explore
description: Verified but not-yet-actioned Claude Code features identified during optimisation session
type: project
originSessionId: ce5c527e-8326-43c1-b0de-927e3a2a21a0
---
## Commands
- `/effort` — model effort level (low/medium/high/max); max is Opus 4.6 only, doesn't persist
- `/recap` — context summary when returning to a session; auto-enabled, works on Bedrock
- `/loop` — recurring tasks within a session (e.g. `/loop 5m check deploy status`)
- `/powerup` — interactive lessons with animated demos

## Hooks
- `PreCompact` — block context compaction (exit code 2); useful during deployments
- `PostCompact` — side-effects after compaction (logging, notifications)
- `CwdChanged` — fires on directory change; natural fit for `direnv allow`
- `FileChanged` — fires on watched file changes; match patterns like `.envrc|.env`

## Settings
- `worktree.sparsePaths` — sparse checkout for large monorepo worktrees
- `modelOverrides` — map Anthropic model IDs to Bedrock ARNs in settings.json
- `showThinkingSummaries` — already set to `true`

## Not worth pursuing now
- OTEL tracing vars — need full telemetry pipeline
- `API_TIMEOUT_MS` — default 10 min is fine
