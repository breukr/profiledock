# Experimental native Dock icons

ProfileDock can create a local ChatGPT app for each profile, with its own name and colored icon in the macOS Dock. This is off by default. Existing profiles keep their current launch behavior until you enable it.

1. Open **Profile Icons → Customize…**.
2. Select **Native macOS Dock icon**, and read the explanation before enabling it.
3. Follow the progress indicator beside the switch and in the editor footer as ProfileDock checks, copies, signs and installs the app. If the signed source profile is already open, it keeps running while the copy is prepared. Quit and reopen it when you are ready to use the new icon; there is no forced restart. To pin its app, use **Show Dock app** and drag that app to the Dock, or choose **Options → Keep in Dock** on its running icon.
4. Changes to a profile's name, color or picture are applied when you next open it from ProfileDock. Rebuilds keep the same app path so existing Dock pins remain valid. macOS may cache the old icon until the next launch.
5. To return to the usual launch mode, quit this profile’s Dock app and turn off **Native macOS Dock icon** in the profile editor. ProfileDock verifies the original installed app’s OpenAI signature, then moves only the generated copy to the Trash. It keeps the same profile data paths and uses the current original on the next launch. If the original is missing or fails verification, the copy is kept. Disabling does not download a newer original; use **Updates** for that. Remove its old Dock pin yourself if necessary.

Choose a colored dot on the installed app icon, initials or up to three custom letters, a custom image, or the ChatGPT logo on a colored background. Use the color picker or enter a six-digit hex code. These choices update the notch, profile list and menu immediately, including when experimental mode is off. They are also independent of the shared/separate installation choice.

Custom images fill the rounded icon surface without an inset colored border. Wide and tall images are cropped from the center, preserving their proportions. The preview and exported Dock icon use the same artwork. Existing copies using an older artwork format refresh when next opened through ProfileDock, once their running app has been closed.

## Tradeoffs

The generated copy is signed locally, rather than by OpenAI. Its vendor-only entitlements are removed and library validation is disabled. Some integrations, permissions or sign-in flows may behave differently. It is an experimental option, and it is not equivalent to the original signed and notarized app.

The original app is only read. Account configuration and history stay in the existing profile directories; ProfileDock does not migrate or delete them when enabling or disabling this feature. A different app signature can still require a fresh sign-in or permission prompt.

Generated apps stay on the Mac that created them. They are not bundled in ProfileDock releases. APFS clones share unchanged resource storage, but updates and rebuilds can require additional disk space.

## Updates

The **Updates → ChatGPT / Codex** section updates the signed source app and rebuilds every enabled native Dock copy in that app group automatically. It prepares and verifies all copies before closing profiles, preserves their data paths and Dock identities, and restores the group if replacement verification fails. Hidden backups beside each app retain the previous versions for recovery.

If the original ChatGPT app updates outside ProfileDock, the next profile launch rebuilds the Dock copy automatically. This also works when opening a pinned Dock app: its helper asks ProfileDock to prepare the new copy before launching ChatGPT. A running profile keeps its current app until it restarts. No active task is interrupted just because a newer source app is available.

**Repair copy** is a recovery action if a copy is missing or damaged. A failed build retains the previous copy. If automatic repair fails, an error explains how to retry or disable the experimental option; the launcher never silently switches accounts. Keep ProfileDock installed at its usual path so pinned Dock apps can find its updater helper.

ProfileDock recognizes copies opened directly from the Dock, including when macOS temporarily reports an invalid process ID after the launcher hands over to ChatGPT. It verifies the exact executable, owned app bundle and profile data argument before matching the process. **Show** targets that existing instance. A waiting update launcher is excluded only from its own preparation check; running ChatGPT copies remain protected from replacement and removal.

## Implementation and attribution

Adapted from [bartekczyz/ai-profiles](https://github.com/bartekczyz/ai-profiles), version 1.2.0, source commit `8569f6553c3a6d30c102eb8b274f93c3d95d7d72`; the original Dock feature is commit [`c9810e2`](https://github.com/bartekczyz/ai-profiles/commit/c9810e20b0b94bb12b3a5ac9852e3b435df22d0b). The MIT notice is included in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and in packaged ProfileDock apps.

The Swift adaptation preserves Electron's helper lookup name, gives each copy a separate bundle identifier and icon, and puts a small native executable inside the copy. That executable launches the relocated vendor binary inside the same bundle with fixed profile paths and a clean environment. Only the relocated executable and outer bundle are re-signed; nested vendor frameworks retain their signatures. URL/document registrations and the vendor update feed are removed from the copy.

Verification uses temporary fixture apps and fictional profiles. Fixture identity and account-routing checks do not establish that every ChatGPT integration works under the new signature. Real account sign-in, permissions, and day-to-day behavior require separate user acceptance testing.
