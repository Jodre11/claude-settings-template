---
name: CLI for Microsoft 365
description: PnP community CLI wrapping Microsoft Graph, SharePoint, Teams, Entra ID — candidate foundation for the Graph MCP server
type: reference
originSessionId: bbf307e6-8ea8-4ad0-9ffc-b3622c5f97b9
---
`pnp/cli-microsoft365` (https://github.com/pnp/cli-microsoft365) — open-source CLI (1.2k stars) that wraps Microsoft Graph and related APIs behind simple commands.

Covers: mail, calendar, Teams, SharePoint, Planner, Power Platform, Entra ID.

Handles OAuth device code flow, delegated permissions, and token caching out of the box — the exact auth layer the Graph MCP server would otherwise need to build from scratch.

Relevant for the graph-mcp project: the MCP server could shell out to `m365` commands instead of calling Graph directly, eliminating custom token management.
