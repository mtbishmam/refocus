# ReFocus

ReFocus is a native macOS menu-bar Pomodoro and screen-break app backed entirely
by an Obsidian vault. The timer follows fixed wall-clock phases, renders only
the current `Today` plan, writes focus check-ins to `log/mon-D.md`, and applies
the routine exceptions from the user's Ikigai system.

## Build and verify

The current project builds with Apple Command Line Tools; full Xcode is optional
for code signing, profiling, and future distribution work.

```sh
swift build
swift run RefocusCoreChecks
scripts/package-app.sh
open .build/release/ReFocus.app
```

Launching the packaged app opens the dashboard and adds the live timer to the
menu bar. If it is already running, the same command brings the dashboard to
the front.

The fixed wall-clock timer is gated by planning. If the active work block is missing or invalid,
ReFocus opens a persistent full-screen planning gate. The primary display embeds
the complete dashboard—Agenda, Today, Tomorrow, Streaks, and Settings—so the plan can be created
without leaving the blocker. The gate remains across timer boundaries until a
valid plan is saved. Morning (`06:00–11:00`) and Afternoon (`12:00–17:00`)
independently require the smaller of ten and the usable cycles remaining in that
block. Evening (`18:00–21:30`) requires the smaller of seven and its usable
remaining cycles. ReFocus then arms automatically
and uses its check-in overlay at `:25–:30` and `:55–:00`.

Normal tasks are capped at four cycles. Every contest uses the single `contest`
kind and may use up to ten cycles in any otherwise valid time window.

On first launch, choose the Obsidian vault containing `tasks.md` and
`ego/ikigai.md`. ReFocus stores a security-scoped bookmark and does not hard-code
the vault as its runtime data source.

For reliable “Launch at Login,” move the packaged app to `/Applications`, open
it once, then enable the option in ReFocus Settings.

## Markdown contract

- Plan source: `tasks.md`, with dated Today and relative Tomorrow sections.
- Future schedule: `agenda.md`; reusable definitions: `task-templates.md`.
- Execution log: `log/aug-4.md` style filenames with ISO date frontmatter.
- Streak definitions: live bullets in `ego/non-negotiables.md`; tri-state daily
  values remain in the daily log.
- ReFocus patches only `<!-- refocus:... -->` managed blocks and reloads after
  external Obsidian or Codex writes.

Persistence is coordinated plain Markdown; ReFocus has no database. The
execution/check-in overlay renders only Today.

Agenda defaults to a one-month range. Scheduled and historical Agenda entries
can be deleted without deleting their permanent daily logs. Today/Tomorrow
details edited from Agenda autosave after validation. Quick Note is available in
the dashboard, screen-break overlay, and menu-bar panel and appends one line to
`dump.md`.

## Safety boundary

The break overlay uses native screen-saver-level windows on every display and
disables ordinary process switching. ReFocus deliberately leaves its standard
Command-Q quit path available; macOS Force Quit, logout, restart, and system
security interfaces also remain unavoidable escape routes.
