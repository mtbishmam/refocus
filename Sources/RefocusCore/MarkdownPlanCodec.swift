import Foundation

public enum PlanCodecError: LocalizedError {
    case missingToday(String)
    case invalidManagedBlock

    public var errorDescription: String? {
        switch self {
        case .missingToday(let date): return "Today has not been planned for \(date)."
        case .invalidManagedBlock: return "The ReFocus plan block is malformed."
        }
    }
}

public struct MarkdownPlanCodec: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = WallClock.dhakaCalendar()) {
        self.calendar = calendar
    }

    public func parseToday(_ markdown: String, date: Date) throws -> TodayPlan {
        let dateText = Self.isoDate(date, calendar: calendar)
        let heading = "# Today - \(dateText)"
        guard let headingRange = markdown.range(of: heading) else {
            throw PlanCodecError.missingToday(dateText)
        }

        let sectionStart = markdown[headingRange.upperBound...].firstIndex(of: "\n").map { markdown.index(after: $0) } ?? headingRange.upperBound
        let remainder = markdown[sectionStart...]
        let sectionEnd: String.Index
        if let nextHeading = remainder.range(of: "\n# ") {
            sectionEnd = nextHeading.lowerBound
        } else {
            sectionEnd = markdown.endIndex
        }
        let section = String(markdown[sectionStart..<sectionEnd])
        let profile = parseProfile(section) ?? RoutineProfileResolver(calendar: calendar).profile(for: date).kind
        return TodayPlan(date: date, profile: profile, tasks: parseTasks(section), isCurrent: true)
    }

    public func renderManagedBlock(tasks: [PlanTask], profile: DayProfileKind) -> String {
        var lines = ["<!-- refocus:plan v=1 profile=\(profile.rawValue) -->"]
        for (index, task) in tasks.sorted(by: { $0.startMinute < $1.startMinute }).enumerated() {
            if index > 0 { lines.append("") }
            let checkbox = task.isComplete ? "x" : " "
            lines.append("- [\(checkbox)] \(Self.time(task.startMinute))–\(Self.time(task.endMinute)) → \(task.title)")
            lines.append("  <!-- refocus:task id=\(task.id.uuidString.lowercased()) start=\(Self.time(task.startMinute)) cycles=\(task.cycles) kind=\(task.kind.rawValue) priority=\(task.priority) difficulty=\(task.difficulty) -->")
            lines.append("  - MVP → \(task.mvp)")
            if task.cycles > 1 || !task.coreTasks.isEmpty {
                lines.append("  - Core tasks")
                for (offset, core) in task.coreTasks.enumerated() {
                    lines.append("    \(offset + 1). [\(core.isComplete ? "x" : " ")] \(core.title)")
                }
            }
        }
        lines.append("<!-- /refocus:plan -->")
        return lines.joined(separator: "\n")
    }

    public func replacingTodayBlock(
        in markdown: String,
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind
    ) throws -> String {
        let dateText = Self.isoDate(date, calendar: calendar)
        let heading = "# Today - \(dateText)"
        let rendered = renderManagedBlock(tasks: tasks, profile: profile)
        guard let headingRange = markdown.range(of: heading) else {
            let separator = markdown.isEmpty ? "" : "\n\n"
            return "\(heading)\n\n\(rendered)\(separator)\(markdown)"
        }

        if let start = markdown.range(of: "<!-- refocus:plan", range: headingRange.upperBound..<markdown.endIndex),
           let end = markdown.range(of: "<!-- /refocus:plan -->", range: start.lowerBound..<markdown.endIndex) {
            let nextTopHeading = markdown.range(of: "\n# ", range: headingRange.upperBound..<markdown.endIndex)
            if let nextTopHeading, start.lowerBound > nextTopHeading.lowerBound {
                throw PlanCodecError.invalidManagedBlock
            }
            return markdown.replacingCharacters(in: start.lowerBound..<end.upperBound, with: rendered)
        }

        let insertionPoint = markdown[headingRange.upperBound...].firstIndex(of: "\n").map { markdown.index(after: $0) } ?? headingRange.upperBound
        var updated = markdown
        updated.insert(contentsOf: "\n\(rendered)\n", at: insertionPoint)
        return updated
    }

    private func parseProfile(_ section: String) -> DayProfileKind? {
        guard let line = section.split(separator: "\n").first(where: { $0.contains("refocus:plan") }) else { return nil }
        return metadata(in: String(line))["profile"].flatMap(DayProfileKind.init(rawValue:))
    }

    private func parseTasks(_ section: String) -> [PlanTask] {
        let lines = section.components(separatedBy: .newlines)
        var tasks: [PlanTask] = []
        var index = 0
        while index < lines.count {
            guard let header = parseTaskHeader(lines[index]) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < lines.count && parseTaskHeader(lines[end]) == nil && !lines[end].contains("<!-- /refocus:plan -->") {
                end += 1
            }
            let block = Array(lines[index..<end])
            let metadataLine = block.first(where: { $0.contains("refocus:task") }) ?? ""
            let values = metadata(in: metadataLine)
            let id = values["id"].flatMap(UUID.init(uuidString:)) ?? UUID()
            let start = values["start"].flatMap(Self.minute) ?? header.start
            let cycles = values["cycles"].flatMap(Int.init) ?? max(1, (header.end - header.start) / 30)
            // `sscContest` was emitted by early MVP builds. Read it as the
            // single modern contest kind and rewrite it as `contest` on save.
            let kindText = values["kind"]
            let kind = kindText == "sscContest" ? .contest : kindText.flatMap(TaskKind.init(rawValue:)) ?? .normal
            let mvp = block.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- MVP →") else { return nil }
                return trimmed.replacingOccurrences(of: "- MVP →", with: "").trimmingCharacters(in: .whitespaces)
            }.first ?? ""
            let cores = block.compactMap(parseCoreTask)
            tasks.append(PlanTask(
                id: id,
                title: header.title,
                startMinute: start,
                cycles: cycles,
                kind: kind,
                priority: values["priority"] ?? "Medium",
                difficulty: values["difficulty"] ?? "Moderate",
                mvp: mvp,
                coreTasks: cores,
                isComplete: header.complete
            ))
            index = end
        }
        return tasks
    }

    private func parseTaskHeader(_ line: String) -> (complete: Bool, start: Int, end: Int, title: String)? {
        let pattern = #"^- \[([ xX])\] ([0-2][0-9]):([0-5][0-9])[–-]([0-2][0-9]):([0-5][0-9]) → (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 7 else { return nil }
        func capture(_ position: Int) -> String {
            guard let range = Range(match.range(at: position), in: line) else { return "" }
            return String(line[range])
        }
        let start = (Int(capture(2)) ?? 0) * 60 + (Int(capture(3)) ?? 0)
        let end = (Int(capture(4)) ?? 0) * 60 + (Int(capture(5)) ?? 0)
        return (capture(1).lowercased() == "x", start, end, capture(6))
    }

    private func parseCoreTask(_ line: String) -> CoreTask? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let pattern = #"^[0-9]+\. \[([ xX])\] (.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let checkedRange = Range(match.range(at: 1), in: trimmed),
              let titleRange = Range(match.range(at: 2), in: trimmed) else { return nil }
        return CoreTask(
            title: String(trimmed[titleRange]),
            isComplete: String(trimmed[checkedRange]).lowercased() == "x"
        )
    }

    private func metadata(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in line.replacingOccurrences(of: "-->", with: "").split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    public static func isoDate(_ date: Date, calendar: Calendar = WallClock.dhakaCalendar()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public static func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    public static func minute(_ value: String) -> Int? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
    }
}
