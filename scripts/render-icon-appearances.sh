#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_tool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$icon_tool" ]] || { echo 'Xcode with Icon Composer is required.' >&2; exit 1; }
mkdir -p Resources/IconPreviews
for pair in light:Default dark:Dark clear-light:ClearLight clear-dark:ClearDark tinted-light:TintedLight tinted-dark:TintedDark; do
    name="${pair%%:*}"
    rendition="${pair#*:}"
    "$icon_tool" Resources/ProfileDock.icon --export-image --output-file "Resources/IconPreviews/$name.png" --platform macOS --rendition "$rendition" --width 512 --height 512 --scale 1
 done
