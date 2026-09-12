#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
stage_dir="$(mktemp -d /private/tmp/profiledock-build.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
bundle="$stage_dir/ProfileDock.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
for architecture in arm64 x86_64; do
    swift build -c release --arch "$architecture" -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/Source/ProfileDock" -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/Source/ProfileDock"
    binary_dir="$(swift build -c release --arch "$architecture" --show-bin-path)"
    cp "$binary_dir/AccountDock" "$stage_dir/AccountDock-$architecture"
done
lipo -create "$stage_dir/AccountDock-arm64" "$stage_dir/AccountDock-x86_64" -output "$bundle/Contents/MacOS/AccountDock"
strip -S "$bundle/Contents/MacOS/AccountDock"
cp THIRD_PARTY_NOTICES.md "$bundle/Contents/Resources/ThirdPartyNotices.txt"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>nl.breukr.account-dock</string>
<key>CFBundleName</key><string>ProfileDock</string>
<key>CFBundleDisplayName</key><string>ProfileDock</string>
<key>CFBundleExecutable</key><string>AccountDock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>100</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$project_dir/.build/AppIcon.iconset"
iconutil -c icns "$project_dir/.build/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
xattr -cr "$bundle"
if [[ -n "${SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$bundle"
else
    codesign --force --sign - "$bundle"
fi
codesign --verify --strict "$bundle"
mkdir -p "$project_dir/dist"
if [[ -e "$project_dir/dist/ProfileDock.app" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_dir/dist/ProfileDock.app/Contents/Info.plist")" == "nl.breukr.account-dock" ]] || exit 1
    rm -rf "$project_dir/dist/ProfileDock.app"
fi
ditto --norsrc --noextattr "$bundle" "$project_dir/dist/ProfileDock.app"
ditto -c -k --keepParent "$bundle" "$project_dir/dist/ProfileDock.zip"
echo "Built: $project_dir/dist/ProfileDock.app (Apple Silicon + Intel)"
