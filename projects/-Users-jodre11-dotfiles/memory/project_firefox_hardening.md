---
name: Firefox hardening — implemented via arkenfox Stow package
description: Firefox privacy hardening replaced manual about:config with arkenfox user.js Stow package; pinned to 140.1; IPv4 proxy workaround can be removed
type: project
originSessionId: 02e78271-d720-451d-9351-145e646f440e
---
Firefox hardening is implemented on `feat/firefox-hardening` as a Stow package in
`~/dotfiles/firefox/` using arkenfox/user.js (pinned to release tag `140.1`).

**What it fixed:**
- Localhost OAuth (IPv6 re-enabled by clearing `network.dns.disableIPv6`)
- claude.ai (FPP replaces RFP via `prefsCleaner.sh` clearing `privacy.resistFingerprinting`)
- OAuth redirects (cross-origin referrers restored)
- WebRTC (re-enabled for video conferencing)

**Why:** User had over-applied manual `about:config` privacy settings. Arkenfox provides
a maintained, versioned baseline with `user-overrides.js` for dev-friendly customisation.

**How to apply:**
- The `claude-personal` IPv4 proxy workaround can now be removed
- To update arkenfox: bump `ARKENFOX_VERSION` in `setup.sh`, close Firefox, re-run `setup.sh`
- Cookie exceptions are batched into a single sqlite3 session; add new origins to `cookie-exceptions.sh`
