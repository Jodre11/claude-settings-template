#!/usr/bin/env bash
# Sanitises a pane title for use as a tmux session name.
# Called by the pane-title-changed hook set in the claude() zsh function.
#
# Usage: tmux-sanitise-name.sh <pane_title> <session_id>
#   pane_title  — raw title from #{pane_title}
#   session_id  — current tmux session id (e.g. $3) for collision guard

set -euo pipefail

title="$1"
session_id="${2:-}"

# Ignore default/blank titles — keep the timestamp name.
case "$title" in
    ""|claude|"Claude Code"|*"Claude Code"*) exit 0 ;;
esac

# --- Stopword removal ---
# Remove filler words that add length without meaning.
stopwords="the a an for and with from this that into onto"

# --- Abbreviation map ---
# Common programming terms condensed for phone-friendly typing.
declare -A abbrevs=(
    [authentication]=auth
    [authorisation]=authz
    [authorization]=authz
    [certificate]=cert
    [certificates]=certs
    [configuration]=config
    [configure]=config
    [configured]=configd
    [database]=db
    [deployment]=deploy
    [development]=dev
    [documentation]=docs
    [document]=doc
    [environment]=env
    [environments]=envs
    [feature]=feat
    [function]=fn
    [functions]=fns
    [implementation]=impl
    [implement]=impl
    [infrastructure]=infra
    [integration]=integ
    [kubernetes]=k8s
    [library]=lib
    [libraries]=libs
    [management]=mgmt
    [message]=msg
    [messages]=msgs
    [middleware]=mw
    [migration]=mig
    [migrations]=migs
    [notification]=notif
    [notifications]=notifs
    [operation]=op
    [operations]=ops
    [package]=pkg
    [packages]=pkgs
    [parameter]=param
    [parameters]=params
    [performance]=perf
    [production]=prod
    [refactor]=refac
    [repository]=repo
    [repositories]=repos
    [request]=req
    [requests]=reqs
    [resource]=res
    [resources]=res
    [response]=resp
    [responses]=resps
    [security]=sec
    [service]=svc
    [services]=svcs
    [specification]=spec
    [specifications]=specs
    [template]=tpl
    [templates]=tpls
    [terraform]=tf
    [testing]=test
    [transaction]=txn
    [transactions]=txns
    [utility]=util
    [utilities]=utils
    [validation]=val
    [variable]=var
    [variables]=vars
    [workday]=wd
)

# Lowercase and replace spaces/underscores with hyphens.
safe=$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | tr ' _' '--')

# Strip non-alphanumeric (keep hyphens).
safe=$(printf '%s' "$safe" | tr -cd 'a-z0-9-')

# Collapse multiple hyphens, trim leading/trailing hyphens.
safe=$(printf '%s' "$safe" | sed 's/--*/-/g;s/^-//;s/-$//')

# Split on hyphens, remove stopwords, apply abbreviations.
IFS='-' read -ra words <<< "$safe"
result=()
for word in "${words[@]}"; do
    # Skip stopwords.
    skip=false
    for sw in $stopwords; do
        if [[ "$word" == "$sw" ]]; then
            skip=true
            break
        fi
    done
    if $skip; then continue; fi

    # Apply abbreviation if one exists.
    if [[ -n "${abbrevs[$word]+x}" ]]; then
        word="${abbrevs[$word]}"
    fi
    result+=("$word")
done

# Rejoin with hyphens.
safe=$(IFS='-'; printf '%s' "${result[*]}")

# Truncate to 25 chars, trim trailing hyphen.
safe="${safe:0:25}"
safe="${safe%-}"

[[ -z "$safe" ]] && exit 0

# Collision guard: if another session already has this name, append
# a short disambiguator from the session id.
if tmux has-session -t "$safe" 2>/dev/null; then
    # Extract last 2 chars of session_id (e.g. "$3" → "3", "$12" → "12").
    suffix="${session_id: -2}"
    suffix="${suffix#\$}"
    safe="${safe:0:22}-${suffix}"
    safe="${safe%-}"
fi

tmux rename-session -- "$safe" 2>/dev/null || true
