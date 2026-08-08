import Foundation
import RefocusCore

enum PersistenceError: LocalizedError {
    case missingPlan(String)

    var errorDescription: String? {
        switch self { case .missingPlan(let day): "No plan is stored for \(day)." }
    }
}

actor VaultWorker {
    private let store: RefocusStore
    private let projection: ProjectionWriter
    private let calendar = WallClock.dhakaCalendar()
    private let cloud = CloudSyncClient()
    private var projectionTask: Task<Void, Never>?
    private var pendingProjectionDays: Set<String> = []
    private var pendingCaptureLines: [String] = []

    init(vaultURL: URL) throws {
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

    func appendQuickNote(_ line: String, submissionID: UUID) async throws {
        guard try await cloud.acquireExportLease(deviceID: projectionDeviceID()) else {
            throw NSError(
                domain: "ReFocusCapture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Another paired device currently owns the iCloud export lease. Try again shortly."]
            )
        }
        try store.appendCapture(line, id: submissionID.uuidString.lowercased())
        try projection.appendCapture(line)
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
