#!/usr/bin/env bash
# secret-prompt-guard.sh — UserPromptSubmit hook. Blocks a prompt that carries a
# live secret value so it never enters context. Cannot redact (docs: prompt is
# block-or-pass only), so it blocks and tells the user to rotate + resubmit.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/_lib.sh"
source "$DIR/secret-patterns.sh"
hook_read_input

prompt=$(hook_field '.prompt')
if [[ -z "$prompt" ]]; then
    exit 0
fi

if classes=$(scan_content_for_secrets "$prompt"); then
    csv=$(printf '%s' "$classes" | tr '\n' ',' | sed 's/,$//')
    hook_prompt_block "SECRET IN PROMPT: your message appears to contain a live credential [$csv]. It was blocked before entering context. Rotate that credential and resubmit without it — reference secrets indirectly (path/name), never by value."
fi
exit 0
