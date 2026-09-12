# Using ProfileDock

1. **Add a profile.** Choose a name and either the shared ChatGPT app or a separate app copy. New profiles start empty.
2. **Open and sign in.** Use ProfileDock or the new Finder launcher in `~/Applications/ProfileDock Launchers`. Each launcher opens its assigned profile. Check the account shown inside ChatGPT.
3. **Hover and switch.** Move to the top center of any display. Click a profile or use ⌥⌘1–9. Expand **Resets** to see expiry countdowns.
4. **Choose what updates.** Open **ChatGPT updates**, select app groups, and click **Update selected ChatGPT apps**. The panel checks whenever you open it. Selected groups close and previously running profiles reopen. Active tasks must finish first.

**Update ProfileDock:** it checks daily while running. Use **Check ProfileDock for updates** for an immediate check, or disable automatic checks in the same card. Downloads and installation need your choice. Only ProfileDock restarts; your profiles stay in place. Users on 1.0.x must install 1.1 or later manually once.

**Cancel a ChatGPT download:** use **Cancel download** beside its progress bar. During signature verification, cancellation may take a moment. Once app installation starts, cancellation is unavailable and ProfileDock must remain open until it finishes.

**Activity cues:** blue dots mean working, orange needs input, green is idle, red is unread, and gray is closed or unknown. New completion/input events briefly light up both sides of the notch or compact bar. **Appearance → Activity & sound** has previews, a visual-cue toggle, optional quiet chimes, and volume. Sounds are off by default. Repeated events are combined, and startup/reconnect snapshots stay quiet. Reduce Motion disables pulsing.

**Shared app or separate copy?** Shared profiles use less disk space but update together. A separate, unmodified ChatGPT copy uses more space and can update independently. Use a profile's options menu to create a copy or move it to the Trash and return to the shared app.

**Remove a profile:** close it, then choose **Remove profile**. Data stays on your Mac by default. For profiles created here, you can also move their data and app copy to the Trash. Imported profiles' original data is protected from deletion here.

**Start at login:** enable it in **Appearance**. ProfileDock follows macOS Reduce Motion and responds to display changes automatically.

**Use another notch app:** choose **Appearance → Placement → Bottom left** or **Bottom right**. The floating launcher sits in the screen's usable lower corner, accounting for a visible Dock, and expands upward on hover. Activity cues move with it, keeping the notch free. **Show ProfileDock in the macOS Dock** adds a regular icon that opens settings on click. Custom hover expansion belongs to the floating launchers, not the system Dock icon.

The app, menu bar, and GitHub use matching four-tile [artwork](BRANDING.md), with light/dark headers and a monochrome template mark.

## A few useful boundaries

- Activity covers local **Work/Codex** tasks, not ordinary chats or tasks on another computer. Missing data is shown as unknown.
- Usage and activity rely on desktop interfaces that OpenAI may change. ProfileDock never buys or redeems reset credits.
- Profiles separate local app state; they are **not a security boundary** between people or companies. The macOS user, files, and Keychain remain shared.
- Update selection is by physical app bundle. ChatGPT's own updater remains active. New ProfileDock releases require Apple Silicon and macOS 14 or later.
- Only the apps selected for an update restart. If an app refuses to quit, it is not force-closed. A hidden copy of its previous version is retained beside an updated app for recovery.

Read [Privacy & security](PRIVACY.md). ProfileDock is an independent project and is not affiliated with OpenAI.
