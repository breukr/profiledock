#!/bin/bash
set -euo pipefail
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your own notarytool keychain profile}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
stage_dir="$(mktemp -d /private/tmp/profiledock-notarize.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
# iCloud-backed source folders can add Finder metadata after a build. Package outside them.
ditto --norsrc --noextattr dist/ProfileDock.app "$stage_dir/ProfileDock.app"
xattr -cr "$stage_dir/ProfileDock.app"
codesign --verify --strict "$stage_dir/ProfileDock.app"
ditto --norsrc --noextattr -c -k --keepParent "$stage_dir/ProfileDock.app" "$stage_dir/ProfileDock.zip"
xcrun notarytool submit "$stage_dir/ProfileDock.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$stage_dir/ProfileDock.app"
xcrun stapler validate "$stage_dir/ProfileDock.app"
spctl --assess --type execute --verbose=2 "$stage_dir/ProfileDock.app"
ditto --norsrc --noextattr -c -k --keepParent "$stage_dir/ProfileDock.app" "$stage_dir/ProfileDock.zip"
cp "$stage_dir/ProfileDock.zip" dist/ProfileDock.zip
ditto --norsrc --noextattr "$stage_dir/ProfileDock.app" dist/ProfileDock.app
(cd dist && shasum -a 256 ProfileDock.zip > SHA256SUMS)
