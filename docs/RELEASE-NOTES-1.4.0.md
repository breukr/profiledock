# ProfileDock 1.4.0

ProfileDock now brings profiles, local chat search, usage and settings together in one native macOS window.

## A more consistent interface

- A searchable sidebar, centered page columns and aligned headers, cards and empty states.
- A profile editor with instant icon previews, custom letters, colors and rounded images that fill their tile. Changes appear throughout ProfileDock without enabling experimental Dock mode.
- A menu-bar dropdown with profile switching and direct access to profiles, search, updates and settings.
- Readable notices with working retry actions, plus visible progress while Dock copies are prepared.
- A Usage Insights drawer with a hover delay, spring animation, content fade and Reduce Motion support.
- Separate Support and About pages, with a pink heart for optional donations and sponsorships.

## Local conversations and context

- Search local Work/Codex conversations by all words, any word or exact phrase, with source, date and archive filters.
- Open a result around its matching passage, retaining the original profile, conversation and date.
- Optionally connect profiles through directional context permissions and native profile mentions. Sharing is off by default; incomplete or unavailable history is identified explicitly.

## Optional native Dock identities

- Give a profile its own ChatGPT name and icon in the macOS Dock using a locally prepared app copy.
- Keep working in the signed source app while the copy is prepared; use the new identity after quitting and reopening that profile.
- Coordinate source updates and Dock-copy rebuilds while retaining profile paths and recovery copies.
- Recognize already-running Dock copies after the launcher hands over to ChatGPT, avoiding a false “still starting” warning.
- Return to the original installed app after its OpenAI signature is verified. Profile data remains in place; an unavailable or invalid original leaves the Dock copy intact.

Native Dock mode is experimental and off by default. Its local copy replaces OpenAI's signature, removes vendor-only permissions and disables library validation. Sign-in, permission prompts and integrations may differ. [Read the tradeoffs](NATIVE-DOCK.md) before enabling it.

## Install or update

Use **Check ProfileDock for Updates…**, or download `ProfileDock.zip` from the [latest release](https://github.com/breukr/profiledock/releases/latest), unzip it and move ProfileDock.app to Applications. Quit only ProfileDock when replacing it manually; ChatGPT profiles can stay open.

Requires macOS 14 or newer, Apple Silicon and the current ChatGPT/Codex desktop app. ChatGPT Classic is not supported. Published downloads are Developer ID signed and notarized; `SHA256SUMS` accompanies the archive. ChatGPT itself is not included.
