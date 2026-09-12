# Releasing

1. Update the version and build number in `scripts/build-app.sh`.
2. Run `swift test`. Review the native UI at normal, narrow, and wide window sizes.
3. Build with your own Developer ID certificate:

   ```sh
   SIGNING_IDENTITY='Developer ID Application: YOUR CERTIFICATE' ./scripts/build-app.sh
   NOTARY_PROFILE='YOUR KEYCHAIN PROFILE' ./scripts/notarize.sh
   ```

4. Scan the source and release artifacts for secrets, private paths, and personal data. Publish from this clean repository only, never a personal development repository's history.
5. Generate the signed Sparkle feed with `SPARKLE_KEY_ACCOUNT='YOUR KEY ACCOUNT' ./scripts/generate-feed.sh`. The private key stays in the macOS Keychain. Generate one initially using Sparkle's `bin/generate_keys --account YOUR_KEY_ACCOUNT` and place only its public key in `scripts/build-app.sh`.
6. Create a tagged GitHub release with `ProfileDock.zip` and `SHA256SUMS`. Confirm notarization, nested framework signatures, and Apple Silicon architecture before publishing. Then copy the exact signed `dist/appcast.xml` into `docs/appcast.xml`, commit and push it. Do not edit the signed XML by hand. Verify the public feed and archive signature after publishing.
7. Test a ProfileDock upgrade through Sparkle, and a fresh installation with empty profiles. Confirm ChatGPT processes and existing profile preferences remain intact. Check cue previews on a MacBook display and an external display. Do not claim physical-device coverage beyond the Macs actually tested.

Signing may ask for access to the publisher's Sparkle private key in macOS Keychain. This is a release-tool prompt, not a requirement for people installing ProfileDock. For verification, use `swift scripts/verify-update.swift dist/appcast.xml dist/ProfileDock.zip PUBLIC_KEY`, with the `SUPublicEDKey` value from the app's Info.plist. This checks both signatures without accessing the Keychain. Sparkle's `sign_update --verify` also reads the private-key item and may cause an unnecessary extra prompt.

Do not commit certificates, signing identities, keychain profile names, local diagnostics, or developer machine paths. GitHub CI builds unsigned artifacts and runs tests; it does not receive signing credentials.

The internal executable, bundle identifier, and preferences folder retain their original Account Dock names so existing installations keep their profiles and login-item identity.
