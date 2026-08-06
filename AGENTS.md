# ReFocus project instructions

## Build and architecture

- Build with `swift build`, run `swift run RefocusCoreChecks`, and package with
  `scripts/package-app.sh`.
- Keep ReFocus native to SwiftUI/AppKit. Speed is the primary product
  constraint.
- Persistence is plain Markdown coordinated through `NSFileCoordinator`; there
  is no database. Do not add Electron, Tauri, a web runtime, an AI API, an
  in-app terminal, or a database without explicit approval.
- The vault is
  `/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian`.
- ReFocus may change only its managed Markdown blocks. Preserve unrelated
  content exactly and treat an external Obsidian/Codex edit as a conflict rather
  than overwriting it.

## Files and ownership

- `tasks.md` is the mobile-readable operational file. It may contain the live
  dated Today and relative Tomorrow plans, three immutable Initial snapshots,
  three live Modified snapshots, completion state, and screen-break logs.
- `agenda.md` stores future scheduled tasks. Agenda capture requires a real
  title only; MVP and subtasks are optional until the task is promoted into
  Tomorrow or Today. The Agenda UI may delete entries from `agenda.md`; archived
  daily logs must never repopulate deleted Agenda history.
- `task-templates.md` stores reusable task definitions.
- `dump.md` is only the user's fast raw capture surface. Never use it as a
  daily-plan archive. Quick Note appends one trimmed line to its end from the
  dashboard, screen-break overlay, or menu-bar panel.
- `log/mon-D.md` is the permanent daily record; store the ISO date in
  frontmatter. When a dated Today is rolled over, archive it in that date's
  daily log, never in `dump.md`.
- Read streak definitions from the live `ego/non-negotiables.md`. Store daily
  blank/win/fail values in `log/mon-D.md`; `log/streaks.md` documents the
  mapping.

## Three planning gates

The day is independently planned and snapshotted in three super-blocks:

| Block | Window | Required cycles |
|---|---:|---:|
| Morning | 06:00–11:00 | `min(10, usable half-hour cycles remaining in this block)` |
| Afternoon | 12:00–17:00 | `min(10, usable half-hour cycles remaining in this block)` |
| Evening | 18:00–21:30 | `min(7, usable half-hour cycles remaining in this block)` |

- Floor the current time to its active wall-clock cycle. At 07:13 the current
  cycle begins at 07:00.
- Only tasks wholly inside the active block count toward that block's gate.
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
- Nothing may overlap the non-overridable 11:00–12:00 or 17:00–18:00 Rest
  Blocks or run after 21:30.
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
collision, malformed-task, duration, and cutoff failures are red.

## Codex commands

`sort_tasks` is an alias for the complete `plan_tasks` workflow. Read the live
Ikigai, the current plan, Agenda, and dump captures; resolve conflicts; show the
complete proposed Today/Tomorrow/Agenda changes; and obtain explicit approval
before writing.

`analyze_day`:

1. Read the day's log plus all three Initial and Modified snapshots, completion
   states, and screen-break answers.
2. Compare planned versus actual work and discuss causes that the evidence
   supports. Ask when the cause is unclear.
3. Propose Summary, Progress, Mistakes, and Gains and obtain explicit approval.
4. Write the approved analysis to `log/mon-D.md`, preserving all managed data.
5. Archive the full dated `tasks.md` Today record in that log and remove the
   analyzed Today section. Do not touch `dump.md`.

`clean_dump`:

1. Parse captures such as `page_name - content`, an indented block beneath a
   page name, `task - do_x`, or `aug 27 - MAT120 exam`.
2. Show a preflight list with every proposed destination/action and a separate
   ambiguity list. Examples: `refocus - ...` targets `refocus.md`; `task - ...`
   targets ReFocus planning/Agenda; a dated item targets Agenda.
3. Obtain explicit approval before writing. Do not move any ambiguous item.
4. Move only approved, unambiguous content, preserve meaning, and remove from
   `dump.md` only the captures successfully committed elsewhere.

The intended evening sequence is `analyze_day` → `clean_dump` → save the plan
in the relative Tomorrow view. Saving Tomorrow writes `# Tomorrow - YYYY-MM-DD`
to `tasks.md`; it becomes Today on that date.

## Streaks

- Use every bullet in the live `ego/non-negotiables.md`, in file order.
- Each date cycles blank → green win → red fail → blank.
- Display current streak, maximum streak, total wins, and total fails.
