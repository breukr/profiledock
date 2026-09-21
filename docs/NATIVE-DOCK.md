# Experimental native Dock icons

ProfileDock can create a local ChatGPT app for each profile, with its own name and colored icon in the macOS Dock. This is off by default. Existing profiles keep their current launch behavior until you enable it.

1. Close the profile, then open ProfileDock Settings → Profiles → its options menu.
2. Choose **Profile settings…**, select **Native macOS Dock icon**, and read the explanation before enabling it.
3. Open the profile. To pin its app, use **Show Dock app** and drag that app to the Dock, or choose **Options → Keep in Dock** on its running icon.
4. Changes to a profile's name, color or picture are applied when you next open it from ProfileDock. Rebuilds keep the same app path so existing Dock pins remain valid. macOS may cache the old icon until the next launch.
5. To return to the usual launch mode, close the profile and turn off **Native macOS Dock icon** in Profile settings. This moves the generated app to the Trash and keeps its profile data. Remove its old Dock pin yourself if necessary.

Choose a colored dot on the installed app icon, initials or up to three custom letters, a custom image, or the ChatGPT logo on a colored background. Use the color picker or enter a six-digit hex code. Icon changes are independent of the shared/separate installation choice.

## Tradeoffs

The generated copy is signed locally, rather than by OpenAI. Its vendor-only entitlements are removed and library validation is disabled. Some integrations, permissions or sign-in flows may behave differently. It is an experimental option, and it is not equivalent to the original signed and notarized app.

The original app is only read. Account configuration and history stay in the existing profile directories; ProfileDock does not migrate or delete them when enabling or disabling this feature. A different app signature can still require a fresh sign-in or permission prompt.

Generated apps stay on the Mac that created them. They are not bundled in ProfileDock releases. APFS clones share unchanged resource storage, but updates and rebuilds can require additional disk space.

## Updates

The **Updates → ChatGPT / Codex** section updates the signed source app and rebuilds every enabled native Dock copy in that app group automatically. It prepares and verifies all copies before closing profiles, preserves their data paths and Dock identities, and restores the group if replacement verification fails. Hidden backups beside each app retain the previous versions for recovery.

If the original ChatGPT app updates outside ProfileDock, the next profile launch rebuilds the Dock copy automatically. This also works when opening a pinned Dock app: its helper asks ProfileDock to prepare the new copy before launching ChatGPT. A running profile keeps its current app until it restarts. No active task is interrupted just because a newer source app is available.

**Repair copy** is a recovery action if a copy is missing or damaged. A failed build retains the previous copy. If automatic repair fails, an error explains how to retry or disable the experimental option; the launcher never silently switches accounts. Keep ProfileDock installed at its usual path so pinned Dock apps can find its updater helper.

## Implementation and attribution

Adapted from [bartekczyz/ai-profiles](https://github.com/bartekczyz/ai-profiles), version 1.2.0, source commit `8569f6553c3a6d30c102eb8b274f93c3d95d7d72`; the original Dock feature is commit [`c9810e2`](https://github.com/bartekczyz/ai-profiles/commit/c9810e20b0b94bb12b3a5ac9852e3b435df22d0b). The MIT notice is included in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) and in packaged ProfileDock apps.

The Swift adaptation preserves Electron's helper lookup name, gives each copy a separate bundle identifier and icon, and puts a small native executable inside the copy. That executable launches the relocated vendor binary inside the same bundle with fixed profile paths and a clean environment. Only the relocated executable and outer bundle are re-signed; nested vendor frameworks retain their signatures. URL/document registrations and the vendor update feed are removed from the copy.

Verification uses temporary fixture apps and fictional profiles. Fixture identity and account-routing checks do not establish that every ChatGPT integration works under the new signature. Real account sign-in, permissions, and day-to-day behavior require separate user acceptance testing.
