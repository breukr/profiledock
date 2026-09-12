#!/bin/bash
set -euo pipefail
: "${SPARKLE_KEY_ACCOUNT:?Set SPARKLE_KEY_ACCOUNT to your Sparkle signing key account}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
stage_dir="$(mktemp -d /private/tmp/profiledock-feed.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/ProfileDock.app/Contents/Info.plist)"
cp dist/ProfileDock.zip "$stage_dir/ProfileDock.zip"
"$project_dir/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" \
    --account "$SPARKLE_KEY_ACCOUNT" --maximum-deltas 0 --maximum-versions 1 \
    --download-url-prefix "https://github.com/breukr/profiledock/releases/download/v$version/" \
    --link "https://github.com/breukr/profiledock" "$stage_dir"
cp "$stage_dir/appcast.xml" dist/appcast.xml
echo "Signed feed: dist/appcast.xml. Publish the release assets before copying it to docs/appcast.xml."
