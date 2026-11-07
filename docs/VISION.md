# ProfileDock 2.0: vision and goals

Set 2026-11-07. This is the north star for the next versions. Product truth lives in `PRODUCT.md`, the look in `DESIGN.md`, round-by-round design decisions in `docs/design-log.md`. Update this file when a goal is met or changes.

## North star

**Every agent, every account, one glance.** A person running five AI agents across several accounts never misses one that is waiting, never signs in to the same account twice, answers from the notch, and switches in one click.

## Who it is for

People who run several agents at once on one Mac: Claude Desktop and Claude Code, ChatGPT and Codex, Cursor, Grok, Hermes, Gemini, OpenCode, T3 Code and terminal agents, often with more than one paid account per provider.

## Pillars and goals

Each goal has a check that says when it is met.

### 1. Never miss what needs you
- **Answerable notch pop-up.** When an agent asks for permission, asks a question, waits, or finishes, a glass pop-up drops from the notch with the question or result, Allow/Deny, the options, and a reply field. *Met when:* a terminal Claude Code permission request can be allowed or denied from the pop-up, and a reply can be typed into a finished terminal session, without touching the terminal.
- **Attention summary.** The collapsed notch and the menu-bar icon show a count of agents that need you; the strip lists them first, oldest first. *Met when:* with three agents waiting, the collapsed notch says so without hovering.
- **Nothing lost.** A missed pop-up stays in a short history until handled.

### 2. Every agent, recognized automatically
- Detect installed and running agents (desktop apps and CLIs) without setup; today about 40 tools are recognized (`docs/AGENT-COVERAGE.md`).
- Real-time state through each tool's own hook system where it exists (Claude Code, Codex, Cursor, Gemini, OpenCode, Copilot, Factory), one shared event inbox, one session model. *Met when:* Claude Code and Codex report working, waiting, question and done with text; others follow per the coverage table.
- Answer paths per agent are explicit in `docs/AGENT-COVERAGE.md`: hook decisions where the tool supports them, typing into a terminal only for the exact identified session, never into an unknown window.

### 3. Usage you can trust
- **Connect once per account.** A connected account stays connected across reboots, app updates and quitting the agent. Last good readings are saved and shown with their age instead of disappearing. *Met when:* after a reboot with an expired Claude Code token, Claude tiles still show their windows with "Updated 3 h ago" and no sign-in banner.
- **No nagging.** A sign-in notice appears only after a definitive failure, at most once a day per account; "Later" is remembered.
- Limit alerts ("weekly 8% left, resets in 1 day") as attention items, not only a bar color.

### 4. Switch in one click
- Profiles for separate signed-in accounts side by side, keyboard shortcuts, launchers. Keep this core, it is the part no competitor has.

### 5. A portal for heavy days
- **Command Center window** (optional): every session grouped by Needs you, Working and Done, with usage, reply and jump-to. Built on the same attention queue and session model as the notch.
- Optional modules: Terminals, Usage insights and the Command Center can each be switched off.

### 6. Feels like Apple made it
- Dark Liquid Glass (native macOS 26 glass, frosted fallback on 14 and 15), black where it meets the notch. System fonts, SF Symbols, Reduce Motion and Reduce Transparency paths.
- Quiet by default: one pulse for working, no decorative loops, no marketing styling inside the app.
- Fast and light: no visible stutter, under 1% average CPU when idle.

## Quality bar for a paid app
- No data loss: an unreadable settings file is backed up and never overwritten.
- No silent breakage after updates: helpers and hooks refresh themselves on launch.
- Every visible change passes `./scripts/design-check.sh`, the design reviewer, and Sam's visual approval.
- Every bug fix ships with a test.

## Roadmap

| Version | Scope | Status |
| --- | --- | --- |
| 2.0 foundation | Claude stays connected, readings saved, no-nag rules; sign-in banner redesign; agent event inbox; answerable notch pop-up for Claude Code; data-safety and CPU fixes; dark glass strip | In progress (branch `claude/profiledock-next`) |
| 2.1 | Codex hooks and Codex app approvals in the pop-up; attention summary in the collapsed notch and menu bar; compact row mode for many agents | Planned |
| 2.2 | Command Center window; limit alerts; attention history | Planned |
| 2.3 | Cursor, OpenCode, Gemini, Copilot and Factory hooks; iTerm2 and tmux reply polish | Planned |
| Launch | Name and logo decision, licensing and payments, new update host, website | Planned |

## Business decisions (open)

These need Sam's decision before launch; the working notes are kept outside the public repo.

1. Name and logo for the paid version.
2. Free and Pro split. Principle: never take away a feature a current free user already has.
3. Payments and licensing provider, trial length.
4. Moving updates off GitHub raw URLs to a host we control before the source becomes private, so installed copies keep updating.
5. Whether a paid product may use the claude.ai web session as a usage source under Anthropic's third-party terms.
