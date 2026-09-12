# Using ProfileDock

1. **Add a profile.** Choose a name and either the shared ChatGPT app or a separate app copy. New profiles start empty.
2. **Open and sign in.** Use ProfileDock or the new Finder launcher in `~/Applications/ProfileDock Launchers`. Each launcher opens its assigned profile. Check the account shown inside ChatGPT.
3. **Hover and switch.** Move to the top center of any display. Click a profile or use ⌥⌘1–9. Expand **Resets** to see expiry countdowns.
4. **Choose what updates.** Open **ChatGPT updates**, select app groups, and click **Update selected ChatGPT apps**. The panel checks whenever you open it. Selected groups close and previously running profiles reopen. Active tasks must finish first.

**Update ProfileDock:** it checks daily while running. Use **Check ProfileDock for updates** for an immediate check, or disable automatic checks in the same card. Downloads and installation need your choice. Only ProfileDock restarts; your profiles stay in place. Users on 1.0.x must install 1.1 or later manually once.

**Cancel a ChatGPT download:** use **Cancel download** beside its progress bar. During signature verification, cancellation may take a moment. Once app installation starts, cancellation is unavailable and ProfileDock must remain open until it finishes.

**Activity cues:** blue dots mean working, orange needs input, green is idle, red is unread, and gray is closed or unknown. A single cue grows from the strip, showing **Done** or **Needs you** on the left and the environment name on the right, then settles back into the strip. The camera area stays clear on notched screens. **Appearance → Activity & sound** has previews, a visual-cue toggle, optional quiet chimes, and volume. Sounds are off by default. Matching events are combined; different states queue separately so names stay accurate. Startup/reconnect snapshots stay quiet. Reduce Motion uses a simple fade.

**Shared app or separate copy?** Shared profiles use less disk space but update together. A separate, unmodified ChatGPT copy uses more space and can update independently. Use a profile's options menu to create a copy or move it to the Trash and return to the shared app.

**Remove a profile:** close it, then choose **Remove profile**. Data stays on your Mac by default. For profiles created here, you can also move their data and app copy to the Trash. Imported profiles' original data is protected from deletion here.

**Start at login:** enable it in **Appearance**. ProfileDock follows macOS Reduce Motion and responds to display changes automatically.

**Fit more accounts:** Appearance has separate compact-strip and expanded-panel width controls. Leave **Automatic** on to adapt to the account count, or choose a width with the slider. Tiles shrink to a readable minimum and wrap into rows. When the screen is full, use the page arrows to reach additional accounts. Compact dots use the available width, with a `+N` count for additional accounts. On a notched display, the compact trigger stays the size of the physical notch. Insights keep a minimum readable width.

**After a ChatGPT update or restart:** ProfileDock reconnects to local activity automatically. **Reconnecting…** means the connection is recovering; **Activity unavailable** means metadata cannot be read; **Update needed** means the activity protocol has changed. Hover the account for an explanation. Unavailable activity is never presented as idle, and reconnecting does not replay completion sounds.

**Place it anywhere:** choose **Appearance → Placement → Free position**. Drag the six-dot grip on the strip or panel header to move it anywhere inside that display's usable area. Each screen remembers its position, including after resizing or reconnecting it. Hover over the rest of the strip to open profiles; the panel opens toward available space and stays on screen. **Reset strip positions** brings the strips back to their starting positions. Choose **Top center** to return to the notch/menu bar. Activity cues move with the strip, leaving room for other notch apps.

**Show ProfileDock in the macOS Dock** adds a regular icon that opens settings on click. Custom hover expansion belongs to the floating strips, not the system Dock icon.

The app, menu bar, and GitHub use matching four-tile [artwork](BRANDING.md), with light/dark headers and a monochrome template mark.

**Working indicators:** a blue rim, soft halo, and outer ring breathe around working profiles; compact working dots glow gently too. The image stays still. Hidden indicators stop animating, and Reduce Motion keeps a steady blue glow.

## A few useful boundaries

- Activity covers local **Work/Codex** tasks, not ordinary chats or tasks on another computer. Missing data is shown as unknown.
- Usage and activity rely on desktop interfaces that OpenAI may change. ProfileDock never buys or redeems reset credits.
- Profiles separate local app state; they are **not a security boundary** between people or companies. The macOS user, files, and Keychain remain shared.
- Update selection is by physical app bundle. ChatGPT's own updater remains active. New ProfileDock releases require Apple Silicon and macOS 14 or later.
- Only the apps selected for an update restart. If an app refuses to quit, it is not force-closed. A hidden copy of its previous version is retained beside an updated app for recovery.

Read [Privacy & security](PRIVACY.md). ProfileDock is an independent project and is not affiliated with OpenAI.
