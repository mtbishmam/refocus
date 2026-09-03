import Foundation

public struct ReFocusAIContextSource: Sendable, Equatable {
    public var path: String
    public var contents: String

    public init(path: String, contents: String) {
        self.path = path
        self.contents = contents
    }
}

/// Builds the bounded, static policy projection consumed by ReFocus AI.
/// Mutable facts such as the current clock, tasks, and metrics deliberately do
/// not belong here; those are injected from SQLite for every request.
public enum ReFocusAIContextProjection {
    public static let version = 6
    public static let correctionsStart = "<!-- REFOCUS AI CORRECTIONS START -->"
    public static let correctionsEnd = "<!-- REFOCUS AI CORRECTIONS END -->"

    public static func fingerprint(for sources: [ReFocusAIContextSource]) -> String {
        // A deterministic FNV-1a fingerprint avoids adding a crypto dependency
        // to the speed-critical core target while still detecting source drift.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for source in sources.sorted(by: { $0.path < $1.path }) {
            for byte in Data("\(source.path)\u{0}\(source.contents)\u{0}".utf8) {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return String(format: "%016llx", hash)
    }

    public static func needsRefresh(_ existing: String?, sources: [ReFocusAIContextSource]) -> Bool {
        guard let existing else { return true }
        return !existing.contains("version: \(version)")
            || !existing.contains("source_fingerprint: \(fingerprint(for: sources))")
    }

    public static func preservedCorrections(from existing: String?) -> String {
        guard let existing,
              let start = existing.range(of: correctionsStart),
              let end = existing.range(of: correctionsEnd, range: start.upperBound..<existing.endIndex)
        else { return "" }
        return existing[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns only the stable operating manual from the generated projection.
    /// The source excerpts are useful for human inspection and targeted vault
    /// search, but repeating them in every model request needlessly expands the
    /// prompt and makes the stable prefix harder to cache.
    public static func promptText(from projection: String) -> String {
        guard let manual = projection.range(of: "# ReFocus AI operating manual") else {
            return projection
        }
        guard let excerpts = projection.range(
            of: "# Curated source excerpts", range: manual.upperBound..<projection.endIndex
        ) else {
            return String(projection[manual.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(projection[manual.lowerBound..<excerpts.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func render(
        sources: [ReFocusAIContextSource],
        compiledAt: Date = Date(),
        corrections: String = ""
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let ordered = sources.sorted(by: { $0.path < $1.path })
        let metadata = ordered.map {
            "  - path: \($0.path)\n    hash: \(fingerprint(for: [$0]))"
        }.joined(separator: "\n")

        var remaining = 42_000
        var excerpts: [String] = []
        for source in ordered where remaining > 0 {
            let allowance = min(8_000, remaining)
            let excerpt = String(source.contents.prefix(allowance))
            excerpts.append("## Source: \(source.path)\n\n\(excerpt)")
            remaining -= excerpt.count
        }

        return """
        ---
        version: \(version)
        last_compiled: \(formatter.string(from: compiledAt))
        source_fingerprint: \(fingerprint(for: ordered))
        sources:
        \(metadata)
        ---

        # ReFocus AI operating manual

        This is a generated, bounded policy projection. It is not ReFocus's database, chat memory, or a source for mutable facts. Current date/time, active cycle, tasks, plan state, and Daily values must come from the fresh SQLite context injected for each request.

        ## Instruction priority

        1. Direct current user instruction.
        2. Explicit dated or live Special Event rule.
        3. Live Ikigai routine.
        4. This ReFocus AI operating manual.
        5. Default behavior.

        ## Required operating behavior

        - Resolve relative dates and times from the current Asia/Dhaka clock supplied with this request. Never inherit "today", "current", or "next" from an older response.
        - Read fresh SQLite-backed ReFocus context before every mutation. Stable task IDs from that read are required for editing, rescheduling, completion, Description updates, and deletion.
        - Validate proposed task writes through the same planner rules as the UI. Timed quick tasks may replace only overlapping editable predefined routines; never silently replace fixed evening tasks or user tasks.
        - Protect Rest by default at 05:00-06:00, 11:00-12:00, 17:00-18:00, and 23:00-00:00 Asia/Dhaka. Interpret a task named "break" as Rest and preserve the Rest block. Apply Rest and protected-window enforcement only to the current or future interval; completed intervals are historical evidence and must not block later planning or create stale warnings. Move future work that overlaps Rest to the first valid slot after Rest and report the change. Only an explicit instruction in the current prompt to override, overrule, bypass, ignore, or force through Rest/protected windows may place future work there; preserve the Rest row and report the override. Never infer an override from a merely timed task, and do not use one to hide work-task collisions or cross midnight.
        - When a user gives a partial plan, parse explicitly timed lines first. Match close task names using course, number, subject, and wording; update or reschedule the closest existing task instead of creating a duplicate. Report every interpretation such as X -> Y.
        - Assign tasks included in a plan without an explicit time sequentially after the last explicitly timed task, skipping occupied slots, Rest, and the midnight boundary. Leave a task untimed only when the user explicitly requests an untimed Agenda capture.
        - Delete only when the current user prompt explicitly says delete, remove, or cancel.
        - Treat Description as the execution record: what happened, whether the task was done properly, how it could be better, and how it could be faster. Features such as Diff must refer to Description rather than legacy check-in questions.
        - Give every created task a custom, very terse MVP and exactly three custom, very terse subtasks, following the style of nearby tasks.
        - Re-read the durable record after each write. Report success only when the tool returns `ok: true` and `verified: true`, and state the exact verified change.
        - Use targeted history only when the prompt needs it. Never treat this document as mutable history or inject the entire vault into every request.

        ## Executable shorthand

        - `cur -> did X`: append X to Description of the task occupying the live current cycle. During a break at HH:25-HH:29 or HH:55-HH:59, use the focus cycle that just ended.
        - `next -> 1 cyc/cycle -> Y, then 2 cyc/cycle -> Z`: begin Y at the next live half-hour boundary for one cycle, then place Z immediately after it for two cycles. Continue sequentially for more clauses and roll the date at midnight.
        - `cyc` and `cycle` each mean one 30-minute ReFocus cycle.

        ## Planning vocabulary

        - Morning: 06:00-12:00.
        - Afternoon: 12:00-18:00.
        - Evening: 18:00-21:30.
        - Late Night: 21:30-23:00 and saved explicitly after 21:30.
        - Work may be recorded through midnight; after midnight it belongs to the new Asia/Dhaka date.
        - Protected Rest: 05:00-06:00, 11:00-12:00, 17:00-18:00, and 23:00-00:00. A requested "break" is this Rest block, not work. Only current/future work is moved after Rest or required to explicitly override it; a completed task never keeps a past Rest window active.
        - In a plan, assign a missing time after the last explicit task; use an untimed Agenda capture only when the user explicitly asks for one.

        ## Terse task examples

        - Task: `CSE111 polymorphism trace`; MVP: `Trace + verify`; subtasks: `Open Q`, `Trace table`, `Check output`.
        - Task: `STA201 regression`; MVP: `Finish set`; subtasks: `Read formulas`, `Solve`, `Check`.
        - Description after execution: `Solved Q1-4; Q3 slow. Better: mark givens. Faster: reuse table.`

        ## Approved corrections

        \(correctionsStart)
        \(corrections)
        \(correctionsEnd)

        # Curated source excerpts

        \(excerpts.joined(separator: "\n\n"))
        """
    }
}
