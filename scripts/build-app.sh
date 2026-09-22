#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
stage_dir="$(mktemp -d /private/tmp/profiledock-build.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
bundle_name="ProfileDock"
bundle_id="nl.breukr.account-dock"
if [[ "${PROFILEDOCK_CONTEXT_PREVIEW:-0}" == "1" ]]; then
    bundle_name="ProfileDock Context Preview"
    bundle_id="nl.breukr.profiledock.context-preview"
fi
bundle="$stage_dir/$bundle_name.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swift build -c release --arch arm64 -Xswiftc -file-prefix-map -Xswiftc "$project_dir=/Source/ProfileDock" -Xswiftc -debug-prefix-map -Xswiftc "$project_dir=/Source/ProfileDock"
binary_dir="$(swift build -c release --arch arm64 --show-bin-path)"
cp "$binary_dir/AccountDock" "$bundle/Contents/MacOS/AccountDock"
cp "$binary_dir/ProfileDockShim" "$bundle/Contents/Resources/ProfileDockShim"
cp "$binary_dir/ProfileDockContext" "$bundle/Contents/MacOS/ProfileDockContext"
ditto Resources/profiledock-context "$bundle/Contents/Resources/ContextPlugin"
mkdir -p "$bundle/Contents/Frameworks"
sparkle="$project_dir/.build/artifacts/sparkle/Sparkle"
ditto --norsrc --noextattr "$sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$bundle/Contents/Frameworks/Sparkle.framework"
cp "$sparkle/LICENSE" "$bundle/Contents/Resources/Sparkle-LICENSE.txt"
ditto Resources/Sounds "$bundle/Contents/Resources/Sounds"
ditto Resources/Brand "$bundle/Contents/Resources/Brand"
strip -S "$bundle/Contents/MacOS/AccountDock"
strip -S "$bundle/Contents/MacOS/ProfileDockContext"
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
<key>CFBundleVersion</key><string>149</string>
<key>CFBundleShortVersionString</key><string>1.4.0</string>
<key>CFBundleIconFile</key><string>ProfileDock</string>
<key>CFBundleIconName</key><string>ProfileDock</string>
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
if [[ "${PROFILEDOCK_CONTEXT_PREVIEW:-0}" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" -c "Set :CFBundleName $bundle_name" -c "Set :CFBundleDisplayName $bundle_name" -c "Set :CFBundleVersion 149" -c "Set :CFBundleShortVersionString 1.4.0-preview.10" -c "Add :ProfileDockContextPreview bool true" "$bundle/Contents/Info.plist"
fi
# Compile the layered monochrome icon; macOS selects light/dark/tinted/clear.
xcrun actool "$project_dir/Resources/ProfileDock.icon" --compile "$bundle/Contents/Resources" --output-format human-readable-text --output-partial-info-plist "$stage_dir/icon-info.plist" --app-icon ProfileDock --enable-on-demand-resources NO --target-device mac --minimum-deployment-target 14.0 --platform macosx --bundle-identifier nl.breukr.account-dock
ditto Resources/IconPreviews "$bundle/Contents/Resources/IconPreviews"
xattr -cr "$bundle"
python3 scripts/sign-bundle.py "$bundle"
mkdir -p "$project_dir/dist"
if [[ -e "$project_dir/dist/$bundle_name.app" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_dir/dist/$bundle_name.app/Contents/Info.plist")" == "$bundle_id" ]] || exit 1
    rm -rf "$project_dir/dist/$bundle_name.app"
fi
ditto --norsrc --noextattr "$bundle" "$project_dir/dist/$bundle_name.app"
xattr -cr "$project_dir/dist/$bundle_name.app"
ditto --norsrc --noextattr -c -k --keepParent "$bundle" "$project_dir/dist/$bundle_name.zip"
echo "Built: $project_dir/dist/$bundle_name.app (Apple Silicon)"
