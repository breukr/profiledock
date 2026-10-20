# ProfileDock 1.6.0

## Coding agents

- Add Grok Bot, Hermes, Grok Build, Gemini CLI and OpenCode from **Profiles → Add Profile → App**. Choose the sign-in already on your Mac or a separate account. A separate account keeps its own folder, so both can stay signed in side by side.
- A separate Grok Bot account opens its own Grok Bot window, the same way as separate Claude Desktop accounts. Open and Close act on that account's window only.
- Terminal tabs running Grok Build, Hermes, Gemini CLI, OpenCode, Copilot CLI, Aider, Amp, Cursor CLI or Goose appear under Terminals with the tool's badge. Cursor and Windsurf / Devin can be opened from the strip. ProfileDock says when a tool has no separate accounts.
- ProfileDock does not store API keys or tokens for these tools. You sign in from the tool itself. See [supported tools](../README.md#supported-tools).

## Claude accounts

- Add a separate Claude Desktop account from Add Profile → Claude Desktop. It opens its own Claude window, so two accounts can stay signed in and open at the same time.
- Claude tiles read five-hour and weekly usage from your Claude Code account directly, refresh at startup, on wake and in the background, and show saved resets with their expiry.
- Usage insights resume reading large Claude Code histories across scans and restarts instead of starting over.

## Sign-in and the strip

- When a Claude Code or Codex sign-in expires, the tile shows **Sign-in needed** with **Reconnect**. The reminder appears in the strip itself. Mute one account, or turn reminders off under Appearance → Activity & Sound.
- Hide a profile from the strip without removing it: use the eye button in Settings → Profiles, or right-click a tile.
- The Done cue waits while Claude Code subagents are still running (**Wait for subagents**, on by default). Update the Claude Code connection in Profiles to install the new hooks.

Existing profiles, sign-ins and preferences are preserved. Requires macOS 14 or later on Apple Silicon.
