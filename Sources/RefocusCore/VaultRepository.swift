import Foundation

public enum VaultRepositoryError: LocalizedError {
    case planConflict

    public var errorDescription: String? {
        "Today changed in Obsidian or Codex while you were editing. Reload and merge before saving."
    }
}

public final class CoordinatedFileAccess: @unchecked Sendable {
    public init() {}

    public func read(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error>!
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try String(contentsOf: coordinatedURL, encoding: .utf8) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    public func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordinationError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do {
                try text.write(to: coordinatedURL, atomically: true, encoding: .utf8)
            } catch {
                writeError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }
}

public final class VaultRepository: @unchecked Sendable {
    public let vaultURL: URL
    public let fileAccess: CoordinatedFileAccess
    public var calendar: Calendar

    public init(
        vaultURL: URL,
        fileAccess: CoordinatedFileAccess = CoordinatedFileAccess(),
        calendar: Calendar = WallClock.dhakaCalendar()
    ) {
        self.vaultURL = vaultURL
        self.fileAccess = fileAccess
        self.calendar = calendar
    }

    public var tasksURL: URL { vaultURL.appendingPathComponent("tasks.md") }
    public var streaksURL: URL {
        vaultURL
            .appendingPathComponent("log", isDirectory: true)
            .appendingPathComponent("streaks.md")
    }

    public func loadToday(date: Date) throws -> TodayPlan {
        let markdown = try fileAccess.read(tasksURL)
        return try MarkdownPlanCodec(calendar: calendar).parseToday(markdown, date: date)
    }

    public func saveToday(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        expectedTasks: [PlanTask]? = nil
    ) throws {
        let latest = try fileAccess.read(tasksURL)
        let codec = MarkdownPlanCodec(calendar: calendar)
        if let expectedTasks {
            do {
                let current = try codec.parseToday(latest, date: date)
                let currentNormalized = codec.renderManagedBlock(tasks: current.tasks, profile: current.profile)
                let expectedNormalized = codec.renderManagedBlock(tasks: expectedTasks, profile: current.profile)
                if currentNormalized != expectedNormalized { throw VaultRepositoryError.planConflict }
            } catch PlanCodecError.missingToday where expectedTasks.isEmpty {
                // The editor began from an unplanned day. Inserting the new
                // dated section preserves stale Today, Later, and Inbox text.
            }
        }
        let updated = try codec.replacingTodayBlock(
            in: latest,
            date: date,
            tasks: tasks,
            profile: profile
        )
        try fileAccess.write(updated, to: tasksURL)
    }

    public func dailyLogURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.month, .day], from: date)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthIndex = max(1, min(12, components.month ?? 1)) - 1
        return vaultURL
            .appendingPathComponent("log", isDirectory: true)
            .appendingPathComponent("\(months[monthIndex])-\(components.day ?? 1).md")
    }

    public func saveCheckIn(_ checkIn: CheckIn, date: Date, streaks: [StreakDefinition]) throws {
        let url = dailyLogURL(for: date)
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try fileAccess.read(url)
            : initialDailyLog(date: date, streaks: streaks)
        let block = render(checkIn: checkIn)
        let startMarker = "<!-- refocus:session id=\(checkIn.id) -->"
        let endMarker = "<!-- /refocus:session id=\(checkIn.id) -->"
        let updated: String
        if let start = existing.range(of: startMarker),
           let end = existing.range(of: endMarker, range: start.lowerBound..<existing.endIndex) {
            updated = existing.replacingCharacters(in: start.lowerBound..<end.upperBound, with: block)
        } else if let heading = existing.range(of: "# Focus Log") {
            let insertion = existing[heading.upperBound...].firstIndex(of: "\n").map { existing.index(after: $0) } ?? heading.upperBound
            var copy = existing
            copy.insert(contentsOf: "\n\(block)\n", at: insertion)
            updated = copy
        } else {
            updated = existing + "\n# Focus Log\n\n\(block)\n"
        }
        try fileAccess.write(updated, to: url)
    }

    public func loadStreakDefinitions() throws -> [StreakDefinition] {
        guard FileManager.default.fileExists(atPath: streaksURL.path) else { return Self.defaultStreaks }
        let text = try fileAccess.read(streaksURL)
        return text.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("- "), line.contains("refocus:streak") else { return nil }
            let name = line.dropFirst(2).components(separatedBy: "<!--").first?.trimmingCharacters(in: .whitespaces) ?? ""
            let values = metadata(in: line)
            guard let id = values["id"], let modeText = values["mode"], let mode = StreakMode(rawValue: modeText) else { return nil }
            return StreakDefinition(id: id, name: name, mode: mode)
        }
    }

    public func setStreakValue(_ definition: StreakDefinition, completed: Bool, date: Date) throws {
        let definitions = try loadStreakDefinitions()
        let url = dailyLogURL(for: date)
        var text = FileManager.default.fileExists(atPath: url.path)
            ? try fileAccess.read(url)
            : initialDailyLog(date: date, streaks: definitions)
        let marker = "<!-- refocus:streak-value id=\(definition.id)"
        let replacement = "- [\(completed ? "x" : " ")] \(definition.name) <!-- refocus:streak-value id=\(definition.id) mode=\(definition.mode.rawValue) -->"
        if let lineRange = lineRange(containing: marker, in: text) {
            text.replaceSubrange(lineRange, with: replacement)
        } else if let heading = text.range(of: "# Streaks") {
            let insertion = text[heading.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? heading.upperBound
            text.insert(contentsOf: "\n\(replacement)", at: insertion)
        }
        try fileAccess.write(text, to: url)
    }

    public func updateAutomaticStreaks(date: Date, planHasMinimum: Bool? = nil) throws {
        let definitions = try loadStreakDefinitions()
        if let planHasMinimum,
           let definition = definitions.first(where: { $0.mode == .planMinimum }) {
            try setStreakValue(definition, completed: planHasMinimum, date: date)
        }
        if let definition = definitions.first(where: { $0.mode == .noMissedCheckIns }) {
            let url = dailyLogURL(for: date)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let text = try fileAccess.read(url)
            let hasSession = text.contains("<!-- refocus:session id=")
            let hasMissed = text.contains("outcome=missed")
            try setStreakValue(definition, completed: hasSession && !hasMissed, date: date)
        }
    }

    public func loadStreakSummaries(for monthDate: Date, definitions: [StreakDefinition]) throws -> [StreakSummary] {
        let range = calendar.range(of: .day, in: .month, for: monthDate) ?? 1..<2
        let today = calendar.startOfDay(for: Date())
        return definitions.map { definition in
            var completed: Set<Int> = []
            for day in range {
                var parts = calendar.dateComponents([.year, .month], from: monthDate)
                parts.day = day
                guard let date = calendar.date(from: parts), date <= today else { continue }
                let url = dailyLogURL(for: date)
                guard let text = try? fileAccess.read(url) else { continue }
                if streakValue(definition, in: text) { completed.insert(day) }
            }
            var longest = 0
            var running = 0
            for day in range {
                if completed.contains(day) { running += 1; longest = max(longest, running) } else { running = 0 }
            }
            let currentDay = calendar.component(.day, from: min(today, calendar.date(byAdding: .month, value: 1, to: monthDate) ?? today))
            var current = 0
            var cursor = currentDay
            while cursor >= 1 && completed.contains(cursor) { current += 1; cursor -= 1 }
            return StreakSummary(definition: definition, current: current, longest: longest, completedDays: completed)
        }
    }

    public static let defaultStreaks = [
        StreakDefinition(id: "five-harder-problems", name: "Solve five harder problems", mode: .manual),
        StreakDefinition(id: "minimum-plan", name: "Complete the minimum daily plan", mode: .planMinimum),
        StreakDefinition(id: "no-missed-checkins", name: "No missed check-ins", mode: .noMissedCheckIns),
    ]

    private func initialDailyLog(date: Date, streaks: [StreakDefinition]) -> String {
        let streakLines = streaks.map {
            "- [ ] \($0.name) <!-- refocus:streak-value id=\($0.id) mode=\($0.mode.rawValue) -->"
        }.joined(separator: "\n")
        return """
        ---
        date: \(MarkdownPlanCodec.isoDate(date, calendar: calendar))
        refocus_schema: 1
        ---

        # Focus Log

        # Progress

        -

        # Gains

        -

        # Mistakes

        -

        # Streaks

        \(streakLines)
        """
    }

    private func render(checkIn: CheckIn) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let taskID = checkIn.taskID?.uuidString.lowercased() ?? "unplanned"
        var lines = [
            "<!-- refocus:session id=\(checkIn.id) -->",
            "## \(formatter.string(from: checkIn.focusStart))–\(formatter.string(from: checkIn.focusEnd)) — \(checkIn.taskTitle)",
            "<!-- refocus:checkin task=\(taskID) outcome=\(checkIn.outcome.rawValue) -->",
            "- What I did → \(checkIn.whatDid)",
            "- Better → \(checkIn.better)",
            "- Faster → \(checkIn.faster)",
        ]
        if let reason = checkIn.emergencyReason, !reason.isEmpty { lines.append("- Emergency escape → \(reason)") }
        lines.append("<!-- /refocus:session id=\(checkIn.id) -->")
        return lines.joined(separator: "\n")
    }

    private func metadata(in line: String) -> [String: String] {
        var result: [String: String] = [:]
        for token in line.replacingOccurrences(of: "-->", with: "").split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        return result
    }

    private func lineRange(containing marker: String, in text: String) -> Range<String.Index>? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let start = text[..<markerRange.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let end = text[markerRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        return start..<end
    }

    private func streakValue(_ definition: StreakDefinition, in text: String) -> Bool {
        let marker = "refocus:streak-value id=\(definition.id)"
        guard let range = lineRange(containing: marker, in: text) else { return false }
        return text[range].contains("[x]") || text[range].contains("[X]")
    }
}
