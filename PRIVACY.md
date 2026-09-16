# Privacy & security

ProfileDock has no account system, advertising, or external analytics. Usage insights stay on your Mac.

Context sharing is a separate, opt-in feature. Its local preview stays on your Mac. When a connected task retrieves passages, those passages become context in the task's current account; that account's provider and workspace policies apply. Enabling a connection alone does not grant access to other profiles.

## What it reads

- Profile preferences, your selected pictures, running app arguments, and local profile directories.
- The signed-in profile's existing `auth.json` to request usage and reset-expiry information directly from `chatgpt.com` over HTTPS. Tokens are not written to ProfileDock's preferences or sent to a ProfileDock server.
- Local Work/Codex task metadata, read markers, and the desktop observer socket to display activity. Stream payloads may contain task content transiently; ProfileDock retains only the status/count metadata it needs, not transcripts.
- When Usage insights is opened, local `sessions` and `archived_sessions` JSONL files for the configured profiles. These files can contain conversation text; the scanner discards it and keeps only token counters, model names, timestamps, and session identifiers. Insights are not uploaded. At launch, a private local cache preloads the last loaded statistics and resumes reading new records after a restart.
- On an explicit Context search or read, the allowed source profiles' local `state_5.sqlite`, `thread_history_1.sqlite`, or referenced JSONL conversation files. The context helper selects visible user/assistant text, filters known injected records, excludes reasoning/tool records and subagent histories, and redacts recognizable token patterns. This is not a guarantee that arbitrary secrets pasted into a conversation can all be identified. It does not read `auth.json`, merge accounts, resume tasks, or contact a model provider itself.

## What it writes

- Rebuildable insight counters, profile/model/session identifiers, read offsets, and hashed file fingerprints in `~/Library/Caches/nl.breukr.profiledock/insights-v1.json`. No transcript text, credentials, display names, or raw session-file paths are stored there. The directory is private to the macOS user (0700), and the file uses 0600 permissions. Report samples are trimmed to the current 30-day window when refreshed; cumulative checkpoints are retained to avoid recounting old usage. macOS may discard this cache; deleting it only makes the next scan start from source history.
- Preferences and resized pictures in `~/Library/Application Support/Account Dock`. This historical folder name remains for compatibility.
- New local profiles in `~/.codex-profile-…`; no existing credentials or conversations are copied into a new profile.
- Finder launchers in `~/Applications/ProfileDock Launchers` and optional signed ChatGPT copies in `~/Applications/ProfileDock Apps`.
- Downloaded updates in a temporary directory, and a recovery copy beside each replaced app.
- Directional Context permissions and the bundled helper in `~/Library/Application Support/Account Dock/Context` (private directory 0700; permissions file 0600). No persistent transcript index is created. Source databases are opened read-only. For closed WAL-mode databases without sidecars, the helper makes a consistency-checked copy in a private temporary directory, reads that copy, then deletes it when the read finishes. A crash may leave a temporary copy for macOS cleanup; it can contain the original database's text. Live WAL records are never silently ignored.
- When you select Context **Connect**, the official `codex mcp add` command registers a profile-bound local helper in that profile's Codex configuration. ProfileDock also installs its marked skill in that profile's `skills/profiledock-context/SKILL.md`. Other server entries and custom skills are preserved. **Disconnect & turn off sharing** revokes that caller's grants first, removes the managed connection and skill, and keeps source conversations intact.

Imported profiles are kept in their existing locations. Removing a profile keeps its data unless you explicitly choose the Trash option. ProfileDock never deletes the stock `.codex` home through that option.

## Network access

Usage requests go directly to OpenAI and reject redirects. Update checks and selected downloads use OpenAI's `persistent.oaistatic.com` update feed. Downloads must pass its Ed25519 signature and the installed app must have OpenAI's Apple developer signature. No update requires signing into a third-party service.

ProfileDock uses Sparkle to check a public GitHub update feed daily while running. Automatic checks can be disabled in Settings. GitHub receives normal web-request metadata, including your IP address and updater user agent; ProfileDock does not send profile names, accounts, chats, or system-profile analytics. Its feed and downloads are signed with Ed25519, and published apps are Developer ID signed and notarized. Download and installation require your choice.

Repository and donation links open when clicked. The terminal installer uses GitHub's public download servers. Activity sounds are local audio files with no network requests.

## Boundaries

Separate profiles are a convenience within one macOS account, not isolation of Keychain, filesystem, developer tools, or server-side access. Verify the signed-in account in each ChatGPT window. Use separate macOS users when you need stronger separation.

The reset and activity interfaces are not a compatibility guarantee from OpenAI. Unknown and unavailable readings are shown explicitly. ProfileDock does not redeem resets or alter subscription plans.

Usage insights cover local profile history, not an account-wide billing record. Changing a profile's sign-in does not reassign older records. API-equivalent amounts compare recorded text tokens against a dated table of Standard USD API rates; they are not invoices or subscription savings. Unpriced and incomplete records are identified. See [the calculation guide](docs/INSIGHTS.md).

Diagnostics are opt-in local files and can contain profile identifiers and app paths. Review them before sharing; never attach credentials, raw task databases, or private screenshots to a public issue.
