# ProfileDock design contract

Source of truth for how ProfileDock looks and moves. Extracted from the code (`Sources/AccountDock`, `Sources/DockCore`) and `docs/MENU-DESIGN.md`. Change this file together with the code. Decisions and their reasons live in `docs/MENU-DESIGN.md`; round history lives in `docs/design-log.md`.

Product: native macOS 14+ utility (SwiftUI + AppKit, Apple Silicon). Surfaces: the **strip** (a notch/menu-bar island that expands on hover), the **attention pop-up** (drops from the notch when an agent needs the user) and the **Settings window** (System Settings style). Direction (Sam, 2026-11-07): **Dark Liquid Glass**, Apple-native and quiet: native controls, system fonts, system semantic colors, native glass only, no marketing styling inside the app.

## Surfaces and tokens

There is no central tokens file. The tokens are the constants below; reuse the named component instead of re-declaring values.

### Settings window (`Sources/AccountDock/SettingsDesign.swift`, `SettingsView.swift`)
- Layout: persistent sidebar (190 min, 210 ideal, 240 max) + one centered content column, max width 760 (`pageWidth`). Window opens 760x560 (compact) or 920x700; minimum 760x560.
- Destinations: Workspace group (Profiles, Search Chats, Usage Insights), Settings group (General, Appearance, Profile Icons, Context Access, Updates), then Support (pink heart) and About last.
- Type: system fonts only. 12 pt semibold secondary for group labels, `.body` for row titles, `.caption` secondary for details, 20 pt page titles, 13 pt controls. Code or hex values use `.monospaced()`.
- Color: system semantic colors only (`controlBackgroundColor`, `separatorColor`, `.secondary`, accent for selection and primary action). No fixed white or black. Warnings use `.orange`, info uses accent.
- Shape: `SettingsCard` radius 10 with a 0.5 pt separator stroke at 0.45 opacity; `SettingsNotice` radius 8; row padding 16 horizontal, 12 vertical; row gap 24; 4-point spacing steps (4, 8, 12, 16, 24).
- Components to reuse: `SettingsCard`, `SettingsGroupBoxStyle`, `SettingsRow`, `SettingsNotice`, `ProfileMessageNotice`, `ProfileGridSettings`. Icons are SF Symbols (`SettingsDestination.symbol`).

### Strip (`Views.swift`, `Island.swift`, `IslandLayout.swift`, `WidgetSizing.swift`)
- Always dark: `.environment(\.colorScheme, .dark)`. Surface (`Glass.swift`, `IslandSurface`): pure black band where the strip meets the notch (notch height + 6), fading over 56 pt into dark tinted native glass (`NSGlassEffectView` on macOS 26+, `.hudWindow` visual effect view on 14/15) under a black shade at 0.66. The strip opens and closes as solid black and the glass fades in (0.22 s) once the outline settles, because window-server glass ignores the animated layer mask. Reduce Transparency: no backdrop, opaque black. Text is white at 0.55 to 1.0 opacity; secondary labels 0.45 to 0.65. Do not add light-mode strip styling.
- Agent identity: agent profiles without a chosen icon show their tool's real app logo with the profile's color dot (`AgentBrand.swift`); tools without an installed app keep a colored monogram.
- Type: card names 13 pt semibold, status lines 11 pt, usage rows and micro actions 10 pt, header title 12 pt semibold. Numbers use `.monospacedDigit()`. The scale preference sizes cards and badges, not type (open decision).
- Collapsed: notch-width capsule (or 160 to 480 pt free strip) with the 11 pt `BrandMark`, "N need you" when an agent waits (else "Agents"), one 6 pt activity dot per profile (`WidgetSizing.visibleDots` caps them, then "+N"), chevron. Top corners 2 pt on a notch, 12 pt when floating; bottom corners 12 pt.
- Header: `BrandMark` + "ProfileDock" 12 pt semibold, attention chips ("N need you" orange, "N working" blue, "N done" red; hidden at zero, counts only when narrow), trailing 28 pt round icon buttons (white 0.08 fill); a spinner replaces the old "Refreshing…" text.
- Expanded width: `WidgetSizing.expanded` = columns x `CardMetrics.idealWidth` (264 x scale) + gaps + 32, automatic up to 1200, 320 to 1400 when set, 520 minimum with Insights open.
- Cards (`ProfileCard`, `CardMetrics`): horizontal, width 240 x scale up to filling the row (cap 560 x scale for a lone card), padding 12, radius 16 continuous, fill white 0.06 (hover 0.09, active 0.10 + 1 pt white 0.18 stroke), no shadow. Left a 36 x scale badge (radius 26%), then name 13 pt semibold white 0.95 over a status line 11 pt (working blue, needs-you orange, done red, else app and sign-in mode), trailing ⌥⌘ shortcut 10 pt mono white 0.35; close button and drag grip only on hover. Every card in a strip has the same height (`CardMetrics.height`). Agent profiles show their real app logo (`AgentBrand`); the corner tool badge hides when it would repeat that logo. Scale range 0.85 to 1.3 (`preferences.scale`).
- Grid: automatic columns = as many minimum-width cards as fit, balanced, at most 4; custom `ProfileGrid` columns are honored while 240 x scale cards fit, rows always; extra profiles paginate. Terminals paginate independently. Header, cards, Terminals and Insights share one leading edge (16 pt). Columns follow the larger section (apps or terminals). Section stack gap 12; strip padding 16 horizontal, 14 bottom, 12 plus notch height top.
- Usage rows: one table row per window inside the card: label 32 pt (white 0.55), 4 pt capsule bar (white 0.12 track, fill from `UsageTint.remaining`: green >= 60%, smoothstep to amber at 25%, to red at <= 10%), percent left 32 pt monospaced, reset 46 pt (white 0.45); columns line up across cards. Row 14 pt, gap 6. A window whose reset time passed shows full and dimmed ("reset") until the next reading. Saved resets: one line ("2 saved resets · next expires 3d") that expands.
- Attention pop-up presentations: finished and waiting turns are a compact pill (380 pt wide, band + 52 pt: badge 26, headline 13 semibold over "Done · project" 11 pt, round 28 pt Reply and Open, close on hover; auto-hides after 5 s unless hovered or replying). Reply grows the pill into a reply card (1 to 4 line field, Return sends, Shift-Return new line, Esc folds back). Permission requests and questions use the full card (countdown in the header, command preview collapses past 4 lines, questions offer "Other…"). One persistent `NotchShape` morphs between island, pill, reply card and full card; queue changes slide content by pager direction; buttons press to 0.96.
- Attention pop-up (`AttentionPanel.swift`): grows out of the collapsed island as one shape (island size and 12 pt bottom corners, spring 0.55 s with a small overshoot to the 440 pt card plus 10 pt concave shoulders where it meets the top edge (`NotchShape`), bottom radius 27 like the strip; text fades in after 0.16 s; a black veil lifts after the shape grows so the morph reads as solid; reverse on close 0.40 s). Flat 2 pt top corners and a black band continuing the notch or menu-bar island, then the strip's material: dark native glass (tint 0.3) under the 0.66 black shade, band fading to clear over 56 pt; the frosted fallback uses the same shade. Allow is `.glassProminent` tinted blue. Reduce Motion: fade only.

### Profile identity (`Profile.swift`, `NativeProfileArtwork.swift`)
- A profile has a name, a 6-digit hex `color`, and a style: dot (colored dot on the app icon), initials (white text on color), image (center-cropped, no inset border), chatgpt (knot extracted from the installed app on the color).
- Letters: custom text up to 3 characters, uppercased; otherwise first plus last word initial, or first 2 letters of a single word.
- Default palette (`ProfileCatalog.discover`): blue 377CF6, teal 009B87, purple 955CE5, green 339958, orange D77620, pink CA528B, red D85252. The same artwork renders in the editor, notch, list and menu; never fork the renderer.
- Activity dot colors (`ProfileActivityState.color`): working blue (0.3, 0.65, 1), waiting orange, unread red, idle green (0.23, 0.9, 0.42), closed white 0.22. Unread badge red capsule, waiting is a black-on-orange pause glyph.

### Brand (`Resources/Brand`, `docs/BRANDING.md`)
Four-tile mark from `mark.json` (dark 151A25 / light EEF4FF backgrounds, blues 4A8FFA, AED0FF, D9E7FF, 629FFF). Menu-bar mark is a template image. Regenerate with `python3 scripts/make-brand.py`; keep the four tiles and spacing.

## Motion

Timings in use today (keep new motion inside these):

| Token | Value | Where |
| --- | --- | --- |
| hover exit delay | 0.12 s | `HoverIntent.exitDelay`; 250 ms hover intent before Insights opens |
| drawer open / close (spring) | 0.42 s / 0.30 s, stiffness 320 / 420, damping 36 / 42 | `IslandSurface.reveal` in `Island.swift` |
| content fade in / out | 0.24 s / 0.18 s (ease out) | `Island.swift` |
| strip reveal morph | 0.16 s open, 0.14 s close | `Island.swift` |
| tile reorder | 0.18 s and 0.15 s ease in-out; snappy 0.25 s on commit | `ProfileReordering.swift` |
| grid change | 0.20 s ease in-out | `Views.swift` |
| usage bar and number | 0.45 s ease in-out | `UsageWindowView` |
| activity cue open / close | 0.55 s / 0.40 s spring, content fade 0.22 s | `ActivityCues.swift` |
| working pulse | 1.05 s autoreverse, only while a task is working and the strip is visible | `IconPulse.swift` |

Rules:
- Motion follows a user action (hover, click, drag) or a real state change (task working, cue). No decorative loops. The working pulse is the only repeating animation and it stops when the state ends or the strip is hidden.
- Springs resize a fixed native canvas; never resize the window per frame (see `docs/MENU-DESIGN.md`).
- Stagger: none. Animate one surface at a time.
- Reduce Motion: every animation reads `accessibilityReduceMotion` (or `NSWorkspace.accessibilityDisplayShouldReduceMotion`) and skips geometry, rotation and pulse; fades may remain at <= 0.16 s. New motion without a Reduce Motion path fails review.
- Regression tests: `IslandRenderingTests` (rapid reversal, Reduce Motion), `IconPulseTests`.

## Done bar

Every visible change meets all of these before it is shown to Sam.

### Windows and sizes (desktop only; ProfileDock ships no mobile)
- Settings window: 760x560 (minimum), 920x700 (default), 1280x800; every destination, light and dark. Plus the profile editor sheet (600x660), an empty state at 1280x800, and compact notices at 320 and 680 wide.
- Strip: widths 360, 680, 1040 at scale 0.85, 1 and 1.3; grids 2x2, 3x3, 6x1, 1x6; sections hidden; terminals collapsed; Insights 488, 680, 1000 wide in light and dark; adaptive widgets 420, 740, 1200. Strip is dark only.
- Also check the Reduce Motion state for anything animated, and increased contrast for new colors.
- `./scripts/design-check.sh` renders all of the above from fixtures. Native SwiftUI has no browser zoom; the scale preference (0.85 to 1.3) is the zoom axis.

### Geometry checks
- Centered elements within 1 px of their container center (empty states, titles, notch capsule vs screen midX).
- Left edges of an aligned group within 1 px (settings rows, tile labels).
- Gaps come from the spacing steps above (4, 8, 10, 12, 13, 16, 24).
- No clipping or truncation without an affordance (`lineLimit` with `.help` or tooltip, `minimumScaleFactor`, `ViewThatFits`). The existing tests assert part of this (`ActivityCueRenderingTests` truncation, `AccountConnectionRenderingTests` notice height, `IslandTests`); extend them for new layouts instead of eyeballing only.
- Hit targets >= 28x28 pt on macOS. Known exceptions today: the 20x20 close and refresh icons on the strip; do not add new ones below 20x20 and do not shrink these further.
- Machine-checked now: `design-check.sh` fails if a render is missing, empty, or has unexpected pixel dimensions. Pixel-level centering and edge checks are reviewer-judged from the PNGs until a test measures them.

### Token lint
`./scripts/design-lint.sh` fails when a raw color literal (`Color(red:`, `Color(white:`, `NSColor(srgbRed:`, hex literals) appears in a file outside its allowed list, or when a file exceeds its baseline count. Run by `design-check.sh`. New colors go through system semantic colors or an existing helper (`UsageTint`, `ProfileActivityState.color`, `StatusDot`).

### AI-look blacklist (reject on sight)
Generic purple/blue gradients, custom or fake glass (hand-made blur, `.ultraThinMaterial` panels on content, glass stacked on glass; only native Liquid Glass on floating surfaces: strip, pop-up, sidebar and toolbar), bento grid as a default layout, emoji as icons (use SF Symbols), centered hero + three feature cards, gradient text on headlines, floating blobs or orbs, stock 3D illustrations, "trusted by" strips with fake logos, uniform rounded-2xl cards everywhere, shadow on everything, lorem ipsum or placeholder numbers, icon-in-circle feature rows. Repo-specific rejections (see `design/references/README.md`): marketing hero type sizes and pill buttons inside the app, decorative bitmap assets, off-center empty states, an inset colored border on custom icon images, fixed white or black in Settings.

### Motion
As in the Motion section: durations from the table, user-action or state triggered, no settling-free loops beyond the working pulse, Reduce Motion path required.

### Fixture hygiene
Renders and screenshots use fictional profiles and a temporary home only. Synthetic names: Noordhaven, Veldkamp, Atlas, Rijnstaal, Meridian (existing fixtures also use Personal, Work, Research). No real account data, tokens, client names or task content (see `CONTRIBUTING.md`).

### Final gate
Sam approves visually. Show him the screenshots and the `design-reviewer` verdict; never record approval he did not give.

## Film and marketing assets
- Launch film: `launch-film/` is a Remotion project (not in git here; local only). Video route: skill `remotion-best-practices`. Do not scaffold a new project; extend the existing one and follow `docs/REMOTION-UPDATE-PROMPT.md`.
- `linkedin-carousel/` holds marketing images (local only, Dutch, Breukr v3 styling). Treat as references, not as in-app design.
- `docs/hero.svg`, `docs/hero-dark.svg`, `docs/companions-preview.png`: README visuals; update when the strip or mark changes.
