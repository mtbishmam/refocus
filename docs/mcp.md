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
- `get_metric_trend` — dated values for weight, calories, expenses, solved
  problems, CP Hours, or a
  custom metric.
- `get_daily_dashboard` — the complete Daily state for one date: every
  editable field, current metric inputs (Weight, Calories, Expenses, Solved
  Problems, and CP Hours), every habit result, current and maximum streaks, total wins/losses,
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
- `create_task` — create a dated Agenda task directly from an explicit prompt.
  Supply an ISO date and concrete title; optional description, MVP, and
  subtasks are preserved and returned by task reads. A half-hour start plus either an end
  or cycle count is optional: without a start, the task remains unscheduled in
  Agenda and appears automatically in that date's Today view. MCP quick tasks
  do not require an MVP or three subtasks. Any
  overlapping predefined routine blocks are durably replaced for that date;
  fixed evening tasks and existing user tasks are never silently deleted.

Scheduled task creation still enforces half-hour scheduling, normal/contest
duration limits, and the 21:30 cutoff. It requires a write-scoped token and an explicit
user instruction. The new task synchronizes through D1 to native and web.

Diff keeps the planning gate explicit. The first successful Save Plan in each
block captures that exact displayed plan as immutable Initial. Morning and
Afternoon therefore each need their own save even when the defaults are left
unchanged; editing first and then saving captures the edited plan. If either
block was never saved, Diff uses that date's predefined routine as a clearly
labelled `default-not-saved` baseline. That fallback does not initialize the
block or unlock work.

`analyze_day` must call `get_daily_dashboard` before asking cause questions. Its
preflight always shows or asks for Weight, Calories, Expenses, Solved Problems,
and CP Hours, then
reviews every returned habit—including hidden imported habits—with its result,
streaks, Deltas, Stage, Wins, and Losses. If a task's MCP inventory does not
expose the full dashboard or write tool, the local Keychain-backed proxy above
is the supported fallback; do not treat a compact `get_day` response as proof
that Daily fields are empty.

Read tools strip storage IDs, field clocks, and tombstones. Daily writes use the
same synchronized field-value entities as native and web edits, so they flow
through D1 to every paired client. AI writes require a write-scoped token and an
explicit user instruction; derived analytics are never directly overwritten.

`currentStreak` is the number of consecutive calendar-day Wins ending at the
latest recorded result on or before the requested date. Missing days, blank
results, and losses break a streak. `maximumStreak`, `totalWins`, and
`totalLosses` use the complete recorded history through that date.
