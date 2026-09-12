#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
destination="${1:-/Applications/ProfileDock.app}"
source_app="$project_dir/dist/ProfileDock.app"
stage_dir="$(mktemp -d /private/tmp/profiledock-local-install.XXXXXX)"
trap 'rm -rf "$stage_dir"' EXIT
ditto --norsrc --noextattr "$source_app" "$stage_dir/ProfileDock.app"
source_app="$stage_dir/ProfileDock.app"
xattr -cr "$source_app"
if pgrep -x AccountDock >/dev/null; then
    echo "Quit ProfileDock or Account Dock before installing." >&2
    exit 1
fi
codesign --verify --strict "$source_app"
backup=""
if [[ -e "$destination" ]]; then
    existing_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist")"
    [[ "$existing_id" == "nl.breukr.account-dock" ]] || { echo "An unrelated app already uses this name." >&2; exit 1; }
    backup="${destination%.app}.backup-$(date +%Y%m%d%H%M%S).app"
    mv "$destination" "$backup"
fi
if ! ditto --norsrc --noextattr "$source_app" "$destination" || ! codesign --verify --strict "$destination"; then
    [[ -n "$backup" ]] && { rm -rf "$destination"; mv "$backup" "$destination"; }
    exit 1
fi
echo "Installed: $destination"
