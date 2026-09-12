# Privacy & security

ProfileDock has no account system, advertising, or analytics.

## What it reads

- Profile preferences, your selected pictures, running app arguments, and local profile directories.
- The signed-in profile's existing `auth.json` to request usage and reset-expiry information directly from `chatgpt.com` over HTTPS. Tokens are not written to ProfileDock's preferences or sent to a ProfileDock server.
- Local Work/Codex task metadata, read markers, and the desktop observer socket to display activity. Stream payloads may contain task content transiently; ProfileDock retains only the status/count metadata it needs, not transcripts.

## What it writes

- Preferences and resized pictures in `~/Library/Application Support/Account Dock`. This historical folder name remains for compatibility.
- New local profiles in `~/.codex-profile-…`; no existing credentials or conversations are copied into a new profile.
- Finder launchers in `~/Applications/ProfileDock Launchers` and optional signed ChatGPT copies in `~/Applications/ProfileDock Apps`.
- Downloaded updates in a temporary directory, and a recovery copy beside each replaced app.

Imported profiles are kept in their existing locations. Removing a profile keeps its data unless you explicitly choose the Trash option. ProfileDock never deletes the stock `.codex` home through that option.

## Network access

Usage requests go directly to OpenAI and reject redirects. Update checks and selected downloads use OpenAI's `persistent.oaistatic.com` update feed. Downloads must pass its Ed25519 signature and the installed app must have OpenAI's Apple developer signature. No update requires signing into a third-party service.

GitHub and donation links open only when you click them. The terminal installer uses GitHub's public release API and download servers.

## Boundaries

Separate profiles are a convenience within one macOS account, not isolation of Keychain, filesystem, developer tools, or server-side access. Verify the signed-in account in each ChatGPT window. Use separate macOS users when you need stronger separation.

The reset and activity interfaces are not a compatibility guarantee from OpenAI. Unknown and unavailable readings are shown explicitly. ProfileDock does not redeem resets or alter subscription plans.

Diagnostics are opt-in local files and can contain profile identifiers and app paths. Review them before sharing; never attach credentials, raw task databases, or private screenshots to a public issue.
