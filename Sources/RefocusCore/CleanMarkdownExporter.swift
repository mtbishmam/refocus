import Foundation

public struct CleanMarkdownExporter: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = WallClock.dhakaCalendar()) {
        self.calendar = calendar
    }

    public func renderAgenda(_ entries: [AgendaTask], asOf date: Date) -> String {
        let today = calendar.startOfDay(for: date)
        let visible = entries.filter { entry in
            !entry.task.isRoutineBlock && entry.task.fixedRole == nil
                && (calendar.startOfDay(for: entry.date) >= today || !entry.task.isComplete)
        }
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.date) }
        var lines = ["# Tasks"]
        if grouped.isEmpty {
            lines.append(contentsOf: ["", "Nothing scheduled."])
        }
        for day in grouped.keys.sorted() {
            let label: String
            if calendar.isDate(day, inSameDayAs: today) {
                label = "Today — \(dayKey(day))"
            } else if day < today {
                label = "Overdue — \(dayKey(day))"
            } else {
                label = dayKey(day)
            }
            lines.append(contentsOf: ["", "## \(label)"])
            let tasks = grouped[day, default: []].sorted {
                agendaMinute($0.task) == agendaMinute($1.task)
                    ? $0.task.title.localizedCaseInsensitiveCompare($1.task.title) == .orderedAscending
                    : agendaMinute($0.task) < agendaMinute($1.task)
            }
            for entry in tasks { lines.append(contentsOf: render(entry.task)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func renderDailyLog(
        date: Date,
        tasks: [PlanTask],
        checkIns: [CheckIn],
        definitions: [DailyFieldDefinition],
        values: [DailyFieldValue],
        analysis: DayAnalysis?
    ) -> String {
        var lines = ["# \(dayKey(date))"]
        if !tasks.isEmpty {
            lines.append(contentsOf: ["", "## Plan"])
            for task in tasks.sorted(by: { $0.startMinute < $1.startMinute }) { lines.append(contentsOf: render(task)) }
        }
        let valueMap = Dictionary(uniqueKeysWithValues: values.map { ($0.definitionID, $0.value) })
        let populated = definitions.compactMap { definition -> String? in
            guard let value = valueMap[definition.id], !value.isEmpty else { return nil }
            let suffix = definition.unit.map { " \($0)" } ?? ""
            return "- \(definition.name): \(humanValue(value, kind: definition.kind))\(suffix)"
        }
        if !populated.isEmpty { lines.append(contentsOf: ["", "## Daily context"] + populated) }
        if !checkIns.isEmpty {
            lines.append(contentsOf: ["", "## Focus sessions"])
            for checkIn in checkIns.sorted(by: { $0.focusStart < $1.focusStart }) {
                let did = checkIn.whatDid.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("- \(time(checkIn.focusStart))–\(time(checkIn.focusEnd)) · \(checkIn.taskTitle) · \(checkIn.outcome.rawValue)")
                if !did.isEmpty { lines.append("  - Did: \(did)") }
                if !checkIn.better.isEmpty { lines.append("  - Better: \(checkIn.better)") }
                if !checkIn.faster.isEmpty { lines.append("  - Faster: \(checkIn.faster)") }
            }
        }
        _ = analysis // Human analysis belongs in journal/mon-D.md, not the machine log.
        return lines.joined(separator: "\n") + "\n"
    }

    public func renderJournalAnalysis(_ analysis: DayAnalysis) -> String {
        var lines = ["<!-- refocus:day-analysis -->"]
        appendAnalysis("Summary", analysis.summary, to: &lines)
        appendAnalysis("Progress", analysis.progress, to: &lines)
        appendAnalysis("Mistakes", analysis.mistakes, to: &lines)
        appendAnalysis("Gains", analysis.gains, to: &lines)
        lines.append("<!-- /refocus:day-analysis -->")
        return lines.joined(separator: "\n")
    }

    private func render(_ task: PlanTask) -> [String] {
        let timing = task.hasScheduledTime ? "\(time(task.startMinute))–\(time(task.endMinute)) · " : ""
        var lines = ["- [\(task.isComplete ? "x" : " ")] \(timing)\(task.title)"]
        if !task.mvp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("  - MVP: \(task.mvp)") }
        for subtask in task.coreTasks where !subtask.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  - [\(subtask.isComplete ? "x" : " ")] \(subtask.title)")
        }
        return lines
    }

    private func appendAnalysis(_ title: String, _ value: String, to lines: inout [String]) {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        lines.append(contentsOf: ["", "## \(title)", "", clean])
    }

    private func humanValue(_ value: String, kind: DailyFieldKind) -> String {
        guard kind == .triState else { return value }
        return switch value { case "win": "Win"; case "fail": "Fail"; default: "Blank" }
    }

    private func dayKey(_ date: Date) -> String { MarkdownPlanCodec.isoDate(date, calendar: calendar) }
    private func agendaMinute(_ task: PlanTask) -> Int { task.hasScheduledTime ? task.startMinute : Int.max }
    private func time(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    private func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

public final class ProjectionWriter: @unchecked Sendable {
    private let vaultURL: URL
    private let access: CoordinatedFileAccess
    private let renderer: CleanMarkdownExporter

    public init(vaultURL: URL, access: CoordinatedFileAccess = CoordinatedFileAccess(), calendar: Calendar = WallClock.dhakaCalendar()) {
        self.vaultURL = vaultURL
        self.access = access
        renderer = CleanMarkdownExporter(calendar: calendar)
    }

    public func exportTasks(_ entries: [AgendaTask], asOf date: Date) throws {
        try access.write(renderer.renderAgenda(entries, asOf: date), to: vaultURL.appendingPathComponent("tasks.md"))
    }

    public func appendCapture(_ text: String) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let url = vaultURL.appendingPathComponent("dump.md")
        let existing = FileManager.default.fileExists(atPath: url.path) ? try access.read(url) : ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try access.write(existing + separator + clean + "\n", to: url)
    }

    public func exportDailyLog(
        date: Date,
        tasks: [PlanTask],
        checkIns: [CheckIn],
        definitions: [DailyFieldDefinition],
        values: [DailyFieldValue],
        analysis: DayAnalysis?
    ) throws {
        let filename = "\(MarkdownPlanCodec.isoDate(date, calendar: renderer.calendar)).md"
        let url = vaultURL.appendingPathComponent("log", isDirectory: true).appendingPathComponent(filename)
        try access.write(
            renderer.renderDailyLog(date: date, tasks: tasks, checkIns: checkIns, definitions: definitions, values: values, analysis: analysis),
            to: url
        )
    }

    public func exportJournalAnalysis(date: Date, analysis: DayAnalysis) throws {
        let components = renderer.calendar.dateComponents([.month, .day], from: date)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let month = months[max(1, min(12, components.month ?? 1)) - 1]
        let url = vaultURL.appendingPathComponent("journal", isDirectory: true)
            .appendingPathComponent("\(month)-\(components.day ?? 1).md")
        let managed = renderer.renderJournalAnalysis(analysis)
        let existing = FileManager.default.fileExists(atPath: url.path) ? try access.read(url) : ""
        let startMarker = "<!-- refocus:day-analysis -->"
        let endMarker = "<!-- /refocus:day-analysis -->"
        let updated: String
        if let start = existing.range(of: startMarker),
           let end = existing.range(of: endMarker, range: start.lowerBound..<existing.endIndex) {
            updated = existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: managed)
        } else {
            let separator = existing.isEmpty || existing.hasSuffix("\n\n") ? "" : (existing.hasSuffix("\n") ? "\n" : "\n\n")
            updated = existing + separator + managed + "\n"
        }
        try access.write(updated, to: url)
    }
}
