# Contributing

Small, focused contributions are welcome. Open an issue for a larger change first.

1. Fork and create a branch.
2. Run `swift test` and build with `./scripts/build-app.sh`.
3. Explain what changed and how you checked it. For UI changes, include a screenshot with fictional or empty profiles.

Use native SwiftUI/AppKit controls and keep profile data local. Never include real account files, tokens, client names, personal icons, or private task content in a commit or issue. Tests must use temporary profile homes and must not stop or update the developer's real apps.
