# Integrated desktop Dock

ProfileDock's optional desktop Dock is part of the existing app. Enable it under **Settings → Dock → Show the ProfileDock Dock**. The existing profile strip remains available.

The Dock reads macOS pinned apps and adds running apps and configured profiles. **Group ChatGPT apps** defaults to on. Its menu uses ProfileDock's own profile names and activation logic; other running ChatGPT/Codex variants are included as well. Turning grouping off shows the individual profiles and instances. Grouping does not write to Apple's pinned-app list. Ordinary app menus offer opening, window selection, Finder reveal, hiding and normal quit.

Individual window selection uses macOS Accessibility access. Profile activation itself does not need that permission. This implementation uses window titles, not screenshot previews, and does not request Screen Recording.

**Automatically hide the macOS Dock** is a separate opt-in. Only the `autohide` preference changes; pins, position and timing are untouched. ProfileDock restores the previous value when disabled or normally quit. If ProfileDock is forcibly terminated, macOS auto-hide remains usable and the saved original is recovered at the next launch.

## Icon appearances

The application retains the four-tile ProfileDock mark in monochrome. The layered `Resources/ProfileDock.icon` artwork defines light, dark and mono treatments; macOS derives tinted and clear renditions. **Auto** uses the bundled system-rendered icon. **Dark**, **Light**, **Tinted** and **Clear** override the running app's Dock icon. Finder remains governed by the system appearance. Clear and Tinted use light/dark variants according to the current macOS appearance.

`./scripts/render-icon-appearances.sh` regenerates the six previews using Apple's Icon Composer. `./scripts/build-app.sh` compiles the layered icon for distribution. Xcode 26 or newer provides the native icon compilation tool.

## Design and provenance

Docky was studied as a functional reference for app grouping, native menus, a settings sidebar and translucent Dock surfaces. No Docky source, artwork or private-API implementation is incorporated here. The new implementation remains under ProfileDock's MIT license.

The visual source is ProfileDock's own `Resources/Brand/mark.json`, `mark-black.svg` and `mark-white.svg`: preserve all four tiles, their geometry and monochrome contrast. Native Icon Composer supplies material rendering. No replacement logo or new brand palette is introduced.

## Checks

- Unit tests cover family recognition, grouped/separate projection, pinned-app deduplication, old preference migration, persisted choices and an isolated profile store.
- Auto-hide tests use fake preferences, including interrupted-run recovery, external changes and write failures. They never change the test machine's Dock.
- `--preview --dock-preview --settings` opens an isolated sample with two fictional profiles. No real profile is launched and the system Dock is not changed by that preview.
