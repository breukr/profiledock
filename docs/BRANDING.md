# ProfileDock artwork

The app icon, GitHub header, and monochrome interface mark share the four-tile geometry in [`mark.json`](../Resources/Brand/mark.json).

- [Dark background](../Resources/Brand/mark-dark.svg)
- [Light background](../Resources/Brand/mark-light.svg)
- [Black mark, transparent](../Resources/Brand/mark-black.svg)
- [White mark, transparent](../Resources/Brand/mark-white.svg)

The menu-bar mark is a macOS template image, so it adapts to light and dark menu bars. GitHub's header also follows the reader's light/dark preference. The application icon uses the dark blue version.

After changing the shared mark, run `python3 scripts/make-brand.py` and rebuild the app. Preserve the four tiles and spacing when resizing it.
