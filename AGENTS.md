# ReFocus project instructions

## Build and architecture

- Build with `swift build`, run `swift run RefocusCoreChecks`, and package with
  `scripts/package-app.sh`.
- Keep ReFocus native to SwiftUI/AppKit. Speed is the primary product
  constraint.
- The user explicitly approved the database/cloud redesign on 2026-08-07.
  SQLite WAL is the native local source of truth, IndexedDB is the web cache,
  and Cloudflare D1 is durable cross-device truth. Do not add Electron, Tauri,
  an embedded web runtime, an in-app terminal, or an AI model API.
- A universal PWA lives in `web/`; it must remain offline-first and fast. Its
  canonical Sites host is `refocus.mtbishmam.chatgpt.site`. Its mtbishmam-owned
  D1 was seeded and verified on 2026-08-08; runtime has no dependency on the
  previous Bari-owned Site or database.
- The canonical Site and D1 owner account is `mtbishmam@gmail.com`. The
  `bari86838683@gmail.com` account is secondary and may run Codex or access the
  private web app, but it must never replace the canonical deployment owner.
  Codex/session IDs are transient and must not be used as deployment identity;
  use the documented project ID, slug, hostname, and canonical owner instead.
- Site-identity gate: before creating a new ChatGPT Site, confirm the exact
  display name, owner namespace, slug, and complete hostname. Do not ask again
  for rebuilds, updates, or redeployments to an already confirmed Site. Ask
  again only when creating a new Site or changing its slug, namespace, or
  hostname. Never infer, normalize, shorten, or substitute a slug from the app
  name, repo name, prior project, or hostname. Treat a mismatched account,
  owner namespace, hostname, or deployment target as a deployment issue to
  diagnose and resolve.
- The vault is
  `/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian`.
- Legacy Markdown is read once during migration and preserved. Runtime state
  must never be reloaded from a Markdown projection.

## Files and ownership

- SQLite stores live tasks, templates, captures, snapshots, check-ins, analyses,
  extensible daily fields, tombstones, and the sync outbox.
- `tasks.md` is a one-way, read-only mobile projection containing unfinished
  overdue work, all Today tasks, and all future tasks. It must contain no UUIDs,
  HTML comments, or machine metadata.
- `log/YYYY-MM-DD.md` is a one-way clean machine activity projection without internal IDs or end-of-day analysis.
- `journal/mon-D.md` is the human-authored daily journal. Preserve unrelated writing exactly; approved `analyze_day` output belongs in its managed analysis block.
- Daily summary is written by the user or AI in the Summary section of `journal/mon-D.md`; it must not be collected as a Daily app field.
- `agenda.md`, `task-templates.md`, `dump.md`, legacy `journal/mon-D.md`, and
  `ego/non-negotiables.md` are preserved migration sources, not runtime stores.
- Cloud-paired projection writes require the D1 export lease. A denied or failed
  lease must not write to iCloud.

## Three planning gates

The day is independently planned and snapshotted in three super-blocks:

| Block | Window | Required cycles |
|---|---:|---:|
| Morning | 06:00–12:00 | `min(12, usable half-hour cycles remaining in this block)` |
| Afternoon | 12:00–18:00 | `min(12, usable half-hour cycles remaining in this block)` |
| Evening | 18:00–21:30 | `min(7, usable half-hour cycles remaining in this block)` |

- The normal 11:00–12:00 and 17:00–18:00 Rest tasks consume two physical
  cycles each, leaving the usual Morning/Afternoon requirement at 10. Because
  Rest is editable per date, deleting one immediately releases those two slots
  and raises that block's required plan to 12 cycles.

- Floor the current time to its active wall-clock cycle. At 07:13 the current
  cycle begins at 07:00.
- Only tasks wholly inside the active block count toward that block's gate,
  except the predefined five-hour Mashup: it remains one task and contributes
  only the half-hour cycles that physically overlap each gate.
  The fixed evening tasks count only toward the Evening gate.
- The first successful save in each block creates its immutable Initial
  snapshot. Later saves refresh that block's Modified snapshot. A save also
  refreshes Modified snapshots for earlier initialized blocks so end-of-day
  state is accurate.
- Red errors block saving. Yellow routine-exception warnings may be explicitly
  accepted for that date. Sort tasks by start time before validating; any
  unapproved collision remains red.
- Planning is a hard gate, but Command-Q must always remain available.
- During a screen break, the user may switch Today into the same structured
  task editor, save a modification, and thereby refresh the active Modified
  snapshot without rewriting its Initial snapshot.

## Task rules

- `normal` and `contest` are the only kinds.
- Normal tasks use one to four cycles. Contest tasks use one to ten cycles.
- Every Today/Tomorrow task has a concrete MVP as its sole completion
  definition and at least three named subtasks; more are allowed.
- Scheduled Agenda tasks may omit MVP and subtasks. They must satisfy the full
  task rules when promoted into Tomorrow or Today.
- Ikigai-derived University, Rest, Morning Routine, and Return Home blocks are
  predefined synchronized routine blocks. They are deliberately editable and
  removable for a date; a deletion is durable and must not silently reappear.
- User-planned tasks may not run after 21:30. The five-minute screen-break
  blocker is independent of this task cutoff and runs around the clock whenever
  ReFocus is running.
- Every day includes:
  - 20:00–20:30 — `Day Analysis and Streaks (CF & Git)`.
  - 20:30–21:00 — `Plan Tomorrow + Miscel Tasks`, extendable to 21:30.
  - 21:00–21:30 — `ReVision`, with ReSolve, ReSync, and Routes, Goals and
    Milestones.
- Only the 21:00–21:30 overlap between Plan Tomorrow and ReVision is permitted.

## Live routine authority

Before every planning, prioritization, rollover, rescheduling, or scheduling
operation, reread `ego/ikigai.md` and calculate the actual weekday in
`Asia/Dhaka`. The live file overrides examples copied here.

Current recurring profiles:

- Monday/Wednesday: Standard Routine, including the suggested 06:00–11:00
  contest.
- Saturday/Thursday: omit the contest, ordinary work 06:00–08:00, protect
  University 08:00–14:00, then ordinary blocks.
- Sunday/Tuesday: keep the 06:00–11:00 contest, enforce Rest 11:00–12:00,
  protect University/transition until 17:00, enforce Rest 17:00–18:00, then
  resume the evening routine.
- Friday: omit the normal contest and use the 09:00–13:00 SSC contest.

Precedence: explicit dated instruction, live Special Event, recurring
University Hours, Standard Routine. If live exceptions conflict without a
precedence rule, ask. University/special-event protection is a yellow,
date-overridable warning that must name its exact window and reason. Rest,
collision, malformed-task, duration, and cutoff failures are red. University
protection remains a named yellow warning that can be accepted for the date.

## Codex commands

`sort_tasks` is an alias for the complete `plan_tasks` workflow. Read the live
Ikigai and obtain current application context through MCP read tools (prefer
`get_optimization_context`) or the clean projections. Resolve conflicts, show
the complete proposed Today/Tomorrow/Agenda changes, and obtain explicit user
approval before the user applies writes in ReFocus.

`analyze_day`:

1. Read the live Ikigai, then call MCP `get_daily_dashboard` for the target date
   and read the day's context plus all three Initial and Modified snapshots,
   completion states, every Daily metric/habit result, current-month and total
   Deltas, Stages, weight progress/ETA, and screen-break answers.
2. Compare planned versus actual work and discuss causes that the evidence
   supports. Ask when the cause is unclear.
3. Propose Summary, Progress, Mistakes, and Gains and obtain explicit approval.
4. Store the approved analysis transactionally and update only the managed analysis block in `journal/mon-D.md`, preserving all user writing.
5. Keep `log/YYYY-MM-DD.md` machine-generated; never put the end-of-day Summary, Progress, Mistakes, or Gains there.

Daily/MCP compatibility rule: whenever any Daily field, habit, metric,
calculation, or dashboard behavior changes, update the `analyze_day` contract,
the MCP read/write tools, token-efficient context shape, documentation, and MCP
contract tests in the same change. AI may edit raw Daily metrics and habit
results through `update_daily_values` only when the user explicitly requests
the write; Delta, Stage, weight progress, and ETA remain derived values.

`clean_dump`:

1. Parse captures such as `page_name - content`, an indented block beneath a
   page name, `task - do_x`, or `aug 27 - MAT120 exam`.
2. Show a preflight list with every proposed destination/action and a separate
   ambiguity list. Examples: `refocus - ...` targets `refocus.md`; `task - ...`
   targets ReFocus planning/Agenda; a dated item targets Agenda.
3. Obtain explicit approval before writing. Do not move any ambiguous item.
4. Move only approved, unambiguous content, preserve meaning, and remove from
   `dump.md` only the captures successfully committed elsewhere.

The intended evening sequence is `analyze_day` → review captures → save the plan
in Tomorrow. Tomorrow becomes Today by scheduled date inside the database; no
Markdown promotion is involved.

## Streaks

- Import every bullet in the legacy `ego/non-negotiables.md`, then manage fields
  in the extensible daily-field table.
- The dashboard categories are `Non-Negotiables` (the current rules from
  `ego/non-negotiables.md`: no all-nighter, no unplanned food after 8, no
  unplanned InstaS, and no unplanned entertainment) and `Good Habits` (`Wake up
  @5:5` and `Solve 5 harder problems` only). Preserve stored values for removed
  or other imported habits even when they are hidden.
- Each date cycles blank → green Win → red Loss → blank. Checked always means
  success, including rules whose names begin with `No`.
- Current Month Delta is Wins minus Losses in the current calendar month. Total
  Delta is Wins minus Losses across all time and never resets. Derive Stage
  exclusively from Total Delta using the dashboard thresholds; stages may fall.
- Weight progress has a permanent 75 kg goal. Derive ETA in days from a recent
  measured downward trend; show `Not enough data` for sparse or non-downward
  histories and never fabricate a rate.

## ChatGPT Account, Site, and Codex Context

### ChatGPT accounts

- Both ChatGPT accounts may be used to build, edit, debug, and test these
  projects:
  - `mtbishmam@gmail.com`
  - `bari86838683@gmail.com`
- ChatGPT Site deployment currently works through `mtbishmam@gmail.com`.
- When working from `bari86838683@gmail.com`, build and stress-test locally
  using localhost, development servers, local APIs, local databases, mocks,
  browser testing, automated tests, and production-style build checks whenever
  possible.
- Treat final deployment as a handoff step to `mtbishmam@gmail.com`. Do not
  claim that a Site was deployed until deployment has been performed or
  independently verified through that account.
- Both accounts use the same local project and source files. Account
  differences do not imply separate codebases.

### Secondary-account workflow

- If the active ChatGPT account is `bari86838683@gmail.com`, treat the
  secondary account as a build, test, and preparation environment only.
- Do not attempt to deploy a ChatGPT Site or claim that a Site deployment
  succeeded from the secondary account.
- For any task involving application data, create or refresh a local snapshot
  of the current persistence layer before testing:
  - D1: use a local D1 database seeded from the available schema and data
    snapshot.
  - R2: use a local R2 simulation populated from the available object
    snapshot.
  - If the project uses another database or storage system, create the
    equivalent isolated local snapshot.
- Keep local bindings pointed at local resources. Do not enable remote
  bindings or connect destructive tests to production D1, R2, or equivalent
  storage.
- Run the local build, migrations, unit tests, API tests, browser checks, and
  relevant insert/update/delete stress tests against the local snapshot.
- If an exact production snapshot is unavailable, say so explicitly and use
  schema-valid fixtures or seed data. Do not claim that production data was
  verified.
- Treat all database and storage changes made from the secondary account as
  local-only. They do not change the deployed Site.
- Before handing work back, report clearly: **Site not yet deployed. Deploy
  the verified build from `mtbishmam@gmail.com`.**
- The primary account is responsible for deploying the approved saved version
  and for any intended production database or storage mutation. After the
  primary account deploys, verify the canonical hostname and report the
  production result separately from local test results.

### Canonical deployed Sites

| Project | Hostname | Description |
|---|---|---|
| ReSync | https://resync.mtbishmam.chatgpt.site | Intentional video and reading consumption system using RePlay, ReRead, Inbox, cooldown, Queue, Finished, AI summaries, value scoring, grounded chat, notes, and learning memory. |
| ReFocus | https://refocus.mtbishmam.chatgpt.site | Personal planning and focus-control system for daily plans, prioritized tasks, work cycles, screen-break overlays, agendas, routines, check-ins, streaks, metrics, offline use, and synchronization. |
| ReSolve | https://resolve.mtbishmam.chatgpt.site | Competitive-programming learning and active-recall system for problem capture, structured reflections, mistakes, mental models, memory cues, difficulty, status, review history, and spaced repetition. |

### Site identity rules

- Before creating a new ChatGPT Site, confirm the exact display name, owner
  namespace, slug, and complete hostname.
- Do not ask again for rebuilds, updates, or redeployments to an already
  confirmed Site.
- Ask again only when creating a new Site or changing its slug, namespace, or
  hostname.
- Never infer, rename, shorten, or substitute a Site slug or hostname.
- Treat a mismatched account, owner namespace, hostname, or deployment target
  as a deployment issue to diagnose and resolve.

### Codex context

- Codex task, thread, and conversation IDs may change frequently and are
  session-specific.
- Do not use Codex IDs as permanent project, Site, or deployment identifiers.
- Use the repository path, Git remote, branch, commit, canonical Site
  hostname, and active ChatGPT account as stable references.
- If an old Codex ID cannot be found, re-establish context from those stable
  references instead of assuming that the project or Site has changed.
