# ProfileDock 1.6.0

## Coding agents

- ProfileDock recognizes 35 coding agents, including Claude Code, Codex, Grok Bot, Grok Build, Hermes, Gemini CLI, OpenCode, pi, Qwen Code, Crush, Kilo Code, Cline, Continue, OpenHands, Mistral Vibe, Kimi Code, Copilot CLI, Aider, Amp, Cursor, Factory Droid, T3 Code, Conductor, Antigravity, Kiro, Zed and Warp. See [coding-agent coverage](AGENT-COVERAGE.md).
- Running agent apps such as Grok Bot or T3 Code get a tile by themselves, with the sign-in already on your Mac. A tile you remove stays removed, and **Settings → Coding Agents → Add running agent apps** turns this off.
- Installed tools are offered with one click in **Profiles** and in the new **Settings → Coding Agents**, which shows what was found, where, and each tool's account notes and install command.
- **Add Profile** is searchable and lists the tools on your Mac first. Choose the sign-in already on your Mac or a separate account where the tool supports one: Grok Bot, Grok Build, Hermes, Gemini CLI, OpenCode, pi, Qwen Code, Crush, Kilo Code, Cline, Continue, OpenHands, Mistral Vibe and Kimi Code. A separate account keeps its own folder, so both can stay signed in side by side.
- Tools installed with nvm, fnm, mise, asdf, Volta, Bun, pnpm or npm prefixes are found, and so are tools that run under Node or Python, such as Hermes and Gemini CLI.
- Tiles say **Not installed** with the install command, or **Sign-in needed** for a new separate Grok Bot account. If Terminal access is denied, the tool still opens in a new Terminal window.
- Coding sessions appear under **Terminals** in Terminal.app, iTerm2, Ghostty, Warp, editor terminals and tmux. iTerm2 sessions open directly; other apps come forward.
- ProfileDock does not store API keys or tokens for these tools. You sign in from the tool itself.

## Claude accounts

- Add a separate Claude Desktop account from Add Profile → Claude Desktop. It opens its own Claude window, so two accounts can stay signed in and open at the same time.
- Claude tiles read five-hour and weekly usage from your Claude Code account directly, refresh at startup, on wake and in the background, and show saved resets with their expiry.
- Usage insights resume reading large Claude Code histories across scans and restarts instead of starting over.

## Sign-in and the strip

- When a Claude Code or Codex sign-in expires, the tile shows **Sign-in needed** with **Reconnect**. The reminder appears in the strip itself. Mute one account, or turn reminders off under Appearance → Activity & Sound.
- Hide a profile from the strip without removing it: use the eye button in Settings → Profiles, or right-click a tile.
- The Done cue waits while Claude Code subagents are still running (**Wait for subagents**, on by default). Update the Claude Code connection in Profiles to install the new hooks.

Existing profiles, sign-ins and preferences are preserved. Requires macOS 14 or later on Apple Silicon.
