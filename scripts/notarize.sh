#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${CODE_SIGN_IDENTITY:-}" || "$CODE_SIGN_IDENTITY" == "-" || $# -ne 1 ]]; then
    printf 'Set CODE_SIGN_IDENTITY to your Developer ID Application identity and pass a notarytool keychain profile.\n' >&2
    exit 1
fi
UNIVERSAL=1 bash scripts/build-app.sh
xcrun notarytool submit dist/AgentWatcher.zip --keychain-profile "$1" --wait
xcrun stapler staple "dist/Agent Watcher.app"
ditto -c -k --sequesterRsrc --keepParent "dist/Agent Watcher.app" dist/AgentWatcher.zip
printf 'Notarized release: %s/dist/AgentWatcher.zip\n' "$PWD"
