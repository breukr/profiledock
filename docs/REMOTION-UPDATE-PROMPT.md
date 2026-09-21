# Prompt: update the ProfileDock launch videos

Copy the prompt below into the task working on the existing `launch-film/` project. It requests video edits and renders, not social publishing.

---

Update the **existing ProfileDock Remotion videos** to tell a clear story about the latest app. Continue the current project, visual language, fictional profiles, and English/Dutch compositions. Do not create a second product or start a new video project. Inspect the current working tree first and preserve unrelated edits in `launch-film/` and `linkedin-carousel/`.

First inspect the running/built ProfileDock version and the actual current UI. The target is **ProfileDock 1.4.0, build 145 or later**, including context tagging and optional native macOS Dock icons. Use the implemented behavior, screenshots, `docs/CONTEXT.md`, and `docs/NATIVE-DOCK.md` as the source of truth. If the available build differs, report that before recording or making feature claims. Do not describe a local build or open PR as a published release.

Read `launch-film/README.md`, the current composition registrations, and these existing sources before editing: `src/timing.json`, `src/opening.json`, `src/Film.tsx`, `src/mac/LaunchFilm.tsx`, `src/mac/camera.ts`, `AuthProblem.tsx`, `ProductReveal.tsx`, `CodexWindow.tsx`, `AccountSwitchScene.tsx`, `account-switching.ts`, `DeviceShot.tsx`, `Desktop.tsx`, `Notch.tsx`, `src/components/Product.tsx`, `InsightsChart.tsx`, `usage-fixture.json`, `usage-data.ts`, `KineticText.tsx`, `motion.ts`, and `scripts/make-score.py`. Resolve names against the actual project structure; do not duplicate a component that already exists.

## Creative direction

The story is **recognize the right account → bring in precisely the context you allow → keep working**. This is a product demonstration, not a tour of every setting. Keep the existing restrained macOS look, carefully timed pointer actions, legible native interface, subtle SFX, and no voice-over. Keep the camera still while a viewer must understand a click, permission, or result. Preserve the established notch/floating-strip identity: native Dock icons are an additional optional capability.

Open on a concrete payoff within the first three seconds: two or three running accounts with unmistakably different native Dock icons. A click switches to the matching persistent window. Follow with a brief recognizable account-switching frustration if it strengthens the cut; shorten the old five-second login sequence instead of adding another long opening.

Use fictional profiles consistently, such as **Studio**, **Research**, and **Personal**. No real account names, chat text, credentials, client logos, notifications, or private history. Make illustrative conversation content clearly fictional. Keep ordinary conversations distinct from Work/Codex task activity: completion and busy indicators must represent supported task activity.

## A suggested 55–60 second main cut

Treat these timings as an editorial starting point, then fit the actual interactions and readability:

| Time | What the viewer sees | Message |
| --- | --- | --- |
| 0–4 s | Recognizable colored native Dock icons; select Studio; its existing window comes forward | “Know which account you're opening.” |
| 4–8 s | Existing ProfileDock reveal and notch/strip | “Your accounts, one place.” |
| 8–16 s | Switch between two persistent windows; one concise profile creation beat showing **Use shared installation** | “Separate sign-ins and history. One installed app.” |
| 16–26 s | Settings → Profile icons → Customize icon; four icon styles briefly previewed; choose ChatGPT logo with a hex background, then show the matching running Dock icon | “Make each profile recognizable.” Keep **Experimental · optional** legible. |
| 26–40 s | Settings → Context access: select **Studio** as the profile that can tag; enable **Research**, leave **Personal** off; Connect if needed; in a new Studio task select the Research skill from `@` suggestions, ask for fictional earlier context, show a sourced result | “Bring in the context you choose.” |
| 40–46 s | Updates screen showing separate **ProfileDock** and **ChatGPT / Codex** sections; a short explanatory transition from updated source to rebuilt profile icons | “Updates keep your profile icons.” |
| 46–54 s | Reuse the strongest existing task-completion/usage beat, then the external-display/free-position strip demonstration | “Fits the way you work.” |
| 54–60 s | Existing clean end card, ProfileDock + Breukr, verified GitHub destination | One CTA: “Try ProfileDock for Mac.” |

Do not cram every legacy feature into the final eight seconds. If the full story cannot remain readable, preserve the best existing usage/reset/external-display shots in a separate overview cut, and keep the launch update focused on Dock identity and controlled context reuse.

## Exact behavior and claims

- **Shared installation** shares installed application files and update timing. Profiles still have separate sign-ins, conversations, and settings. **Separate installation** adds a separately updateable app copy and uses more disk space; it does not create an account or subscription. Never depict “shared app” as shared chats.
- Native Dock mode is **off by default**, enabled per profile, and can be disabled. Show its **Experimental** badge and a short readable explanation: “Creates a locally re-signed app copy. Some macOS protections and integrations differ.” Show the real warning in the longer demonstration. Do not claim that OpenAI signs, endorses, or supports modified copies, or that all sign-in flows are guaranteed to work.
- Icon choices are a colored dot, initials/custom letters, a custom image, and the ChatGPT logo on a selected background. Show a valid six-digit hex value, for example `#009B87`. Appearance edits are applied when the profile next opens from ProfileDock; show a close/reopen transition if needed. Do not animate an immediate running-app icon update that the app does not implement.
- Dock icons are actual running macOS Dock identities, not just launcher shortcuts. Preserve the same profile's window and history across switches; do not invent new windows on every click.
- **Context tagging is directional and off by default.** Studio → Research does not grant Research → Studio, and Personal remains unavailable. Show that direction plainly in one shot. There is no “share everything” step.
- Tagging searches supported local **Work/Codex conversation history**. It does not import all ChatGPT web/mobile chats, merge accounts, or transfer subscriptions. Selecting a profile mention invokes a managed skill. Show the actual skill suggestion label from the build instead of inventing an account-selector UI.
- Local search and its preview happen on the Mac. If retrieved excerpts are used in a task, those excerpts enter that task's active account/model context. Do not use the blanket claim “nothing ever leaves your Mac.”
- Use a grounded fictional example: Research contains a workshop note saying “15-minute demonstration, then hands-on exercises.” Studio asks `Use @research to find the workshop format we discussed.` The result names Research, the fictional conversation, and its date, with a small excerpt. Keep matching source text visible; do not fabricate a successful live retrieval if the fixture/connection is unavailable.
- **ProfileDock updates** update this companion; **ChatGPT / Codex updates** update OpenAI's desktop app. Profiles sharing a source update together. ProfileDock prepares rebuilt Dock copies with an app-group update. An update performed outside ProfileDock is picked up when the profile next launches. Active tasks are not forcibly interrupted for background rebuilding. Use an explicitly illustrative diagram or edited transition if no real update is available; do not stage a fake successful update screen.
- ProfileDock itself has a clearly named **Settings** sidebar tab with separate Dock and menu-bar visibility switches and startup controls. The same Settings screen contains **Profile icons**, **Context access**, **Appearance**, and **General**. The sidebar’s **Search chats** screen is for retrieval. When its Dock preference is off, a temporary Dock icon appears while Settings is open to support the native top-left app menu; it hides again when Settings closes. Show the **ProfileDock** menu with distinct ProfileDock and ChatGPT/Codex update commands in a longer settings cut if useful. Do not confuse this companion visibility setting with each profile's experimental Dock icon.
- Retain truthful existing usage/reset behavior. Do not invent savings, speed multipliers, user counts, vendor approvals, or security guarantees.

Include the improved **Search chats** screen in the longer demonstration or a short alternate cut: select a profile, enter a grounded fixture query, show All words / Any word / Exact phrase, highlighted matches, one card per conversation, and reading around a result. Own-profile search needs no cross-profile grant; additional profiles still require permission. Keep the main cut focused instead of adding a rushed settings checklist.

## Platform edits

Make deliberate edits from the same project, not one video with three labels. These are creative targets; verify current upload requirements before final export rather than treating these dimensions/durations as platform limits.

1. **Reddit — proof first, about 35–45 seconds.** Show a real account switch, the native Dock identity, the permission direction, and a useful context result. Use plain language and a modest GitHub end card. Include the experimental caveat visibly. Avoid advertising-style superlatives. Provide a factual draft post explaining what changed, the re-signing tradeoff, and asking for specific feedback. Do not publish it.
2. **LinkedIn — practical workflow, about 40–50 seconds, 4:5.** Open with a work/personal-context problem and show Studio using only approved Research context. Keep text comfortably readable in the feed, strong silent comprehension, and one CTA. Produce EN and natural NL variants using the project's existing language system, with identical feature claims.
3. **X — immediate visual payoff, about 20–25 seconds, 4:5 using the existing preset.** Begin with the distinct Dock icons, one profile switch, one permission/mention/result sequence, and the end card. Include “Optional experimental Dock icons.” Let the longer cut carry detailed updates/settings explanations. Provide a short factual draft caption; do not publish it.

Also retain an EN 16:9 main cut for the repository/desktop demonstration. Keep essential text inside safe composition margins and adapt crops intentionally. Do not shrink an entire desktop until its controls are unreadable. Reuse the current export/codec presets unless a verified platform requirement calls for a change.

## Implementation and acceptance

All motion must remain deterministic and frame-driven. Reuse existing timing/camera abstractions; no CSS timers, random values, or new animation frameworks. Keep edits maintainable through shared scenes and composition data. Respect reduced-motion legibility: cuts and pointer actions should explain the behavior without requiring elaborate camera movement.

Run the project's existing checks (`npm run lint`, `node scripts/check-timing.mjs`, `node scripts/check-camera.mjs`, `node scripts/check-usage.mjs`, and `npm run review`, as applicable to the current scripts). Update timing assertions only to reflect deliberate editorial changes. Inspect representative frames at every scene boundary plus full silent playback and SFX playback. Check clipping, pointer targets, labels, continuity, contrast, text hold times, and fictional-data hygiene at full-size and feed-size desktop previews. Render a low-cost review pass before final exports.

Deliver the updated sources, final files with language/platform/aspect labels, a contact sheet, final timings, the draft post/caption copy, and a concise claims checklist tied to observed app behavior. State which footage is captured, reconstructed from the actual UI, or an illustrative transition. Report test and render results accurately. Leave publishing to me.
