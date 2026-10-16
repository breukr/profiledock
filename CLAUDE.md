# ProfileDock

Native macOS utility (SwiftUI + AppKit, Swift 6 package, macOS 14+, Apple Silicon). Public open-source repo: never commit real accounts, tokens, client names, personal icons or private task content. Tests use temporary profile homes and must not stop or update the developer's real apps.

- Layout: `Sources/DockCore` (models, layout math), `Sources/AccountDock` (app, SwiftUI views), `Sources/ContextCore` (context search), helpers `ProfileDockClaude|Shim|Context`, `Tests/`, `docs/`, `scripts/`.
- Check: `swift test`; package with `./scripts/build-app.sh` (CI also runs the smoke scripts in `.github/workflows/check.yml`).
- Conventions: `CONTRIBUTING.md`. Native controls first, small focused changes, fictional or empty profiles in screenshots.
- `launch-film/` (Remotion) and `linkedin-carousel/` exist only in the maintainer's local checkout, untracked; do not add them to git.

## Design work

Applies to every change a user can see: UI, layout, styling, motion, icons, screenshots, film.

1. Read first: `DESIGN.md` (source of truth and done bar), `design/references/README.md` (approved and
   rejected examples with reasons) and the last 3 rounds in `docs/design-log.md`. Re-read the log after a
   resume or compaction.
2. Tokens: no central file. Settings tokens are in `Sources/AccountDock/SettingsDesign.swift`; strip
   constants in `Sources/DockCore/IslandLayout.swift`, `WidgetSizing.swift` and `Views.swift`; colors via
   system semantic colors, `UsageTint`, `ProfileActivityState.color`. `./scripts/design-lint.sh` blocks new raw colors.
3. Aesthetic skill: invoke the `impeccable` skill before the first edit, even for a small refinement (it loads the design context and its craft floor) (native; adapt its iOS reference to the macOS HIG), the only taste skill for
   this repo. 21st.dev is web-only, skip it here; use SwiftUI and AppKit system controls.
4. Visual check: `./scripts/design-check.sh` renders settings (all pages, 3 sizes, light and dark), strip
   (3 widths x 3 scales, grids, sections), insights, usage and cues from fixtures into `qa/design-check/`
   (gitignored, about 45 s). Open and look at every changed screen before saying done; a passing build or
   test is not a visual check. Never launch the app against real profiles for screenshots.
5. Review: run the `design-reviewer` subagent with the task, changed files and screenshot paths. Fix its
   findings and re-run it; at most 2 rounds, then show Sam the screenshots with the reviewer verdict.
6. Log the round in `docs/design-log.md` (round, decision, rejected, why).
7. Motion: native Core Animation and SwiftUI; timing spec in `DESIGN.md` (Motion), every animation needs a
   Reduce Motion path, regression tests in `IslandRenderingTests` and `IconPulseTests`. No motion-lab route
   in a native app. Video: `launch-film/` with skill `remotion-best-practices`, follow
   `docs/REMOTION-UPDATE-PROMPT.md`.
8. Final gate: Sam approves visually. Never record approval he did not give.
