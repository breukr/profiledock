#!/usr/bin/env bash
# One-command visual check. Renders the key screens from fictional fixtures into a gitignored folder
# and fails on lint errors, failing render tests, or missing/blank/odd-sized images.
#
#   ./scripts/design-check.sh
#
# Env: PROFILEDOCK_DESIGN_OUT   output folder (default: qa/design-check, gitignored)
#      PROFILEDOCK_DESIGN_SKIP_BUILD=1   reuse the existing debug build
#
# Safety: the renders use the app's own opt-in render tests, which build views from temporary profile
# homes and never launch the app or read real accounts. As a second guard, HOME points at an empty
# throwaway directory while the tests run.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="${PROFILEDOCK_DESIGN_OUT:-$ROOT/qa/design-check}"
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac

"$ROOT/scripts/design-lint.sh"

rm -rf "$OUT"
for d in settings companions grids insights usage cues connections attention; do mkdir -p "$OUT/$d"; done
FAKE_HOME="$(mktemp -d)"
trap 'rm -rf "$FAKE_HOME"' EXIT

if [ "${PROFILEDOCK_DESIGN_SKIP_BUILD:-0}" = 1 ]; then BUILD=(--skip-build); else swift build --build-tests >/dev/null; BUILD=(--skip-build); fi

start=$(date +%s)
HOME="$FAKE_HOME" \
PROFILEDOCK_RENDER_SETTINGS="$OUT/settings" \
PROFILEDOCK_RENDER_COMPANIONS="$OUT/companions" \
PROFILEDOCK_RENDER_GRIDS="$OUT/grids" \
PROFILEDOCK_RENDER_INSIGHTS="$OUT/insights" \
PROFILEDOCK_RENDER_USAGE="$OUT/usage" \
PROFILEDOCK_RENDER_CUES="$OUT/cues" \
PROFILEDOCK_RENDER_CONNECTIONS="$OUT/connections" \
PROFILEDOCK_RENDER_ATTENTION="$OUT/attention" \
swift test "${BUILD[@]}" \
  --filter 'SettingsRenderingTests|CompanionRenderingTests|InsightsTests/testRender|UsageTintTests/testRenderUsageColorScale|ActivityCueRenderingTests|IconPulseTests|AccountConnectionRenderingTests|AttentionPanelTests/testRender' \
  >"$OUT/test.log" 2>&1 || { tail -40 "$OUT/test.log"; echo "design-check: render tests failed (full log: $OUT/test.log)"; exit 1; }

# Minimum image counts per group, and sanity per image (readable PNG, not tiny, not blank-sized).
expect="settings:69 companions:14 grids:17 insights:9 usage:3 cues:4 connections:3 attention:21"
fail=0; total=0
for pair in $expect; do
  dir=${pair%%:*}; min=${pair##*:}
  n=$(find "$OUT/$dir" -name '*.png' | wc -l | tr -d ' ')
  total=$((total + n))
  if [ "$n" -lt "$min" ]; then echo "FAIL $dir: $n images, expected at least $min"; fail=1; fi
  while IFS= read -r png; do
    w=$(sips -g pixelWidth "$png" 2>/dev/null | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/ {print $2}')
    bytes=$(stat -f %z "$png")
    if [ -z "$w" ] || [ -z "$h" ] || [ "$w" -lt 100 ] || [ "$h" -lt 40 ] || [ "$bytes" -lt 1500 ]; then
      echo "FAIL $png: ${w:-?}x${h:-?}, $bytes bytes"; fail=1
    fi
  done < <(find "$OUT/$dir" -name '*.png')
done
[ "$fail" -eq 0 ] || exit 1

echo "design-check: $total images in $OUT ($(( $(date +%s) - start ))s of tests)"
echo "  settings/    every destination x 760/920/1280 wide x light/dark, editor, empty, notices"
echo "  companions/  strip at 360/680/1040 x scale 0.85/1/1.3, connectors, terminals, settings"
echo "  grids/       strip for 2x2, 3x3, 6x1, 1x6 at three scales, hidden sections"
echo "  insights/    insights panel 488/680/1000 light+dark, adaptive widgets 420/740/1200"
echo "  usage/ cues/ connections/   usage bars, activity cues, sign-in notices"
echo "  attention/   notch pop-up: pills (done, waiting, hover, floating, queue, any agent), reply cards, permission, questions with Other, queue, Reduce Transparency (fallback surface; glass cannot be captured)"
echo "Open and look at every screen you changed. Geometry assertions run inside the tests."
