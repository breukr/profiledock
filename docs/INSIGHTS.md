# Usage insights

Open **Usage insights** beneath your profiles, or use its larger page in Settings.

- Choose one account or **All accounts**.
- Switch between **Today**, **7 days**, and **30 days**.
- Plot **Cost**, **Tokens**, or **Sessions**. Select the chart to inspect a period.
- In **All accounts**, each bar stacks the contributions of your accounts. Colors match the legend and stay the same in single-account views. Select a bar to see each account's token total and percentage for that period. Choose **Tokens** to compare token proportions; **Cost** compares estimated cost instead.
- The legend wraps into rows. Its account cards show totals for the period, or the selected bar, without horizontal scrolling.
- Choose **On click**, **On hover**, or **Always expanded** in the drawer menu. These apply inside the expanded profile strip; hover mode closes when you leave the strip.

## What the numbers mean

**Tokens** include input and output. Cached input and cache writes are parts of input, not extra tokens. Reasoning is already included in output.

**API-equivalent cost** estimates what the recorded text tokens would cost at published Standard API rates in USD, checked on **12 September 2026**. Cached input, cache writes, and the greater-than-272K input threshold use their applicable rates for supported models. Old usage is valued at this dated price table, not historical prices. Fast mode, tools, regional uplifts, taxes, and subscriptions are excluded. Unknown models or incomplete request detail are left unpriced, never substituted with a cheaper model or counted as free. A plus sign marks a partial estimate.

**Sessions** are distinct local threads with recorded usage in the selected period. Identifiable subagents are grouped into their parent. **Average per session** divides the period's estimated cost by those sessions; it is unavailable when the estimate is incomplete. Daily session counts may sum to more than the period total because one thread can be active on several days.

Periods use the Mac's local calendar and time zone. Seven and thirty days include today. Today's chart is hourly; longer periods use daily bars.

## Coverage and privacy

The scanner reads local profile session files only when insights are opened. A private local cache preloads the last loaded statistics at app launch while new records are read in the background, including after restarting ProfileDock. The page labels saved data while it updates. Per-file checkpoints let unchanged history be skipped; appended records resume after the last complete line. Replaced, truncated, or changed files are checked again. Corrupt caches and caches using older pricing are rebuilt automatically. Large histories take longer on the first scan if no usable cache exists. It does not send history to a server, create a transcript copy, or require an API key.

Account names refer to local profiles. Other devices, cloud-only chats, missing/deleted logs, and unrecognized record formats are outside coverage. Switching a profile's signed-in account does not retroactively identify its old sessions. Repeated records and copied sessions are deduplicated in the combined view; inherited totals are not charged again. Incomplete or oversized records produce a coverage note rather than invented totals.

These estimates are not a bill, a measure of subscription savings, or an account-wide spending report.

Pricing source: [OpenAI API pricing](https://developers.openai.com/api/docs/pricing). Scanner reference: [CodexBar](https://github.com/steipete/CodexBar). Attribution is in [Third-party notices](../THIRD_PARTY_NOTICES.md).
