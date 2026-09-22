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
| One centered 760-point maximum column on every page | Keep titles, cards and page edges stable when switching between Profiles, Search Chats and settings, including wide windows. |
| Separate Support and About at the end of the sidebar | Pink heart for optional donations and sponsorships; About remains the final destination for app information and help. |
| Custom images fill the rounded icon | Center-crop without distortion or inset borders; share the renderer between the native Dock preview and exported icon. |
| One profile icon choice across every surface | The editor, notch, profile list and menu use the same style, letters and image immediately, even with experimental mode off. Existing uploaded logos remain the default for older profiles. |
| Visible progress beside the experimental switch and in the fixed footer | Report copying, signing, verification and installation as they happen. Keep the profile editor open and prevent competing changes until the operation finishes; errors and retry remain visible above the footer. |
| Insights hover uses a short spring and content fade | A 250 ms hover-intent delay prevents accidental opens; the chevron rotates, the surface expands in 420 ms and retracts in 300 ms. It stays open while the chart or its menus are in use. Reduce Motion skips geometry and rotation. |
| Contained notices with explicit recovery buttons | Sam's warning feedback; retry the affected profile by identity and discard obsolete actions when the notice changes. |

Tokens: system fonts (12-point captions, 13-point controls, 20-point page titles), system semantic colors, accent for selection and primary actions, 4-point spacing increments, 10-point grouped surfaces, half-point separators. Support both appearances without fixed white/black colors. Keep SF Symbols, native focus rings and standard keyboard actions. No decorative bitmap assets or custom glass effects.

## Verification

Check the packaged app at normal, narrow and wide desktop sizes, plus a shorter window. Inspect light and dark appearances, sidebar search, profile menus, profile editor, General, Appearance, Updates and context navigation. Keep real profile data and running ChatGPT processes intact. Fixture content belongs only in an isolated preview home.

Insights animation uses a fixed native window canvas while its mask and content layers animate; the window settles to the final bounds afterward. Regression checks cover rapid reversals, top and floating positions, menu interaction, shutdown and Reduce Motion. This avoids resizing the window and reflowing its contents on every animation frame.

Native Dock process recognition handles Launch Services reporting PID -1 after the helper execs ChatGPT. The recovery path matches the exact kernel executable, then verifies the owned bundle, profile identity and user-data argument before registering that process. Reopen and graceful quit address the verified PID; active Dock copies remain protected from replacement or removal. Disabling verifies the current original app's OpenAI signature before removing the managed copy and preserves the profile's data paths. It does not download a newer original or migrate account data.

Native render coverage: `PROFILEDOCK_RENDER_SETTINGS=/private/tmp/profiledock-settings-renders swift test --filter SettingsRenderingTests` exports all ten pages at 760×560, 920×700 and 1280×800 in light and dark appearances, plus the profile editor, a wide empty state and compact notices. These are fixture renders; bundle resources and inactive control colors differ from the installed app. Live preview checks cover empty-state centering and clicking the recovery button. The `--preview-notice` flag only operates in preview mode and keeps retries inside its temporary profile home.
