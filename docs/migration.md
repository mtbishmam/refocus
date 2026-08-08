# Markdown cutover

On the first launch of the database-backed build, ReFocus performs a read-only
inventory before importing:

- current dated Today and prepared Tomorrow plans;
- scheduled Agenda entries;
- task templates;
- all daily logs with ISO `date:` frontmatter;
- non-negotiable definitions and their historical tri-state values.

The inventory is written to
`~/Library/Application Support/ReFocus/legacy-import-report.json` with counts and
`sourceFilesPreserved: true`. The database is
`~/Library/Application Support/ReFocus/refocus.sqlite3`.

The source Markdown is not deleted. `tasks.md`, old `journal/mon-D.md` files,
`task-templates.md`, and `ego/non-negotiables.md` become preserved legacy input.
After cutover, ReFocus writes only the clean output projection `tasks.md` and
new machine-only `log/YYYY-MM-DD.md` files. Human journal writing and approved day analysis remain in `journal/mon-D.md`. Quick notes are stored internally and synchronized
instead of appending to `dump.md`.

If import fails, the completion marker is not committed and the next launch can
retry. Import and each later command run in `BEGIN IMMEDIATE` transactions.
