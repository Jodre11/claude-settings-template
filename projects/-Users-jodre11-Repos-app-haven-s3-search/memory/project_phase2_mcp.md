---
name: Phase 2 — MCP server for S3Search
description: Planned future work to expose S3Search as an MCP server so Claude Code can search S3 natively during sessions
type: project
---

Phase 2 of S3Search is an MCP server mode (`s3search serve --mcp`) that exposes ls, grep, and tree as MCP tools for Claude Code.

**Why:** The CLI tool's service layer (IS3ObjectEnumerator, IContentSearcher, IConsoleFormatter) is already decoupled from the CLI. Wrapping it as an MCP server makes S3 a first-class data source in Claude Code sessions — useful for log analysis, data exploration, and CI artifact inspection.

**Planned additions:**
- MCP server mode exposing existing commands as tools
- `head` command — first N lines of an S3 object (for peeking at file contents)
- `cat` command — full object download to stdout with size guard
- `--json` output flag — structured output for reliable machine parsing

**How to apply:** When the user starts phase 2 work, reference this plan. The service layer is ready — the main work is MCP transport wiring and the new commands.
