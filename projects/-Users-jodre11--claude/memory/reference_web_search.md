---
name: web-search-tool
description: web-search uses a local SearXNG instance (Docker, port 8888) — self-hosted metasearch, used by the web-search skill
type: reference
---
`web-search` is a caching Python wrapper around a local SearXNG instance running in Docker on
port 8888. No API key, no tracking, no rate limiting. SearXNG aggregates results from Google,
Bing, DuckDuckGo, Brave, Wikipedia, and GitHub.

**Quick usage:** `web-search -n 5 "search query"`

**If SearXNG is not running:** `searxng-ctl.sh start` (requires Docker Desktop).

**Plugin source:** `~/Repos/claude-code-plugins/plugins/web-search/`
**Installed path:** `~/.claude/plugins/marketplaces/jodre11-plugins/plugins/web-search/`
**SearXNG config:** `~/.local/share/searxng/` (docker-compose.yml + settings.yml, stowed from dotfiles)
**Result cache:** `~/.cache/web-search/cache.db` (SQLite, 1 hour TTL)
