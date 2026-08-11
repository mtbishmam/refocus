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
- `get_daily_dashboard` — the complete Daily state for one date: structured
  inputs, habit results, month/lifetime Delta, Stage, monthly history, and
  weight progress/ETA.
- `update_daily_values` — batch-edit Daily metrics and habit results. Habits use
  `blank`, `win`, or `fail`; Delta, Stage, progress, and ETA are derived and
  recalculate automatically.

Read tools strip storage IDs, field clocks, and tombstones. Daily writes use the
same synchronized field-value entities as native and web edits, so they flow
through D1 to every paired client. AI writes require a write-scoped token and an
explicit user instruction; derived analytics are never directly overwritten.
