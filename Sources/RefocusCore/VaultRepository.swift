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
    public var dumpURL: URL { vaultURL.appendingPathComponent("dump.md") }
    public var agendaURL: URL { vaultURL.appendingPathComponent("agenda.md") }
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
        var latest = FileManager.default.fileExists(atPath: tasksURL.path) ? try fileAccess.read(tasksURL) : ""
        let codec = MarkdownPlanCodec(calendar: calendar)
        if let expectedTasks {
            do {
                let current = try codec.parseToday(latest, date: date)
                let currentNormalized = codec.renderManagedBlock(tasks: current.tasks, profile: current.profile)
                let expectedNormalized = codec.renderManagedBlock(tasks: expectedTasks, profile: current.profile)
                if currentNormalized != expectedNormalized { throw VaultRepositoryError.planConflict }
            } catch PlanCodecError.missingToday where expectedTasks.isEmpty {
                // A new date starts a new dynamic tasks.md. The previous file
                // is preserved verbatim in dump.md before replacement.
            }
        }
        let dateText = MarkdownPlanCodec.isoDate(date, calendar: calendar)
        if !latest.contains("# Today - \(dateText)") && !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try archiveInDump(latest, label: "tasks.md rollover")
            latest = ""
        }
        let updated = try codec.replacingTodayBlock(
            in: latest,
            date: date,
            tasks: tasks,
            profile: profile
        )
        var current = updated
        if !current.contains("<!-- refocus:initial-plan") {
            let initial = codec.renderInitialBlock(tasks: tasks, profile: profile)
            if let planStart = current.range(of: "<!-- refocus:plan") {
                current.insert(contentsOf: initial + "\n\n", at: planStart.lowerBound)
            }
        }
        let compact = compactTodayDocument(current, date: date)
        if compact != current && !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try archiveInDump(current, label: "tasks.md non-Today content")
        }
        try fileAccess.write(compact, to: tasksURL)
        try savePlanSnapshots(date: date, initialTasks: tasks, modifiedTasks: tasks, profile: profile)
    }

    public func loadAgenda() throws -> [AgendaTask] {
        var entries = FileManager.default.fileExists(atPath: agendaURL.path)
            ? AgendaMarkdownCodec(calendar: calendar).parse(try fileAccess.read(agendaURL))
            : []
        let known = Set(entries.map(\.id))
        let logDirectory = vaultURL.appendingPathComponent("log", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            var seen = known
            for file in files where file.pathExtension == "md" {
                guard let text = try? fileAccess.read(file),
                      let date = frontmatterDate(in: text),
                      let start = text.range(of: "<!-- refocus:modified-plan-snapshot -->"),
                      let end = text.range(of: "<!-- /refocus:modified-plan-snapshot -->", range: start.lowerBound..<text.endIndex) else { continue }
                let block = String(text[start.upperBound..<end.lowerBound])
                let synthetic = "# Today - \(MarkdownPlanCodec.isoDate(date, calendar: calendar))\n\n\(block)"
                guard let plan = try? MarkdownPlanCodec(calendar: calendar).parseToday(synthetic, date: date) else { continue }
                for task in plan.tasks where !task.isComplete && !seen.contains(task.id) {
                    entries.append(AgendaTask(date: date, task: task))
                    seen.insert(task.id)
                }
            }
        }
        if FileManager.default.fileExists(atPath: tasksURL.path),
           let liveText = try? fileAccess.read(tasksURL),
           let staleDate = todayHeadingDate(in: liveText),
           staleDate < calendar.startOfDay(for: Date()),
           let stalePlan = try? MarkdownPlanCodec(calendar: calendar).parseToday(liveText, date: staleDate) {
            var seen = Set(entries.map(\.id))
            for task in stalePlan.tasks where !task.isComplete && !seen.contains(task.id) {
                entries.append(AgendaTask(date: staleDate, task: task))
                seen.insert(task.id)
            }
        }
        return entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.task.startMinute < $1.task.startMinute
        }
    }

    public func saveAgenda(_ tasks: [AgendaTask]) throws {
        try fileAccess.write(AgendaMarkdownCodec(calendar: calendar).render(tasks), to: agendaURL)
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
        try saveCheckInToTasks(checkIn, date: date)
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

        # Summary

        -

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

    private func savePlanSnapshots(
        date: Date,
        initialTasks: [PlanTask],
        modifiedTasks: [PlanTask],
        profile: DayProfileKind
    ) throws {
        let definitions = (try? loadStreakDefinitions()) ?? Self.defaultStreaks
        let url = dailyLogURL(for: date)
        var text = FileManager.default.fileExists(atPath: url.path)
            ? try fileAccess.read(url)
            : initialDailyLog(date: date, streaks: definitions)
        let codec = MarkdownPlanCodec(calendar: calendar)
        if !text.contains("<!-- refocus:initial-plan-snapshot -->") {
            text = upsertManagedBlock(
                in: text,
                startMarker: "<!-- refocus:initial-plan-snapshot -->",
                endMarker: "<!-- /refocus:initial-plan-snapshot -->",
                heading: "# Initial Plan",
                body: codec.renderManagedBlock(tasks: initialTasks, profile: profile)
            )
        }
        text = upsertManagedBlock(
            in: text,
            startMarker: "<!-- refocus:modified-plan-snapshot -->",
            endMarker: "<!-- /refocus:modified-plan-snapshot -->",
            heading: "# Modified Plan",
            body: codec.renderManagedBlock(tasks: modifiedTasks, profile: profile)
        )
        try fileAccess.write(text, to: url)
    }

    private func saveCheckInToTasks(_ checkIn: CheckIn, date: Date) throws {
        guard FileManager.default.fileExists(atPath: tasksURL.path) else { return }
        var text = try fileAccess.read(tasksURL)
        let dateText = MarkdownPlanCodec.isoDate(date, calendar: calendar)
        guard text.contains("# Today - \(dateText)") else { return }
        let rendered = render(checkIn: checkIn)
        let start = "<!-- refocus:session id=\(checkIn.id) -->"
        let end = "<!-- /refocus:session id=\(checkIn.id) -->"
        if let startRange = text.range(of: start),
           let endRange = text.range(of: end, range: startRange.lowerBound..<text.endIndex) {
            text.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: rendered)
        } else if let logEnd = text.range(of: "<!-- /refocus:day-log -->") {
            text.insert(contentsOf: rendered + "\n\n", at: logEnd.lowerBound)
        } else {
            text += "\n\n# Screen Break Logs\n\n<!-- refocus:day-log -->\n\(rendered)\n<!-- /refocus:day-log -->\n"
        }
        try fileAccess.write(text, to: tasksURL)
    }

    private func compactTodayDocument(_ text: String, date: Date) -> String {
        let heading = "# Today - \(MarkdownPlanCodec.isoDate(date, calendar: calendar))"
        var parts = [heading]
        for markers in [
            ("## Initial Plan", "<!-- refocus:initial-plan", "<!-- /refocus:initial-plan -->"),
            ("## Modified Plan", "<!-- refocus:plan", "<!-- /refocus:plan -->"),
            ("## Screen Break Logs", "<!-- refocus:day-log -->", "<!-- /refocus:day-log -->"),
        ] {
            if let start = text.range(of: markers.1),
               let end = text.range(of: markers.2, range: start.lowerBound..<text.endIndex) {
                parts.append(markers.0 + "\n\n" + String(text[start.lowerBound..<end.upperBound]))
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private func archiveInDump(_ content: String, label: String) throws {
        let existing = FileManager.default.fileExists(atPath: dumpURL.path) ? try fileAccess.read(dumpURL) : "# Dump\n"
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let archived = "\(existing.trimmingCharacters(in: .newlines))\n\n<!-- refocus:archive at=\(timestamp) source=\(label.replacingOccurrences(of: " ", with: "-")) -->\n\(content.trimmingCharacters(in: .newlines))\n<!-- /refocus:archive -->\n"
        try fileAccess.write(archived, to: dumpURL)
    }

    private func upsertManagedBlock(
        in text: String,
        startMarker: String,
        endMarker: String,
        heading: String,
        body: String
    ) -> String {
        let block = "\(heading)\n\n\(startMarker)\n\(body)\n\(endMarker)"
        if let start = text.range(of: startMarker),
           let end = text.range(of: endMarker, range: start.lowerBound..<text.endIndex) {
            let headingStart = text[..<start.lowerBound].range(of: heading, options: .backwards)?.lowerBound ?? start.lowerBound
            return text.replacingCharacters(in: headingStart..<end.upperBound, with: block)
        }
        return text.trimmingCharacters(in: .newlines) + "\n\n" + block + "\n"
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

    private func frontmatterDate(in text: String) -> Date? {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("date: ") }) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(line.dropFirst("date: ".count)))
    }

    private func todayHeadingDate(in text: String) -> Date? {
        guard let line = text.components(separatedBy: .newlines).first(where: { $0.hasPrefix("# Today - ") }) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(line.dropFirst("# Today - ".count)))
    }
}
