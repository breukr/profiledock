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
