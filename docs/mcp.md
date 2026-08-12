# AI context and MCP

Production endpoint:

```text
https://refocus.mtbishmam.chatgpt.site/api/mcp
```

ReFocus is deployed as a private ChatGPT Site, so direct clients must pass two
independent credentials: the Sites dispatch bypass in
`OAI-Sites-Authorization` and a ReFocus token in `Authorization`. The native Mac
app stores both in Keychain after pairing.

Local Codex clients should use the checked-in stdio proxy. It reads the paired
credentials from Keychain and never prints or stores them in Codex config:

```sh
codex mcp add refocus -- \
  /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node \
  /Users/mtbishmam/code/refocus/web/scripts/refocus-mcp-proxy.mjs
```

Restart or open a new Codex task after adding the server; MCP inventories are
fixed when a task starts. A browser login cookie is not a substitute for MCP
configuration, and an `rf_...` token by itself cannot cross a private Site's
dispatch gate.

For a hosted ChatGPT connector that cannot set both headers, publish a dedicated
public MCP ingress or change the canonical Site to public access while retaining
the ReFocus token checks on every data API. Never expose D1 data without the
application-level bearer-token check.

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
  prompts used by `analyze_day`, plus the immutable Initial-vs-Final plan data.
- `get_plan_diff` — token-efficient immutable Initial snapshots and the
  separately persisted exact-20:00 Asia/Dhaka Final snapshot. It explicitly
  reports pending or unavailable cutoffs and never substitutes Modified state.
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
