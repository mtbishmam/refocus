# AI context and MCP

Production endpoint:

```text
https://refocus.mtbishmam.chatgpt.site/api/mcp
```

Create an AI read/write token in the web app's **Connections** section and send it as
`Authorization: Bearer <token>`. The token is shown once; D1 stores only its
SHA-256 hash.

Tools:

- `get_optimization_context` — preferred first call; compact recent agenda,
  metrics, focus outcomes, and analyses.
- `get_agenda` — scheduled work for a date range.
- `get_day` — one day's tasks, metrics, sessions, and analysis.
- `get_metric_trend` — dated values for weight, calories, solved problems, or a
  custom metric.
- `get_daily_dashboard` — the complete Daily state for one date: every
  editable field, current metric inputs (including weight, calories, and solved
  problems), every habit result, current and maximum streaks, total wins/losses,
  month/lifetime Deltas, Stage, monthly history, weight progress/ETA, and the
  prompts used by `analyze_day`.
- `update_daily_values` — write any editable Daily field (metrics, text fields,
  or habit results) in one explicit write-scoped batch. Habits use `blank`,
  `win`, or `fail`; current/max streaks, wins/losses, Delta, Stage, weight
  progress, and ETA are derived and recalculate automatically. The server
  advertises the complete editable field list in `writeAccess.editableFields`.

Read tools strip storage IDs, field clocks, and tombstones. Daily writes use the
same synchronized field-value entities as native and web edits, so they flow
through D1 to every paired client. AI writes require a write-scoped token and an
explicit user instruction; derived analytics are never directly overwritten.

`currentStreak` is the number of consecutive calendar-day Wins ending at the
latest recorded result on or before the requested date. Missing days, blank
results, and losses break a streak. `maximumStreak`, `totalWins`, and
`totalLosses` use the complete recorded history through that date.
