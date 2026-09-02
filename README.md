# ReFocus

ReFocus is a speed-first daily execution system. The macOS app remains native
SwiftUI/AppKit so the wall-clock timer and blocking overlays stay immediate.
SQLite is the local source of truth, Cloudflare D1 synchronizes devices, and a
small offline-first PWA provides the same agenda and daily inputs on iPhone,
Ubuntu, and any modern browser.

## What changed

The old runtime treated `tasks.md`, `agenda.md`, and daily Markdown logs as a
distributed database. A single edit could rewrite several iCloud files, trigger
broad vault watchers, reparse the same content repeatedly, and let a stale reload
overwrite a reschedule. That was the source of both latency and the intermittent
Agenda bugs.

The new data path is:

```text
SwiftUI / PWA → local transaction → sync outbox → Cloudflare D1
                         └────────→ background clean Markdown projection
```

- Task edits and reschedules commit once in SQLite WAL on macOS or IndexedDB in
  the PWA.
- Sync is field-level latest-wins with hybrid clocks, idempotent mutation IDs,
  tombstones, and an offline outbox.
- D1 is durable cross-device truth. A 90-second server lease ensures only one Mac
  writes iCloud projections.
- `tasks.md` is output-only and deliberately contains no UUIDs, HTML comments,
  or machine metadata.
- Clean machine logs are written to `log/YYYY-MM-DD.md`; human writing and approved day analysis live in `journal/mon-D.md`.
- The old Markdown files are imported once, preserved, and recorded in
  `legacy-import-report.json` beside the local database.

The full design is in [docs/architecture.md](docs/architecture.md), migration
details are in [docs/migration.md](docs/migration.md), and AI access is described
in [docs/mcp.md](docs/mcp.md).

## Planning capacity

Morning (06:00–12:00) and Afternoon (12:00–18:00) each contain 12 physical
half-hour cycles. A scheduled one-hour Rest task occupies two of those slots,
so the normal gate requires 10 work cycles. Rest remains editable for each
date: deleting it releases its slots and immediately raises that block's
required plan to 12. The protected Rest windows are 05:00–06:00, 11:00–12:00,
17:00–18:00, and 23:00–00:00 in Asia/Dhaka; the early and last windows are
outside the planning quota.
Evening is saved first for 18:00–21:30 (up to seven
cycles). At 21:30 the no-plan blocker deliberately returns for a separate
21:30–23:00 Late Night save (up to three cycles). The planning quota ends at
23:00, while work and task scheduling remain available through midnight.

## Native AI assistant

ReFocus includes an opt-in AI tab and a screen-break AI panel powered by the
OpenAI Responses API. The API key is supplied by the user and stored only in
macOS Keychain. Streaming answers include supported reasoning summaries and
tool progress; hidden chain-of-thought is never displayed. Tool calls read and
write through the same SQLite-backed task and Daily-field paths as the native
UI and can search a bounded set of planning context in the configured Obsidian
vault.

During a screen break, each expanded work item is a compact execution editor:
task name, MVP, Description, and three subtasks only. The current task is always
expanded. Description is the one record of what happened and how execution
could improve or become faster; Diff, focus logs, and day analysis all use it.
Periodic breaks may be skipped three times per Dhaka day, and the overlay
follows macOS full-screen Space changes.

The ReFocus menu-bar icon is a retained AppKit status item with an active-Space
floating panel, so its quick menu opens from any macOS Space even when the
dashboard window lives in another one. Launch at login is controlled explicitly
from Settings rather than enabled implicitly at startup.

The assistant receives a fresh Dhaka date, time, cycle, and current task on
every turn. It understands `cur -> did ...` as an append to the current task
Description and sequential `next -> N cyc/cycle -> ...` planning. New AI tasks
always receive one terse custom MVP and exactly three terse custom subtasks.
The static policy portion is regenerated at `agents/context/refocus-ai.md`
when its curated vault sources change; current tasks and Daily values remain
fresh SQLite context, with recent history injected only when relevant. Native
AI writes are planner-validated and reported successful only after durable
read-back verification. The assistant preserves the four protected Rest
windows by default, interprets "break" as Rest, moves current/future overlapping work after
Rest, matches close task names before creating duplicates, and allocates
untimed tasks after the last explicitly timed task in a partial plan. An
explicit current-prompt override/overrule/bypass instruction may place work in
Rest while keeping the Rest row visible; the override is reported and never
inferred. Submitting a prompt from any non-AI dashboard tab opens
a smooth 50/50 AI-left/work-right split without hiding the selected tab;
the split can be closed independently and its conversation remains in the AI
tab. Response text supports mouse selection across the entire multi-paragraph
message.

## Build and verify

```sh
swift build
swift run RefocusCoreChecks
scripts/package-app.sh
open .build/release/ReFocus.app
```

The web client lives in `web/` and uses the bundled Sites/vinext toolchain:

```sh
cd web
pnpm install --frozen-lockfile
pnpm exec tsc --noEmit
pnpm run build
node --test tests/rendered-html.test.mjs
```

Its canonical production host is `https://refocus.mtbishmam.chatgpt.site`.
The mtbishmam-owned D1 was seeded from the local SQLite source of truth and
verified against the previous Bari cloud on 2026-08-08. Runtime no longer
depends on the previous deployment.

Deployment identity is intentionally account-stable: `mtbishmam@gmail.com` is
the official owner, while `bari86838683@gmail.com` is a secondary access/Codex
account. Changing Codex sessions or IDs must not change the Sites project,
hostname, D1 owner, or native pairing target. See
[docs/deployment.md](docs/deployment.md).

## Daily context and AI

Daily fields are extensible instead of hard-coded streak columns. The Daily
dashboard preserves the rapid date-by-habit entry workflow and adds compact
weight and habit analytics above it. Non-Negotiables contain the four current
rules from `ego/non-negotiables.md`; the visible Good Habits are only `Wake up @5:5` and
`Solve 5 harder problems`. Historical values for retired/hidden fields remain
stored.

Checked is always a Win, an explicit failure is a Loss, and blank is neutral.
Calendar-month Delta and lifetime Delta are derived from the daily records;
Stage is derived only from lifetime Delta and can move up or down. Weight ETA
uses a recent measured downward trend, is always shown in days, and remains
`Not enough data` when the history or trend is not meaningful. Weight (kg),
Calories (kcal), and Solved problems remain structured immediate-save metrics.
Daily summary is not an app field: the user or AI writes it in the Summary
section of `journal/mon-D.md`.

The MCP endpoint is `/api/mcp`. AI clients should call
`get_optimization_context` first and `get_daily_dashboard` during day analysis.
The Daily response includes every editable field, weight, calories, solved
problems, every habit's current/maximum streak, wins/losses, Deltas, Stage,
weight progress, prompts for the analysis conversation, and immutable
Initial-vs-20:00-Final plan evidence. `get_plan_diff` returns only that plan
evidence when a smaller response is preferable. Explicit Daily
edits use the write-scoped `update_daily_values` tool; it covers every field
advertised by `writeAccess.editableFields`, while streaks, Deltas, Stage,
progress, and ETA remain derived.

Explicit task removal uses the write-scoped `delete_task` or `delete_tasks`
tools. Before deleting, the AI rereads `get_day` or `get_agenda` with
`include_task_ids=true`; normal reads omit IDs. Deletions create synchronized
tombstones, including when the user explicitly removes a predefined or fixed
evening block for that date.

## Safety boundary

The screen-break overlay stays native and leaves Command-Q, Force Quit, logout,
restart, and system security interfaces available. ReFocus contains no Electron,
Tauri, embedded web runtime, or in-app terminal. The optional native assistant
is the only direct model integration and requires the user's Keychain-backed
OpenAI API key.
