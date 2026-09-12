#!/bin/bash
set -euo pipefail
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to your own notarytool keychain profile}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
codesign --verify --strict dist/ProfileDock.app
xcrun notarytool submit dist/ProfileDock.zip --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple dist/ProfileDock.app
xcrun stapler validate dist/ProfileDock.app
spctl --assess --type execute --verbose=2 dist/ProfileDock.app
ditto -c -k --keepParent dist/ProfileDock.app dist/ProfileDock.zip
(cd dist && shasum -a 256 ProfileDock.zip > SHA256SUMS)
