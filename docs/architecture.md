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
| Native macOS app | Normal macOS app with a retained active-Space AppKit status panel, planning gates, timer, blockers, fast editing, SQLite WAL |
| Native ReFocus AI | Optional OpenAI Responses API chat; Keychain secret; SQLite-backed task/Daily tools; bounded vault context |
| Universal PWA | iPhone/Ubuntu/browser editing, IndexedDB cache and outbox |
| Cloudflare D1 | Durable cross-device entities, field clocks, mutations, leases |
| Markdown projector | One-way `tasks.md` and clean daily logs for Obsidian |
| MCP | Compact optimization context plus explicit, write-scoped Daily edits and quick scheduled-task creation |

The canonical Site is private at the Sites dispatch layer. Native sync and the
local Codex MCP proxy therefore authenticate twice: `OAI-Sites-Authorization`
crosses the Site gate, then the scoped ReFocus bearer token selects and
authorizes the D1 owner. A browser session is never treated as an MCP
connection. Hosted clients that cannot send both headers require a separate
public MCP ingress (or a public Site with all data APIs still protected by the
ReFocus bearer-token layer).

SQLite tables hold tasks, day plans and immutable/modified snapshots, Description-backed check-ins,
daily-field definitions and values, analyses, captures, tombstones, migration
history, per-day periodic-break skip records, and the sync outbox. The main thread only updates observable state after
the local transaction; sync and projections are debounced background work.

The D1 schema stores fields independently. Each field is resolved by its hybrid
clock and device identifier, while mutation IDs make retries idempotent. Deletes
are tombstones. Pull uses a monotonic change cursor and returns the latest merged
entity state.

The native AI surface is not part of persistence or synchronization. It streams
through the OpenAI Responses API only when the user configures a Keychain-backed
API key. Supported reasoning summaries and tool progress are display metadata;
hidden chain-of-thought is never requested for display. Its context has three
layers: a generated static policy projection at `agents/context/refocus-ai.md`,
a fresh SQLite snapshot injected on every request, and bounded task/metric
history selected only when the current prompt needs it. Source fingerprints
refresh the static projection when its curated vault notes change, while a
marked approved-corrections section survives regeneration. Mutable facts never
come from the Markdown policy layer.

Every mutation passes the ordinary planner validation, writes through the same
`RefocusStore` transaction and sync outbox as a manual edit, then receives a
durable SQLite read-back. Tool results expose `verified: true` only after that
read-back matches; deletion additionally requires explicit delete/remove/cancel
language. The assistant receives targeted vault search instead of uploading the
whole vault on every prompt.

The task Description is the canonical execution/reflection narrative. The
screen-break task expander edits only the task name, MVP, Description, and three
subtask slots; the active task is always expanded. The four protected Rest
windows are 05:00–06:00, 11:00–12:00, 17:00–18:00, and 23:00–00:00 Asia/Dhaka. AI planning
preserves them by default for current/future intervals, interprets "break" as Rest, moves overlapping work
after Rest, matches close task names before creating duplicates, and allocates
omitted times after the last explicit task. An explicit current-prompt
override/overrule/bypass instruction may place work in Rest without deleting
the Rest row; the override is reported and never inferred. Work-task collisions
and the midnight boundary remain independently validated for current/future
intervals; completed intervals are historical evidence and cannot block later
planning;
those edits take the ordinary Today transaction path so Modified snapshots,
Diff, focus-session logs, and day analysis see the same value. Legacy
What-did/Better/Faster check-ins decode into one Description without discarding
history. Periodic five-minute screen breaks can be skipped no more than three
times per Asia/Dhaka day. Screen-saver-level panels join all Spaces, reassert
themselves after active-Space changes, and remain above full-screen apps.

Every native AI request carries fresh Asia/Dhaka wall-clock and cycle context.
`cur -> did X` appends X to the current task Description. `next -> N cycles ->
Task` starts at the next half-hour cycle and consecutive `then` clauses continue
from the prior task's end. AI-created tasks include a terse custom MVP and
exactly three terse custom subtasks.

On the normal dashboard, typing into the shared composer smoothly reveals the
same two-pane work surface used during a screen break: ReFocus AI remains on the
left while the selected Agenda, Today, Tomorrow, Daily, Diff, or Settings view
stays editable on the right. Assistant output is rendered as one selectable
attributed-text surface so a mouse selection can cross paragraphs and lists;
the per-message copy action still copies the complete source response.

The menu-bar entry is a retained AppKit status item and floating panel rather
than a SwiftUI `MenuBarExtra` window. The panel uses `moveToActiveSpace` and is
positioned from the clicked status-bar button, keeping the quick menu anchored
to whichever Space the user is currently viewing, independent of the
dashboard window's last Space. Launch at login is user-controlled from
Settings and is not enabled implicitly at startup.

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
Agenda. Each `log/YYYY-MM-DD.md` includes a clean, ID-free Initial and latest
Modified plan for every initialized planning block, so `analyze_day` can compare
intent with later rescheduling and edits. SQLite also stores immutable first-save
timestamps and a separate immutable Final snapshot captured during the exact
20:00 Asia/Dhaka minute. The Final includes task dates and tombstones so moved,
removed, completed, and edited tasks remain comparable by UUID; it is synced as
the write-once `day_plan_final` D1 entity. A missed cutoff is reported as
unavailable and is never reconstructed. Projection files never feed back into
live state.
