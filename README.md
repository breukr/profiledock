<p align="center"><img src="docs/hero.svg" alt="ProfileDock — your ChatGPT profiles, one place" width="860"></p>

<p align="center">
  <a href="https://github.com/breukr/profiledock/releases/latest">Download for Mac</a> ·
  <a href="#install-with-an-agent">Install with an agent</a> ·
  <a href="#how-it-works">Quick guide</a> ·
  <a href="https://github.com/breukr/profiledock/issues">Feedback</a>
</p>

ProfileDock puts your ChatGPT and Codex profiles at the top of every screen. Hover to switch accounts, check usage, see unread Work results, and find out when saved resets expire.

**Free. Open source. Mac-native. Made by [Breukr](https://github.com/breukr).**

- **One home for your accounts.** Create profiles and Finder launchers; switch with a click or ⌥⌘1–9.
- **Updates on your terms.** Select all app groups or just the ones you can restart. Separate copies update independently.
- **At a glance.** Blue means working, orange means waiting for you, red means unread results.
- **Fits your Mac.** Matches the notch on a MacBook and the menu-bar height on external displays. Extra profiles scroll.
- **Saved resets, explained.** Expand the resets row for an oldest-first expiry countdown.

Requires **macOS 14+**, Apple Silicon or Intel, and the **current [ChatGPT desktop app](https://chatgpt.com/download/)**. ChatGPT Classic is not supported. ProfileDock does not include or redistribute ChatGPT.

## Install

Download **ProfileDock.zip** from [Releases](https://github.com/breukr/profiledock/releases/latest), unzip it, and move **ProfileDock.app** to Applications. Open it, click **Add profile**, and sign in when you open your new profile.

### Install with an agent

Paste this into a local coding agent with terminal access:

> Install ProfileDock from https://github.com/breukr/profiledock. Read its README and installation script first. Use the latest official release, verify its SHA-256 checksum and macOS signature, and install it in Applications. If no signed release is available, build it locally from source. Keep my existing ChatGPT profiles, chats, and credentials intact. Open ProfileDock when ready; I will sign in myself.

### Install through Terminal

Download the installer, inspect it, then run it:

```sh
curl -fL https://raw.githubusercontent.com/breukr/profiledock/main/scripts/download-install.sh -o /tmp/profiledock-install.sh
less /tmp/profiledock-install.sh
bash /tmp/profiledock-install.sh
```

To build locally instead, install Xcode Command Line Tools (`xcode-select --install`) and Swift 6+, then:

```sh
git clone https://github.com/breukr/profiledock.git
cd profiledock
./scripts/build-app.sh
./scripts/install-app.sh
open /Applications/ProfileDock.app
```

The build creates a universal app for Apple Silicon and Intel. Local builds use a local signature; published downloads are identified separately in their release notes.

## How it works

1. **Add a profile**, then open it and sign in to ChatGPT.
2. **Hover at the top center** of any screen. Click a profile or press ⌥⌘1–9.
3. **Expand Resets** for expiry countdowns. Blue means working, orange means waiting for you, red means unread results.
4. **Choose updates** in Settings. Shared profiles update together; separate app copies can update independently.

A profile's options menu lets you change its picture, create a Finder launcher or app copy, and remove it. Data stays on your Mac by default. **Appearance** includes startup at login and display sizing.

[Full guide](docs/GUIDE.md) · [Privacy & security](PRIVACY.md)

Activity covers local Work/Codex tasks. Profiles are not a security boundary, and OpenAI's desktop interfaces may change. ProfileDock never redeems reset credits. It is independent of OpenAI.

## Support

If ProfileDock helps, **[give it a star](https://github.com/breukr/profiledock)**, share it, or [contribute](CONTRIBUTING.md). Everything stays free.

## Development

```sh
swift test
./scripts/build-app.sh
```

Swift, SwiftUI, and AppKit. No third-party runtime dependencies. See [release notes](docs/RELEASING.md) for signing and notarization. [MIT licensed](LICENSE); third-party acknowledgments are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
