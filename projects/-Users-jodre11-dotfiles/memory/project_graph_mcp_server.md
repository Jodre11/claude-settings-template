---
name: Graph MCP server
description: Planned MCP server for Microsoft Graph access via delegated permissions — pending Haven Entra ID app registration approval
type: project
originSessionId: bbf307e6-8ea8-4ad0-9ffc-b3622c5f97b9
---
Planning an MCP server (graph-mcp) to give Claude Code agentic access to Microsoft Graph within the delegated context of the hosting user.

**Architecture decisions (2026-04-10):**
- Single-tenant app registration in Haven's Entra ID
- Delegated permissions only (never application-level)
- Device code flow for auth, long-lived refresh token cached locally
- Start read-only, expand write scopes incrementally as confidence builds
- CLI for Microsoft 365 (`pnp/cli-microsoft365`) discovered as a potential foundation — handles OAuth, token caching, and Graph API abstraction, so the MCP server could be a thin wrapper over `m365` commands

**Why:** Enable Claude Code to query email, calendar, Teams, SharePoint, etc. on behalf of the user without manual copy-paste of data into conversations.

**How to apply:** Blocked on Haven approving the Entra ID app registration. User pitched the idea to the team on 2026-04-10. Once approved, implementation can begin — start with the first read-only Graph resource the user needs.
