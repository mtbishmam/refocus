import Foundation

public struct AgendaMarkdownCodec: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = WallClock.dhakaCalendar()) {
        self.calendar = calendar
    }

    public func parse(_ markdown: String) -> [AgendaTask] {
        let lines = markdown.components(separatedBy: .newlines)
        var entries: [AgendaTask] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("## "), let date = date(from: String(line.dropFirst(3))) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count && !lines[end].hasPrefix("## ") && !lines[end].contains("<!-- /refocus:agenda -->") {
                end += 1
            }
            let body = lines[(index + 1)..<end].joined(separator: "\n")
            let synthetic = "# Today - \(MarkdownPlanCodec.isoDate(date, calendar: calendar))\n\n<!-- refocus:plan v=1 profile=standard -->\n\(body)\n<!-- /refocus:plan -->"
            if let plan = try? MarkdownPlanCodec(calendar: calendar).parseToday(synthetic, date: date) {
                entries.append(contentsOf: plan.tasks.map { AgendaTask(date: date, task: $0) })
            }
            index = end
        }
        return entries.sorted(by: Self.isEarlier)
    }

    public func render(_ entries: [AgendaTask], carriedForwardIDs: Set<UUID> = []) -> String {
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        var lines = ["# Agenda", "", "<!-- refocus:agenda v=1 -->"]
        for id in carriedForwardIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            lines.append("<!-- refocus:agenda-carried id=\(id.uuidString) -->")
        }
        for date in grouped.keys.sorted() {
            lines.append("")
            lines.append("## \(MarkdownPlanCodec.isoDate(date, calendar: calendar))")
            let tasks = grouped[date, default: []].map(\.task).sorted { $0.startMinute < $1.startMinute }
            let rendered = MarkdownPlanCodec(calendar: calendar).renderManagedBlock(tasks: tasks, profile: .standard)
            let taskLines = rendered.components(separatedBy: .newlines).dropFirst().dropLast()
            lines.append(contentsOf: taskLines)
        }
        lines.append("<!-- /refocus:agenda -->")
        return lines.joined(separator: "\n") + "\n"
    }

    public func carriedForwardIDs(in markdown: String) -> Set<UUID> {
        Set(markdown.components(separatedBy: .newlines).compactMap { line in
            let prefix = "<!-- refocus:agenda-carried id="
            guard line.hasPrefix(prefix), line.hasSuffix(" -->") else { return nil }
            let start = line.index(line.startIndex, offsetBy: prefix.count)
            let end = line.index(line.endIndex, offsetBy: -4)
            return UUID(uuidString: String(line[start..<end]))
        })
    }

    private func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    private static func isEarlier(_ lhs: AgendaTask, _ rhs: AgendaTask) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.task.startMinute < rhs.task.startMinute
    }
}
