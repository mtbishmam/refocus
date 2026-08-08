# ReFocus architecture

## Priorities

1. A local interaction must never wait for iCloud or the network.
2. Rescheduling is one transactional command, not two file rewrites.
3. Every editing client works offline and converges when connectivity returns.
4. Human and AI exports contain useful context, not storage machinery.

Target budgets are under 50 ms p95 for a visible local change, under 10 ms p95
for a SQLite write transaction, under 200 ms for warm local-store startup, and
under two seconds for online convergence under ordinary network conditions.

## Components

| Component | Responsibility |
|---|---|
| Native macOS app | Planning gates, timer, blockers, fast editing, SQLite WAL |
| Universal PWA | iPhone/Ubuntu/browser editing, IndexedDB cache and outbox |
| Cloudflare D1 | Durable cross-device entities, field clocks, mutations, leases |
| Markdown projector | One-way `tasks.md` and clean daily logs for Obsidian |
| Read-only MCP | Compact optimization, agenda, day, and metric context |

SQLite tables hold tasks, day plans and immutable/modified snapshots, check-ins,
daily-field definitions and values, analyses, captures, tombstones, migration
history, and the sync outbox. The main thread only updates observable state after
the local transaction; sync and projections are debounced background work.

The D1 schema stores fields independently. Each field is resolved by its hybrid
clock and device identifier, while mutation IDs make retries idempotent. Deletes
are tombstones. Pull uses a monotonic change cursor and returns the latest merged
entity state.

On the canonical personal Site, authenticated browser sessions from either of
the user's ChatGPT accounts resolve to the durable owner attached to the first
Mac write token. A bearer device token always takes precedence over a Sites
session header. This keeps browser-to-Mac and Mac-to-browser edits in the same
D1 partition.

## Projection ownership

When cloud pairing is configured, a Mac requests a 90-second export lease and
renews through normal background activity. A failed or denied lease suppresses
the iCloud write. Without cloud pairing, the only local Mac is allowed to export.

`tasks.md` contains unfinished overdue tasks, all of Today, and all future
tasks. Completed historical tasks stay in their daily logs instead of cluttering
Agenda. Projection files never feed back into live state.
