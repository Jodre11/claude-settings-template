---
name: web-search-tool
description: ddgr (DuckDuckGo CLI) is available for web searches — installed via Homebrew, used by the web-search skill
type: reference
originSessionId: 7aef9fa4-e54b-4074-a9e9-ee74800040d5
---
`ddgr` is installed on macOS via Homebrew and provides web search from the CLI. No API key or
tracking. Used by the `web-search` skill at `~/.claude/skills/web-search/SKILL.md`.

**Quick usage:** `ddgr --json --np -n 5 "search query"`

**When to use:** Any time you need URLs, documentation links, error message lookups, or current
information. Prefer this over guessing URLs or telling the user you can't search.
