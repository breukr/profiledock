# Product

<!-- impeccable:product-schema 1 -->

Written 2026-11-07 from Sam's brief and the repository. Facts marked *(inferred)* were not confirmed in an interview; Sam answered three decisions on 2026-11-07 (look, macOS floor, first build), recorded under Constraints.

## Platform

macOS native (SwiftUI + AppKit). Not web.

## Users

- **Primary:** people who run several AI agents and accounts at the same time on one Mac: Claude (Desktop and Claude Code), ChatGPT and Codex, Cursor, Grok, Hermes, Gemini, OpenCode and terminal agents. Typically a developer or AI-heavy freelancer with two to ten sessions in flight, several paid accounts per provider, and limited attention. Sam is the reference user.
- **Situation:** working in one app while agents run elsewhere. They need to know, without switching windows, which agent is waiting for them, which one finished, and how much of each account's usage limit is left.
- **Job:** keep many agents moving with as little context switching as possible: notice, answer, switch, and avoid hitting a limit by surprise.

## Product Purpose

ProfileDock is mission control for AI agents on a Mac. It finds the agents and accounts on the machine, shows their state and usage limits in the notch, tells the user when one needs them, and lets them answer or jump straight to it. Success: a user running five agents never misses a waiting agent, never has to sign in to the same account twice, and switches accounts in one click.

## Positioning

The only native app that combines **multiple accounts per provider** (separate signed-in profiles side by side, ProfileDock's original core), **every agent on the Mac** (desktop apps and CLIs), **usage limits per account**, and an **answerable attention queue** in the notch. Notch-only monitors do not manage accounts; usage bars do not know about sessions; orchestrators live in their own IDE-like window.

## Capabilities

- Profiles: separate signed-in copies of ChatGPT/Codex, Claude Desktop and other tools, switchable with a click or ⌥⌘1–9.
- Agent discovery: about 40 tools by PATH, install folders, Launch Services and config folders; running terminal sessions by process scan.
- Usage: 5-hour and weekly limits per account, saved resets, usage insights (tokens, cost estimates, sessions).
- Attention: activity dots, notch cues, and (2.0) an answerable pop-up for permission requests, questions and finished turns.
- Context: search earlier local conversations across profiles, with explicit per-profile sharing.

## Terminology

Profile (one signed-in account in one app or tool), tile (a profile in the strip), strip (the notch or floating panel), cue (short notch notice), attention item (something an agent needs from the user), usage window (a rate-limit period such as 5 hours or 7 days), saved resets.

## Constraints

- Look (Sam, 2026-11-07): **Dark Liquid Glass**. Black where it meets the notch, fading into dark tinted native macOS glass; pop-ups and the portal use the same glass. Native glass only, no custom blur.
- Platform floor (Sam, 2026-11-07): **macOS 14+**, real Liquid Glass on macOS 26+, frosted fallback before that.
- First build (Sam, 2026-11-07): notch pop-ups with reply, after fixing the sign-in banner and Claude reconnecting.
- Data stays on the Mac. ProfileDock never stores or forwards agent credentials, and never sends conversation text off the machine.
- Distribution outside the Mac App Store (the sandbox would block reading other apps' data, hooks and terminal control).
- Public repo today: no real accounts, client names or personal data in code, fixtures or screenshots.

## Accessibility

Reduce Motion and Reduce Transparency paths for every animation and glass surface; Increase Contrast adds strokes; VoiceOver labels on every control; 28 pt hit targets (20 pt strip exceptions documented in DESIGN.md).

## Open decisions

- Product name and logo for the paid version.
- Free versus Pro split, price, and when to make the source private (open list in `docs/VISION.md`).
- Whether to use the claude.ai web session as a usage source in a paid product, given Anthropic's third-party terms.
