# AI context and MCP

Production endpoint:

```text
https://refocus.mtbishmam.chatgpt.site/api/mcp
```

Create a read-only token in the web app's **Connections** section and send it as
`Authorization: Bearer <token>`. The token is shown once; D1 stores only its
SHA-256 hash.

Tools:

- `get_optimization_context` — preferred first call; compact recent agenda,
  metrics, focus outcomes, and analyses.
- `get_agenda` — scheduled work for a date range.
- `get_day` — one day's tasks, metrics, sessions, and analysis.
- `get_metric_trend` — dated values for weight, calories, solved problems, or a
  custom metric.

The MCP server is intentionally read-only. It strips storage IDs, field clocks,
tombstones, blank values, and empty analysis sections. Plan or analysis changes
remain user-confirmed in the ReFocus UI rather than giving an AI silent write
authority.
