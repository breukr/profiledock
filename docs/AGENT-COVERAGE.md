# Coding-agent coverage

ProfileDock describes each tool once in [`AgentRegistry.swift`](../Sources/DockCore/AgentRegistry.swift). This table records how each tool is recognized, whether a profile can keep a separate sign-in, and the primary source that decision rests on. Separate accounts are offered only where the vendor's documentation or source code shows that one folder (an environment variable or `--user-data-dir`) holds the sign-in. Everything else opens with the sign-in already on the Mac.

Checked 2026-10-20 unless noted. "Reused" rows were verified for PR #18 and re-read for this table; no newer release changed them.

## How recognition works

- **Installed command.** ProfileDock checks the GUI app's `PATH`, Homebrew, `~/.local/bin` and the global bins of npm prefixes, nvm, fnm, mise, asdf, Volta, Bun, pnpm, Yarn, Deno, Go and Cargo, plus a tool's own install folder (for example `~/.grok/bin`). It checks only whether a file exists, is executable, and where its symlink points.
- **Desktop app.** Launch Services lists every copy with a known bundle id, including renamed or duplicate copies. ProfileDock prefers `/Applications`, then `~/Applications`, then the newest version, and skips copies in the Trash, mounted installers, App Translocation and its own managed copies. Only `Info.plist` is read.
- **Running in a terminal.** A TTY's foreground job counts, preferring the process the shell started. Tools written in Node or Python run as `node` or `python`, so ProfileDock reads that process's argv (never its environment) to see which script it runs. A script counts by name only when it is an installed command (an absolute path without `.js` or `.py`), so `python3 gemini.py` is not Gemini CLI unless its package proves it. Idle shells, background and stopped jobs are ignored.
- **Shared command names.** `pi`, `agent`, `cn`, `droid`, `kimi` and `vibe` are used by other programs too. They count only when the resolved install path names the tool's own package or install folder, including Volta and pnpm package folders behind their shims. Factory's installer puts a plain `droid` file in `~/.local/bin`; that counts only while `~/.factory` exists. ProfileDock never runs a tool, its `--version` or its login to identify it.
- **Opening a missing tool.** A tool the last scan missed is looked for again when you open it. If it is still not found, ProfileDock shows the install command and **Open Anyway**, which it remembers for that profile, for tools on a PATH only your shell knows.
- **Launching an nvm, fnm, mise or asdf install.** ProfileDock runs the command with the Node beside it, so the Terminal shell does not need that version on its PATH. The command works in zsh, bash and fish.
- **Config folder only.** A folder such as `~/.qwen` shows the tool was used before. It is listed as "used before" but not offered or added.

## Automatic adding

- A running desktop agent app (Grok Bot, T3 Code, Conductor, Antigravity, Kiro, Cursor, Windsurf / Devin, Trae, and Claude Desktop) gets a tile with the existing sign-in. An instance started with its own `--user-data-dir` is treated as someone else's and left alone.
- Editors and terminals that are not mainly agents (Zed, Warp) and installed CLIs are offered with one click in **Settings → Agents** and at the top of **Add Profile**.
- Coding terminals keep appearing on their own while **Automatically find coding terminals** is on.
- Removing an automatic entry adds the tool to a dismissed list, so it is not added again until you add it by hand. Hiding keeps the entry. **Settings → Agents → Add running agent apps automatically** turns automatic adding off.

## Coverage table

| Tool | Recognized by | Separate accounts | Why | Source |
| --- | --- | --- | --- | --- |
| ChatGPT / Codex | `codex`; ChatGPT.app, Codex.app (`com.openai.codex`); `~/.codex` | Yes (existing) | `CODEX_HOME` holds `auth.json` | Reused; [Codex docs](https://developers.openai.com/codex) |
| Claude Desktop, Claude Code | `claude`; Claude.app (`com.anthropic.claudefordesktop`) | Yes for Claude Desktop (existing) | `CLAUDE_CONFIG_DIR` and the app's `--user-data-dir` | Reused; [Claude Code docs](https://code.claude.com/docs/en/desktop) |
| Grok Bot | Grok Bot.app (`com.anysphere.sand`) | Yes | `--user-data-dir` moves user data and its data root; a second instance ran signed out and reports `signedIn` in `desktop-status.json` | Reused; live check on this Mac for PR #18 |
| Grok Build | `grok` in `~/.grok/bin`; `~/.grok` | Yes | `GROK_HOME` holds `auth.json` | Reused; [xAI docs](https://docs.x.ai/build/settings) |
| Hermes | `hermes` (runs as `python …/.hermes/hermes-agent/hermes`) | Yes | `HERMES_HOME`, in a folder outside `~/.hermes` and not named `profiles` | Reused; [Hermes profiles](https://hermes-agent.nousresearch.com/docs/user-guide/profiles), [install.sh](https://github.com/NousResearch/hermes-agent/blob/main/scripts/install.sh) |
| Gemini CLI | `gemini` (`@google/gemini-cli`) | Yes | `GEMINI_CLI_HOME`; leave the optional Keychain storage off | Reused; [Gemini CLI docs](https://geminicli.com/docs/cli/enterprise/) |
| OpenCode | `opencode` (`opencode-ai`, Homebrew) | Yes | `XDG_DATA_HOME` moves `auth.json`; `OPENCODE_DB` does not | Reused; [OpenCode CLI](https://opencode.ai/docs/cli/) |
| pi | `pi` from `@earendil-works/pi-coding-agent`, the older `@mariozechner/pi-coding-agent`, or the managed install in `~/.pi/agent/install` | Yes | `PI_CODING_AGENT_DIR` holds `auth.json` | [config.ts](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/config.ts), [auth-storage.ts](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/auth-storage.ts), [environment variables](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/environment-variables.md) |
| Qwen Code | `qwen` (`@qwen-code/qwen-code`); `~/.qwen` | Yes | `QWEN_HOME` holds `oauth_creds.json` | [storage.ts](https://github.com/QwenLM/qwen-code/blob/main/packages/core/src/config/storage.ts), qwenOAuth2.ts |
| Crush | `crush` (Homebrew, `@charmland/crush`) | Yes | `CRUSH_GLOBAL_DATA` holds `crush.json` with keys and OAuth | [load.go](https://github.com/charmbracelet/crush/blob/main/internal/config/load.go), store.go |
| Kilo Code CLI | `kilo`, `kilocode` (`@kilocode/cli`) | Yes | `XDG_DATA_HOME/kilo/auth.json`, as in OpenCode | [global.ts and auth/index.ts](https://github.com/Kilo-Org/kilocode) |
| Cline CLI | `cline` (npm `cline`); `~/.cline` | Yes | `CLINE_DIR` replaces `~/.cline` with `providers.json` | [config docs](https://docs.cline.bot/cline-cli/overview), [paths.ts](https://github.com/cline/cline/blob/main/sdk/packages/shared/src/storage/paths.ts) |
| Continue CLI | `cn` only from `@continuedev/cli` | Yes | `CONTINUE_GLOBAL_DIR` holds `auth.json` (shared with the IDE extensions) | [env.ts, authEnv.ts](https://github.com/continuedev/continue/tree/main/extensions/cli/src) |
| OpenHands CLI | `openhands` (PyPI `openhands`) | Yes | `OPENHANDS_PERSISTENCE_DIR` holds settings and `cloud/api_key.txt` | [locations.py](https://github.com/OpenHands/OpenHands-CLI) |
| Mistral Vibe | `vibe` only from the `mistral-vibe` tool environment | Yes | `VIBE_HOME` holds `.env` | [README and _vibe_home.py](https://github.com/mistralai/mistral-vibe) |
| Kimi Code | `kimi` only from `~/.kimi-code`, `@moonshot-ai/kimi-code` or Homebrew `kimi-code` | Yes | `KIMI_CODE_HOME` holds `credentials/` | [paths.ts, data-locations.md](https://github.com/MoonshotAI/kimi-code) |
| GitHub Copilot CLI | `copilot` (`@github/copilot`) | No | One Keychain item; Copilot switches accounts with `/user switch` | Reused; [GitHub docs](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli) |
| Aider | `aider` (runs as `python …/aider`) | No | No account folder; keys are the user's own files | Reused; [Aider config](https://aider.chat/docs/config/aider_conf.html) |
| Amp | `amp`, `~/.amp/bin` | No | Amp switches accounts itself (`amp account switch`) | Reused; [Amp CLI](https://ampcode.com/docs/cli) |
| Cursor CLI | `cursor-agent`; `agent` only from `~/.local/share/cursor-agent` | No | Keychain login | Reused; [Cursor CLI](https://cursor.com/docs/cli/reference/configuration) |
| Cursor | Cursor.app (`com.todesktop.230313mzl4w4u92`) | No | No documented second data folder | Reused |
| Windsurf / Devin | Windsurf.app, Devin.app (`com.exafunction.windsurf`) | No | No documented data folder setting | Reused |
| Goose | `goose`; `~/.config/goose` | No | Provider keys in one keyring item | Reused; [Goose](https://block.github.io/goose/) |
| Factory Droid | `droid` only at `~/.local/bin/droid`, Homebrew cask `droid` or npm `droid` | No | Keyring sign-in; no documented folder variable | [CLI reference](https://docs.factory.com/droid-cli/cli-reference), [security](https://docs.factory.com/cli/account/security.md) |
| Augment Auggie | `auggie` (`@augmentcode/auggie`) | No | `--augment-cache-dir` is documented, but not that it moves the sign-in | [CLI reference](https://docs.augmentcode.com/cli/reference) |
| Codebuff | `codebuff` (npm) | No | `FREEBUFF_CONFIG_DIR` is not used by every code path | [config-dir.ts](https://github.com/CodebuffAI/codebuff) |
| Junie CLI | `junie` (`@jetbrains/junie`) | No | `JUNIE_HOME` is documented, the sign-in location is not | [environment variables](https://junie.jetbrains.com/docs/environment-variables.html) |
| Antigravity CLI | `agy`; `~/.gemini/antigravity-cli` | No | Keychain sign-in | [install docs](https://antigravity.google/docs/install) |
| Kiro CLI | `kiro-cli`; `~/Library/Application Support/kiro-cli` | No | Only the version 3 preview documents `KIRO_HOME` for sign-ins | [configuration](https://kiro.dev/docs/configuration/), [CLI 3 blog](https://kiro.dev/blog/cli-3/) |
| T3 Code | T3 Code.app, any channel (`com.t3tools.t3code`) | No | It drives Claude Code, Codex and others with their own sign-ins; give those CLIs separate accounts | [t3code source](https://github.com/pingdotgg/t3code) (DesktopApp.ts, DesktopStatePaths.ts) |
| Conductor | Conductor.app (`com.conductor.app`) | No | Uses the shared Claude Code and Codex sign-ins | [FAQ](https://www.conductor.build/docs/faq) |
| Antigravity | Antigravity.app (`com.google.antigravity`) | Not yet | `--user-data-dir` is accepted and starts a fresh data folder (live check 2026-10-20), but it was not yet confirmed visually that the Google sign-in stays separate | Local `Info.plist` and `product.json`; [docs](https://antigravity.google/docs) |
| Kiro | Kiro.app (`dev.kiro.desktop`) | No | The sign-in appears to use the shared AWS SSO cache | [Homebrew cask](https://github.com/Homebrew/homebrew-cask/blob/master/Casks/k/kiro.rb), [authentication](https://kiro.dev/docs/getting-started/authentication/) |
| Trae | Trae.app (`com.trae.app`) | No | No verified data-folder behavior | [Homebrew cask](https://formulae.brew.sh/api/cask/trae.json) |
| Zed | Zed.app, Zed Preview.app (`dev.zed.Zed`, `dev.zed.Zed-Preview`) | No | `--user-data-dir` exists but the sign-in is a Keychain item | [main.rs, zed_credentials_provider.rs](https://github.com/zed-industries/zed) |
| Warp | Warp.app (`dev.warp.Warp-Stable`, `dev.warp.Warp-Preview`) | No | `WARP_DATA_PROFILE` only works in development builds | [channel/state.rs](https://github.com/warpdotdev/warp) |

## Not included

- Jules (`@google/jules`): a client for a cloud task service, with no local agent session.
- Roo Code: an editor extension only; the repository was archived in May 2026.
- Plandex: no release since October 2025.
- Warp's agent CLI (`warp`) and Amazon Q's `q`: both command names are too generic to identify without running them.
