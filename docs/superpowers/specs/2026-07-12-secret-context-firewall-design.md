# Secret Context Firewall — Design

**Date:** 2026-07-12
**Status:** Approved design, pre-implementation
**Repos:** `~/.claude` (claude-settings, via `.tmpl` hydration) **and** `~/Repos/claude-settings-template/` (public seed) — ship to both.

## Problem

Assure with high certainty that Claude or any subagent never reads a **secret value** into
context or the transcript, where it could be (a) sent to Bedrock on the next turn, (b) persisted
on disk in the JSONL transcript, (c) propagated to a subagent/MCP server, or (d) exported via
OTEL telemetry. Secrets may still be **manipulated indirectly by scripts** (fetch-and-redirect
to a file is fine; print-to-context is not). Any inadvertent capture must be flagged
**immediately and loudly** so the credential can be regenerated swiftly.

## Foundational constraint (why prevention-first)

A value cannot be un-read. Once a tool result exists, it is in the transcript and is sent to
Bedrock on the next turn — i.e. off-machine, irreversibly. Therefore the guarantee must be
built on **blocking dangerous actions before they run** and **scrubbing tool output before it
egresses**, with detection/alarm as the residual-risk net. This is not an alarm-only design.

### Verified platform capabilities (source: code.claude.com/docs/en/hooks, 2026-07-12)

- `PreToolUse` → `hookSpecificOutput.permissionDecision: "deny"` blocks a tool call before it
  executes. (Already used by this repo's `_lib.sh` `hook_deny`.)
- `PostToolUse` → `hookSpecificOutput.updatedToolOutput` **replaces the tool result before the
  model sees it.** This is the linchpin: a secret-shaped value in a result can be scrubbed to a
  redaction marker *before it reaches Bedrock on the next turn*.
- `PostToolUse`/`PreToolUse`/`UserPromptSubmit` → `additionalContext` injects text the model
  reads (used for the loud alarm).
- `UserPromptSubmit` → `decision: "block"` blocks (and erases) a prompt; it **cannot** rewrite
  it. So a live secret pasted into a prompt is blocked, not silently redacted.

## Honest certainty boundary

- **Known secret shapes and known secret-bearing paths → prevented deterministically** (Layers 1–2).
- **Novel-shaped secret from an unexpected source → caught-and-scrubbed at the last local moment
  by the `PostToolUse` scanner, then alarmed loudly.** Scrub happens before Bedrock egress.
- **Irreducible gap:** a secret whose shape no pattern recognises at all will pass. We minimise
  this gap (broad high-precision pattern set) but do not claim to eliminate it. This is stated
  so "high certainty" is not oversold.

## Architecture — three layers + cross-cutting

### Layer 1 — Prevent (block before execution)

**`PreToolUse:Bash` — command-shape blocklist** (`hooks/secret-bash-guard.sh`):
Deny commands that print secrets to stdout:
- `env`, `printenv` (bare, or grepping secret-ish names)
- `echo`/`printf` of a `$SECRET`-style variable
- `cat`/`less`/`more`/`head`/`tail`/`xxd`/`strings` of a **denylisted path** (see path list)
- `aws secretsmanager get-secret-value …`, `aws ecr get-login-password …`, and similar
  secret-emitting commands **unless** output is redirected to a `/tmp/claude-*` session file or
  piped into a script.

**Indirect-manipulation carve-out (decided: strict):** the secret-fetch commands are allowed
**only** when redirected to a `/tmp/claude-*` path (`> /tmp/claude-…`) or piped (`| …`) into a
script. Bare stdout is denied. This honours "manipulate indirectly by scripts is permitted"
while keeping the value out of context. Aligns with the existing `$CLAUDE_TEMP_DIR` policy.

**`PreToolUse:Read|Grep|Glob` — path denylist** (`hooks/secret-path-guard.sh`):
Deny reads of secret-bearing paths. Initial denylist:
`.env`, `.env.*`, `*.pem`, `*.key`, `*.p12`, `*.pfx`, `id_rsa*`, `id_ed25519*`, `~/.ssh/**`
(private keys; `*.pub` allowed), `~/.aws/credentials`, `.netrc`, `config.env`,
`*.tfvars` containing secrets, `credentials.json`, `.npmrc` (auth token), `.pgpass`.
`config.env.example` and `*.tmpl` are allowlisted (placeholders, not real values).

**the organisation org-specific convention (local `.tmpl` only — placeholder slot in the public template):**
the organisation repos encrypt secrets at rest in git via [Strongbox](https://github.com/uw-labs/strongbox),
keyed on a `**/secrets/**` directory convention (`.gitattributes`: `**/secrets/** filter=strongbox`).
Critically, **strongbox protects secrets in git, not in the working tree** — the checked-out copy is
decrypted plaintext, so a `Read`/`cat` of a file under `**/secrets/**` pulls the decrypted secret
straight into context. This is a deterministic **path** convention (not a value shape), so it is
high-precision with zero false positives. Add to the denylist:
`**/secrets/**`, `**/.strongbox-keyid`, `**/.strongbox_keyring`, `*.secret`.
The public template ships this as a commented placeholder showing where an org plugs in its own
secret-path convention; the concrete the organisation entries stay in `~/.claude` only.

**Scale finding (2026-07-12):** `~/Repos/<checkout>` holds ~37 repos; **7** use the strongbox
`**/secrets/**` filter (`internal-repo-a`, `internal-repo-b`, `internal-repo-c`,
`internal-repo-d`, `internal-repo-e`, `internal-repo-f`, `internal-repo-g`),
with **~180 `secrets/` directories** across the working trees — each decrypted plaintext, each a
read-into-context risk. This scale rules out per-repo `settings.local.json` deny blocks (they don't
cover future clones or worktrees and guarantee gaps).

**Interim stopgap applied (2026-07-12) — user-level, global:** the denylist was promoted to the
**user-level `permissions.deny`** in `~/.claude/settings.json` (immediate effect) and its hydration
source `~/.claude/settings.json.tmpl`, plus the paired public template's `settings.json.tmpl`:
`Read(**/secrets/**)`, `Read(**/.strongbox-keyid)`, `Read(**/*.secret)`,
`Bash(cat|strings|xxd **/secrets/**)` (the existing `~/.strongbox_keyring` entries were retained).
This one config covers all 7 strongbox repos, all ~180 dirs, and every future clone — in every
repo, not just the organisation (global scope chosen deliberately: defensive by default). The two per-repo
blocks initially added were reverted as redundant. The hook-based firewall supersedes this stopgap
once shipped, adding the runtime-fetch guard + output scrubber the deny list cannot provide.

**`UserPromptSubmit` — inbound prompt scan** (`hooks/secret-prompt-guard.sh`):
Scan the submitted prompt against the secret-shape patterns; `decision: "block"` + reason if a
live credential shape is present, so a pasted key never enters context.

### Layer 2 — Scrub before egress (linchpin)

**`PostToolUse` (all tools)** (`hooks/secret-output-scrubber.sh`):
Scan `tool_response` against **secret-shape patterns only** (high precision — the
`ALWAYS_PATTERNS` set, NOT the identity/org patterns, which would be noisy and are a git-time
concern). On match:
1. Emit `hookSpecificOutput.updatedToolOutput` with each matched span replaced by
   `[REDACTED-SECRET-BREACH:<class>]`. The model/Bedrock never receive the raw value.
2. Trigger Layer 3 (breach response).

Because Claude Code hooks are global, this also covers **MCP tool results and subagent tool
calls** — satisfying the subagent/MCP propagation surface.

**Scanner engine (decided): regex-only.** High-precision in-hook bash/grep regex, ~5–15ms per
call. `gitleaks` remains the **git-time** engine (`.githooks/pre-commit`), not run per tool call
(100–200ms/call latency rejected). No opt-in deep scan for now (YAGNI; revisit if a real miss
occurs).

### Layer 3 — Breach response (fires on any Layer 2 match)

Implemented in a shared `hooks/secret-breach-alarm.sh` invoked by the scrubber:
1. **Loud in-conversation alarm** via `additionalContext`: names the secret class, the source
   tool + file/command, and instructs "REGENERATE THIS CREDENTIAL NOW — it may have reached the
   prior turn's context." The model must surface this to the user immediately.
2. **OS-level notification**: `osascript -e 'display notification …'` + audible bell (out-of-band
   alert even if the transcript isn't being watched). macOS-only; guarded for portability.
3. **Breach ledger**: append a timestamped record (UTC, secret class, source, session id) to
   `~/.claude/breach-ledger.log` — a durable regenerate-me checklist. Ledger stores **class and
   source only, never the value**.
4. **On-disk transcript scrub**: replace the raw value in the session JSONL transcript under
   `~/.claude/projects/**/*.jsonl` with the redaction marker (belt-and-braces, in case the raw
   value was persisted before `updatedToolOutput` took effect). Path/format to be confirmed
   empirically during implementation before relying on it.

### Cross-cutting concerns

- **DRY secret patterns:** extract `ALWAYS_PATTERNS` into `hooks/secret-patterns.sh`, sourced by
  the runtime hooks **and** `.githooks/pre-commit`. Single source of truth. Identity/org patterns
  stay in pre-commit only (git-time concern, noisy at runtime).
- **Env hygiene (upstream reducer):** audit that Claude Code's process env does not carry live
  secrets that a stray `env` would dump. Document guidance; do not over-engineer.
- **Telemetry hygiene:** confirm the OTEL config (`OTEL_LOGS_EXPORTER=otlp`) does not export
  prompt/response bodies. Since Layers 1–2 keep secrets out of context, they cannot ride
  telemetry — but verify the collector config carries no message content. Documentation +
  a one-time check, not new code.
- **Escape hatch:** a `CLAUDE_ALLOW_SECRET_READ=1` env override for the rare deliberate case,
  mirroring `SKIP_SECRET_SCAN=1` in pre-commit. Logged loudly to the ledger when used.

## Components & interfaces

| Component | Event / trigger | Input | Output / effect |
|---|---|---|---|
| `secret-patterns.sh` | sourced library | — | exports `SECRET_PATTERNS` array + `scan_for_secrets()` |
| `secret-bash-guard.sh` | `PreToolUse:Bash` | `tool_input.command` | `permissionDecision: deny` on print-to-stdout secret cmd |
| `secret-path-guard.sh` | `PreToolUse:Read\|Grep\|Glob` | `tool_input.file_path`/pattern | `deny` on denylisted path |
| `secret-prompt-guard.sh` | `UserPromptSubmit` | prompt text | `decision: block` on live-secret shape |
| `secret-output-scrubber.sh` | `PostToolUse` (all) | `tool_response` | `updatedToolOutput` (redacted) + invoke alarm |
| `secret-breach-alarm.sh` | called by scrubber | class, source | alarm text + OS notif + ledger + transcript scrub |

All hooks reuse `_lib.sh` (`hook_read_input`, `hook_field`, `hook_deny`) and obey the repo's
Bash rules. Wired into `settings.json.tmpl` `hooks` block and the template repo's equivalent.

## Error handling

- **Fail-safe on the deny path:** if a guard hook errors, it must not silently allow. For
  `PreToolUse`, a scan failure defaults to `ask` (prompt the user) rather than `allow`.
- **Fail-safe on the scrub path:** if the scrubber cannot parse a result, it redacts
  conservatively (whole result → marker + alarm) rather than passing it through. A false
  redaction is recoverable (re-run the tool); a missed secret is not.
- Hook timeouts kept at 5s (repo convention). Regex scan is well under budget.

## Testing

Following repo convention (`*.test.sh` next to each hook, e.g. `bash-guard.test.sh`):
- `secret-bash-guard.test.sh` — denies `cat .env`, `env`, `echo $AWS_SECRET`,
  `aws secretsmanager get-secret-value` (bare); allows redirect-to-`/tmp/claude-*` and pipe forms;
  allows benign `cat README.md`.
- `secret-path-guard.test.sh` — denies `.env`/`*.pem`/`~/.aws/credentials` and the the organisation
  `**/secrets/**` convention (incl. `.strongbox-keyid`, `.strongbox_keyring`, `*.secret`);
  allows `config.env.example`, `*.pub`, `*.tmpl`, and a benign `secrets.md` doc that is not under
  a `secrets/` directory (guard against over-matching).
- `secret-prompt-guard.test.sh` — blocks a prompt containing an `AKIA…` key; passes clean prose.
- `secret-output-scrubber.test.sh` — given a `tool_response` with an AWS key / private-key header,
  asserts `updatedToolOutput` contains the marker and not the raw value; asserts the alarm fires;
  asserts a clean result passes through unchanged (no false redaction).
- `secret-patterns.test.sh` — pattern-set unit tests (true positives + known-benign negatives).
- Breach-alarm test — asserts ledger append (class/source only, no value) and alarm text; OS
  notification stubbed.

## Out of scope (YAGNI)

- External DLP proxy on Bedrock egress.
- Registering actual secret values / hashes as a tripwire (itself a storage surface; rejected).
- Per-call gitleaks (latency).
- Encrypting the on-disk transcript.

## Residual risk register

1. Novel-shaped secret unseen by patterns → passes. Mitigation: broad high-precision set;
   loud alarm on any recognised shape; periodic pattern review.
2. `updatedToolOutput` timing vs. transcript persistence → transcript scrub is the backstop;
   confirm behaviour empirically before relying on it.
3. Prior-turn Bedrock egress cannot be recalled → the alarm's job is speed of regeneration,
   which the design maximises. This is inherent, not a defect.
