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
    # One previous version is kept for rollback, outside /Applications so Spotlight and Open With
    # do not list it as another ProfileDock. Older copies from earlier installs go to the Trash.
    backup_dir="${PROFILEDOCK_BACKUP_DIR:-$HOME/Library/Application Support/ProfileDock Backups/previous-install}"
    mkdir -p "$backup_dir"
    backup="$backup_dir/ProfileDock.backup-$(date +%Y%m%d%H%M%S).app"
    mv "$destination" "$backup"
fi
if ! ditto --norsrc --noextattr "$source_app" "$destination" || ! codesign --verify --strict "$destination"; then
    [[ -n "$backup" ]] && { rm -rf "$destination"; mv "$backup" "$destination"; }
    exit 1
fi
if [[ -n "$backup" ]]; then
    for old in "$backup_dir"/ProfileDock.backup-*.app; do
        [[ "$old" == "$backup" || ! -e "$old" ]] && continue
        mv "$old" "$HOME/.Trash/$(basename "$old" .app)-$$.app"
    done
fi
echo "Installed: $destination${backup:+ (previous version kept in $backup_dir)}"
