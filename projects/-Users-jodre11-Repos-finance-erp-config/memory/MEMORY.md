# Finance ERP Config - Memory

## Transformer Rule Execution (finance-erp)
- Rules in `CheckFieldConfig` are applied **cumulatively in array order**
- Each rule mutates the `Accounts` object in place; subsequent rules see prior mutations
- Source: `TransformerExtensions.CheckAndReplaceFields` in finance-erp repo
- `exact` and `contains` CheckTypes both match against **current live field value**
- See [transformer-rules.md](transformer-rules.md) for details

## Skills
- `/review-pr` skill located at `~/.claude/skills/review-pr/skill.md`
- Updated 2026-03-16: Added Step 4 "Re-check PR State Before Posting" to handle delays between analysis and user verdict
- Step 1 GraphQL query fetches all replies (first: 10) with author info, not just first comment
