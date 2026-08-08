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

Daily fields are extensible instead of hard-coded streak columns. The initial
set includes all migrated non-negotiables plus Weight (kg), Calories (kcal),
Solved problems, and Daily summary. New number, text, and tri-state fields fit
the same storage and trend model.

The read-only MCP endpoint is `/api/mcp`. AI clients should call
`get_optimization_context` first; narrower day, agenda, and metric tools are for
follow-up detail. Responses omit internal IDs and empty fields. A clean Markdown
projection remains available as the zero-setup fallback.

## Safety boundary

The screen-break overlay stays native and leaves Command-Q, Force Quit, logout,
restart, and system security interfaces available. ReFocus contains no Electron,
Tauri, embedded web runtime, in-app terminal, or AI model API.
