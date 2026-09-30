#!/usr/bin/env bash
# Compatibility shim: a settings.json hydrated before this hook was retired still registers it on Agent. It makes no
# decision. Re-run scripts/apply-settings.sh to drop the registration; this shim is removed in a later release.
exit 0
