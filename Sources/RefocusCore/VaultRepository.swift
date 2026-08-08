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

    public func appendLine(_ line: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        var coordinationError: NSError?
        var appendError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forMerging, error: &coordinationError) { coordinatedURL in
            do {
                let handle = try FileHandle(forUpdating: coordinatedURL)
                defer { try? handle.close() }
                let offset = try handle.seekToEnd()
                var prefix = ""
                if offset > 0 {
                    try handle.seek(toOffset: offset - 1)
                    let lastByte = try handle.read(upToCount: 1)
                    if lastByte != Data([0x0A]) { prefix = "\n" }
                    _ = try handle.seekToEnd()
                }
                try handle.write(contentsOf: Data("\(prefix)\(line)\n".utf8))
                try handle.synchronize()
            } catch {
                appendError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let appendError { throw appendError }
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
    public var templatesURL: URL { vaultURL.appendingPathComponent("task-templates.md") }
    public var nonNegotiablesURL: URL {
        vaultURL.appendingPathComponent("ego", isDirectory: true).appendingPathComponent("non-negotiables.md")
    }
    public var streaksURL: URL {
        vaultURL
            .appendingPathComponent("log", isDirectory: true)
            .appendingPathComponent("streaks.md")
    }

    public func loadToday(date: Date) throws -> TodayPlan {
        let markdown = try fileAccess.read(tasksURL)
        return try MarkdownPlanCodec(calendar: calendar).parseToday(markdown, date: date)
    }

    public func loadTomorrow(date: Date) throws -> TodayPlan {
        let markdown = try fileAccess.read(tasksURL)
        return try MarkdownPlanCodec(calendar: calendar).parseTomorrow(markdown, date: date)
    }

    public func saveToday(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment,
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
                // A new date can begin from an empty file or a prepared
                // Tomorrow section.
            }
        }
        let dateText = MarkdownPlanCodec.isoDate(date, calendar: calendar)
        if !latest.contains("# Today - \(dateText)"), let staleDate = todayHeadingDate(in: latest), staleDate != date {
            try migrateIncompleteTasksToAgenda(in: latest, date: staleDate)
            try archiveTasksInDailyLog(latest, date: staleDate)
            latest = removingTopSection(
                from: latest,
                heading: "# Today - \(MarkdownPlanCodec.isoDate(staleDate, calendar: calendar))"
            )
            if latest.contains("# Tomorrow - \(dateText)") {
                latest = latest.replacingOccurrences(of: "# Tomorrow - \(dateText)", with: "# Today - \(dateText)")
            }
        } else if !latest.contains("# Today - \(dateText)"), latest.contains("# Tomorrow - \(dateText)") {
            latest = latest.replacingOccurrences(of: "# Tomorrow - \(dateText)", with: "# Today - \(dateText)")
        }
        let updated = try codec.replacingTodayBlock(
            in: latest,
            date: date,
            tasks: tasks,
            profile: profile
        )
        var current = updated
        let heading = "# Today - \(dateText)"
        for candidate in PlanningSegment.allCases {
            let existingInitial = section(current, headedBy: heading)
                .contains("<!-- refocus:initial-plan v=1 segment=\(candidate.rawValue)")
            guard candidate == segment || existingInitial else { continue }
            current = upsertSegmentSnapshots(
                in: current,
                heading: heading,
                tasks: tasks,
                profile: profile,
                segment: candidate
            )
        }
        try fileAccess.write(current, to: tasksURL)
        try savePlanSnapshots(date: date, initialTasks: tasks, modifiedTasks: tasks, profile: profile, segment: segment)
    }

    public func saveTomorrow(date: Date, tasks: [PlanTask], profile: DayProfileKind) throws {
        let codec = MarkdownPlanCodec(calendar: calendar)
        var text = FileManager.default.fileExists(atPath: tasksURL.path) ? try fileAccess.read(tasksURL) : ""
        text = try codec.replacingTomorrowBlock(in: text, date: date, tasks: tasks, profile: profile)
        let heading = "# Tomorrow - \(MarkdownPlanCodec.isoDate(date, calendar: calendar))"
        for segment in PlanningSegment.allCases {
            text = upsertSegmentSnapshots(
                in: text,
                heading: heading,
                tasks: tasks,
                profile: profile,
                segment: segment
            )
        }
        try fileAccess.write(text, to: tasksURL)
    }

    public func loadAgenda(asOf date: Date = Date()) throws -> [AgendaTask] {
        let codec = AgendaMarkdownCodec(calendar: calendar)
        var entries = FileManager.default.fileExists(atPath: agendaURL.path)
            ? codec.parse(try fileAccess.read(agendaURL))
            : []
        if FileManager.default.fileExists(atPath: tasksURL.path),
           let liveText = try? fileAccess.read(tasksURL),
           let staleDate = todayHeadingDate(in: liveText),
           calendar.startOfDay(for: staleDate) < calendar.startOfDay(for: date) {
            try migrateIncompleteTasksToAgenda(in: liveText, date: staleDate)
            if FileManager.default.fileExists(atPath: agendaURL.path) {
                entries = codec.parse(try fileAccess.read(agendaURL))
            }
        }
        return entries.sorted {
            if $0.date != $1.date { return $0.date < $1.date }
            return $0.task.startMinute < $1.task.startMinute
        }
    }

    public func saveAgenda(_ tasks: [AgendaTask]) throws {
        let codec = AgendaMarkdownCodec(calendar: calendar)
        let carriedForwardIDs: Set<UUID>
        if FileManager.default.fileExists(atPath: agendaURL.path),
           let existing = try? fileAccess.read(agendaURL) {
            carriedForwardIDs = codec.carriedForwardIDs(in: existing)
        } else {
            carriedForwardIDs = []
        }
        try fileAccess.write(codec.render(tasks, carriedForwardIDs: carriedForwardIDs), to: agendaURL)
    }

    public func appendQuickNote(_ line: String) throws {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try fileAccess.appendLine(clean, to: dumpURL)
    }

    public func loadTemplates() throws -> [PlanTask] {
        guard FileManager.default.fileExists(atPath: templatesURL.path) else { return [] }
        let text = try fileAccess.read(templatesURL)
        guard let start = text.range(of: "<!-- refocus:plan"),
              let end = text.range(of: "<!-- /refocus:plan -->", range: start.lowerBound..<text.endIndex) else { return [] }
        let block = String(text[start.lowerBound..<end.upperBound])
        let synthetic = "# Today - 2000-01-01\n\n\(block)"
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: "2000-01-01") else { return [] }
        return (try? MarkdownPlanCodec(calendar: calendar).parseToday(synthetic, date: date).tasks) ?? []
    }

    public func saveTemplates(_ tasks: [PlanTask]) throws {
        let block = MarkdownPlanCodec(calendar: calendar).renderManagedBlock(tasks: tasks, profile: .standard)
        try fileAccess.write("# ReFocus Task Templates\n\n\(block)\n", to: templatesURL)
    }

    public func dailyLogURL(for date: Date) -> URL {
        let components = calendar.dateComponents([.month, .day], from: date)
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let monthIndex = max(1, min(12, components.month ?? 1)) - 1
        return vaultURL
            .appendingPathComponent("journal", isDirectory: true)
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
        guard FileManager.default.fileExists(atPath: nonNegotiablesURL.path) else { return Self.defaultStreaks }
        let text = try fileAccess.read(nonNegotiablesURL)
        let parsed = text.components(separatedBy: .newlines).compactMap { line -> StreakDefinition? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { return nil }
            let name = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return StreakDefinition(id: Self.slug(name), name: name, mode: .manual)
        }
        return parsed.isEmpty ? Self.defaultStreaks : parsed
    }

    public func setStreakValue(_ definition: StreakDefinition, status: StreakStatus, date: Date) throws {
        let definitions = try loadStreakDefinitions()
        let url = dailyLogURL(for: date)
        var text = FileManager.default.fileExists(atPath: url.path)
            ? try fileAccess.read(url)
            : initialDailyLog(date: date, streaks: definitions)
        let marker = "<!-- refocus:streak-value id=\(definition.id)"
        let checkbox = status == .win ? "x" : " "
        let replacement = "- [\(checkbox)] \(definition.name) <!-- refocus:streak-value id=\(definition.id) state=\(status.rawValue) -->"
        if let lineRange = lineRange(containing: marker, in: text) {
            text.replaceSubrange(lineRange, with: replacement)
        } else if let heading = text.range(of: "# Streaks") {
            let insertion = text[heading.upperBound...].firstIndex(of: "\n").map { text.index(after: $0) } ?? heading.upperBound
            text.insert(contentsOf: "\n\(replacement)", at: insertion)
        }
        try fileAccess.write(text, to: url)
    }

    public func updateAutomaticStreaks(date: Date, planHasMinimum: Bool? = nil) throws {
        // Non-negotiables are intentionally judged by the user as blank, win,
        // or fail. ReFocus never guesses these states automatically.
    }

    public func loadStreakSummaries(for monthDate: Date, definitions: [StreakDefinition]) throws -> [StreakSummary] {
        let range = calendar.range(of: .day, in: .month, for: monthDate) ?? 1..<2
        let today = calendar.startOfDay(for: Date())
        return definitions.map { definition in
            var statuses: [Int: StreakStatus] = [:]
            for day in range {
                var parts = calendar.dateComponents([.year, .month], from: monthDate)
                parts.day = day
                guard let date = calendar.date(from: parts), date <= today else { continue }
                let url = dailyLogURL(for: date)
                guard let text = try? fileAccess.read(url) else { continue }
                statuses[day] = streakStatus(definition, in: text)
            }
            var longest = 0
            var running = 0
            for day in range {
                if statuses[day] == .win { running += 1; longest = max(longest, running) } else { running = 0 }
            }
            let currentDay = calendar.component(.day, from: min(today, calendar.date(byAdding: .month, value: 1, to: monthDate) ?? today))
            var current = 0
            var cursor = currentDay
            while cursor >= 1 && statuses[cursor] == .win { current += 1; cursor -= 1 }
            return StreakSummary(
                definition: definition,
                current: current,
                longest: longest,
                statuses: statuses,
                totalWins: statuses.values.filter { $0 == .win }.count,
                totalFails: statuses.values.filter { $0 == .fail }.count
            )
        }
    }

    public static let defaultStreaks = [
        StreakDefinition(id: "wake-up-5-5", name: "wake up @5.5", mode: .manual),
        StreakDefinition(id: "five-harder-problems", name: "Solve five harder problems", mode: .manual),
        StreakDefinition(id: "no-food-after-8", name: "no food after 8", mode: .manual),
        StreakDefinition(id: "no-unplanned-entertainment", name: "no unplanned entertainment", mode: .manual),
        StreakDefinition(id: "no-unplanned-insta-s-11-5-return-home-wake-up", name: "no unplanned insta s", mode: .manual),
    ]

    private func initialDailyLog(date: Date, streaks: [StreakDefinition]) -> String {
        let streakLines = streaks.map {
            "- [ ] \($0.name) <!-- refocus:streak-value id=\($0.id) state=blank -->"
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

        # Mistakes

        -

        # Gains

        -

        # Streaks

        \(streakLines)
        """
    }

    private func savePlanSnapshots(
        date: Date,
        initialTasks: [PlanTask],
        modifiedTasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) throws {
        let definitions = (try? loadStreakDefinitions()) ?? Self.defaultStreaks
        let url = dailyLogURL(for: date)
        var text = FileManager.default.fileExists(atPath: url.path)
            ? try fileAccess.read(url)
            : initialDailyLog(date: date, streaks: definitions)
        let codec = MarkdownPlanCodec(calendar: calendar)
        let initialStart = "<!-- refocus:initial-plan-snapshot segment=\(segment.rawValue) -->"
        let initialEnd = "<!-- /refocus:initial-plan-snapshot segment=\(segment.rawValue) -->"
        if !text.contains(initialStart) {
            text = upsertManagedBlock(
                in: text,
                startMarker: initialStart,
                endMarker: initialEnd,
                heading: "# \(segment.title) — Initial Plan",
                body: codec.renderInitialBlock(tasks: initialTasks, profile: profile, segment: segment)
            )
        }
        let modifiedStart = "<!-- refocus:modified-plan-snapshot segment=\(segment.rawValue) -->"
        let modifiedEnd = "<!-- /refocus:modified-plan-snapshot segment=\(segment.rawValue) -->"
        text = upsertManagedBlock(
            in: text,
            startMarker: modifiedStart,
            endMarker: modifiedEnd,
            heading: "# \(segment.title) — Modified Plan",
            body: codec.renderModifiedBlock(tasks: modifiedTasks, profile: profile, segment: segment)
        )
        // A later save may include completion or timing changes to an earlier
        // block. Refresh every already-initialized Modified snapshot while
        // preserving each block's first-saved Initial snapshot.
        for earlier in PlanningSegment.allCases where earlier != segment {
            let earlierInitial = "<!-- refocus:initial-plan-snapshot segment=\(earlier.rawValue) -->"
            guard text.contains(earlierInitial) else { continue }
            text = upsertManagedBlock(
                in: text,
                startMarker: "<!-- refocus:modified-plan-snapshot segment=\(earlier.rawValue) -->",
                endMarker: "<!-- /refocus:modified-plan-snapshot segment=\(earlier.rawValue) -->",
                heading: "# \(earlier.title) — Modified Plan",
                body: codec.renderModifiedBlock(tasks: modifiedTasks, profile: profile, segment: earlier)
            )
        }
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
        guard let todayRange = sectionRange(in: text, headedBy: "# Today - \(dateText)") else { return }
        if let startRange = text.range(of: start, range: todayRange),
           let endRange = text.range(of: end, range: startRange.lowerBound..<todayRange.upperBound) {
            text.replaceSubrange(startRange.lowerBound..<endRange.upperBound, with: rendered)
        } else if let logEnd = text.range(of: "<!-- /refocus:day-log -->", range: todayRange) {
            text.insert(contentsOf: rendered + "\n\n", at: logEnd.lowerBound)
        } else {
            let block = "\n\n## Screen Break Logs\n\n<!-- refocus:day-log -->\n\(rendered)\n<!-- /refocus:day-log -->\n"
            text.insert(contentsOf: block, at: todayRange.upperBound)
        }
        try fileAccess.write(text, to: tasksURL)
    }

    private func upsertSegmentSnapshots(
        in text: String,
        heading: String,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) -> String {
        var result = text
        let codec = MarkdownPlanCodec(calendar: calendar)
        let initialStart = "<!-- refocus:initial-plan v=1 segment=\(segment.rawValue)"
        if !section(result, headedBy: heading).contains(initialStart) {
            result = insertInSection(
                codec.renderInitialBlock(tasks: tasks, profile: profile, segment: segment),
                label: "### \(segment.title) — Initial",
                in: result,
                headedBy: heading
            )
        }
        let modified = codec.renderModifiedBlock(tasks: tasks, profile: profile, segment: segment)
        let modifiedStart = "<!-- refocus:modified-plan v=1 segment=\(segment.rawValue)"
        let modifiedEnd = "<!-- /refocus:modified-plan -->"
        let scoped = sectionRange(in: result, headedBy: heading)
        if let scoped,
           let start = result.range(of: modifiedStart, range: scoped),
           let end = result.range(of: modifiedEnd, range: start.lowerBound..<scoped.upperBound) {
            result.replaceSubrange(start.lowerBound..<end.upperBound, with: modified)
        } else {
            result = insertInSection(modified, label: "### \(segment.title) — Modified", in: result, headedBy: heading)
        }
        return result
    }

    private func archiveTasksInDailyLog(_ tasksMarkdown: String, date: Date) throws {
        guard let daySection = extractTopSection(
            from: tasksMarkdown,
            heading: "# Today - \(MarkdownPlanCodec.isoDate(date, calendar: calendar))"
        ) else { return }
        let definitions = (try? loadStreakDefinitions()) ?? Self.defaultStreaks
        let url = dailyLogURL(for: date)
        var log = FileManager.default.fileExists(atPath: url.path)
            ? try fileAccess.read(url)
            : initialDailyLog(date: date, streaks: definitions)
        log = upsertManagedBlock(
            in: log,
            startMarker: "<!-- refocus:day-record -->",
            endMarker: "<!-- /refocus:day-record -->",
            heading: "# ReFocus Day Record",
            body: daySection
        )
        try fileAccess.write(log, to: url)
    }

    private func migrateIncompleteTasksToAgenda(in tasksMarkdown: String, date: Date) throws {
        guard let daySection = extractTopSection(
            from: tasksMarkdown,
            heading: "# Today - \(MarkdownPlanCodec.isoDate(date, calendar: calendar))"
        ) else { return }
        let synthetic = daySection + "\n"
        guard let plan = try? MarkdownPlanCodec(calendar: calendar).parseToday(synthetic, date: date) else { return }
        let codec = AgendaMarkdownCodec(calendar: calendar)
        let existingMarkdown = FileManager.default.fileExists(atPath: agendaURL.path)
            ? try fileAccess.read(agendaURL)
            : ""
        var entries = codec.parse(existingMarkdown)
        let carriedForwardIDs = codec.carriedForwardIDs(in: existingMarkdown)
        let existingIDs = Set(entries.map(\.id))
        let unfinished = plan.tasks.filter {
            !$0.isComplete &&
            $0.fixedRole == nil &&
            !existingIDs.contains($0.id) &&
            !carriedForwardIDs.contains($0.id)
        }
        guard !unfinished.isEmpty else { return }
        entries.append(contentsOf: unfinished.map { AgendaTask(date: date, task: $0) })
        try fileAccess.write(
            codec.render(entries, carriedForwardIDs: carriedForwardIDs.union(unfinished.map(\.id))),
            to: agendaURL
        )
    }

    private func section(_ text: String, headedBy heading: String) -> String {
        guard let range = sectionRange(in: text, headedBy: heading) else { return "" }
        return String(text[range])
    }

    private func sectionRange(in text: String, headedBy heading: String) -> Range<String.Index>? {
        guard let headingRange = text.range(of: heading) else { return nil }
        let end = text.range(of: "\n# ", range: headingRange.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return headingRange.lowerBound..<end
    }

    private func extractTopSection(from text: String, heading: String) -> String? {
        guard let range = sectionRange(in: text, headedBy: heading) else { return nil }
        return String(text[range]).trimmingCharacters(in: .newlines)
    }

    private func removingTopSection(from text: String, heading: String) -> String {
        guard let range = sectionRange(in: text, headedBy: heading) else { return text }
        var result = text
        result.removeSubrange(range)
        return result.trimmingCharacters(in: .newlines)
    }

    private func insertInSection(_ block: String, label: String, in text: String, headedBy heading: String) -> String {
        guard let scoped = sectionRange(in: text, headedBy: heading) else { return text }
        let insertion = text.range(of: "<!-- refocus:plan", range: scoped)?.lowerBound ?? scoped.upperBound
        var copy = text
        copy.insert(contentsOf: "\(label)\n\n\(block)\n\n", at: insertion)
        return copy
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

    private func streakStatus(_ definition: StreakDefinition, in text: String) -> StreakStatus {
        let marker = "refocus:streak-value id=\(definition.id)"
        guard let range = lineRange(containing: marker, in: text) else { return .blank }
        let line = String(text[range])
        if let state = metadata(in: line)["state"].flatMap(StreakStatus.init(rawValue:)) { return state }
        return line.contains("[x]") || line.contains("[X]") ? .win : .blank
    }

    private static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character(String($0)) : "-" }
        return String(scalars).split(separator: "-").joined(separator: "-")
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
