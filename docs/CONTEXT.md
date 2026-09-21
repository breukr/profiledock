# Context across profiles

Context brings relevant earlier **local Work/Codex text conversations** into the
profile you are working in. It does not copy accounts or resume source tasks.

## Start using it

1. Open ProfileDock **Settings → Context tagging**.
2. Choose the profile you are **Working in**.
3. Enable the profiles it may read under **Allow context from**. Access is
   directional: allowing Studio to read Research does not allow Research to read Studio.
4. Use **Try a search** to preview local passages, or select **Connect** and
   start a new task in the receiving profile.
5. Type `@research`, select the source skill from the desktop chat's suggestions,
   and ask: “Check our earlier conversations about the workshop in @research.”
   Plain-text aliases and ordinary profile names also work.

Profile mentions are local skills, using the desktop chat's existing native `@`
picker and skill chips. They are not a new kind of account attachment. The source
skill pins the receiving and source profile IDs; the MCP helper still checks access
on every request. OpenAI documents [explicit skill mentions and display metadata](https://learn.chatgpt.com/docs/build-skills).
Codex CLI and the IDE use `$skill-name` instead of `@`; their skills picker shows
the underlying `<alias>-pd-…` name.
If a running client does not pick up new skills or the server in a new task,
restart that receiving profile when its active work is finished. No source profile
needs to be started. ProfileDock does not modify the host app or intercept typing.

Connection and sharing are separate: **Connect** installs the helper and skill;
source toggles control access. Changes to grants are checked on every request,
including before returning passages. Previously retrieved text already present
in a task cannot be removed by revoking later access. Disconnect revokes all
outgoing context-read grants for that receiving profile before removing its tools.

## What gets returned

The helper lists enabled profiles, searches topic keywords, and reads surrounding
messages or subsequent pages. Matches include stable profile, conversation and
message IDs, the conversation title, and the original message date. Search uses
case/diacritic-insensitive keyword ranking, not embeddings or a separate AI model.
Use distinctive words from the original conversation, or try a synonym.

Only allowed profiles are exposed to the receiving task. Historical messages are
data, not new instructions. Assistant completion claims still need independent
verification. Labels identify local profile folders, not verified account owners;
signing a different account into a profile does not reassign its old history.

Search is bounded: up to 500 recently updated eligible conversations per source,
4,000 candidate text records or 24 MiB per conversation, and an eight-second source
budget within a 24-second request budget. Search returns at most 30 excerpts with
at most three per conversation. Messages are capped at 12,000 characters; read
responses are paginated and capped at roughly 28,000 characters. Partial coverage
is explicit. Date filters apply to both the conversation catalog and message dates.
Archived conversations are included unless you turn them off.

Ordinary ChatGPT/cloud-only history, attachments and voice-only records are not
covered. Excluded subagent, automation, reasoning, and tool records are not sources.
Missing, changing, corrupt or unsupported history is reported as unavailable or
partial, never treated as proof that no conversations exist.

## Integration and maintenance

`ContextCore` owns profile discovery, grant checks, history readers, extraction,
ranking, pagination and the MCP surface. The native UI and `ProfileDockContext`
executable share that module. The executable uses local stdio; it opens no network
listener and makes no model/API calls. The three tools are `list_profiles`,
`search_sessions`, and `read_session`, all annotated read-only.

**Connect** uses the installed official Codex CLI to register only the managed
server name, with a fixed caller ID in its launch arguments. Tool arguments cannot
change the caller or provide file paths. The helper is copied to a stable private
application-support path, so moving ProfileDock does not break the connection.
Use **Connected → Refresh connection** after a context-helper update to install
the current bundled helper and skill. A conflicting custom server or unmarked
skill is left untouched. Source histories are never changed by Connect.

`ContextMentions` generates source skills only for enabled sources, in the receiving
profile's own skills folder. Native discovery reads each skill's name, description
and `agents/openai.yaml`. Refreshing the connection or checking a connected
profile synchronizes its mentions. Changing grants or profile names in Context
also synchronizes them. The searchable skill name contains the alias, because the
current desktop menu does not search nested `interface.displayName` metadata even
though it uses that metadata to render labels. Renaming replaces the skill path;
its source-specific suffix prevents another source from reusing an old path.
An already inserted chip for a renamed profile must be selected again.
Disabled and removed sources lose their generated files;
already inserted mentions remain subject to live source-ID and grant checks.
Duplicate display names include the source ID for disambiguation. Skill folders
have source-specific `<alias>-pd-…` names, preserving custom skills that happen to
share a profile's display name. A conflict at a generated path is reported.
SHA-256 receipts record generated files so refresh/removal preserves external edits
and extra files. If cleanup is blocked by such an edit, access revocation still
applies immediately. Skills cached by the host may remain visible until it refreshes.

The reusable skill is also packaged as `Resources/profiledock-context`, a local
skills-only plugin. Its manifest intentionally does not duplicate the per-profile
MCP registration. The native Connect button installs the same skill directly,
so a marketplace installation is optional, not a prerequisite.

The app-server alternative was reviewed against the official
[App Server documentation](https://learn.chatgpt.com/docs/app-server). It exposes
thread listing and reading, but its transport/runtime integration is experimental
and does not provide a documented read-only lifecycle for a second process over
every desktop profile. This version uses a narrow local storage adapter, validates
required columns and recognized history modes, and fails explicitly on unknown
formats. It must be rechecked when Codex changes local history storage. The
[MCP connection](https://learn.chatgpt.com/docs/extend/mcp) uses the supported
stdio configuration and official CLI commands.

This is a convenience within one macOS user, not an OS security boundary. An
application with unrestricted filesystem access under the same user can read or
change local files independently. See [Privacy](../PRIVACY.md).

## Development and verification

```sh
swift test
python3 scripts/context-smoke.py .build/debug/ProfileDockContext
PROFILEDOCK_CONTEXT_PREVIEW=1 ./scripts/build-app.sh
python3 scripts/context-smoke.py 'dist/ProfileDock Context Preview.app/Contents/MacOS/ProfileDockContext'
```

The preview bundle has a separate app identity, no update checks, no global
shortcuts or floating strips, and opens Context settings. It can run alongside
the normal ProfileDock app. It uses real profile preferences unless launched with
`--preview-home` pointing to a fictional test home. `context-smoke.py --keep-fixture`
creates such a home and prints its path. Never commit real account data or private
screenshots. The helper's optional `--home` flag exists for explicit fixture tests;
the installed connection does not expose it as a tool argument.
Use `--compact-preview` with the preview app to check the minimum 760 × 560 pt
window; the normal initial window is 840 × 620 pt. Native window zoom checks the
wide layout. The context form keeps a readable width on large displays.

For CLI use, call `ProfileDockContext profiles --profile ID`,
`ProfileDockContext search --profile ID --sources ID,ID --query 'topic'`, or
`ProfileDockContext read --profile ID --source ID --session ID`. Add `--cursor`
to read another page, or `--message` to focus on a search hit.
