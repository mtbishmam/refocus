import Foundation
import RefocusCore

enum PersistenceError: LocalizedError {
    case missingPlan(String)

    var errorDescription: String? {
        switch self { case .missingPlan(let day): "No plan is stored for \(day)." }
    }
}

private struct AITaskRecord: Codable {
    var date: String
    var task: PlanTask
}

private struct AIContextPayload: Codable {
    var asOf: String
    var timezone: String
    var currentDate: String
    var currentTime: String
    var currentMinute: Int
    var currentPhase: String
    var currentCycleStart: String
    var nextCycleStart: String
    var currentTask: AITaskRecord?
    var selectedDate: String
    var tasks: [AITaskRecord]
    var agenda: [AITaskRecord]
    var dailyFields: [DailyFieldDefinition]
    var dailyValues: [DailyFieldValue]
}

private struct AITargetedHistoryPayload: Codable {
    var reason: String
    var taskDescriptions: [AITaskRecord]
    var dailyValues: [DailyFieldValue]
}

struct AIRequestContext: Sendable {
    var operatingManual: String
    var liveContext: String
    var targetedHistory: String?
}

actor VaultWorker {
    private let store: RefocusStore
    private let projection: ProjectionWriter
    private let vaultURL: URL
    private let calendar = WallClock.dhakaCalendar()
    private let cloud = CloudSyncClient()
    private var projectionTask: Task<Void, Never>?
    private var pendingProjectionDays: Set<String> = []
    private var pendingCaptureLines: [String] = []

    init(vaultURL: URL) throws {
        self.vaultURL = vaultURL
        store = try RefocusStore(databaseURL: RefocusStore.defaultDatabaseURL())
        projection = ProjectionWriter(vaultURL: vaultURL)

        // Markdown is imported once and then becomes a one-way projection.
        // The originals are never removed or rewritten during migration.
        if !store.isLegacyImportComplete {
            let legacy = VaultRepository(vaultURL: vaultURL)
            let now = Date()
            let importCalendar = WallClock.dhakaCalendar()
            let tomorrowDate = importCalendar.date(byAdding: .day, value: 1, to: now) ?? now
            let agenda: [AgendaTask]
            if FileManager.default.fileExists(atPath: legacy.agendaURL.path),
               let markdown = try? legacy.fileAccess.read(legacy.agendaURL) {
                agenda = AgendaMarkdownCodec(calendar: importCalendar).parse(markdown)
            } else {
                agenda = []
            }
            let appLogs = Self.readLegacyLogs(in: vaultURL.appendingPathComponent("log", isDirectory: true))
            let journalLogs = Self.readLegacyLogs(in: vaultURL.appendingPathComponent("journal", isDirectory: true))
            let legacyLogs = appLogs.merging(journalLogs) { _, journal in journal }
            let streaks = (try? legacy.loadStreakDefinitions()) ?? VaultRepository.defaultStreaks
            try Self.writeMigrationReport(
                databaseURL: RefocusStore.defaultDatabaseURL(),
                todayCount: (try? legacy.loadToday(date: now).tasks.count) ?? 0,
                tomorrowCount: (try? legacy.loadTomorrow(date: tomorrowDate).tasks.count) ?? 0,
                agendaCount: agenda.count,
                logCount: legacyLogs.count
            )
            try store.importLegacy(
                today: try? legacy.loadToday(date: now),
                tomorrow: try? legacy.loadTomorrow(date: tomorrowDate),
                agenda: agenda,
                templates: (try? legacy.loadTemplates()) ?? [],
                streaks: streaks,
                legacyLogs: legacyLogs,
                legacyFieldValues: Self.readLegacyFieldValues(logs: legacyLogs, definitions: streaks)
            )
        }
    }

    func refreshProjections() {
        let today = Date()
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        scheduleBackgroundWork(days: [today, tomorrow])
    }

    func loadToday(date: Date) throws -> TodayPlan {
        let inserted = try store.ensurePredefinedRoutineBlocks(on: date)
        if inserted { scheduleBackgroundWork(days: [date]) }
        guard let plan = try store.loadPlan(date: date) else { throw PersistenceError.missingPlan(dayKey(date)) }
        return plan
    }

    func loadTomorrow(date: Date) throws -> TodayPlan {
        let inserted = try store.ensurePredefinedRoutineBlocks(on: date)
        if inserted { scheduleBackgroundWork(days: [date]) }
        guard let plan = try store.loadPlan(date: date) else { throw PersistenceError.missingPlan(dayKey(date)) }
        return plan
    }

    func loadStreakDefinitions() throws -> [StreakDefinition] {
        try store.fieldDefinitions().filter { $0.kind == .triState }.map {
            StreakDefinition(id: $0.id, name: $0.name, mode: .manual)
        }
    }

    func loadDailyFieldDefinitions() throws -> [DailyFieldDefinition] {
        try store.fieldDefinitions()
    }

    func loadDailyFieldValues(for date: Date) throws -> [DailyFieldValue] {
        try store.fieldValues(from: date, through: date)
    }

    func loadDailyMetricHistory() throws -> [DailyFieldValue] {
        try store.allFieldValues().filter {
            ["weight", "calories", "expenses", "solved-problems", "cp-hours"].contains($0.definitionID) && !$0.value.isEmpty
        }
    }

    func loadDiff(on date: Date, now: Date) throws -> (PlanSnapshots?, FinalSnapshotAvailability) {
        (try store.planSnapshotsForDiff(on: date), try store.finalSnapshot(on: date, now: now))
    }

    func captureFinalSnapshot(on date: Date, at cutoff: Date) throws -> Bool {
        let captured = try store.captureFinalSnapshot(on: date, at: cutoff)
        if captured { scheduleBackgroundWork(days: [date]) }
        return captured
    }

    func loadDailyDashboardAnalytics(
        for date: Date, definitions: [StreakDefinition]
    ) throws -> DailyDashboardAnalytics {
        DailyAnalytics.dashboard(
            definitions: definitions,
            values: try store.allFieldValues(),
            asOf: date,
            calendar: calendar
        )
    }

    func setDailyFieldValue(_ definition: DailyFieldDefinition, value: String, date: Date) throws {
        try store.setFieldValue(definitionID: definition.id, value: value, date: date)
        scheduleBackgroundWork(days: [date])
    }

    func loadAgenda(asOf date: Date = Date()) throws -> [AgendaTask] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        let insertedToday = try store.ensurePredefinedRoutineBlocks(on: date)
        let insertedTomorrow = try store.ensurePredefinedRoutineBlocks(on: tomorrow)
        if insertedToday || insertedTomorrow { scheduleBackgroundWork(days: [date, tomorrow]) }
        return try store.agenda(asOf: date).filter {
            !calendar.isDate($0.date, inSameDayAs: date) && !calendar.isDate($0.date, inSameDayAs: tomorrow)
        }
    }

    func saveAgenda(_ tasks: [AgendaTask]) throws {
        try store.saveScheduledEntries(tasks)
        scheduleBackgroundWork(days: tasks.map(\.date))
    }

    func saveAgendaEdits(date: Date, tasks: [PlanTask], profile: DayProfileKind) throws {
        try store.saveAgendaEdits(date: date, tasks: tasks, profile: profile)
        scheduleBackgroundWork(days: [date])
    }

    func rescheduleTask(_ taskID: UUID, to date: Date) throws {
        try store.rescheduleTask(id: taskID, to: date)
        scheduleBackgroundWork(days: [date])
    }

    func rescheduleTodayTask(
        _ taskID: UUID,
        to date: Date,
        sourceDate: Date,
        remainingTasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) throws {
        try store.rescheduleTask(
            id: taskID, to: date, sourceDate: sourceDate, remainingSourceTasks: remainingTasks,
            profile: profile, segment: segment
        )
        scheduleBackgroundWork(days: [sourceDate, date])
    }

    func rescheduleTaskIntoToday(
        _ taskID: UUID,
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) throws {
        try store.rescheduleTaskIntoPlan(
            id: taskID, to: date, destinationTasks: tasks, profile: profile, segment: segment
        )
        scheduleBackgroundWork(days: [date])
    }

    func deleteTask(_ taskID: UUID) throws {
        try store.deleteTask(id: taskID)
        scheduleBackgroundWork(days: [])
    }

    func loadAIContext(on date: Date) throws -> String {
        let now = Date()
        _ = try store.ensurePredefinedRoutineBlocks(on: date)
        let dayTasks = try store.tasks(on: date)
        let lower = calendar.date(byAdding: .day, value: -30, to: date) ?? date
        let upper = calendar.date(byAdding: .day, value: 365, to: date) ?? date
        let agenda = try store.agenda(asOf: date).filter { $0.date >= lower && $0.date <= upper }
        let definitions = try store.fieldDefinitions()
        let values = try store.fieldValues(from: date, through: date)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let today = calendar.startOfDay(for: now)
        _ = try store.ensurePredefinedRoutineBlocks(on: today)
        let currentTasks = calendar.isDate(today, inSameDayAs: date) ? dayTasks : try store.tasks(on: today)
        let wallClock = WallClock(calendar: calendar)
        let snapshot = wallClock.snapshot(at: now)
        let currentMinute = wallClock.minuteOfDay(for: snapshot.cycleStart)
        let currentTask = currentTasks.first(where: { $0.contains(minuteOfDay: currentMinute) })
        let nextCycle = calendar.date(byAdding: .minute, value: 30, to: snapshot.cycleStart) ?? snapshot.phaseEnd
        let payload = AIContextPayload(
            asOf: ISO8601DateFormatter().string(from: now),
            timezone: "Asia/Dhaka",
            currentDate: dayKey(now),
            currentTime: localTime(now),
            currentMinute: wallClock.minuteOfDay(for: now),
            currentPhase: snapshot.phase.rawValue,
            currentCycleStart: localTime(snapshot.cycleStart),
            nextCycleStart: localTime(nextCycle),
            currentTask: currentTask.map { AITaskRecord(date: dayKey(today), task: $0) },
            selectedDate: dayKey(date),
            tasks: dayTasks.map { AITaskRecord(date: dayKey(date), task: $0) },
            agenda: agenda.map { AITaskRecord(date: dayKey($0.date), task: $0.task) },
            dailyFields: definitions,
            dailyValues: values
        )
        return String(data: try encoder.encode(payload), encoding: .utf8) ?? "{}"
    }

    func loadAIRequestContext(prompt: String, on date: Date) throws -> AIRequestContext {
        let operatingManual = try refreshAIContextProjection()
        let liveContext = try loadAIContext(on: date)
        return AIRequestContext(
            operatingManual: operatingManual,
            liveContext: liveContext,
            targetedHistory: try targetedAIHistory(for: prompt, on: date)
        )
    }

    func prepareAIContextProjection() throws {
        _ = try refreshAIContextProjection()
    }

    private func refreshAIContextProjection() throws -> String {
        let relativePaths = [
            "ego/ikigai.md", "ego/non-negotiables.md", "ego/goals.md",
            "ego/habits.md", "ego/universal-truths.md", "ego/gyoji.md",
            "agents/context/reapps.md",
        ]
        let sources = relativePaths.compactMap { relativePath -> ReFocusAIContextSource? in
            let url = vaultURL.appendingPathComponent(relativePath)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ReFocusAIContextSource(path: relativePath, contents: contents)
        }
        let contextURL = vaultURL.appendingPathComponent("agents/context/refocus-ai.md")
        let existing = try? String(contentsOf: contextURL, encoding: .utf8)
        guard ReFocusAIContextProjection.needsRefresh(existing, sources: sources) else {
            return existing ?? ""
        }
        let document = ReFocusAIContextProjection.render(
            sources: sources,
            corrections: ReFocusAIContextProjection.preservedCorrections(from: existing)
        )
        try FileManager.default.createDirectory(
            at: contextURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try document.write(to: contextURL, atomically: true, encoding: .utf8)
        return document
    }

    private func targetedAIHistory(for prompt: String, on date: Date) throws -> String? {
        let lower = prompt.lowercased()
        let historyTerms = [
            "history", "previous", "recent", "last ", "before", "what did", "did ",
            "better", "faster", "description", "metric", "weight", "calorie",
            "expense", "solved", "cp hour", "trend", "past",
        ]
        guard historyTerms.contains(where: lower.contains) else { return nil }

        let start = calendar.date(byAdding: .day, value: -14, to: date) ?? date
        var descriptions: [AITaskRecord] = []
        var cursor = start
        while cursor <= date, descriptions.count < 30 {
            let entries = try store.tasks(on: cursor).filter {
                !($0.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            descriptions.append(contentsOf: entries.prefix(max(0, 30 - descriptions.count)).map {
                AITaskRecord(date: dayKey(cursor), task: $0)
            })
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? date.addingTimeInterval(1)
        }
        let metricStart = calendar.date(byAdding: .day, value: -45, to: date) ?? date
        let values = try store.fieldValues(from: metricStart, through: date)
        let payload = AITargetedHistoryPayload(
            reason: "The current prompt requested recent execution or Daily history.",
            taskDescriptions: descriptions,
            dailyValues: values
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return String(data: try encoder.encode(payload), encoding: .utf8)
    }

    private func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    func searchVaultForAI(_ query: String) -> String {
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return "[]" }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return "[]" }
        var matches: [[String: String]] = []
        for case let url as URL in enumerator {
            if matches.count >= 10 { break }
            guard url.pathExtension.lowercased() == "md",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let lower = text.lowercased()
            guard terms.allSatisfy(lower.contains) else { continue }
            let first = terms.compactMap { lower.range(of: $0)?.lowerBound }.min() ?? lower.startIndex
            let start = lower.index(first, offsetBy: -500, limitedBy: lower.startIndex) ?? lower.startIndex
            let end = lower.index(first, offsetBy: 1_500, limitedBy: lower.endIndex) ?? lower.endIndex
            matches.append([
                "path": url.path.replacingOccurrences(of: vaultURL.path + "/", with: ""),
                "excerpt": String(text[start..<end]),
            ])
        }
        guard let data = try? JSONSerialization.data(withJSONObject: matches, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    func createAITask(_ arguments: AICreateTaskArguments) throws -> AgendaTask {
        let date = try parseAIDate(arguments.date)
        let minute = try parseAITime(arguments.startTime)
        let requestedKind = TaskKind(rawValue: arguments.kind ?? "normal") ?? .normal
        let cycles = max(1, min(10, arguments.cycles))
        let fallback = compactTaskDetails(title: arguments.title)
        var subtaskTitles = (arguments.subtasks ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        for candidate in fallback.subtasks where subtaskTitles.count < 3 && !subtaskTitles.contains(candidate) {
            subtaskTitles.append(candidate)
        }
        let task = PlanTask(
            title: arguments.title,
            description: arguments.description,
            startMinute: minute ?? 0,
            cycles: cycles,
            kind: cycles > 4 ? .contest : requestedKind,
            priority: arguments.priority ?? "Medium",
            difficulty: arguments.difficulty ?? "Moderate",
            mvp: arguments.mvp?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? arguments.mvp! : fallback.mvp,
            coreTasks: Array(subtaskTitles.prefix(3)).map { CoreTask(title: $0) },
            displayColor: TaskDisplayColor(rawValue: arguments.color ?? "none") ?? .none,
            quickCapture: true,
            timeAssigned: minute != nil
        )
        try validateAIWrite(task, on: date, replacing: nil)
        try store.upsertAIQuickTask(task, on: date)
        scheduleBackgroundWork(days: [date])
        guard let verified = try store.taskEntry(id: task.id) else {
            throw RefocusStoreError.corrupt("created task failed durable read-back verification")
        }
        return verified
    }

    func appendAITaskDescription(taskID: String, text: String) throws -> AgendaTask {
        guard let id = UUID(uuidString: taskID), var entry = try store.taskEntry(id: id) else {
            throw RefocusStoreError.corrupt("task to update was not found")
        }
        let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addition.isEmpty else { return entry }
        let existing = entry.task.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        entry.task.description = existing.isEmpty ? addition : existing + "\n" + addition
        try store.replaceAITask(id: id, with: entry.task, on: entry.date)
        scheduleBackgroundWork(days: [entry.date])
        guard let verified = try store.taskEntry(id: id), verified.task.description == entry.task.description else {
            throw RefocusStoreError.corrupt("task Description failed durable read-back verification")
        }
        return verified
    }

    private func compactTaskDetails(title: String) -> (mvp: String, subtasks: [String]) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            "Finish \(clean)",
            ["Open + scope", "Do \(clean)", "Check + save"]
        )
    }

    func updateAITask(_ arguments: AIUpdateTaskArguments) throws -> AgendaTask {
        guard let id = UUID(uuidString: arguments.taskID), var entry = try store.taskEntry(id: id) else {
            throw RefocusStoreError.corrupt("task to update was not found")
        }
        if let date = arguments.date { entry.date = try parseAIDate(date) }
        if let title = arguments.title { entry.task.title = title }
        if let description = arguments.description {
            entry.task.description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        }
        if let startTime = arguments.startTime {
            if startTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.task.timeAssigned = false
                entry.task.startMinute = 0
            } else {
                entry.task.startMinute = try parseAITime(startTime) ?? 0
                entry.task.timeAssigned = nil
            }
        }
        if let cycles = arguments.cycles { entry.task.cycles = max(1, min(10, cycles)) }
        if let kind = arguments.kind, let value = TaskKind(rawValue: kind) { entry.task.kind = value }
        if let priority = arguments.priority { entry.task.priority = priority }
        if let difficulty = arguments.difficulty { entry.task.difficulty = difficulty }
        if let color = arguments.color, let value = TaskDisplayColor(rawValue: color) {
            entry.task.displayColor = value == .none ? nil : value
        }
        if let mvp = arguments.mvp { entry.task.mvp = mvp }
        if let completed = arguments.completed { entry.task.isComplete = completed }
        if let subtasks = arguments.subtasks {
            entry.task.coreTasks = subtasks.map { CoreTask(title: $0.title, isComplete: $0.completed) }
        }
        entry.task.quickCapture = true
        try validateAIWrite(entry.task, on: entry.date, replacing: id)
        try store.replaceAITask(id: id, with: entry.task, on: entry.date)
        scheduleBackgroundWork(days: [entry.date])
        guard let verified = try store.taskEntry(id: id), verified.task == entry.task,
              calendar.isDate(verified.date, inSameDayAs: entry.date) else {
            throw RefocusStoreError.corrupt("updated task failed durable read-back verification")
        }
        return verified
    }

    func rescheduleAITask(_ arguments: AIRescheduleTaskArguments) throws -> AgendaTask {
        guard let id = UUID(uuidString: arguments.taskID), var entry = try store.taskEntry(id: id) else {
            throw RefocusStoreError.corrupt("task to reschedule was not found")
        }
        entry.date = try parseAIDate(arguments.date)
        if let startTime = arguments.startTime {
            if startTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.task.timeAssigned = false
                entry.task.startMinute = 0
            } else {
                entry.task.startMinute = try parseAITime(startTime) ?? 0
                entry.task.timeAssigned = nil
            }
        }
        try validateAIWrite(entry.task, on: entry.date, replacing: id)
        try store.replaceAITask(id: id, with: entry.task, on: entry.date)
        scheduleBackgroundWork(days: [entry.date])
        guard let verified = try store.taskEntry(id: id),
              verified.task.startMinute == entry.task.startMinute,
              verified.task.timeAssigned == entry.task.timeAssigned,
              calendar.isDate(verified.date, inSameDayAs: entry.date) else {
            throw RefocusStoreError.corrupt("rescheduled task failed durable read-back verification")
        }
        return verified
    }

    func setAIFieldValue(definitionID: String, value: String, dateText: String) throws -> DailyFieldValue {
        let date = try parseAIDate(dateText)
        guard try store.fieldDefinitions().contains(where: { $0.id == definitionID }) else {
            throw RefocusStoreError.corrupt("daily field was not found")
        }
        try store.setFieldValue(definitionID: definitionID, value: value, date: date)
        scheduleBackgroundWork(days: [date])
        guard let verified = try store.fieldValues(from: date, through: date).first(where: {
            $0.definitionID == definitionID && $0.value == value
        }) else {
            throw RefocusStoreError.corrupt("Daily field failed durable read-back verification")
        }
        return verified
    }

    func deleteAITaskAndVerify(_ taskID: UUID) throws {
        guard try store.taskEntry(id: taskID) != nil else {
            throw RefocusStoreError.corrupt("task to delete was not found")
        }
        try store.deleteTask(id: taskID)
        guard try store.taskEntry(id: taskID) == nil else {
            throw RefocusStoreError.corrupt("deleted task remained after durable read-back verification")
        }
        scheduleBackgroundWork(days: [])
    }

    private func validateAIWrite(_ task: PlanTask, on date: Date, replacing taskID: UUID?) throws {
        let validator = PlanValidator()
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: date)
        let existing = try store.tasks(on: date)
        let baseline = validator.validate(
            tasks: existing, profile: profile, minimumCycles: 0,
            requireFixedTasks: false, requireTaskDetails: true,
            scheduledDate: date, now: Date(), calendar: calendar
        ).filter { $0.severity == .error }.map(\.description)
        let candidate = existing.filter { current in
            if current.id == taskID { return false }
            if task.hasScheduledTime && current.isRoutineBlock
                && current.startMinute < task.endMinute && current.endMinute > task.startMinute {
                return false
            }
            return true
        } + [task]
        let resulting = validator.validate(
            tasks: candidate, profile: profile, minimumCycles: 0,
            requireFixedTasks: false, requireTaskDetails: true,
            scheduledDate: date, now: Date(), calendar: calendar
        ).filter { $0.severity == .error }.map(\.description)
        var remainingBaseline = baseline
        let introduced = resulting.filter { issue in
            if let index = remainingBaseline.firstIndex(of: issue) {
                remainingBaseline.remove(at: index)
                return false
            }
            return true
        }
        guard introduced.isEmpty else {
            throw RefocusStoreError.corrupt("planner rejected the change: \(introduced.joined(separator: " "))")
        }
    }

    private func parseAIDate(_ value: String) throws -> Date {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { throw RefocusStoreError.corrupt("date must use YYYY-MM-DD") }
        return date
    }

    private func parseAITime(_ value: String?) throws -> Int? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), [0, 30].contains(parts[1]) else {
            throw RefocusStoreError.corrupt("start_time must use a half-hour HH:mm value")
        }
        return parts[0] * 60 + parts[1]
    }

    func appendQuickNote(_ line: String, submissionID: UUID) throws {
        // Commit to SQLite immediately so the global shortcut never waits on
        // network or the cross-device export lease. Projection and cloud work
        // remain lease-protected and flush in the background.
        try store.appendCapture(line, id: submissionID.uuidString.lowercased())
        pendingCaptureLines.append(line)
        scheduleBackgroundWork(days: [])
    }

    func loadTemplates() throws -> [PlanTask] { try store.loadTemplates() }
    func saveTemplates(_ tasks: [PlanTask]) throws { try store.saveTemplates(tasks) }

    func saveToday(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment,
        expectedTasks: [PlanTask]
    ) throws {
        try store.savePlan(date: date, tasks: tasks, profile: profile, segment: segment)
        scheduleBackgroundWork(days: [date])
    }

    func saveTomorrow(date: Date, tasks: [PlanTask], profile: DayProfileKind) throws {
        try store.saveCompletePlan(date: date, tasks: tasks, profile: profile)
        scheduleBackgroundWork(days: [date])
    }

    func saveCheckIn(_ checkIn: CheckIn, streaks: [StreakDefinition]) throws {
        try store.saveCheckIn(checkIn)
        scheduleBackgroundWork(days: [checkIn.focusStart])
    }

    func screenBreakSkipCount(on date: Date) throws -> Int {
        try store.screenBreakSkipCount(on: date)
    }

    func recordScreenBreakSkip(id: String, at date: Date) throws -> Int {
        try store.recordScreenBreakSkip(id: id, at: date)
    }

    func updatePlanMinimum(date: Date, completed: Bool) throws {
        // Planning success can be represented by a user-defined daily field;
        // the old implicit Markdown streak mutation is intentionally retired.
    }

    func setStreakValue(_ definition: StreakDefinition, status: StreakStatus, date: Date) throws {
        try store.setFieldValue(definitionID: definition.id, value: status.rawValue, date: date)
        scheduleBackgroundWork(days: [date])
    }

    func streakSummaries(for date: Date, definitions: [StreakDefinition]) throws -> [StreakSummary] {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? date
        let values = try store.fieldValues(from: interval.start, through: end)
        let today = calendar.startOfDay(for: Date())
        return definitions.map { definition in
            var statuses: [Int: StreakStatus] = [:]
            for value in values where value.definitionID == definition.id {
                guard let day = parseDay(value.date), day <= today, let status = StreakStatus(rawValue: value.value) else { continue }
                statuses[calendar.component(.day, from: day)] = status
            }
            let numberOfDays = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
            var longest = 0
            var running = 0
            for day in numberOfDays {
                if statuses[day] == .win { running += 1; longest = max(longest, running) } else { running = 0 }
            }
            let currentDay = min(calendar.component(.day, from: today), numberOfDays.count)
            var current = 0
            var cursor = currentDay
            while cursor > 0, statuses[cursor] == .win { current += 1; cursor -= 1 }
            return StreakSummary(
                definition: definition, current: current, longest: longest, statuses: statuses,
                totalWins: statuses.values.filter { $0 == .win }.count,
                totalFails: statuses.values.filter { $0 == .fail }.count
            )
        }
    }

    func syncNow() async -> CloudSyncResult {
        await cloud.sync(store: store)
    }

    func connectCloudSync() async throws -> CloudSyncResult {
        try await cloud.validateConnection()
        try store.prepareCloudTarget(CloudSyncClient.targetIdentifier)
        return await cloud.sync(store: store)
    }

    private func exportTasksProjection() throws {
        try projection.exportTasks(store.agenda(asOf: Date()), asOf: Date())
    }

    private func exportDaily(_ date: Date) throws {
        let definitions = try store.fieldDefinitions()
        let analysis = try store.analysis(on: date)
        try projection.exportDailyLog(
            date: date,
            tasks: try store.tasks(on: date),
            snapshots: try store.planSnapshots(on: date),
            checkIns: try store.checkIns(on: date),
            definitions: definitions,
            values: try store.fieldValues(from: date, through: date),
            analysis: nil
        )
        if let analysis { try projection.exportJournalAnalysis(date: date, analysis: analysis) }
    }

    private func scheduleBackgroundWork(days: [Date]) {
        pendingProjectionDays.formUnion(days.map(dayKey))
        projectionTask?.cancel()
        projectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushBackgroundWork()
        }
    }

    private func flushBackgroundWork() async {
        _ = await cloud.sync(store: store)
        guard (try? await cloud.acquireExportLease(deviceID: projectionDeviceID())) == true else { return }
        let days = pendingProjectionDays.compactMap(parseDay)
        pendingProjectionDays.removeAll()
        try? exportPendingCaptures()
        try? exportTasksProjection()
        for day in days { try? exportDaily(day) }
    }

    private func exportPendingCaptures() throws {
        while let line = pendingCaptureLines.first {
            try projection.appendCapture(line)
            pendingCaptureLines.removeFirst()
        }
    }

    private func projectionDeviceID() -> String {
        if let saved = UserDefaults.standard.string(forKey: "projectionDeviceID") { return saved }
        let created = UUID().uuidString.lowercased()
        UserDefaults.standard.set(created, forKey: "projectionDeviceID")
        return created
    }

    private func dayKey(_ date: Date) -> String { MarkdownPlanCodec.isoDate(date, calendar: calendar) }
    private func parseDay(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func readLegacyLogs(in directory: URL) -> [String: String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [:] }
        var logs: [String: String] = [:]
        for file in files where file.pathExtension.lowercased() == "md" {
            guard let content = try? String(contentsOf: file, encoding: .utf8),
                  let match = content.range(of: #"(?m)^date:\s*(\d{4}-\d{2}-\d{2})\s*$"#, options: .regularExpression) else { continue }
            let line = String(content[match])
            let day = line.replacingOccurrences(of: "date:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if day.count == 10 { logs[day] = content }
        }
        return logs
    }

    private static func writeMigrationReport(
        databaseURL: URL, todayCount: Int, tomorrowCount: Int, agendaCount: Int, logCount: Int
    ) throws {
        let report: [String: Any] = [
            "mode": "dry-run-before-import",
            "sourceFilesPreserved": true,
            "todayTasks": todayCount,
            "tomorrowTasks": tomorrowCount,
            "agendaTasks": agendaCount,
            "dailyLogs": logCount,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: databaseURL.deletingLastPathComponent().appendingPathComponent("legacy-import-report.json"), options: .atomic)
    }

    private static func readLegacyFieldValues(
        logs: [String: String], definitions: [StreakDefinition]
    ) -> [DailyFieldValue] {
        var values: [DailyFieldValue] = []
        for (day, content) in logs {
            for definition in definitions {
                let marker = "refocus:streak-value id=\(definition.id) state="
                guard let range = content.range(of: marker) else { continue }
                let tail = content[range.upperBound...]
                let state = String(tail.prefix { $0 != " " && $0 != "-" && $0 != ">" })
                if StreakStatus(rawValue: state) != nil {
                    values.append(DailyFieldValue(definitionID: definition.id, date: day, value: state))
                }
            }
        }
        return values
    }
}
