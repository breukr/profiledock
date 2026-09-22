# ProfileDock desktop design

## Reference lock

Design a native macOS utility for switching accounts and managing their settings. The build target is Apple's System Settings grouping and navigation, with Finder's compact rows and explicit actions. This is a direct implementation of Sam's Apple-app brief, using SwiftUI and AppKit controls.

References inspected on 22 September 2026:

- System Settings on this Mac: persistent sidebar, related settings grouped in one surface, inset separators, trailing controls, and descriptive text below the setting label.
- [Apple sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars): stable top-level destinations and native sidebar behavior.
- [Apple menus](https://developer.apple.com/design/human-interface-guidelines/menus): grouped commands, recognizable labels, keyboard equivalents and state indication.
- Refero Apple style `e02fcb85-b3eb-4b9e-985f-ab2044beb6cc`: system typography, neutral surface hierarchy and restrained interactive accent. Marketing hero sizes, imagery and pill buttons do not apply to this utility.
- Refero Things style `0796cd74-edc2-4e12-9c71-25fac02a1cb2`: concise desktop labels and disciplined alignment. No marketing-page composition is carried into the app.

## Decisions

| Decision | Reference and purpose |
| --- | --- |
| Workspace and Settings groups in one sidebar | System Settings; remove the second level of segmented navigation. |
| Search destinations by common setting terms | System Settings search; make sound, login, Dock and access controls findable. |
| One grouped profile list, aligned actions | Finder and System Settings; make account names and open state easy to scan. |
| Show for an open profile, Open for a closed profile | Current process state; label the action accurately. |
| One-click status menu with profile icons and open indicators | Native menu-bar utilities; make the dropdown discoverable without right-clicking. |
| Standard Settings command goes to General | macOS menu conventions; avoid dropping users into experimental icon settings. |
| Short labels, detailed help next to advanced controls | System Settings; reduce repetitive paragraphs while retaining security disclosure. |
| Center empty states in their available pane | Sam's screenshot feedback; size the scroll content from its viewport, with matching header and content columns. |
| Contained notices with explicit recovery buttons | Sam's warning feedback; retry the affected profile by identity and discard obsolete actions when the notice changes. |

Tokens: system fonts (12-point captions, 13-point controls, 20-point page titles), system semantic colors, accent for selection and primary actions, 4-point spacing increments, 10-point grouped surfaces, half-point separators. Support both appearances without fixed white/black colors. Keep SF Symbols, native focus rings and standard keyboard actions. No decorative bitmap assets or custom glass effects.

## Verification

Check the packaged app at normal, narrow and wide desktop sizes, plus a shorter window. Inspect light and dark appearances, sidebar search, profile menus, profile editor, General, Appearance, Updates and context navigation. Keep real profile data and running ChatGPT processes intact. Fixture content belongs only in an isolated preview home.

Native render coverage: `PROFILEDOCK_RENDER_SETTINGS=/private/tmp/profiledock-settings-renders swift test --filter SettingsRenderingTests` exports all nine pages at 760×560, 920×700 and 1280×800 in light and dark appearances, plus the profile editor, a wide empty state and compact notices. These are fixture renders; bundle resources and inactive control colors differ from the installed app. Live preview checks cover empty-state centering and clicking the recovery button. The `--preview-notice` flag only operates in preview mode and keeps retries inside its temporary profile home.
