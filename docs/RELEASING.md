# Releasing

1. Update the version and build number in `scripts/build-app.sh`.
2. Run `swift test`. Review the native UI at normal, narrow, and wide window sizes.
3. Build with your own Developer ID certificate:

   ```sh
   SIGNING_IDENTITY='Developer ID Application: YOUR CERTIFICATE' ./scripts/build-app.sh
   NOTARY_PROFILE='YOUR KEYCHAIN PROFILE' ./scripts/notarize.sh
   ```

4. Scan the source and release artifacts for secrets, private paths, and personal data. Publish from this clean repository only, never a personal development repository's history.
5. Create a tagged GitHub release with `ProfileDock.zip` and `SHA256SUMS`. Confirm notarization and both architectures before calling a download signed and notarized.

Do not commit certificates, signing identities, keychain profile names, local diagnostics, or developer machine paths. GitHub CI builds unsigned artifacts and runs tests; it does not receive signing credentials.

The internal executable, bundle identifier, and preferences folder retain their original Account Dock names so existing installations keep their profiles and login-item identity.
