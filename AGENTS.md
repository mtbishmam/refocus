# ReFocus project instructions

## Shared ReApp context

Whenever a task mentions any ReApp or asks about how ReFocus relates to ReSync
or ReSolve, read the canonical AI context at
[`agents/context/reapps.md`](<../../Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/agents/context/reapps.md>).
It is derived from the current code under `/Users/mtbishmam/code` and contains
the family vocabulary, exact Site URLs, product boundaries, repository map,
architecture, data model, and planned-versus-shipped distinctions. This file
remains authoritative for ReFocus-specific implementation rules; the shared
note prevents cross-app context from being lost.

## Build and architecture

- Build with `swift build`, run `swift run RefocusCoreChecks`, and package with
  `scripts/package-app.sh`.
- Keep ReFocus native to SwiftUI/AppKit. Speed is the primary product
  constraint.
- The user explicitly approved the database/cloud redesign on 2026-08-07.
  SQLite WAL is the native local source of truth, IndexedDB is the web cache,
  and Cloudflare D1 is durable cross-device truth. Do not add Electron, Tauri,
  an embedded web runtime, or an in-app terminal. The native opt-in ReFocus AI
  assistant may call the OpenAI Responses API directly with a user-supplied API
  key stored in macOS Keychain; never store that secret in SQLite, Markdown,
  UserDefaults, source control, logs, or Cloudflare.
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
- Daily exposes editable dated history for Weight, Calories, Expenses, Solved
  Problems, and CP Hours in addition to habit history; current and historical
  values remain immediate-save and derived analytics recalculate from edits.
- `agenda.md`, `task-templates.md`, `dump.md`, legacy `journal/mon-D.md`, and
  `ego/non-negotiables.md` are preserved migration sources, not runtime stores.
- Cloud-paired projection writes require the D1 export lease. A denied or failed
  lease must not write to iCloud.

## Four planning gates

The day is independently planned and snapshotted in four super-blocks:

| Block | Window | Required cycles |
|---|---:|---:|
| Morning | 06:00–12:00 | `min(12, usable half-hour cycles remaining in this block)` |
| Afternoon | 12:00–18:00 | `min(12, usable half-hour cycles remaining in this block)` |
| Evening | 18:00–21:30 | `min(7, usable half-hour cycles remaining in this block)` |
| Late Night | 21:30–23:00 | `min(3, usable half-hour cycles remaining in this block)` |

- The normal 11:00–12:00 and 17:00–18:00 Rest tasks consume two physical
  cycles each, leaving the usual Morning/Afternoon requirement at 10. The
  05:00–06:00 and 23:00–00:00 windows are protected guard periods outside the
  planning quota. Because Rest is editable per date, deleting one
  immediately releases its two physical slots and raises that block's required
  plan to 12 cycles where applicable.

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
- During a screen break, expanding a task exposes only its editable name, MVP,
  Description, and exactly three editable subtask slots. The current task is
  always expanded. Those execution-field edits autosave through Today and
  refresh the active Modified snapshot without rewriting its Initial snapshot.
- Morning and Afternoon still require an explicit save even when their
  predefined defaults are accepted unchanged. Diff may show an unsaved block's
  predefined routine as a labelled default Initial baseline, but that fallback
  has no capture timestamp, does not initialize the planning gate, and does not
  unlock work. If the user edits before the first save, that edited plan becomes
  the immutable Initial snapshot.
- Tomorrow and an all-day predefined-plan confirmation initialize Morning,
  Afternoon, and Evening only. Late Night is deliberately excluded so the hard
  no-plan blocker returns at 21:30 and requires an explicit 21:30–23:00 save.
  The planning gate ends at 23:00; tasks may still be recorded through the date
  boundary without another planning-cycle quota.

## Task rules

- `normal` and `contest` are the only kinds.
- Normal tasks use one to four cycles. Contest tasks use one to ten cycles.
- Every Today/Tomorrow task has a concrete MVP as its sole completion
  definition and at least three named subtasks; more are allowed.
- Task Description is the single execution narrative: what actually happened,
  whether the work was done properly, what could improve, and what could be
  faster. It replaces the former What-did/Better/Faster check-in questions in
  screen breaks, Focus-session projections, Diff review, and `analyze_day`.
- A task is historical when its scheduled date is before today in Asia/Dhaka,
  or when it is scheduled today and its complete interval has ended. Historical
  tasks may omit MVP and subtasks (and retain unnamed imported subtasks), while
  timing, duration, collision, Rest, and cutoff validation remains active.
- Scheduled Agenda tasks may omit MVP and subtasks. They must satisfy the full
  task rules when promoted into Tomorrow or Today.
- Explicit write-scoped MCP `create_task` calls create quick tasks that may
  omit MVP and subtasks even in Today/Tomorrow. They may be unscheduled dated
  Agenda tasks, which appear automatically in that date's Today view, or
  scheduled tasks. Scheduled tasks retain all timing,
  duration, collision, and cutoff rules. An MCP quick task durably replaces
  overlapping non-Rest predefined routine blocks for that date, but never silently
  deletes fixed evening tasks or existing user tasks.
- Explicit write-scoped MCP `delete_task` and `delete_tasks` calls may remove
  tasks only after an ID-enabled `get_day` or `get_agenda` read and an explicit
  user instruction. Normal reads omit IDs. Optional expected date/title/start
  guards should be supplied when practical. Deletion writes the same durable
  tombstone and sync change used by native/web UI deletion; an explicitly
  targeted predefined or fixed evening block remains deleted for that date.
- Ikigai-derived University, Rest, Morning Routine, and Return Home blocks are
  predefined synchronized routine blocks. They are deliberately editable and
  removable for a date; a deletion is durable and must not silently reappear.
- User-planned tasks and focused work may continue after 21:30 through the
  midnight boundary. Work after midnight belongs to the next dated plan. The
  five-minute periodic screen-break blocker runs around the clock whenever
  ReFocus is running and may be skipped at most three times per Asia/Dhaka
  calendar day. A skipped periodic break stays dismissed through that break's
  end; the allowance resets after midnight. Scheduled one-hour Rest blockers and the persistent
  no-plan blocker each offer a one-minute temporary release before relocking.
- Every day starts with these fixed evening defaults, each explicitly deletable
  for that date:
  - 20:00–20:30 — `Day Analysis and Streaks (CF & Git)`.
  - 20:30–21:00 — `Plan Tomorrow + Miscel Tasks`, extendable to 21:30.
  - 21:00–21:30 — `ReVision`, with ReSolve, ReSync, and Routes, Goals and
    Milestones.
- Only the 21:00–21:30 overlap between Plan Tomorrow and ReVision is permitted.

## Native ReFocus AI

- The AI tab and screen-break AI panel use the OpenAI Responses API with
  streaming text, supported reasoning summaries, and visible tool progress.
  Never expose or claim access to hidden chain-of-thought.
- The assistant must read current SQLite-backed ReFocus context before changing
  records. Its tools may create, edit, reschedule, complete, move, or delete
  tasks and may edit current or historical Daily fields. Task deletion still
  requires an explicit delete/remove/cancel instruction from the user.
- Native AI task creation always supplies a custom, very terse MVP and exactly
  three custom, very terse subtasks, using nearby saved tasks as style context.
  AI quick tasks may replace only overlapping predefined routine blocks. They
  must never silently remove fixed evening or existing user tasks.
- AI must preserve Rest at 05:00–06:00, 11:00–12:00, 17:00–18:00, and
  23:00–00:00. A task named "break" is interpreted as Rest. If a partial plan leaves a task without
  a time, assign it after the last explicitly timed task while skipping occupied
  slots and Rest. Similar task names are matched to existing tasks before a new
  record is created, and any X → Y interpretation is reported to the user.
- Every Responses API turn and tool round receives a fresh Asia/Dhaka date,
  time, phase, current-cycle start, next-cycle start, and current task. Older
  chat turns must never override this live context after midnight.
- AI context has three layers: the generated static policy projection at
  `agents/context/refocus-ai.md`, a fresh SQLite snapshot on every request and
  before every mutation, and bounded task/metric history only when the prompt
  needs it. Mutable facts must never come from the Markdown policy projection.
  Regeneration preserves its marked approved-corrections section.
- Native AI task writes use the ordinary planner validator and must pass a
  durable SQLite read-back before the tool returns `verified: true`. The AI
  must not report a write as successful without both `ok: true` and
  `verified: true`.
- Shorthand is executable: `cur -> did X` appends X to the Description of the
  task occupying the current cycle (the just-ended focus cycle during its
  screen break). `next -> 1 cyc/cycle -> Y, then 2 cyc/cycle -> Z` schedules Y
  for the next half-hour cycle and Z for the following two cycles, continuing
  sequentially for additional `then` clauses. `cyc` and `cycle` are synonyms.
- The generated policy projection includes bounded material from the
  configured vault and exposes targeted Markdown search. Prefer
  `ego/ikigai.md`, current
  non-negotiables, goals, habits, universal truths, and gyoji; do not ingest the
  entire vault into every request.

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
- Every profile preserves the 23:00–00:00 Rest window; it is outside the
  planning quota but remains a screen guard.
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

`analyze_day` is the scheduled `refocus-day-analysis` heartbeat. Read the
canonical vault document at
`/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/agents/scheduled/analyze_day.md`
before running it; that document contains the complete context for its
trigger, source order, snapshot and Daily/MCP contract, evidence rules,
approval gate, allowed writes, forbidden mutations, storage/lease behavior,
validation, rollback, and verification. Do not maintain a project-local copy.

Any change to `analyze_day`, Daily fields or calculations, MCP read/write
tools, plan snapshots/final capture, projection destinations, approval rules,
or safety behavior must update the canonical vault document in the same
change. `log/YYYY-MM-DD.md` remains machine-generated; approved day analysis
belongs only in the managed block of `journal/mon-D.md` (the current projector
uses names such as `journal/aug-10.md`).

`clean_dump`:

Read `/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/agents/commands/clean_dump.md`
before running the command. That file is the canonical, complete clean_dump
context. It contains the parsing grammar, routing map, approval gate,
Agenda/storage rules, ambiguity policy, commit behavior, and verification
requirements. Any future change to clean_dump must update that file in the same
change; do not maintain a second inline copy here.

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
