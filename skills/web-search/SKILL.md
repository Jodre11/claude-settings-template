---
name: web-search
description: Use when you need to search the web for URLs, documentation, error messages, or current information. Also use when the user asks for links or references you cannot confidently produce from memory.
---

# Web Search

Search the web via `ddgr` (DuckDuckGo CLI). No tracking, no API key.

## When to Use

- User asks for URLs or links
- Need to verify a URL before giving it to the user
- Looking up error messages, library docs, or current information
- Any time you would otherwise say "I can't search the web"

## Usage

```bash
ddgr --json --np -n 5 "search query"
```

Key flags: `--json` (machine-readable), `--np` (non-interactive), `-n N` (result count, max 25).

Pipe through `jq` to extract specific fields:

```bash
ddgr --json --np -n 3 "EFF Cover Your Tracks" | jq '.[].url'
```

## Other Useful Flags

| Flag | Purpose |
|------|---------|
| `-t d` | Results from past day |
| `-t w` | Results from past week |
| `-w SITE` | Restrict to a specific site |
| `-r us-en` | Region-specific results |

## Common Mistakes

- Forgetting `--np` — without it, `ddgr` enters interactive mode and hangs
- Forgetting `--json` — plain text output is harder to parse reliably
- Guessing URLs instead of searching — always search and verify
