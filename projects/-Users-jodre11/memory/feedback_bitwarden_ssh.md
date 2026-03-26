---
name: Bitwarden SSH agent limitations
description: Bitwarden CLI cannot import SSH keys properly; must use desktop app clipboard import. Claude terminal cannot receive Bitwarden agent auth prompts.
type: feedback
---

Bitwarden CLI `bw create item` with type 5 (SSH Key) does a raw string copy — it does not decrypt or re-serialise passphrase-encrypted keys. The agent will refuse to sign with keys imported this way.

**Why:** We burned a full session discovering this. The CLI-imported keys appeared in `ssh-add -l` but all signing operations failed with "agent refused operation".

**How to apply:**
- To import existing SSH keys into Bitwarden, use the **desktop app**: edit the SSH key item → "Import key from clipboard" button. This handles decryption and re-serialisation.
- The "Import key from clipboard" button appears on the **edit** screen, not the create screen.
- Claude Code's terminal cannot receive Bitwarden agent authorisation prompts — signing/SSH commands must be run in the user's own terminal.
- The Bitwarden desktop app must be running and unlocked for SSH operations.
