---
name: Firefox overhardened — blocking dev workflows
description: Firefox privacy hardening breaks localhost OAuth callbacks (IPv6), claude.ai, and other dev tools; investigating arkenfox/user.js as Stow package
type: project
originSessionId: 0a788949-b781-4658-8b2b-18b739b34092
---
Firefox is overhardened, causing breakage across multiple dev workflows.

**Confirmed issues:**
- Claude Code personal OAuth: callback server binds IPv6-only (`[::1]`), Firefox can't connect (likely `network.dns.disableIPv6 = true`)
- claude.ai doesn't work in Firefox — must use Chrome
- General auth/redirect friction across various sites

**Why:** User over-applied privacy hardening settings. The goal is hardened-but-usable, not hardened-to-the-point-of-broken.

**How to apply:** A Firefox Stow package in `~/dotfiles/firefox/` based on arkenfox/user.js with dev-friendly `user-overrides.js` is the planned approach. Once fixed, the `claude-personal` IPv4 proxy workaround can be removed. Prompt for the investigation saved at `/tmp/claude-firefox-prompt/firefox-hardening-prompt.md`.
