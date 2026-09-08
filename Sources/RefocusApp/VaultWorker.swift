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

struct AIRequestContext: Sendable {
    var preferences: String
    var liveContext: String
}

struct AITaskWriteResult: Sendable {
    var entry: AgendaTask
    var interpretation: String?
    var affectedDates: [Date]
    var displacementReceipts: [String]
    var unscheduledTitles: [String]

    init(
        entry: AgendaTask, interpretation: String? = nil,
        affectedDates: [Date]? = nil, displacementReceipts: [String] = [],
        unscheduledTitles: [String] = []
    ) {
        self.entry = entry
        self.interpretation = interpretation
        self.affectedDates = affectedDates ?? [entry.date]
        self.displacementReceipts = displacementReceipts
        self.unscheduledTitles = unscheduledTitles
    }
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

        // Materialize the protected Rest rows as part of startup, before the
        // dashboard or AI panel is opened. This matters for the menu-bar-only
        // launch path, where no Today view may call loadToday yet.
        let today = calendar.startOfDay(for: Date())
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        _ = try store.ensurePredefinedRoutineBlocks(on: today)
        _ = try store.ensurePredefinedRoutineBlocks(on: tomorrow)
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
        // Keep the default context local to the selected plan. A different
        // date can be loaded explicitly through get_refocus_context, while a
        // year of Agenda records on every request can overwhelm the model.
        let lower = calendar.startOfDay(for: date)
        let upper = calendar.date(byAdding: .day, value: 14, to: lower) ?? lower
        let agenda = try store.agenda(asOf: date).filter { $0.date >= lower && $0.date <= upper }
        let definitions = try store.fieldDefinitions()
        let values = try store.fieldValues(from: date, through: date)
        let encoder = JSONEncoder()
        // Compact JSON is easier for the model to parse and avoids spending
        // input tokens on indentation repeated for every task and field.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let today = calendar.startOfDay(for: now)
        _ = try store.ensurePredefinedRoutineBlocks(on: today)
        let currentTasks = calendar.isDate(today, inSameDayAs: date) ? dayTasks : try store.tasks(on: today)
        let wallClock = WallClock(calendar: calendar)
        let snapshot = wallClock.snapshot(at: now)
        let currentMinute = wallClock.minuteOfDay(for: snapshot.cycleStart)
        let currentTask = currentTasks.first(where: {
            $0.hasScheduledTime && $0.contains(minuteOfDay: currentMinute)
        })
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

    func loadAIRequestContext(prompt _: String, on date: Date) throws -> AIRequestContext {
        AIRequestContext(
            preferences: try store.aiPreferences(),
            liveContext: try compactAIContext(on: date)
        )
    }

    func refreshAIWriteContext(on date: Date) throws {
        _ = try store.ensurePredefinedRoutineBlocks(on: date)
        _ = try store.tasks(on: date)
    }

    func loadAIPreferences() throws -> String { try store.aiPreferences() }

    func saveAIPreferences(_ document: String) throws -> String {
        try store.saveAIPreferences(document)
        return try store.aiPreferences()
    }

    func recordAIUsage(promptID: UUID, on date: Date, usage: AITokenUsage) throws -> AITokenUsage {
        try store.recordAIUsage(promptID: promptID, on: date, usage: usage)
        return try store.aiUsage(on: date)
    }

    func loadAIUsage(on date: Date) throws -> AITokenUsage { try store.aiUsage(on: date) }

    func unscheduledSummary(on dates: [Date]) throws -> [String] {
        var seenDays: Set<String> = []
        var lines: [String] = []
        for date in dates {
            let key = dayKey(date)
            guard seenDays.insert(key).inserted else { continue }
            for task in try store.tasks(on: date) where !task.hasScheduledTime {
                lines.append("\(key) — \(task.title)")
            }
        }
        return lines
    }

    private func compactAIContext(on date: Date) throws -> String {
        let now = Date()
        _ = try store.ensurePredefinedRoutineBlocks(on: date)
        let tasks = try store.tasks(on: date)
        let today = calendar.startOfDay(for: now)
        let currentTasks = calendar.isDate(today, inSameDayAs: date) ? tasks : try store.tasks(on: today)
        let wallClock = WallClock(calendar: calendar)
        let snapshot = wallClock.snapshot(at: now)
        let currentMinute = wallClock.minuteOfDay(for: snapshot.cycleStart)
        let currentTask = currentTasks.first(where: {
            $0.hasScheduledTime && $0.contains(minuteOfDay: currentMinute)
        })
        let nextCycle = calendar.date(byAdding: .minute, value: 30, to: snapshot.cycleStart) ?? snapshot.phaseEnd
        let taskRecords: [[String: Any]] = tasks.map { task in
            var value: [String: Any] = [
                "id": task.id.uuidString.lowercased(), "title": task.title,
                "start": task.hasScheduledTime ? task.startMinute : -1,
                "cycles": task.cycles, "complete": task.isComplete,
            ]
            if let fixedRole = task.fixedRole { value["fixed_role"] = fixedRole.rawValue }
            return value
        }
        let payload: [String: Any] = [
            "timezone": "Asia/Dhaka", "date": dayKey(now), "time": localTime(now),
            "phase": snapshot.phase.rawValue,
            "cycle_start": localTime(snapshot.cycleStart),
            "next_cycle_start": localTime(nextCycle),
            "selected_date": dayKey(date),
            "current_task_id": currentTask.map { $0.id.uuidString.lowercased() } ?? NSNull(),
            "tasks": taskRecords,
            "unscheduled": taskRecords.filter { ($0["start"] as? Int) == -1 }.compactMap { $0["title"] as? String },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    func createAITask(_ arguments: AICreateTaskArguments, prompt: String) throws -> AITaskWriteResult {
        let date = try parseAIDate(arguments.date)
        _ = try store.ensurePredefinedRoutineBlocks(on: date)
        let requestedMinute = try parseAITime(arguments.startTime)
        let requestedKind = TaskKind(rawValue: arguments.kind ?? "normal") ?? .normal
        let cycles = max(1, min(4, arguments.cycles))
        let requestedTitle = arguments.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let preserveUntimed = explicitlyRequestsUntimed(prompt)
        let allowOverride = explicitlyRequestsOverride(prompt)
        let planningIntent = hasPlanningIntent(prompt)

        if FixedPlanTasks.isRestAlias(requestedTitle) {
            guard let minute = requestedMinute,
                  let restWindow = FixedPlanTasks.restWindow(overlapping: minute, end: minute + cycles * 30),
                  minute >= restWindow.startMinute,
                  minute + cycles * 30 <= restWindow.endMinute else {
                throw RefocusStoreError.corrupt("Break means Rest. Schedule it inside 05:00–06:00, 11:00–12:00, 17:00–18:00, or 23:00–00:00.")
            }
            let existing = try store.tasks(on: date).first {
                $0.isRoutineBlock && $0.predefinedKind == .rest
                    && $0.startMinute == restWindow.startMinute
                    && $0.endMinute == restWindow.endMinute
            }
            if let existing {
                return AITaskWriteResult(
                    entry: AgendaTask(date: date, task: existing),
                    interpretation: "Interpreted \(quoted(requestedTitle)) as the protected Rest block \(MarkdownPlanCodec.time(restWindow.startMinute))–\(MarkdownPlanCodec.time(restWindow.endMinute)) and kept it in place.",
                    unscheduledTitles: try unscheduledTitles(on: date)
                )
            }
            throw RefocusStoreError.corrupt("The requested Rest block is not available for this date; add or restore the protected Rest block first.")
        }

        let existing = try store.tasks(on: date)
        let match = planningIntent ? closestExistingTask(title: requestedTitle, in: existing) : nil
        let schedulingExisting = existing.filter { $0.id != match?.id }
        var minute = requestedMinute
        var interpretation: String?
        if let requestedMinute, !allowOverride,
           let restWindow = protectedRestWindow(
               on: date, start: requestedMinute, end: requestedMinute + cycles * 30
           ) {
            guard let replacement = automaticStartTime(
                cycles: cycles,
                after: restWindow.endMinute,
                existing: schedulingExisting,
                on: date
            ) else {
                throw RefocusStoreError.corrupt("Could not move this task after protected Rest without crossing midnight.")
            }
            minute = replacement
            interpretation = "Moved this task from \(MarkdownPlanCodec.time(requestedMinute)) to \(MarkdownPlanCodec.time(replacement)) after protected Rest."
        }
        if minute == nil && !preserveUntimed && planningIntent,
           let anchor = latestExplicitUserEnd(in: schedulingExisting) {
            guard let automaticallyAllocated = automaticStartTime(
                cycles: cycles,
                after: anchor,
                existing: schedulingExisting,
                on: date
            ) else {
                throw RefocusStoreError.corrupt("Could not allocate this task after the last explicitly timed task without entering a protected Rest window or crossing midnight.")
            }
            minute = automaticallyAllocated
            interpretation = "Allocated this previously untimed task after the last explicitly timed task at \(MarkdownPlanCodec.time(automaticallyAllocated))."
        }

        if let match {
            var merged = match
            let originalTitle = match.title
            merged.description = arguments.description ?? merged.description
            if let mvp = arguments.mvp, !mvp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { merged.mvp = mvp }
            if let subtasks = arguments.subtasks, !subtasks.isEmpty {
                merged.coreTasks = Array(subtasks.prefix(3)).map { CoreTask(title: $0) }
            }
            if let priority = arguments.priority { merged.priority = priority }
            if let difficulty = arguments.difficulty { merged.difficulty = difficulty }
            if let color = arguments.color, let value = TaskDisplayColor(rawValue: color) {
                merged.displayColor = value == .none ? nil : value
            }
            merged.cycles = cycles
            merged.kind = cycles > 4 ? .contest : requestedKind
            if let minute {
                merged.startMinute = minute
                merged.timeAssigned = nil
            } else if !merged.hasScheduledTime && !preserveUntimed,
                      let anchor = latestExplicitUserEnd(in: existing.filter { $0.id != match.id }) {
                guard let automaticallyAllocated = automaticStartTime(
                    cycles: cycles,
                    after: anchor,
                    existing: existing.filter { $0.id != match.id },
                    on: date
                ) else {
                    throw RefocusStoreError.corrupt("Could not allocate this matched task after the last explicitly timed task without entering a protected Rest window or crossing midnight.")
                }
                merged.startMinute = automaticallyAllocated
                merged.timeAssigned = nil
            }
            if allowOverride { merged.routineOverride = true }
            if !allowOverride && !merged.routineOverride {
                let restInterpretation = try moveTaskOutOfProtectedRest(
                    &merged,
                    existing: existing.filter { $0.id != match.id },
                    on: date
                )
                if let restInterpretation {
                    interpretation = [interpretation, restInterpretation].compactMap { $0 }.joined(separator: " ")
                }
            }
            merged.quickCapture = true
            let authoritativeSlot = requestedMinute != nil && minute == requestedMinute
            try validateAIWrite(
                merged, on: date, replacing: match.id,
                displacingOverlaps: authoritativeSlot
            )
            let displaced = try store.replaceAITask(
                id: match.id, with: merged, on: date,
                displacingOverlaps: authoritativeSlot
            )
            scheduleBackgroundWork(days: [date])
            guard let verified = try store.taskEntry(id: match.id), verified.task == merged else {
                throw RefocusStoreError.corrupt("matched task failed durable read-back verification")
            }
            let mapping = "Interpreted \(quoted(requestedTitle)) as existing task \(quoted(originalTitle)) and merged the requested details into it."
            return AITaskWriteResult(
                entry: verified,
                interpretation: [mapping, interpretation].compactMap { $0 }.joined(separator: " "),
                displacementReceipts: displaced,
                unscheduledTitles: try unscheduledTitles(on: date)
            )
        }

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
            routineOverride: allowOverride,
            displayColor: TaskDisplayColor(rawValue: arguments.color ?? "none") ?? .none,
            quickCapture: true,
            timeAssigned: minute != nil
        )
        let authoritativeSlot = requestedMinute != nil && minute == requestedMinute
        try validateAIWrite(
            task, on: date, replacing: nil,
            displacingOverlaps: authoritativeSlot
        )
        let displaced = try store.upsertAIQuickTask(
            task, on: date, displacingOverlaps: authoritativeSlot
        )
        scheduleBackgroundWork(days: [date])
        guard let verified = try store.taskEntry(id: task.id) else {
            throw RefocusStoreError.corrupt("created task failed durable read-back verification")
        }
        return AITaskWriteResult(
            entry: verified, interpretation: interpretation,
            displacementReceipts: displaced,
            unscheduledTitles: try unscheduledTitles(on: date)
        )
    }

    private func quoted(_ value: String) -> String { "\"\(value)\"" }

    private func hasPlanningIntent(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["plan", "schedule", "task", "tasks", "give", "put", "move", "reschedule", "assign", "->"]
            .contains(where: lower.contains)
    }

    private func explicitlyRequestsUntimed(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["untimed", "without a time", "no time", "agenda only", "to agenda", "in agenda", "leave it in agenda"]
            .contains(where: lower.contains)
    }

    private func explicitlyRequestsOverride(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let denialPhrases = [
            "do not override", "don't override", "without overriding", "no override",
            "do not overwrite", "don't overwrite", "without overwriting",
            "do not bypass", "don't bypass", "without bypassing"
        ]
        guard !denialPhrases.contains(where: lower.contains) else { return false }
        let overrideMarkers = ["override", "overwrit", "overrule", "bypass", "ignore", "force"]
        guard overrideMarkers.contains(where: lower.contains) else { return false }
        let protectedScope = ["rest", "sleep", "protected", "anything", "everything", "window", "period"]
        return protectedScope.contains(where: lower.contains)
    }

    private func latestExplicitUserEnd(in tasks: [PlanTask]) -> Int? {
        tasks.filter { $0.hasScheduledTime && !$0.isRoutineBlock }
            .map(\.endMinute)
            .max()
    }

    private func unscheduledTitles(on date: Date) throws -> [String] {
        try store.tasks(on: date)
            .filter { !$0.hasScheduledTime }
            .map(\.title)
    }

    private func automaticStartTime(cycles: Int, after anchor: Int?, existing: [PlanTask], on date: Date) -> Int? {
        guard let anchor else { return nil }
        var cursor = max(0, anchor)
        while cursor + cycles * 30 <= 1440 {
            if let rest = protectedRestWindow(on: date, start: cursor, end: cursor + cycles * 30) {
                cursor = rest.endMinute
                continue
            }
            let occupied = existing.contains {
                $0.hasScheduledTime && $0.startMinute < cursor + cycles * 30 && $0.endMinute > cursor
            }
            if !occupied { return cursor }
            cursor += 30
        }
        return nil
    }

    private func moveTaskOutOfProtectedRest(_ task: inout PlanTask, existing: [PlanTask], on date: Date) throws -> String? {
        guard task.hasScheduledTime,
              let restWindow = protectedRestWindow(on: date, start: task.startMinute, end: task.endMinute)
        else { return nil }
        if FixedPlanTasks.isRestAlias(task.title),
           FixedPlanTasks.isAllowedScheduledRest(start: task.startMinute, end: task.endMinute) {
            return nil
        }
        let oldStart = task.startMinute
        guard let replacement = automaticStartTime(
            cycles: task.cycles,
            after: restWindow.endMinute,
            existing: existing,
            on: date
        ) else {
            throw RefocusStoreError.corrupt("Could not move \(task.title) after protected Rest without crossing midnight.")
        }
        task.startMinute = replacement
        task.timeAssigned = nil
        return "Moved \(quoted(task.title)) from \(MarkdownPlanCodec.time(oldStart)) to \(MarkdownPlanCodec.time(replacement)) after protected Rest."
    }

    private func protectedRestWindow(on date: Date, start: Int, end: Int, now: Date = Date()) -> RoutineWindow? {
        guard !isHistoricalInterval(on: date, endingAt: end, now: now) else { return nil }
        return FixedPlanTasks.restWindow(overlapping: start, end: end)
    }

    private func isHistoricalInterval(on date: Date, endingAt endMinute: Int, now: Date) -> Bool {
        let day = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: now)
        if day < today { return true }
        guard day == today else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let currentMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return endMinute <= currentMinute
    }

    private func closestExistingTask(title: String, in tasks: [PlanTask]) -> PlanTask? {
        let requested = taskTokens(title)
        guard requested.count >= 2 else { return nil }
        let candidates = tasks.filter { !$0.isRoutineBlock && !$0.isComplete }.compactMap { task -> (PlanTask, Int, Double)? in
            let tokens = taskTokens(task.title)
            let shared = requested.intersection(tokens).count
            let sharedNumbers = requested.intersection(tokens).filter { $0.allSatisfy(\.isNumber) }.count
            let score = Double(shared) / Double(requested.union(tokens).count)
            guard shared >= 2 || sharedNumbers >= 2 else { return nil }
            guard score >= 0.5 || sharedNumbers >= 2 else { return nil }
            return (task, shared + sharedNumbers, score + Double(sharedNumbers) * 0.05)
        }
        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.2 > $1.2
        }.first?.0
    }

    private func taskTokens(_ title: String) -> Set<String> {
        let raw = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var tokens = Set(raw)
        for token in raw where token.count > 1 {
            var letters = ""
            var digits = ""
            for character in token {
                if character.isNumber { digits.append(character) } else { letters.append(character) }
            }
            if !letters.isEmpty { tokens.insert(letters) }
            if !digits.isEmpty { tokens.insert(digits) }
        }
        return tokens
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

    func updateAITask(_ arguments: AIUpdateTaskArguments, prompt: String) throws -> AITaskWriteResult {
        guard let id = UUID(uuidString: arguments.taskID), var entry = try store.taskEntry(id: id) else {
            throw RefocusStoreError.corrupt("task to update was not found")
        }
        let sourceDate = entry.date
        if let date = arguments.date { entry.date = try parseAIDate(date) }
        if let title = arguments.title { entry.task.title = title }
        if let description = arguments.description {
            entry.task.description = description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : description
        }
        let suppliedScheduledTime = arguments.startTime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if let startTime = arguments.startTime {
            if startTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.task.timeAssigned = false
                entry.task.startMinute = 0
            } else {
                entry.task.startMinute = try parseAITime(startTime) ?? 0
                entry.task.timeAssigned = nil
            }
        }
        if let cycles = arguments.cycles { entry.task.cycles = max(1, min(4, cycles)) }
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
        let allowOverride = explicitlyRequestsOverride(prompt)
        if suppliedScheduledTime { entry.task.routineOverride = allowOverride }
        else if allowOverride { entry.task.routineOverride = true }
        var interpretation: String?
        if !allowOverride && !entry.task.routineOverride {
            interpretation = try moveTaskOutOfProtectedRest(
                &entry.task,
                existing: try store.tasks(on: entry.date).filter { $0.id != id },
                on: entry.date
            )
        }
        let authoritativeSlot = suppliedScheduledTime && interpretation == nil
        entry.task.quickCapture = true
        try validateAIWrite(
            entry.task, on: entry.date, replacing: id,
            displacingOverlaps: authoritativeSlot
        )
        let displaced = try store.replaceAITask(
            id: id, with: entry.task, on: entry.date,
            displacingOverlaps: authoritativeSlot
        )
        scheduleBackgroundWork(days: [entry.date])
        guard let verified = try store.taskEntry(id: id), verified.task == entry.task,
              calendar.isDate(verified.date, inSameDayAs: entry.date) else {
            throw RefocusStoreError.corrupt("updated task failed durable read-back verification")
        }
        return AITaskWriteResult(
            entry: verified,
            interpretation: interpretation,
            affectedDates: [sourceDate, verified.date],
            displacementReceipts: displaced,
            unscheduledTitles: try unscheduledTitles(on: verified.date)
        )
    }

    func rescheduleAITask(_ arguments: AIRescheduleTaskArguments, prompt: String) throws -> AITaskWriteResult {
        guard let id = UUID(uuidString: arguments.taskID), var entry = try store.taskEntry(id: id) else {
            throw RefocusStoreError.corrupt("task to reschedule was not found")
        }
        let sourceDate = entry.date
        entry.date = try parseAIDate(arguments.date)
        let suppliedScheduledTime = arguments.startTime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if let startTime = arguments.startTime {
            if startTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                entry.task.timeAssigned = false
                entry.task.startMinute = 0
            } else {
                entry.task.startMinute = try parseAITime(startTime) ?? 0
                entry.task.timeAssigned = nil
            }
        }
        let allowOverride = explicitlyRequestsOverride(prompt)
        if suppliedScheduledTime { entry.task.routineOverride = allowOverride }
        else if allowOverride { entry.task.routineOverride = true }
        var interpretation: String?
        if !allowOverride && !entry.task.routineOverride {
            interpretation = try moveTaskOutOfProtectedRest(
                &entry.task,
                existing: try store.tasks(on: entry.date).filter { $0.id != id },
                on: entry.date
            )
        }
        let authoritativeSlot = suppliedScheduledTime && interpretation == nil
        try validateAIWrite(
            entry.task, on: entry.date, replacing: id,
            displacingOverlaps: authoritativeSlot
        )
        let displaced = try store.replaceAITask(
            id: id, with: entry.task, on: entry.date,
            displacingOverlaps: authoritativeSlot
        )
        scheduleBackgroundWork(days: [entry.date])
        guard let verified = try store.taskEntry(id: id),
              verified.task.startMinute == entry.task.startMinute,
              verified.task.timeAssigned == entry.task.timeAssigned,
              calendar.isDate(verified.date, inSameDayAs: entry.date) else {
            throw RefocusStoreError.corrupt("rescheduled task failed durable read-back verification")
        }
        return AITaskWriteResult(
            entry: verified,
            interpretation: interpretation,
            affectedDates: [sourceDate, verified.date],
            displacementReceipts: displaced,
            unscheduledTitles: try unscheduledTitles(on: verified.date)
        )
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

    func deleteAITaskAndVerify(_ taskID: UUID) throws -> Date {
        guard let existing = try store.taskEntry(id: taskID) else {
            throw RefocusStoreError.corrupt("task to delete was not found")
        }
        try store.deleteTask(id: taskID)
        guard try store.taskEntry(id: taskID) == nil else {
            throw RefocusStoreError.corrupt("deleted task remained after durable read-back verification")
        }
        scheduleBackgroundWork(days: [])
        return existing.date
    }

    private func validateAIWrite(
        _ task: PlanTask, on date: Date, replacing taskID: UUID?,
        displacingOverlaps: Bool = false
    ) throws {
        if task.isRoutineBlock && task.predefinedKind == .rest &&
            !FixedPlanTasks.isAllowedScheduledRest(start: task.startMinute, end: task.endMinute) {
            throw RefocusStoreError.corrupt("Protected Rest blocks must remain at 05:00–06:00, 11:00–12:00, 17:00–18:00, or 23:00–00:00.")
        }
        if !task.isRoutineBlock && !task.routineOverride && task.hasScheduledTime,
           let restWindow = protectedRestWindow(on: date, start: task.startMinute, end: task.endMinute) {
            throw RefocusStoreError.corrupt("\(task.title) cannot be scheduled during protected Rest \(MarkdownPlanCodec.time(restWindow.startMinute))–\(MarkdownPlanCodec.time(restWindow.endMinute)).")
        }
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
            if displacingOverlaps && task.hasScheduledTime && current.hasScheduledTime
                && current.startMinute < task.endMinute && current.endMinute > task.startMinute {
                return false
            }
            if task.hasScheduledTime && current.isRoutineBlock
                && current.predefinedKind != .rest
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
