#!/bin/bash
set -euo pipefail
[[ "$(uname -s)" == "Darwin" ]] || { echo "ProfileDock is for macOS." >&2; exit 1; }
[[ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]] || { echo "ProfileDock requires an Apple Silicon Mac." >&2; exit 1; }
work_dir="$(mktemp -d /private/tmp/profiledock-install.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
release_url="https://github.com/breukr/profiledock/releases/latest/download"
curl --fail --location --proto '=https' --tlsv1.2 "$release_url/ProfileDock.zip" -o "$work_dir/ProfileDock.zip"
curl --fail --location --proto '=https' --tlsv1.2 "$release_url/SHA256SUMS" -o "$work_dir/SHA256SUMS"
expected="$(awk '$2 == "ProfileDock.zip" && length($1) == 64 && $1 !~ /[^0-9a-f]/ { print $1 }' "$work_dir/SHA256SUMS")"
actual="$(shasum -a 256 "$work_dir/ProfileDock.zip" | awk '{print $1}')"
[[ -n "$expected" && "$actual" == "$expected" ]] || { echo "Checksum mismatch. Nothing was installed." >&2; exit 1; }
ditto -x -k "$work_dir/ProfileDock.zip" "$work_dir/unpacked"
app="$work_dir/unpacked/ProfileDock.app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == "nl.breukr.account-dock" ]] || exit 1
codesign --verify --deep --strict -R '=anchor apple generic and certificate leaf[subject.OU] = "RJ44EKYMM5"' "$app"
spctl --assess --type execute "$app"
if pgrep -x AccountDock >/dev/null; then
    echo "Quit ProfileDock or Account Dock, then run this installer again. ChatGPT can stay open." >&2
    exit 1
fi
destination="/Applications/ProfileDock.app"
if [[ ! -w /Applications ]]; then
    mkdir -p "$HOME/Applications"
    destination="$HOME/Applications/ProfileDock.app"
fi
backup=""
if [[ -e "$destination" ]]; then
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")" == "nl.breukr.account-dock" ]] || { echo "An unrelated app already has this name." >&2; exit 1; }
    backup="${destination%.app}.backup-$(date +%Y%m%d%H%M%S).app"
    mv "$destination" "$backup"
fi
if ! ditto "$app" "$destination" || ! codesign --verify --strict "$destination"; then
    [[ -n "$backup" ]] && { rm -rf "$destination"; mv "$backup" "$destination"; }
    exit 1
fi
open "$destination"
echo "ProfileDock is installed. Add a profile and sign in inside ChatGPT."
