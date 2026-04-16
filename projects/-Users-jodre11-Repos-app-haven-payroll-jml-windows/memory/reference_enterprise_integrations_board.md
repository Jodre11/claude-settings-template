---
name: Enterprise Integrations project board
description: GitHub project board for Enterprise Integrations team — project #135, URL format for deep-linking issues
type: reference
originSessionId: 107d65b5-9f26-40a4-8654-71c86fa1e89f
---
Enterprise Integrations board: https://github.com/orgs/HavenEngineering/projects/135

Deep-link to an issue on the board uses this URL format:
`https://github.com/orgs/HavenEngineering/projects/135?pane=issue&itemId={numeric_item_id}&issue={org}%7C{repo}%7C{issue_number}`

Example:
`https://github.com/orgs/HavenEngineering/projects/135?pane=issue&itemId=176397698&issue=HavenEngineering%7Capp-haven-payroll-jml-windows%7C25`

The `itemId` is a numeric ID (not the `PVTI_` GraphQL ID). To get it, use the project board UI or
extract from the URL after navigating to the item.
