---
name: Raspberry Pi services
description: Pi at pi.local runs Pi-hole (DNS) and PiVPN (WireGuard VPN for family access)
type: reference
---

Raspberry Pi at `pi.local`:
- **Pi-hole** — DNS ad-blocking. Update with `pihole -up`.
- **PiVPN** — WireGuard VPN so the user's daughter can VPN into the home network. Script updates disabled; update via `sudo apt update; sudo apt upgrade`.
- SSH requires Ghostty TERM override (`SetEnv TERM=xterm-256color` in `.ssh/config`).
