#!/usr/bin/env bash
# Compatibility shim: a settings.json hydrated before reviewer-guard.sh replaced this hook still registers this name.
# Re-run scripts/apply-settings.sh to register the new hook; this shim is removed in a later release.
exec "$(dirname "$0")/reviewer-guard.sh"
