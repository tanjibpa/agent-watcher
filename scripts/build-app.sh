#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${CONFIGURATION:-release}"
build_arguments=(-c "$configuration")
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    build_arguments+=(--arch arm64 --arch x86_64)
fi
swift build "${build_arguments[@]}"
binary_directory="$(swift build "${build_arguments[@]}" --show-bin-path)"
app="$PWD/dist/Agent Watcher.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_directory/AgentWatcher" "$app/Contents/MacOS/AgentWatcher"
cp "$binary_directory/agent-watcher-hook" "$app/Contents/MacOS/agent-watcher-hook"
cp Integrations/pi/agent-watcher.ts "$app/Contents/Resources/agent-watcher.ts"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$app/Contents/Info.plist"
fi
identity="${CODE_SIGN_IDENTITY:--}"
timestamp=(--timestamp)
if [[ "$identity" == "-" ]]; then timestamp=(--timestamp=none); fi
codesign --force --options runtime "${timestamp[@]}" --sign "$identity" "$app/Contents/MacOS/agent-watcher-hook"
codesign --force --options runtime "${timestamp[@]}" --entitlements Resources/AgentWatcher.entitlements --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$PWD/dist/AgentWatcher.zip"
printf 'Built %s\n' "$app"
