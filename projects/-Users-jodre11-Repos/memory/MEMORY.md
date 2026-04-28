# Memory Index

- [Workday IaC PoC](workday-iac-poc.md) — ISU setup, SOAP API details, tenant info
- [tmux Claude Wrapper](tmux-claude-wrapper.md) — zsh function wrapping claude in tmux, auth hook remote support
- [Terminal Setup](user_terminal.md) — Uses Ghostty terminal emulator
- [Cloud SearXNG](project_cloud_searxng.md) — Oracle `christian47` Stockholm, PAYG upgrade pending
- [S3 search defaults](reference_s3_search_defaults.md) — finance-prod-elevated profile, haven-finance-source-data-prod bucket

# Feedback

- [Subagent permissions](feedback_subagent_permissions.md) — allow-permission hooks workaround applied; maintain allowlist in two places
- [Temp directory convention](feedback_temp_directory_convention.md) — use session ID not $PPID; cross-platform considerations
- [CRITICAL: Haiku agent workaround](feedback_agent_haiku_model_workaround.md) — always set model: "sonnet" on Haiku agents (effort flag bug)
- [WebFetch effort param](feedback_webfetch_effort_param.md) — WebFetch fails when effort param forwarded; use curl or sonnet subagent

# Preferences

## Web Browsing
- Always invoke the `playwright-cli` skill FIRST for any web browsing, webpage viewing, or browser interaction task
- The skill guides how to use the underlying Playwright MCP tools — do not jump straight to raw MCP tools
