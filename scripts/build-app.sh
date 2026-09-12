#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
stage_dir="$(mktemp -d /private/tmp/profiledock-build.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
bundle="$stage_dir/ProfileDock.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swift build -c release --arch arm64 -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/Source/ProfileDock" -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/Source/ProfileDock"
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$binary_dir/AccountDock" "$bundle/Contents/MacOS/AccountDock"
mkdir -p "$bundle/Contents/Frameworks"
sparkle="$project_dir/.build/artifacts/sparkle/Sparkle"
ditto --norsrc --noextattr "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$bundle/Contents/Resources/Sparkle-LICENSE.txt"
ditto Resources/Sounds "$bundle/Contents/Resources/Sounds"
ditto Resources/Brand "$bundle/Contents/Resources/Brand"
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
<key>CFBundleVersion</key><string>121</string>
<key>CFBundleShortVersionString</key><string>1.2.1</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSArchitecturePriority</key><array><string>arm64</string></array>
<key>SUFeedURL</key><string>https://raw.githubusercontent.com/breukr/profiledock/main/docs/appcast.xml</string>
<key>SUPublicEDKey</key><string>JG1uWGDrg9GzxpUUNq+SISRiocj3SO8FEIhy++fwDDE=</string>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUScheduledCheckInterval</key><integer>86400</integer>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUAllowsAutomaticUpdates</key><false/>
<key>SUSendProfileInfo</key><false/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$project_dir/.build/AppIcon.iconset"
iconutil -c icns "$project_dir/.build/AppIcon.iconset" -o "$bundle/Contents/Resources/AppIcon.icns"
xattr -cr "$bundle"
python3 scripts/sign-bundle.py "$bundle"
mkdir -p "$project_dir/dist"
if [[ -e "$project_dir/dist/ProfileDock.app" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_dir/dist/ProfileDock.app/Contents/Info.plist")" == "nl.breukr.account-dock" ]] || exit 1
    rm -rf "$project_dir/dist/ProfileDock.app"
fi
ditto --norsrc --noextattr "$bundle" "$project_dir/dist/ProfileDock.app"
xattr -cr "$project_dir/dist/ProfileDock.app"
ditto --norsrc --noextattr -c -k --keepParent "$bundle" "$project_dir/dist/ProfileDock.zip"
echo "Built: $project_dir/dist/ProfileDock.app (Apple Silicon)"
