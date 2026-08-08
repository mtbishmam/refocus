# ReFocus deployment identities

Historical Bari-owned deployment:

- Site: `https://refocus-mtbishmam.bari86838683.chatgpt.site`
- Sites project: `appgprj_6a75db706f2481919b7d632b8f783186`

The canonical mtbishmam deployment uses display name `ReFocus`, slug `refocus`,
and hostname `https://refocus.mtbishmam.chatgpt.site`.

- Official owner account: `mtbishmam@gmail.com`
- Secondary access/Codex account: `bari86838683@gmail.com`
- Canonical Sites project: `appgprj_6a7624dfe23c81918e473d3a33ede4f8`
- D1 binding: `DB`

The official account owns the Site, source repository, and D1. The secondary
account may be used to run Codex and access the private app, but must not create
or substitute another deployment. Codex IDs, thread IDs, browser session IDs,
and other generated identities change frequently and are never authoritative.
Always resolve this deployment from the canonical owner account, exact project
ID, slug, and hostname above.

The canonical web runtime maps both authenticated account sessions to the D1
owner established by the first write-scoped Mac pairing token. Bearer tokens
take precedence over Sites session headers, preventing a native request from
being routed into the currently active ChatGPT account's partition.

On first pairing with the canonical Site, the native app stages a complete
snapshot from SQLite before syncing. Credentials are stored under a new
Keychain service so tokens from the Bari-owned deployment cannot be reused.

Migration was completed and verified on 2026-08-08. The canonical D1 contains
all 58 entities present in the old D1 plus five additional day-plan snapshots
and the task-template record. No old task, capture, check-in, daily-field
definition, or daily-field value is missing. The old Site and D1 are no longer
required by ReFocus and may be deleted from the Bari account.
