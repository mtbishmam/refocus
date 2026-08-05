# ReFocus project instructions

## Build and verification

- Build the native app with `swift build`.
- Run behavior checks with `swift run RefocusCoreChecks`.
- Package the local app with `scripts/package-app.sh`.
- Keep the app native to SwiftUI/AppKit. Do not add Electron, Tauri, a web
  runtime, a database, an in-app terminal, or an AI API without explicit user
  approval.
- ReFocus may edit only its versioned managed blocks in `tasks.md` and daily
  logs. Preserve Later, Completed, Inbox, and unrelated Markdown exactly.
- Keep streak definitions in `log/streaks.md`; store each day's streak values
  in that day's `log/mon-D.md` entry.

## Obsidian planning bridge

The attached Obsidian vault is at
`/Users/mtbishmam/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian`.
Its `AGENTS.md`, live `ego/ikigai.md`, `ego/non-negotiables.md`, and `tasks.md`
are authoritative for task planning.

When the user says `sort_tasks`, run the vault's complete `plan_tasks` workflow;
do not perform a shallow reorder. Re-read the live Ikigai file every time,
calculate the actual weekday in `Asia/Dhaka`, consider Today, Later, Completed,
and Inbox, display the complete proposed file, and wait for explicit approval
before writing.

Mandatory current exception resolution:

- Monday/Wednesday: Standard Routine with the 6:00–11:00 contest.
- Saturday/Thursday: omit the contest, ordinary work 6:00–8:00, protect
  university 8:00–14:00, then ordinary blocks.
- Sunday/Tuesday: keep the 6:00–11:00 contest, protect 11:30–18:00 for
  transition, university, and return, then resume the evening routine.
- Friday: omit the normal contest and use only the 9:00–13:00 SSC contest.

Explicit dated instructions override Special Events, which override University
Hours, which override the Standard Routine. Ask if two live exceptions conflict.
Before proposing or writing, audit the weekday, profile, protected windows,
contest duration, dynamic cycle minimum, four-cycle ordinary-task cap, and 9:30
PM cutoff. The minimum is the smaller of twelve and the number of unprotected
half-hour slots actually remaining before 9:30 PM.

Planning is now a hard gate. Do not tell the user to begin work before the
complete Today plan is approved and written. ReFocus must remain unarmed until
Today reaches the dynamic cycle minimum and passes every plan validation rule;
saving a valid plan unlocks the wall-clock work rhythm. `normal` and `contest`
are the only task kinds. A contest may occur in any unprotected window and may
use one to ten cycles; it is not required merely because of the day profile.

Every task uses its MVP as the completion definition; never add a separate
`Completion` field. A one-cycle task needs only a concrete MVP. A multi-cycle
task needs exactly three core tasks. Preserve ReFocus's hidden UUID metadata and
managed Today markers. The app overlay consumes only the current dated Today
section; it must never display Later, Completed, or Inbox.
