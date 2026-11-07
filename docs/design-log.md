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

## Round 2 (2026-11-07): horizontal cards, notch pop-up as one shape
Decision: tiles became horizontal cards (badge left, name and status, usage table with shared columns, saved resets on one line), header got attention chips ("1 needs you · 1 working · 1 done"), cards fill their row and columns follow the larger section. The answerable pop-up grows out of the collapsed island (notch or menu-bar island) as one shape: island size to card with a spring, concave shoulders at the top edge, black band continuing the island, the strip's glass and shade; it folds back into the island when closed or while the strip is open. Agent cards without usage reserve one row and say the tool shares no limits; passed resets show full and dimmed.
Rejected: a separate card below the menu bar (Sam: "should look like one big smooth blob"); scale-in animation (distorted radii and text); centered grids with dead space; tiles capped at 340 pt on wide strips.
Why: Sam's feedback on the first glass build (cards too vertical, alignment, logos) and on the pop-up (must come out of the notch, no gap). Design reviewer round 1 FAIL: stale renders, missing shoulders, pop-up lighter than strip, radius and copy mismatches, two small hit targets; all fixed in this round.
Reviewer: round 1 FAIL (fixed); round 2 not run yet.
Sam: pending.

## Round 3 (2026-11-07): compact "done" pill, replies, more agents
Decision: finished and waiting turns show a compact pill from the island (name, "Done · project", Reply, Open) that auto-hides; permission requests and questions keep the full card. Reply works from the pop-up for every Claude Code and Codex session, including desktop chats (a short Stop-hook hold, extended while typing), else into the terminal tab, else copied and the exact chat opened. Gemini, Cursor, Copilot, Factory, Qwen and OpenCode can be connected from Settings → Coding Agents (display and Open; no answers yet).
Rejected: a message body on "done" (Sam: just a quick pop-up and Open); two cross-fading shapes for pill and card (one morphing NotchShape instead).
Why: Sam's request to separate "done" from "needs you", reply from the pop-up, and make it cohesive across agents.
Reviewer: not run this round.
Sam: pending.
