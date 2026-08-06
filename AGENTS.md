# ReFocus project instructions

## Build and verification

- Build the native app with `swift build`.
- Run behavior checks with `swift run RefocusCoreChecks`.
- Package the local app with `scripts/package-app.sh`.
- Keep the app native to SwiftUI/AppKit. Do not add Electron, Tauri, a web
  runtime, a database, an in-app terminal, or an AI API without explicit user
  approval.
- ReFocus may edit its versioned managed blocks in `tasks.md`, `agenda.md`, and
  daily logs. `tasks.md` is a current-day dashboard, not a backlog: when a new
  day begins, archive its previous contents verbatim into `dump.md` before
  replacing it. Preserve unrelated Markdown in `dump.md` and the daily logs.
- Keep streak definitions in `log/streaks.md`; store each day's streak values
  in that day's `log/mon-D.md` entry.

## Obsidian planning bridge

The attached Obsidian vault is at
`/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian`.
Its `AGENTS.md`, live `ego/ikigai.md`, `ego/non-negotiables.md`, and `tasks.md`
are authoritative for task planning.

When the user says `sort_tasks`, run the vault's complete `plan_tasks` workflow;
do not perform a shallow reorder. Re-read the live Ikigai file every time,
  calculate the actual weekday in `Asia/Dhaka`, consider the current plan,
  `agenda.md`, and every capture in `dump.md`, display the complete proposed
  Today plan, and wait for explicit approval before writing.

Mandatory current exception resolution:

- Monday/Wednesday: Standard Routine with the 6:00–11:00 contest.
- Saturday/Thursday: omit the contest, ordinary work 6:00–8:00, protect
  university 8:00–14:00, then ordinary blocks.
- Sunday/Tuesday: keep the 6:00–11:00 contest, enforce Rest 11:00–12:00,
  protect the 12:00–17:00 transition/university window, enforce Rest
  17:00–18:00, then resume the evening routine.
- Friday: omit the normal contest and use only the 9:00–13:00 SSC contest.

Explicit dated instructions override Special Events, which override University
Hours, which override the Standard Routine. Ask if two live exceptions conflict.
Before proposing or writing, audit the weekday, profile, protected windows,
contest duration, dynamic cycle minimum, four-cycle ordinary-task cap, and 9:30
PM cutoff. The minimum is the smaller of twelve and the number of unprotected
half-hour slots actually remaining before 9:30 PM.

The 11:00–12:00 and 17:00–18:00 Rest Blocks are absolute and never
overridable. University and other recurring routine-exception windows are
yellow warnings: state the exact protected time and its reason, and allow an
explicit dated override such as “not going to university today.” All malformed
tasks, Rest Block collisions, ordinary task collisions, cutoff violations, and
the first-plan cycle minimum are red blockers.

Planning is now a hard gate. Do not tell the user to begin work before the
complete Today plan is approved and written. ReFocus must remain unarmed until
Today reaches the dynamic cycle minimum and passes every plan validation rule;
saving a valid plan unlocks the wall-clock work rhythm. `normal` and `contest`
are the only task kinds. A contest may occur in any unprotected window and may
use one to ten cycles; it is not required merely because of the day profile.

Every task uses its MVP as the completion definition; never add a separate
`Completion` field. Every task, including a one-cycle task, needs at least three
named subtasks, and may have more. Preserve ReFocus's hidden UUID metadata and
managed Today markers. The app overlay consumes only the current dated Today
section; it must never display `agenda.md` or `dump.md` captures.

Every day contains these fixed blocks: 20:00–20:30 “Day Analysis and Streaks
(CF & Git)”; 20:30–21:00 “Plan Tomorrow + Miscel Tasks,” extendable to 21:30;
and 21:00–21:30 “ReVision” with ReSolve, ReSync, and Routes, Goals and
Milestones as subtasks. Only the permitted 21:00–21:30 overlap between Plan
Tomorrow and ReVision is exempt from collision validation.

On the first valid save, preserve an immutable Initial Plan snapshot. Later
saves update the Modified Plan. Screen-break answers are written both beside
the live plan in `tasks.md` and to `log/mon-D.md`.

When the user says `analyze_day`, read the live `tasks.md`, compare Initial Plan
with Modified Plan, inspect completion states and every screen-break answer,
then collaboratively derive Summary, Progress, Mistakes, and Gains. Write the
approved result to that day's log. `clean_dump` is reserved for the later
interactive workflow that rewrites every capture into its canonical location;
never delete an unresolved capture.
