---
name: SSH key inventory
description: Current SSH keys stored in Bitwarden vault — GitHub (regenerated 2026-03-26), Raspberry Pi, Termius iOS
type: project
---

Three SSH keys in Bitwarden, all ED25519, all verified working as of 2026-03-26:

- **GitHub** — regenerated 2026-03-26 (old key was exposed in a Claude session). Public key: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDJ4UNevIANnJaOURYVtXedahHusCvbOa1QL4zcb7rdC`
- **Raspberry Pi** — for `pi.local`
- **Termius iOS** — used from iPhone

No private keys on disk. `SSH_AUTH_SOCK` points to `~/.bitwarden-ssh-agent.sock` (set in `.zshrc`).

**Why:** Migrated from on-disk keys to Bitwarden SSH agent for centralised encrypted storage.

**How to apply:** If SSH operations fail, check Bitwarden desktop app is running and unlocked. If signing fails, check `.gitconfig` signingkey matches the current GitHub key's public key.
