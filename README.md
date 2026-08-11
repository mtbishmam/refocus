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
required plan to 12. Evening remains 18:00–21:30 with up to seven cycles.

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
`get_optimization_context` first and `get_daily_dashboard` during day analysis;
narrower day, agenda, and metric tools are available for follow-up detail.
Explicit Daily edits use the write-scoped `update_daily_values` tool, while
Delta, Stage, progress, and ETA remain derived. Read responses omit internal
IDs and empty fields. A clean Markdown projection remains available as the
zero-setup fallback.

## Safety boundary

The screen-break overlay stays native and leaves Command-Q, Force Quit, logout,
restart, and system security interfaces available. ReFocus contains no Electron,
Tauri, embedded web runtime, in-app terminal, or AI model API.
