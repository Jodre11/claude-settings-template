# Secret Context Firewall — Design

**Date:** 2026-07-12
**Status:** Implemented 2026-07-12. See **Implementation findings** below — the Layer 2
`updatedToolOutput` redaction does NOT take effect on the shipped Claude Code version, so the
delivered feature is a **detector + alarm + on-disk scrub**, not a pre-egress preventer. Layer 1
(block-before-execution) is verified working and IS true prevention.
**Repos:** `~/.claude` (claude-settings, via `.tmpl` hydration) **and** `~/Repos/claude-settings-template/` (public seed) — ship to both.

## Implementation findings (2026-07-12, live-verified on Claude Code 2.1.207)

The design below was sound against the documented hook API, but live testing after wiring the
hooks in revealed one load-bearing assumption does not hold on this Claude Code version. Recorded
honestly here so the design is not read as delivering more than it does:

- **Layer 2 `updatedToolOutput` does NOT redact the result the model sees (CC 2.1.207).** A
  controlled single-`Bash` probe emitting a dummy AWS-key-shaped value showed the raw value still
  reaching the model, while the `additionalContext` breach alarm from the *same* hook JSON object
  *was* applied. Our emitted JSON matches the documented schema exactly
  (`hookSpecificOutput.updatedToolOutput`), and the docs state it applies to all tools — so this
  is a **platform limitation on this version, not a hook defect**. Net effect: Layer 2 is a loud
  **detector**, not the "linchpin preventer" the design called it. The prior-turn/next-turn
  Bedrock egress of a captured value is therefore NOT closed by Layer 2 here.
- **Layer 1 IS true prevention and is verified live:** `Read` and `cat` of `**/secrets/**` denied;
  bare `aws secretsmanager get-secret-value` denied; the same redirected to `/tmp/claude-*`
  allowed (reached the AWS CLI). These block *before* the value is ever read — the genuine
  guarantee now rests here.
- **Layer 3 works:** breach ledger (class + source only, no raw value), macOS notification, and
  in-conversation `additionalContext` alarm all fire. The on-disk transcript scrub is the
  after-the-fact backstop and is now the *primary* redaction mechanism given the Layer 2 gap.
- **Pattern change:** the `bedrock-arn` content pattern was **removed** — it flagged the user's own
  `modelOverrides` inference-profile ARNs (an identifier, not a regenerable credential) as a breach
  on every config read. False-positive noise that would train the alarm to be ignored.
- **Follow-ups:** (a) re-test `updatedToolOutput` after any CC upgrade — if a later version honours
  it, Layer 2 becomes true prevention as originally designed; (b) consider `suppressOutput` as a
  partial mitigation; (c) worth an upstream bug report (docs say all-tools; 2.1.207 ignores it for
  Bash while honouring `additionalContext`).

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
- `PostToolUse` → `hookSpecificOutput.updatedToolOutput` is **documented** to replace the tool
  result before the model sees it. This was intended as the linchpin. **NOTE (see Implementation
  findings): on Claude Code 2.1.207 this field is not applied for Bash results in practice, so the
  redaction does not actually reach the model — Layer 2 degrades to detection + alarm on this
  version.**
- `PostToolUse`/`PreToolUse`/`UserPromptSubmit` → `additionalContext` injects text the model
  reads (used for the loud alarm).
- `UserPromptSubmit` → `decision: "block"` blocks (and erases) a prompt; it **cannot** rewrite
  it. So a live secret pasted into a prompt is blocked, not silently redacted.

## Honest certainty boundary

- **Known secret-bearing paths / secret-emitting commands → prevented deterministically by Layer 1**
  (block before execution). Verified live. This is the real guarantee.
- **A secret that appears in a tool result (not caught by Layer 1) → detected and alarmed by the
  `PostToolUse` scanner, and scrubbed from the on-disk transcript.** On CC 2.1.207 it is **NOT**
  scrubbed from the copy the model/Bedrock see (the `updatedToolOutput` gap) — so for this class,
  the design delivers *fast detection + regenerate-me alarm*, not prevention of the next-turn
  egress. Do not oversell this as prevention on the current version.
- **Irreducible gap:** a secret whose shape no pattern recognises at all will pass Layer 2 entirely
  (no detection). Layer 1 still prevents it if it lives on a known path / behind a known command.

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

**Org-specific secret-path convention (local `.tmpl` only — placeholder slot in the public template):**
Some organisations encrypt secrets at rest in git via a tool such as
[Strongbox](https://github.com/uw-labs/strongbox), keyed on a directory convention
(e.g. `.gitattributes`: `**/secrets/** filter=strongbox`). Critically, **an at-rest git filter
protects secrets in git, not in the working tree** — the checked-out copy is decrypted plaintext,
so a `Read`/`cat` of a file under such a directory pulls the decrypted secret straight into context.
This is a deterministic **path** convention (not a value shape), so it is high-precision with zero
false positives. Where an org uses such a convention, add its paths to the denylist, e.g.:
`**/secrets/**`, `**/.strongbox-keyid`, `**/.strongbox_keyring`, `*.secret`.
The public template ships this as a commented placeholder showing where an org plugs in its own
secret-path convention; concrete org-specific entries stay in the private downstream repo only.

**Scale consideration:** a monorepo-style checkout can hold dozens of repos, of which several may
use an at-rest git filter across many `secrets/` directories — each decrypted plaintext, each a
read-into-context risk. That scale rules out per-repo `settings.local.json` deny blocks (they don't
cover future clones or worktrees and leave guarantee gaps).

**Interim stopgap pattern — user-level, global:** promote the denylist to the **user-level
`permissions.deny`** in the private `settings.json` (immediate effect) and its hydration source
`settings.json.tmpl`, plus the paired public template's `settings.json.tmpl`:
`Read(**/secrets/**)`, `Read(**/.strongbox-keyid)`, `Read(**/*.secret)`,
`Bash(cat|strings|xxd **/secrets/**)` (retain any existing keyring entries). One user-level config
covers every matching repo and every future clone — in every repo (global scope chosen
deliberately: defensive by default). Any per-repo blocks are then redundant. The hook-based firewall
supersedes this stopgap once shipped, adding the runtime-fetch guard + output scrubber the deny list
cannot provide.

**`UserPromptSubmit` — inbound prompt scan** (`hooks/secret-prompt-guard.sh`):
Scan the submitted prompt against the secret-shape patterns; `decision: "block"` + reason if a
live credential shape is present, so a pasted key never enters context.

### Layer 2 — Scrub before egress (intended linchpin; detector-only on CC 2.1.207)

**`PostToolUse` (all tools)** (`hooks/secret-output-scrubber.sh`):
Scan `tool_response` against **secret-shape patterns only** (high precision — the
`ALWAYS_PATTERNS` set, NOT the identity/org patterns, which would be noisy and are a git-time
concern). On match:
1. Emit `hookSpecificOutput.updatedToolOutput` with each matched span replaced by
   `[REDACTED-SECRET-BREACH:<class>]`. **Intended:** the model/Bedrock never receive the raw
   value. **Actual on CC 2.1.207:** the field is not applied, so the raw value still reaches the
   model — the redaction only lands in the on-disk transcript scrub (Layer 3.4). Re-test after CC
   upgrades.
2. Trigger Layer 3 (breach response) — this is what actually fires on this version.

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
- `secret-path-guard.test.sh` — denies `.env`/`*.pem`/`~/.aws/credentials` and the org
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
2. `updatedToolOutput` **not applied on CC 2.1.207** (confirmed empirically, not just a timing
   risk) → the on-disk transcript scrub is now the *primary*, not backup, redaction; the model
   still sees the raw value in-turn. Re-test on CC upgrade; if honoured, Layer 2 becomes true
   prevention. Consider an upstream bug report.
3. Prior-turn Bedrock egress cannot be recalled → the alarm's job is speed of regeneration,
   which the design maximises. This is inherent, not a defect.
