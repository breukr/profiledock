# Design log

One entry per design round, newest at the bottom. Read the last 3 before starting visible work; re-read after a resume or compaction. Keep entries short.

Format:

```
## Round N (YYYY-MM-DD): <task>
Decision:
Rejected:
Why:
Reviewer:
Sam:
```

`Reviewer:` is the `design-reviewer` verdict and round count. `Sam:` records only approval or feedback Sam actually gave; write "pending" until then.

## Round 0 (2026-10-16): design contract set up
Decision: added `DESIGN.md` (surfaces, tokens, motion table, done bar), `design/references/` (README plus candidate renders), `scripts/design-check.sh` (renders about 120 fixture screens into gitignored `qa/design-check/`), `scripts/design-lint.sh` (raw-color ratchet), `.claude/agents/design-reviewer.md`, this log, and a Design work section in `CLAUDE.md`.
Rejected: a pixel-diff baseline for Swift renders (fonts and system colors vary by macOS version, so diffs would be noisy); a new motion-lab (native app, timings are in `DESIGN.md` and tests).
Why: a fresh session needs one place for the rules, one command to see the screens, and an independent reviewer before Sam looks. Existing render tests already cover the key screens, so the script wraps them instead of adding a second route.
Reviewer: n/a (setup only).
Sam: pending.

## Round 1 (2026-11-07): Dark Liquid Glass, sign-in notice, agent logos
Decision: Sam chose Dark Liquid Glass (black notch band fading into dark tinted native glass), macOS 14+ with a frosted fallback, and the answerable notch pop-up as the first feature. The sign-in notice became one aligned row per account (badge column, name and reason, fixed Reconnect and ⋯ column; "Later" moved into the ⋯ menu and a header xmark). Agent profiles show their tool's real app logo. The glass fades in after the strip settles because window-server glass ignores the animated mask.
Rejected: keeping the pure black strip (Sam asked for glass); masking the glass during the spring (not possible with `NSGlassEffectView`); a separate "Later" text button (misaligned, 13 pt default font, read as a label).
Why: Sam's screenshot of the live notice ("alignment and look feel weird") and his brief (Apple-native, futuristic, glassy). Live check of the glass via a preview copy with fictional profiles; Sam supplied full-screen screenshots of it.
Reviewer: pending (after the horizontal card layout lands).
Sam: feedback 2026-11-07 on the first glass build: cards too vertical, alignment can be better, show real app logos. Approval pending.
