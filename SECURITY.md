# Security Conventions

This document records the security invariants this repository relies on. Follow them when adding or changing hooks,
scripts and configuration. [README.md](README.md) has the detail on each layer.

## Secrets Management

- **Never commit secrets** — personal values belong in `config.env` (gitignored), never in a `.tmpl` file. A secret a
  script needs is fetched into the session vault (`$CLAUDE_SECRET_DIR`) and passed to the script by path.
- **Memory stays local** — `projects/*/memory/` is gitignored, because Claude Code's per-project memory names real
  organisations, repositories and people. Version it only in a private repository.
- **No subprocess env scrub** — `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` forces every session to start in the default
  permission mode, and the Bash tool's shell snapshot re-exports what it strips, so the template removes it. Keep a
  credential out of Claude Code at its source instead: export it from your shell profile only when `CLAUDECODE` is
  unset.

## Claude Code Hooks

- **The secret firewall** — the `secret-*` hooks keep secret values out of the model's context: they deny reads and
  commands that would print a secret, block a prompt carrying one, and redact tool output, recording each leak's class
  and source but never its value.
- **Fail closed** — a guard that cannot finish screening a command in the time it has denies it, with a route to
  retry in a form it can check, rather than allowing it or parking an unattended session on a prompt.
- **Safer routes** — `git-safer-route.sh` denies a forced branch delete, hard reset, forced clean or force push with
  the non-destructive equivalent; their native ask rules stay as the backstop. `gh-rerun-ask.sh` asks before a rerun
  unless a pull request triggered the run.
- **Single-command Bash discipline is load-bearing** — `secret-bash-guard.sh` and `reviewer-guard.sh` screen every
  word of every pipeline stage, which is only sound because `bash-guard.sh` denies every other compound form. Never
  relax one without the other.
- **Generated files are guarded** — `tmpl-output-guard.sh` denies a direct edit of a hydrated output, and
  `settings-edit-ask.sh` asks before a direct edit of `settings.json`.

## Template Hydration

- `hydrate.sh` replaces `__PLACEHOLDER__` tokens with bash parameter expansion (`${var//pattern/replacement}`), which
  is pure string substitution. It does not use `eval`, `envsubst`, or anything else that interprets shell
  metacharacters in config values.
- Hydrated outputs are gitignored. Only the `.tmpl` sources are committed.

## Git Hooks and CI

- **Pre-commit and pre-push** — `.githooks/guard-config.sh` and `.gitleaks.toml` define the patterns. The pre-commit
  hook scans every added line and runs gitleaks; the pre-push hook repeats both over every commit a push would
  publish, including its message, author and committer. gitleaks has no bypass; `SKIP_PATTERN_SCAN=1` skips only the
  pattern scan.
- **Local pattern lists** — names that must not be published live in the gitignored `.githooks/*-patterns.local`
  lists, which the hooks read and refuse to commit.
- **CI** — gitleaks, the pattern-sync check, the output-ignore check, the test suite and ShellCheck run on every push
  to `main` and every pull request into it. ShellCheck runs through `scripts/shellcheck.sh` at `--severity=warning`
  with `--norc`, so a local rc file cannot pass what CI fails.

## Dependency Pinning

- GitHub Actions are pinned to full commit SHAs, not tags, so a moved tag cannot change what runs.
