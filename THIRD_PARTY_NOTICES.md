# Sparkle

ProfileDock uses [Sparkle 2.9.6](https://github.com/sparkle-project/Sparkle) for signed application updates. Its complete license and bundled dependency notices are included as `Sparkle-LICENSE.txt` in the app's Resources folder and in the resolved Sparkle package.

# ProfileDock chimes

The original chimes and generator are dedicated under [CC0 1.0](Resources/Sounds/LICENSE.md). They contain no third-party recordings.

# CodexBar

The usage integration follows CodexBar's account-scoped OAuth request approach and service schema.

The local Usage insights scanner also follows the documented `event_msg/token_count` and `turn_context` conventions examined in CodexBar's `CostUsageScanner.swift` and `CodexSubagentRolloutShape.swift` at revision `0f5735e1aedabc6dd3249c544d0a72fdd555845b`. ProfileDock implements its own bounded reader, aggregation, Standard-rate estimates, and native charts; it does not bundle the CodexBar app or its full scanner.

- Project: https://github.com/steipete/CodexBar
- Inspected revision: `4cfb60692bdd8cfbba7a491e94bb121b59a835a5`
- References: `docs/codex.md`, `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift`, `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthCredentials.swift`, and `Sources/CodexBarCore/CreditsModels.swift`.

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


# codex-profiles

The direct launcher uses the profile environment and user-data conventions documented by [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles).

MIT License

Copyright (c) 2026 Chai Pin Zheng

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
