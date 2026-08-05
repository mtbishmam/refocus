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

The fixed wall-clock timer is gated by planning. If Today is missing or invalid,
ReFocus opens a persistent full-screen planning gate. The primary display embeds
the complete dashboard—Today, Streaks, and Settings—so the plan can be created
without leaving the blocker. The gate remains across timer boundaries until a
valid plan is saved. Its cycle minimum is the smaller of twelve and the number
of unprotected half-hour slots remaining before 9:30 PM, so late planning cannot
create an impossible lock. ReFocus then arms automatically
and uses its check-in overlay at `:25–:30` and `:55–:00`.

Normal tasks are capped at four cycles. Every contest uses the single `contest`
kind and may use up to ten cycles in any otherwise valid time window.

On first launch, choose the Obsidian vault containing `tasks.md` and
`ego/ikigai.md`. ReFocus stores a security-scoped bookmark and does not hard-code
the vault as its runtime data source.

For reliable “Launch at Login,” move the packaged app to `/Applications`, open
it once, then enable the option in ReFocus Settings.

## Markdown contract

- Plan source: `tasks.md`, current `# Today - YYYY-MM-DD` section only.
- Execution log: `log/aug-4.md` style filenames with ISO date frontmatter.
- Streak definitions: `log/streaks.md`; daily values remain in the daily log.
- ReFocus patches only `<!-- refocus:... -->` managed blocks and reloads after
  external Obsidian or Codex writes.

`Later`, `Completed`, and `Inbox` remain planning inputs for Codex but are never
shown in the execution/check-in overlay.

## Safety boundary

The break overlay uses native screen-saver-level windows on every display and
disables ordinary process switching. ReFocus deliberately leaves its standard
Command-Q quit path available; macOS Force Quit, logout, restart, and system
security interfaces also remain unavoidable escape routes.
