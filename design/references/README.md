# Design references

Seeded 2026-10-16. Verdicts need evidence; "approved" here means shipped on `main` and described in a release or design doc, not a fresh sign-off. Sam's visual approval is never assumed (`DESIGN.md` final gate).

Regression snapshots: `./scripts/design-check.sh` (fixtures, gitignored output in `qa/design-check/`). The `candidates/` images are copies of that output from 2026-10-16 on `main` bf3e1ea, kept as comparison points, not approvals. There are no pixel-diff baselines for Swift; the reviewer compares new renders against these.

| file | verdict | one-line reason | evidence/source | date |
| --- | --- | --- | --- | --- |
| `Resources/IconPreviews/dark.png`, `light.png`, `clear-*.png`, `tinted-*.png` (in-repo, not copied) | approved (shipped) | Monochrome four-tile mark on a flat field; same geometry in every appearance, no gradient or gloss. | `docs/ICON-APPEARANCES.md`, release commit 0797e79 | 2026-09 |
| `docs/hero.svg`, `docs/hero-dark.svg` (in-repo) | approved (shipped) | README hero follows the reader's light/dark; mark-led, one product line, no feature-card grid. | `README.md` header, `docs/BRANDING.md` | 2026-09 |
| `docs/companions-preview.png` (in-repo) | approved (shipped) | Strip on pure black: 11 pt names, 10 pt secondary lines, 52 pt radius-26% badges, tiles in an even 10 pt gap grid, circular agent badge top-right. | `README.md` companions section, commit 8f8f98a | 2026-09 |
| `candidates/settings-profiles-1280-dark.png` | candidate | One centered 760 pt column, grouped rows with trailing Open and a 0.5 pt inset separator, sidebar groups Workspace and Settings. | `docs/MENU-DESIGN.md` decisions; approval of this render not evidenced | 2026-10-16 |
| `candidates/settings-appearance-920-light.png` | candidate | Light mode uses system semantic colors only; cards radius 10 with a hairline stroke, no shadow. | `docs/MENU-DESIGN.md` tokens; approval not evidenced | 2026-10-16 |
| `candidates/profile-editor-dark.png` | candidate | Editor sheet 600x660 with live icon preview, hex field in monospace, same artwork as notch and list. | `docs/NATIVE-DOCK.md`, `MENU-DESIGN.md`; approval not evidenced | 2026-10-16 |
| `candidates/strip-680-scale-1.png` | candidate | Mixed Codex, Claude and Terminal tiles in two sections with equal widths; dark only. Note: renders show "Loading usage..." because the fixture never configures usage. | `CompanionRenderingTests`; approval not evidenced | 2026-10-16 |
| `candidates/strip-grid-3x3.png` | candidate | Custom 3x3 grid: width follows columns (3 x 142 + 32), rows stack at a constant 10 pt gap, sections below. | `docs/RELEASE-NOTES-1.5.0.md`; approval not evidenced | 2026-10-16 |
| `candidates/insights-680-dark.png` | candidate | Usage insights chart at 680 wide, tokens/cost/sessions switch, system-colored series. | `docs/INSIGHTS.md`; approval not evidenced | 2026-10-16 |
| `rejected/` (text) marketing hero sizes and pill buttons inside the app | rejected | Utility density: 12/13 pt type and system controls, not landing-page scale. | `docs/MENU-DESIGN.md` Reference lock | 2026-09-22 |
| `rejected/` (text) off-center empty states, mismatched header and content columns | rejected | Empty state must center in the available pane; header and content share one 760 pt column. | `docs/MENU-DESIGN.md` decisions (Sam's screenshot feedback) | 2026-09-22 |
| `rejected/` (text) custom glass effects, decorative bitmaps, fixed white or black in Settings | rejected | Flat system surfaces and semantic colors in both appearances. | `docs/MENU-DESIGN.md` Tokens | 2026-09-22 |
| `rejected/` (text) inset colored border around a custom icon image | rejected | Custom images fill the rounded icon, center-cropped, no inset border. | `docs/NATIVE-DOCK.md` | 2026-09 |
| `rejected/` (text) icon style only in experimental mode | rejected | One icon choice must show in editor, notch, list and menu even with experimental mode off. | `docs/MENU-DESIGN.md` decisions | 2026-09 |

Marketing images in the local, untracked `linkedin-carousel/` (Dutch, Breukr v3 paper style) and `launch-film/` are references for marketing only and are not in this repository.
