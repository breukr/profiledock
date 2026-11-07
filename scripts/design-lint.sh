#!/usr/bin/env bash
# Token lint: fail when raw color literals appear where DESIGN.md does not allow them.
# Allowed files keep a ceiling (ratchet): the count may go down, never up.
# Add a new file to ALLOWED only with a DESIGN.md note explaining why a helper cannot be used.
set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='Color\(red:|Color\(white:|NSColor\(srgbRed|NSColor\(red:|NSColor\(white:|Color\(hex|Color\(\.sRGB|"#[0-9A-Fa-f]{6}"'
# file:ceiling
ALLOWED="
Sources/AccountDock/IconPulse.swift:4
Sources/AccountDock/InsightsView.swift:4
Sources/AccountDock/NativeProfileArtwork.swift:1
Sources/AccountDock/ProfileSettings.swift:1
Sources/AccountDock/Views.swift:7
Sources/AccountDock/UsageTint.swift:1
"
status=0
for file in Sources/AccountDock/*.swift; do
  count=$(grep -cE "$PATTERN" "$file" || true)
  [ "$count" -eq 0 ] && continue
  ceiling=$(printf '%s\n' "$ALLOWED" | awk -F: -v f="$file" '$1==f {print $2}')
  if [ -z "$ceiling" ]; then
    echo "FAIL $file: $count raw color literal(s); use system semantic colors or an existing helper (UsageTint, ProfileActivityState.color)"
    status=1
  elif [ "$count" -gt "$ceiling" ]; then
    echo "FAIL $file: $count raw color literal(s), ceiling is $ceiling"
    status=1
  fi
done
[ "$status" -eq 0 ] && echo "design-lint: ok"
exit "$status"
