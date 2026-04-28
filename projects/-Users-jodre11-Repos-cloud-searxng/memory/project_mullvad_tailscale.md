---
name: Mullvad + Tailscale DNS conflict
description: Mullvad VPN on macOS blocks Tailscale DNS (getDNSServers failed), breaking access to tailnet services like SearXNG. App-level split tunnelling doesn't fix it.
type: project
originSessionId: e094a8a2-aa79-4292-bbba-e3da64972df3
---
Mullvad's app-level split tunnelling on macOS does not properly exclude Tailscale — the firewall rules and DNS override operate below the app exclusion layer, causing "getDNSServers failed: Fallthrough, no resolvers found" in Tailscale.

**Planned fix:** Replace the Mullvad app with a raw WireGuard config that carves out Tailscale's CGNAT range (100.64.0.0/10) from AllowedIPs. This lets both tunnels coexist. Trade-off: loses Mullvad kill switch and auto-reconnect.

**Why:** SearXNG and other tailnet services (searxng.taild2db48.ts.net) are unreachable when Mullvad is active on macOS.

**How to apply:** When the user revisits this, reference the WireGuard AllowedIPs approach and the blog post at samasaur1.github.io/blog/split-tunneling-with-tailscale-and-wireguard-on-macos.
