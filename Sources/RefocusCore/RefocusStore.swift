import CSQLite
import Foundation

public enum RefocusStoreError: LocalizedError {
    case open(String)
    case sqlite(String)
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): "Could not open the ReFocus database: \(message)"
        case .sqlite(let message): "ReFocus database error: \(message)"
        case .corrupt(let message): "ReFocus data is invalid: \(message)"
        }
    }
}

/// The single local source of truth. A VaultWorker actor owns this object, so
/// all access is serialized without making UI callers wait for Markdown/iCloud.
public final class RefocusStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let calendar: Calendar
    private var deviceID = ""

    public init(databaseURL: URL, calendar: Calendar = WallClock.dhakaCalendar()) throws {
        self.calendar = calendar
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw RefocusStoreError.open(message)
        }
        db = handle
        sqlite3_busy_timeout(handle, 2_000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try migrate()
        try migrateFinalSnapshots()
        if let existing = try scalar("SELECT value FROM meta WHERE key = 'device_id'") {
            deviceID = existing
        } else {
            let created = UUID().uuidString.lowercased()
            try execute("INSERT INTO meta(key, value) VALUES('device_id', ?)", [.text(created)])
            deviceID = created
        }
        try migrateRenamedDefinitions()
        try migrateDailyFieldCatalog()
        try repairMissingDayPlans()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    public static func defaultDatabaseURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("ReFocus", isDirectory: true).appendingPathComponent("refocus.sqlite3")
    }

    public var isLegacyImportComplete: Bool {
        (try? scalar("SELECT value FROM meta WHERE key = 'legacy_import_v2'")) == "complete"
    }

    public func importLegacy(
        today: TodayPlan?,
        tomorrow: TodayPlan?,
        agenda: [AgendaTask],
        templates: [PlanTask],
        streaks: [StreakDefinition],
        legacyLogs: [String: String] = [:],
        legacyFieldValues: [DailyFieldValue] = []
    ) throws {
        guard !isLegacyImportComplete else { return }
        try transaction {
            if let today {
                try upsertDayPlan(today, recordOutbox: true)
            }
            if let tomorrow {
                try upsertDayPlan(tomorrow, recordOutbox: true)
            }
            for entry in agenda {
                try upsertTask(entry.task, date: entry.date, recordOutbox: true)
                try ensureDayPlan(date: entry.date)
            }
            try saveTemplatesInternal(templates)
            if !templates.isEmpty { try enqueue(kind: "templates", id: "templates", operation: "upsert", payload: try encoder.encode(templates)) }
            let existingDefinitions = streaks.enumerated().map { offset, streak in
                DailyFieldDefinition(id: streak.id, name: streak.name, kind: .triState, position: offset)
            }
            let builtIns = [
                DailyFieldDefinition(id: "weight", name: "Weight", kind: .number, unit: "kg", position: existingDefinitions.count),
                DailyFieldDefinition(id: "calories", name: "Calories", kind: .number, unit: "kcal", position: existingDefinitions.count + 1),
                DailyFieldDefinition(id: "solved-problems", name: "Solved problems", kind: .number, position: existingDefinitions.count + 2),
            ]
            for definition in existingDefinitions + builtIns {
                try upsertDefinition(definition)
                try enqueue(kind: "field_definition", id: definition.id, operation: "upsert", payload: try encoder.encode(definition))
            }
            for value in legacyFieldValues {
                try execute(
                    "INSERT OR REPLACE INTO field_values(definition_id, day, value, updated_hlc) VALUES(?, ?, ?, ?)",
                    [.text(value.definitionID), .text(value.date), .text(value.value), .text(nextHLC())]
                )
                try enqueue(kind: "field_value", id: value.id, operation: "upsert", payload: try encoder.encode(value))
            }
            for (day, content) in legacyLogs {
                try execute("INSERT OR IGNORE INTO legacy_logs(day, content) VALUES(?, ?)", [.text(day), .text(content)])
            }
            try execute("INSERT OR REPLACE INTO meta(key, value) VALUES('legacy_import_v2', 'complete')")
        }
    }

    public func loadPlan(date: Date) throws -> TodayPlan? {
        let key = dayKey(date)
        guard let row = try firstRow(
            "SELECT profile, initial_segments FROM day_plans WHERE date = ?",
            [.text(key)]
        ) else { return nil }
        let tasks = try tasks(on: date)
        let profile = DayProfileKind(rawValue: row[0] ?? "") ?? RoutineProfileResolver(calendar: calendar).profile(for: date).kind
        let segments = Set((row[1] ?? "").split(separator: ",").compactMap { PlanningSegment(rawValue: String($0)) })
        return TodayPlan(date: date, profile: profile, tasks: tasks, initialSegments: segments)
    }

    public func planSnapshots(on date: Date) throws -> PlanSnapshots? {
        guard let plan = try loadPlan(date: date) else { return nil }
        let initialByName = try snapshotMap(date: date, column: "initial_snapshots")
        let modifiedByName = try snapshotMap(date: date, column: "modified_snapshots")
        let initialTimes = try initialSnapshotTimes(date: date)
        return PlanSnapshots(
            profile: plan.profile,
            initial: Dictionary(uniqueKeysWithValues: initialByName.compactMap { key, value in
                PlanningSegment(rawValue: key).map { ($0, value) }
            }),
            modified: Dictionary(uniqueKeysWithValues: modifiedByName.compactMap { key, value in
                PlanningSegment(rawValue: key).map { ($0, value) }
            }),
            initialCapturedAt: Dictionary(uniqueKeysWithValues: initialTimes.compactMap { key, value in
                PlanningSegment(rawValue: key).map { ($0, value) }
            })
        )
    }

    /// Diff-only baseline. An unsaved Morning or Afternoon block compares
    /// against that date's deterministic predefined routine, but remains
    /// uninitialized for the planning gate. A nil capture timestamp marks the
    /// baseline as a default fallback rather than a successful user save.
    public func planSnapshotsForDiff(on date: Date) throws -> PlanSnapshots {
        let stored = try planSnapshots(on: date)
        let profile = stored?.profile ?? RoutineProfileResolver(calendar: calendar).profile(for: date).kind
        var initial = stored?.initial ?? [:]
        let defaults = PredefinedRoutineBlocks.daily(for: date, calendar: calendar)
        for segment in [PlanningSegment.morning, .afternoon] where initial[segment] == nil {
            initial[segment] = defaults.filter {
                segment.contains($0) || $0.planningCycles(in: segment) > 0
            }
        }
        return PlanSnapshots(
            profile: profile,
            initial: initial,
            modified: stored?.modified ?? [:],
            initialCapturedAt: stored?.initialCapturedAt ?? [:]
        )
    }

    @discardableResult
    public func captureFinalSnapshot(on date: Date, at cutoff: Date) throws -> Bool {
        guard calendar.isDate(date, inSameDayAs: cutoff),
              calendar.component(.hour, from: cutoff) == 20,
              calendar.component(.minute, from: cutoff) == 0 else { return false }
        var captured = false
        try transaction {
            try ensureDayPlan(date: date)
            guard try scalarBlob("SELECT final_snapshot FROM day_plans WHERE date = ?", [.text(dayKey(date))]) == nil else { return }
            let initial = try snapshotMap(date: date, column: "initial_snapshots")
            let initialIDs = Set(initial.values.flatMap { $0 }.map { $0.id.uuidString.lowercased() })
            var states: [FinalTaskSnapshot] = []
            try query("SELECT id, scheduled_date, payload, deleted FROM tasks", []) { row in
                guard let id = row.text(0), let scheduled = row.text(1), let payload = row.blob(2),
                      (scheduled == dayKey(date) || initialIDs.contains(id)),
                      let task = try? decoder.decode(PlanTask.self, from: payload) else { return }
                states.append(FinalTaskSnapshot(task: task, scheduledDate: scheduled, deleted: row.int(3) != 0))
            }
            let profile = (try loadPlan(date: date))?.profile ?? RoutineProfileResolver(calendar: calendar).profile(for: date).kind
            let snapshot = FinalPlanSnapshot(capturedAt: cutoff, profile: profile, tasks: states)
            let hlc = nextHLC()
            try execute("UPDATE day_plans SET final_snapshot = ?, final_captured_at = ?, updated_hlc = ? WHERE date = ? AND final_snapshot IS NULL",
                        [.blob(try encoder.encode(snapshot)), .double(cutoff.timeIntervalSince1970), .text(hlc), .text(dayKey(date))])
            let cloud = FinalPlanCloudRecord(snapshot: try encoder.encode(snapshot).base64EncodedString())
            try enqueue(kind: "day_plan_final", id: dayKey(date), operation: "upsert", payload: try encoder.encode(cloud), hlc: hlc)
            captured = true
        }
        return captured
    }

    public func finalSnapshot(on date: Date, now: Date) throws -> FinalSnapshotAvailability {
        if let data = try scalarBlob("SELECT final_snapshot FROM day_plans WHERE date = ?", [.text(dayKey(date))]),
           let snapshot = try? decoder.decode(FinalPlanSnapshot.self, from: data) { return .available(snapshot) }
        let day = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        if day > today || (day == today && (calendar.component(.hour, from: now) < 20)) { return .pending }
        return .unavailable
    }

    @discardableResult
    public func ensurePredefinedRoutineBlocks(on date: Date) throws -> Bool {
        var changed = false
        try transaction {
            try ensureDayPlan(date: date)
            for definition in PredefinedRoutineBlocks.daily(for: date, calendar: calendar) {
                let id = definition.id.uuidString.lowercased()
                // Include deleted rows: a user's deletion is a durable choice.
                if let deleted = try scalar("SELECT deleted FROM tasks WHERE id = ?", [.text(id)]), deleted == "1" {
                    continue
                } else if let payload = try scalarBlob("SELECT payload FROM tasks WHERE id = ?", [.text(id)]),
                          let existing = try? decoder.decode(PlanTask.self, from: payload),
                          existing.isRoutineBlock,
                          (existing.predefinedVersion ?? 0) < (definition.predefinedVersion ?? 0) {
                    try upsertTask(PredefinedRoutineBlocks.upgrade(existing, to: definition), date: date)
                    changed = true
                } else if try scalar("SELECT id FROM tasks WHERE id = ?", [.text(id)]) == nil {
                    try upsertTask(definition, date: date)
                    changed = true
                }
            }
            for retiredID in PredefinedRoutineBlocks.retiredIDs(for: date, calendar: calendar) {
                let id = retiredID.uuidString.lowercased()
                guard try scalar("SELECT deleted FROM tasks WHERE id = ?", [.text(id)]) != "1",
                      let payload = try scalarBlob("SELECT payload FROM tasks WHERE id = ?", [.text(id)]),
                      let task = try? decoder.decode(PlanTask.self, from: payload),
                      task.isRoutineBlock,
                      ["Rest", "Rest — InstaS + Bath + Food + Coffee", "5H Mashup"].contains(task.title)
                else { continue }
                try tombstoneTask(id: id)
                changed = true
            }
        }
        return changed
    }

    public func tasks(on date: Date) throws -> [PlanTask] {
        var result: [PlanTask] = []
        try query(
            "SELECT payload FROM tasks WHERE scheduled_date = ? AND deleted = 0 ORDER BY start_minute, title COLLATE NOCASE",
            [.text(dayKey(date))]
        ) { row in
            guard let payload = row.blob(0) else { throw RefocusStoreError.corrupt("task payload missing") }
            result.append(try decoder.decode(PlanTask.self, from: payload))
        }
        return result
    }

    public func agenda(asOf date: Date) throws -> [AgendaTask] {
        var result: [AgendaTask] = []
        try query(
            "SELECT scheduled_date, payload FROM tasks WHERE deleted = 0 AND fixed_role IS NULL ORDER BY scheduled_date, start_minute, title COLLATE NOCASE"
        ) { row in
            guard let dateText = row.text(0), let scheduled = parseDay(dateText), let payload = row.blob(1) else { return }
            let task = try decoder.decode(PlanTask.self, from: payload)
            guard !task.isRoutineBlock else { return }
            result.append(AgendaTask(date: scheduled, task: task))
        }
        return result
    }

    public func savePlan(date: Date, tasks: [PlanTask], profile: DayProfileKind, segment: PlanningSegment) throws {
        try transaction {
            let existingIDs = Set(try taskIDs(on: date))
            let incomingIDs = Set(tasks.map { $0.id.uuidString.lowercased() })
            for staleID in existingIDs.subtracting(incomingIDs) { try tombstoneTask(id: staleID) }
            for task in tasks { try upsertTask(task, date: date) }
            try updatePlanMetadata(date: date, tasks: tasks, profile: profile, segment: segment)
        }
    }

    public func saveCompletePlan(date: Date, tasks: [PlanTask], profile: DayProfileKind) throws {
        try transaction {
            let existingIDs = Set(try taskIDs(on: date))
            let incomingIDs = Set(tasks.map { $0.id.uuidString.lowercased() })
            for staleID in existingIDs.subtracting(incomingIDs) { try tombstoneTask(id: staleID) }
            for task in tasks { try upsertTask(task, date: date) }
            var initial = try snapshotMap(date: date, column: "initial_snapshots")
            var initialTimes = try initialSnapshotTimes(date: date)
            let savedAt = Date()
            for segment in PlanningSegment.allCases where initial[segment.rawValue] == nil {
                initial[segment.rawValue] = tasks.filter {
                    segment.contains($0) || $0.planningCycles(in: segment) > 0
                }
                initialTimes[segment.rawValue] = savedAt
            }
            let modified = Dictionary(uniqueKeysWithValues: PlanningSegment.allCases.map {
                ($0.rawValue, tasks.filter($0.contains))
            })
            try execute(
                """
                INSERT INTO day_plans(date, profile, initial_segments, initial_snapshots, modified_snapshots, initial_snapshot_times, updated_hlc)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(date) DO UPDATE SET profile=excluded.profile,
                  initial_segments=excluded.initial_segments, initial_snapshots=excluded.initial_snapshots,
                  modified_snapshots=excluded.modified_snapshots, initial_snapshot_times=excluded.initial_snapshot_times,
                  updated_hlc=excluded.updated_hlc
                """,
                [.text(dayKey(date)), .text(profile.rawValue),
                 .text(PlanningSegment.allCases.map(\.rawValue).joined(separator: ",")),
                 .blob(try encoder.encode(initial)), .blob(try encoder.encode(modified)),
                 .blob(try encoder.encode(initialTimes)), .text(nextHLC())]
            )
            try enqueueDayPlanRecord(date: date, profile: profile, initial: initial, modified: modified, initialTimes: initialTimes)
        }
    }

    public func saveScheduledEntries(_ entries: [AgendaTask]) throws {
        try transaction {
            for entry in entries {
                try upsertTask(entry.task, date: entry.date)
                try ensureDayPlan(date: entry.date)
            }
        }
    }

    /// Persists edits made from Agenda immediately without requiring the full
    /// Today/Tomorrow planning form to be valid. Initial snapshots remain
    /// immutable; initialized Modified snapshots follow the latest task rows.
    public func saveAgendaEdits(date: Date, tasks: [PlanTask], profile: DayProfileKind) throws {
        try transaction {
            try ensureDayPlan(date: date)
            let existingIDs = Set(try taskIDs(on: date))
            let incomingIDs = Set(tasks.map { $0.id.uuidString.lowercased() })
            for staleID in existingIDs.subtracting(incomingIDs) {
                try tombstoneTask(id: staleID)
            }
            for task in tasks { try upsertTask(task, date: date) }
            try refreshPlanMetadata(date: date, tasks: tasks, profile: profile, segment: .morning)
        }
    }

    public func rescheduleTask(id: UUID, to date: Date) throws {
        let idText = id.uuidString.lowercased()
        try transaction {
            guard let row = try firstRow("SELECT payload FROM tasks WHERE id = ? AND deleted = 0", [.text(idText)]),
                  let encoded = row[0].flatMap({ Data(base64Encoded: $0) }) else {
                throw RefocusStoreError.corrupt("task to reschedule was not found")
            }
            let task = try decoder.decode(PlanTask.self, from: encoded)
            try upsertTask(task, date: date)
            try ensureDayPlan(date: date)
        }
    }

    public func rescheduleTask(
        id: UUID,
        to destination: Date,
        sourceDate: Date,
        remainingSourceTasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) throws {
        let idText = id.uuidString.lowercased()
        try transaction {
            guard let row = try firstRow("SELECT payload FROM tasks WHERE id = ? AND deleted = 0", [.text(idText)]),
                  let encoded = row[0].flatMap({ Data(base64Encoded: $0) }) else {
                throw RefocusStoreError.corrupt("task to reschedule was not found")
            }
            let task = try decoder.decode(PlanTask.self, from: encoded)
            try upsertTask(task, date: destination)
            try ensureDayPlan(date: destination)
            try updatePlanMetadata(date: sourceDate, tasks: remainingSourceTasks, profile: profile, segment: segment)
        }
    }

    public func rescheduleTaskIntoPlan(
        id: UUID,
        to destination: Date,
        destinationTasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) throws {
        let idText = id.uuidString.lowercased()
        try transaction {
            guard let row = try firstRow("SELECT payload FROM tasks WHERE id = ? AND deleted = 0", [.text(idText)]),
                  let encoded = row[0].flatMap({ Data(base64Encoded: $0) }) else {
                throw RefocusStoreError.corrupt("task to reschedule was not found")
            }
            let persistedTask = try decoder.decode(PlanTask.self, from: encoded)
            let movedTask = destinationTasks.first(where: { $0.id == id }) ?? persistedTask
            try upsertTask(movedTask, date: destination)
            try refreshPlanMetadata(
                date: destination, tasks: destinationTasks, profile: profile, segment: segment
            )
        }
    }

    public func deleteTask(id: UUID) throws {
        try transaction { try tombstoneTask(id: id.uuidString.lowercased()) }
    }

    public func loadTemplates() throws -> [PlanTask] {
        guard let value = try scalar("SELECT value FROM meta WHERE key = 'templates'"),
              let data = Data(base64Encoded: value) else { return [] }
        return try decoder.decode([PlanTask].self, from: data)
    }

    public func saveTemplates(_ templates: [PlanTask]) throws {
        try transaction {
            try saveTemplatesInternal(templates)
            try enqueue(kind: "templates", id: "templates", operation: "upsert", payload: try encoder.encode(templates))
        }
    }

    public func appendCapture(_ text: String, id: String = UUID().uuidString.lowercased(), at date: Date = Date()) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        try transaction {
            guard try scalar("SELECT id FROM captures WHERE id = ?", [.text(id)]) == nil else { return }
            try execute("INSERT INTO captures(id, text, created_at, updated_hlc) VALUES(?, ?, ?, ?)",
                        [.text(id), .text(clean), .double(date.timeIntervalSince1970), .text(nextHLC())])
            try enqueue(kind: "capture", id: id, operation: "upsert", payload: Data(clean.utf8))
        }
    }

    public func saveCheckIn(_ checkIn: CheckIn) throws {
        try transaction {
            let data = try encoder.encode(checkIn)
            try execute(
                "INSERT OR REPLACE INTO check_ins(id, day, payload, updated_hlc) VALUES(?, ?, ?, ?)",
                [.text(checkIn.id), .text(dayKey(checkIn.focusStart)), .blob(data), .text(nextHLC())]
            )
            try enqueue(kind: "check_in", id: checkIn.id, operation: "upsert", payload: data)
        }
    }

    public func checkIns(on date: Date) throws -> [CheckIn] {
        var result: [CheckIn] = []
        try query("SELECT payload FROM check_ins WHERE day = ? ORDER BY id", [.text(dayKey(date))]) { row in
            if let data = row.blob(0) { result.append(try decoder.decode(CheckIn.self, from: data)) }
        }
        return result
    }

    public func fieldDefinitions() throws -> [DailyFieldDefinition] {
        var result: [DailyFieldDefinition] = []
        try query("SELECT id, name, kind, unit, position, success_rule FROM field_definitions WHERE archived = 0 ORDER BY position, name") { row in
            guard let id = row.text(0), let name = row.text(1), let kindText = row.text(2), let kind = DailyFieldKind(rawValue: kindText) else { return }
            result.append(DailyFieldDefinition(id: id, name: name, kind: kind, unit: row.text(3), position: row.int(4), successRule: row.text(5)))
        }
        return result
    }

    public func setFieldValue(definitionID: String, value: String, date: Date) throws {
        let key = dayKey(date)
        try transaction {
            try execute(
                """
                INSERT INTO field_values(definition_id, day, value, updated_hlc) VALUES(?, ?, ?, ?)
                ON CONFLICT(definition_id, day) DO UPDATE SET value=excluded.value, updated_hlc=excluded.updated_hlc
                """,
                [.text(definitionID), .text(key), .text(value), .text(nextHLC())]
            )
            let payload = try encoder.encode(DailyFieldValue(definitionID: definitionID, date: key, value: value))
            try enqueue(kind: "field_value", id: "\(definitionID):\(key)", operation: "upsert", payload: payload)
        }
    }

    public func fieldValues(from start: Date, through end: Date) throws -> [DailyFieldValue] {
        var result: [DailyFieldValue] = []
        try query(
            "SELECT definition_id, day, value FROM field_values WHERE day >= ? AND day <= ? ORDER BY day, definition_id",
            [.text(dayKey(start)), .text(dayKey(end))]
        ) { row in
            guard let definitionID = row.text(0), let day = row.text(1), let value = row.text(2) else { return }
            result.append(DailyFieldValue(definitionID: definitionID, date: day, value: value))
        }
        return result
    }

    public func allFieldValues() throws -> [DailyFieldValue] {
        var result: [DailyFieldValue] = []
        try query("SELECT definition_id, day, value FROM field_values ORDER BY day, definition_id") { row in
            guard let definitionID = row.text(0), let day = row.text(1), let value = row.text(2) else { return }
            result.append(DailyFieldValue(definitionID: definitionID, date: day, value: value))
        }
        return result
    }

    public func saveAnalysis(_ analysis: DayAnalysis, date: Date) throws {
        let data = try encoder.encode(analysis)
        try transaction {
            try execute("INSERT OR REPLACE INTO day_analysis(day, payload, updated_hlc) VALUES(?, ?, ?)",
                        [.text(dayKey(date)), .blob(data), .text(nextHLC())])
            try enqueue(kind: "day_analysis", id: dayKey(date), operation: "upsert", payload: data)
        }
    }

    public func analysis(on date: Date) throws -> DayAnalysis? {
        guard let value = try scalarBlob("SELECT payload FROM day_analysis WHERE day = ?", [.text(dayKey(date))]) else { return nil }
        return try decoder.decode(DayAnalysis.self, from: value)
    }

    public func pendingMutations(limit: Int = 200) throws -> [Data] {
        var payloads: [Data] = []
        try query("SELECT payload FROM outbox ORDER BY sequence LIMIT ?", [.integer(limit)]) { row in
            if let data = row.blob(0) { payloads.append(normalizedMutationPayload(data)) }
        }
        return payloads
    }

    public func acknowledgeMutations(_ mutationIDs: [String]) throws {
        guard !mutationIDs.isEmpty else { return }
        try transaction {
            for id in mutationIDs { try execute("DELETE FROM outbox WHERE mutation_id = ?", [.text(id)]) }
        }
    }

    /// Stages a complete authoritative snapshot when pairing this local store
    /// with a different cloud deployment. This avoids depending on already
    /// acknowledged outbox entries from the previous D1 database.
    @discardableResult
    public func prepareCloudTarget(_ target: String) throws -> Int {
        guard try scalar("SELECT value FROM meta WHERE key = 'cloud_sync_target'") != target else { return 0 }

        var seed: [SeedMutation] = []
        try query("SELECT id, scheduled_date, payload, deleted, updated_hlc FROM tasks ORDER BY id") { row in
            guard let id = row.text(0), let dateText = row.text(1), let payload = row.blob(2),
                  let task = try? decoder.decode(PlanTask.self, from: payload) else { return }
            let deleted = row.int(3) != 0
            seed.append(SeedMutation(
                kind: "task", id: id, operation: deleted ? "delete" : "upsert",
                payload: deleted ? Data() : try taskSyncPayload(task, date: parseDay(dateText) ?? Date()),
                hlc: row.text(4)
            ))
        }
        try query(
            "SELECT date, profile, initial_segments, initial_snapshots, modified_snapshots, updated_hlc, initial_snapshot_times, final_snapshot FROM day_plans ORDER BY date"
        ) { row in
            guard let day = row.text(0), let profile = row.text(1),
                  let initialData = row.blob(3), let modifiedData = row.blob(4) else { return }
            let initial = (try? decoder.decode([String: [PlanTask]].self, from: initialData)) ?? [:]
            let modified = (try? decoder.decode([String: [PlanTask]].self, from: modifiedData)) ?? [:]
            let record = DayPlanCloudRecord(
                date: day, profile: profile,
                initialSegments: (row.text(2) ?? "").split(separator: ",").map(String.init),
                initialSnapshots: initial, modifiedSnapshots: modified,
                initialSnapshotTimes: row.blob(6).flatMap { try? decoder.decode([String: Date].self, from: $0) } ?? [:]
            )
            seed.append(SeedMutation(
                kind: "day_plan", id: day, operation: "upsert",
                payload: try encoder.encode(record), hlc: row.text(5)
            ))
            if let finalData = row.blob(7) {
                seed.append(SeedMutation(
                    kind: "day_plan_final", id: day, operation: "upsert",
                    payload: try encoder.encode(FinalPlanCloudRecord(snapshot: finalData.base64EncodedString())), hlc: row.text(5)
                ))
            }
        }
        try query("SELECT id, payload, updated_hlc FROM check_ins ORDER BY id") { row in
            guard let id = row.text(0), let payload = row.blob(1) else { return }
            seed.append(SeedMutation(kind: "check_in", id: id, operation: "upsert", payload: payload, hlc: row.text(2)))
        }
        try query("SELECT id, text, created_at, updated_hlc FROM captures ORDER BY created_at, id") { row in
            guard let id = row.text(0), let capture = row.text(1) else { return }
            let payload = try JSONSerialization.data(withJSONObject: ["text": capture, "createdAt": row.text(2) ?? ""])
            seed.append(SeedMutation(kind: "capture", id: id, operation: "upsert", payload: payload, hlc: row.text(3)))
        }
        try query("SELECT id, name, kind, unit, position, success_rule, archived FROM field_definitions ORDER BY position, id") { row in
            guard let id = row.text(0), let name = row.text(1), let kindText = row.text(2),
                  let kind = DailyFieldKind(rawValue: kindText) else { return }
            let definition = DailyFieldDefinition(
                id: id, name: name, kind: kind, unit: row.text(3), position: row.int(4), successRule: row.text(5)
            )
            seed.append(SeedMutation(
                kind: "field_definition", id: id,
                operation: row.int(6) == 0 ? "upsert" : "delete",
                payload: try encoder.encode(definition), hlc: nil
            ))
        }
        try query("SELECT definition_id, day, value, updated_hlc FROM field_values ORDER BY day, definition_id") { row in
            guard let definitionID = row.text(0), let day = row.text(1), let value = row.text(2) else { return }
            let fieldValue = DailyFieldValue(definitionID: definitionID, date: day, value: value)
            seed.append(SeedMutation(
                kind: "field_value", id: "\(definitionID):\(day)", operation: "upsert",
                payload: try encoder.encode(fieldValue), hlc: row.text(3)
            ))
        }
        try query("SELECT day, payload, updated_hlc FROM day_analysis ORDER BY day") { row in
            guard let day = row.text(0), let payload = row.blob(1) else { return }
            seed.append(SeedMutation(kind: "day_analysis", id: day, operation: "upsert", payload: payload, hlc: row.text(2)))
        }
        if let encodedTemplates = try scalar("SELECT value FROM meta WHERE key = 'templates'"),
           let payload = Data(base64Encoded: encodedTemplates) {
            seed.append(SeedMutation(kind: "templates", id: "templates", operation: "upsert", payload: payload, hlc: nil))
        }

        try transaction {
            try execute("DELETE FROM outbox")
            for record in seed {
                try enqueue(
                    kind: record.kind, id: record.id, operation: record.operation,
                    payload: record.payload, hlc: record.hlc
                )
            }
            try execute(
                "INSERT OR REPLACE INTO meta(key, value) VALUES('cloud_sync_target', ?)",
                [.text(target)]
            )
        }
        return seed.count
    }

    public func applyRemotePull(_ data: Data) throws {
        let response = try decoder.decode(RemotePull.self, from: data)
        try transaction {
            for entity in response.entities {
                let remoteHLC = entity.clocks.values.map(\.hlc).max() ?? ""
                let pendingClocks = try pendingFieldClocks(kind: entity.kind, id: entity.id)
                if entity.fields["_deleted"]?.boolValue == true {
                    if let pending = pendingClocks["_deleted"], pending.hlc > remoteHLC { continue }
                    switch entity.kind {
                    case "task":
                        try execute("UPDATE tasks SET deleted = 1, updated_hlc = ? WHERE id = ?", [.text(remoteHLC), .text(entity.id.lowercased())])
                    case "field_definition":
                        // Retire the definition without cascading into its
                        // historical values; archived habit/metric data stays
                        // available for migration and analysis.
                        try execute("UPDATE field_definitions SET archived = 1 WHERE id = ?", [.text(entity.id)])
                    default:
                        break
                    }
                    continue
                }
                switch entity.kind {
                case "task":
                    var fields: [String: JSONValue] = [:]
                    if let localPayload = try scalarBlob(
                        "SELECT payload FROM tasks WHERE id = ? AND deleted = 0", [.text(entity.id.lowercased())]
                    ), let localTask = try? decoder.decode(PlanTask.self, from: localPayload),
                       let localDate = try scalar("SELECT scheduled_date FROM tasks WHERE id = ?", [.text(entity.id.lowercased())]) {
                        fields = try taskSyncFieldsJSON(localTask, dateText: localDate)
                    }
                    for (field, value) in entity.fields {
                        guard let remoteClock = entity.clocks[field] else { continue }
                        if let pending = pendingClocks[field], !clock(remoteClock, isLaterThan: pending) { continue }
                        fields[field] = value
                    }
                    guard let id = UUID(uuidString: entity.id),
                          let title = fields["title"]?.stringValue,
                          let dateText = fields["date"]?.stringValue,
                          let scheduled = parseDay(dateText) else { continue }
                    let time = fields["time"]?.stringValue ?? "09:00"
                    let parts = time.split(separator: ":").compactMap { Int($0) }
                    let start = parts.count == 2 ? parts[0] * 60 + parts[1] : 540
                    let subtasks = fields["subtasks"]?.arrayValue?.compactMap { value -> CoreTask? in
                        guard let item = value.objectValue, let name = item["title"]?.stringValue else { return nil }
                        return CoreTask(title: name, isComplete: item["complete"]?.boolValue ?? false)
                    } ?? []
                    let task = PlanTask(
                        id: id, title: title, startMinute: start, cycles: fields["cycles"]?.intValue ?? 1,
                        kind: TaskKind(rawValue: fields["kind"]?.stringValue ?? "normal") ?? .normal,
                        priority: fields["priority"]?.stringValue ?? "Medium",
                        difficulty: fields["difficulty"]?.stringValue ?? "Moderate",
                        mvp: fields["mvp"]?.stringValue ?? "", coreTasks: subtasks,
                        isComplete: fields["complete"]?.boolValue ?? false,
                        fixedRole: fields["fixedRole"]?.stringValue.flatMap(FixedTaskRole.init(rawValue:)),
                        routineOverride: fields["routineOverride"]?.boolValue ?? false,
                        routineBlock: fields["routineBlock"]?.boolValue ?? false,
                        durationMinutes: fields["durationMinutes"]?.intValue,
                        displayColor: TaskDisplayColor(rawValue: fields["displayColor"]?.stringValue ?? "none") ?? .none,
                        predefinedKind: fields["predefinedKind"]?.stringValue.flatMap(PredefinedBlockKind.init(rawValue:)),
                        predefinedKey: fields["predefinedKey"]?.stringValue,
                        predefinedVersion: fields["predefinedVersion"]?.intValue,
                        quickCapture: fields["quickCapture"]?.boolValue ?? false,
                        timeAssigned: fields["hasScheduledTime"]?.boolValue ?? (fields["time"]?.stringValue != nil)
                    )
                    try upsertTask(task, date: scheduled, recordOutbox: false)
                    let mergedHLC = ([remoteHLC] + pendingClocks.values.map(\.hlc)).max() ?? remoteHLC
                    try execute("UPDATE tasks SET updated_hlc = ? WHERE id = ?", [.text(mergedHLC), .text(entity.id.lowercased())])
                    if try scalar("SELECT date FROM day_plans WHERE date = ?", [.text(dateText)]) == nil {
                        let empty = try encoder.encode([String: [PlanTask]]())
                        let profile = RoutineProfileResolver(calendar: calendar).profile(for: scheduled).kind.rawValue
                        try execute(
                            "INSERT INTO day_plans(date, profile, initial_segments, initial_snapshots, modified_snapshots, updated_hlc) VALUES(?, ?, '', ?, ?, ?)",
                            [.text(dateText), .text(profile), .blob(empty), .blob(empty), .text(remoteHLC)]
                        )
                    }
                case "field_value":
                    guard let definition = entity.fields["definitionKey"]?.stringValue ?? entity.fields["definitionID"]?.stringValue,
                          let day = entity.fields["date"]?.stringValue,
                          let value = entity.fields["value"]?.stringValue else { continue }
                    try execute(
                        "INSERT OR REPLACE INTO field_values(definition_id, day, value, updated_hlc) VALUES(?, ?, ?, ?)",
                        [.text(definition), .text(day), .text(value), .text(remoteHLC)]
                    )
                case "field_definition":
                    guard HabitCatalog.aliases[entity.id] == nil else { continue }
                    guard let name = entity.fields["name"]?.stringValue else { continue }
                    try upsertDefinition(DailyFieldDefinition(
                        id: entity.id, name: name,
                        kind: DailyFieldKind(rawValue: entity.fields["kind"]?.stringValue ?? "text") ?? .text,
                        unit: entity.fields["unit"]?.stringValue,
                        position: entity.fields["position"]?.intValue ?? 0
                    ))
                case "day_plan_final":
                    guard try scalarBlob("SELECT final_snapshot FROM day_plans WHERE date = ?", [.text(entity.id)]) == nil,
                          let encoded = entity.fields["snapshot"]?.stringValue,
                          let data = Data(base64Encoded: encoded),
                          let snapshot = try? decoder.decode(FinalPlanSnapshot.self, from: data),
                          parseDay(entity.id) != nil else { continue }
                    try ensureDayPlan(date: parseDay(entity.id)!)
                    try execute(
                        "UPDATE day_plans SET final_snapshot = ?, final_captured_at = ?, updated_hlc = ? WHERE date = ? AND final_snapshot IS NULL",
                        [.blob(data), .double(snapshot.capturedAt.timeIntervalSince1970), .text(remoteHLC), .text(entity.id)]
                    )
                case "day_plan":
                    guard let scheduled = parseDay(entity.id),
                          let payload = try? encoder.encode(entity.fields),
                          let remote = try? decoder.decode(DayPlanCloudRecord.self, from: payload) else { continue }
                    try ensureDayPlan(date: scheduled)
                    var initial = try snapshotMap(date: scheduled, column: "initial_snapshots")
                    var modified = try snapshotMap(date: scheduled, column: "modified_snapshots")
                    var initialTimes = try initialSnapshotTimes(date: scheduled)
                    for (segment, tasks) in remote.initialSnapshots where initial[segment] == nil { initial[segment] = tasks }
                    for (segment, timestamp) in remote.initialSnapshotTimes ?? [:] where initialTimes[segment] == nil { initialTimes[segment] = timestamp }
                    if let clock = entity.clocks["modifiedSnapshots"],
                       pendingClocks["modifiedSnapshots"].map({ self.clock(clock, isLaterThan: $0) }) ?? true {
                        modified = remote.modifiedSnapshots
                    }
                    let profile = DayProfileKind(rawValue: remote.profile) ?? RoutineProfileResolver(calendar: calendar).profile(for: scheduled).kind
                    let initialized = PlanningSegment.allCases.filter { initial[$0.rawValue] != nil }.map(\.rawValue).joined(separator: ",")
                    try execute(
                        "UPDATE day_plans SET profile = ?, initial_segments = ?, initial_snapshots = ?, modified_snapshots = ?, initial_snapshot_times = ?, updated_hlc = ? WHERE date = ?",
                        [.text(profile.rawValue), .text(initialized), .blob(try encoder.encode(initial)), .blob(try encoder.encode(modified)),
                         .blob(try encoder.encode(initialTimes)), .text(remoteHLC), .text(entity.id)]
                    )
                default: continue
                }
            }
        }
    }

    private func migrate() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS tasks(
              id TEXT PRIMARY KEY, scheduled_date TEXT NOT NULL, title TEXT NOT NULL,
              start_minute INTEGER NOT NULL, fixed_role TEXT, payload BLOB NOT NULL,
              deleted INTEGER NOT NULL DEFAULT 0, updated_hlc TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS tasks_schedule ON tasks(scheduled_date, deleted, start_minute);
            CREATE TABLE IF NOT EXISTS day_plans(
              date TEXT PRIMARY KEY, profile TEXT NOT NULL, initial_segments TEXT NOT NULL DEFAULT '',
              initial_snapshots BLOB NOT NULL, modified_snapshots BLOB NOT NULL, updated_hlc TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS check_ins(id TEXT PRIMARY KEY, day TEXT NOT NULL, payload BLOB NOT NULL, updated_hlc TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS check_ins_day ON check_ins(day);
            CREATE TABLE IF NOT EXISTS captures(id TEXT PRIMARY KEY, text TEXT NOT NULL, created_at REAL NOT NULL, updated_hlc TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS field_definitions(
              id TEXT PRIMARY KEY, name TEXT NOT NULL, kind TEXT NOT NULL, unit TEXT,
              position INTEGER NOT NULL, success_rule TEXT, archived INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS field_values(
              definition_id TEXT NOT NULL REFERENCES field_definitions(id), day TEXT NOT NULL,
              value TEXT NOT NULL, updated_hlc TEXT NOT NULL, PRIMARY KEY(definition_id, day)
            );
            CREATE INDEX IF NOT EXISTS field_values_day ON field_values(day);
            CREATE TABLE IF NOT EXISTS day_analysis(day TEXT PRIMARY KEY, payload BLOB NOT NULL, updated_hlc TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS legacy_logs(day TEXT PRIMARY KEY, content TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS outbox(
              sequence INTEGER PRIMARY KEY AUTOINCREMENT, mutation_id TEXT NOT NULL UNIQUE,
              entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL, operation TEXT NOT NULL,
              hlc TEXT NOT NULL, payload BLOB NOT NULL, created_at REAL NOT NULL
            );
            """
        )
    }

    private func migrateFinalSnapshots() throws {
        if try scalar("SELECT COUNT(*) FROM pragma_table_info('day_plans') WHERE name = 'final_snapshot'") == "0" {
            try execute("ALTER TABLE day_plans ADD COLUMN final_snapshot BLOB")
        }
        if try scalar("SELECT COUNT(*) FROM pragma_table_info('day_plans') WHERE name = 'final_captured_at'") == "0" {
            try execute("ALTER TABLE day_plans ADD COLUMN final_captured_at REAL")
        }
        if try scalar("SELECT COUNT(*) FROM pragma_table_info('day_plans') WHERE name = 'initial_snapshot_times'") == "0" {
            try execute("ALTER TABLE day_plans ADD COLUMN initial_snapshot_times BLOB")
        }
    }

    private func migrateRenamedDefinitions() throws {
        let id = "no-unplanned-insta-s-11-5-return-home-wake-up"
        guard var definition = try fieldDefinitions().first(where: { $0.id == id }),
              definition.name != "no unplanned insta s" else { return }
        definition.name = "no unplanned insta s"
        try transaction {
            try upsertDefinition(definition)
            try enqueue(
                kind: "field_definition", id: id, operation: "upsert",
                payload: try encoder.encode(definition)
            )
        }
    }

    private func migrateDailyFieldCatalog() throws {
        let canonical = HabitCatalog.entries.enumerated().map { offset, habit in
            DailyFieldDefinition(id: habit.id, name: habit.name, kind: .triState, position: offset)
        } + [
            DailyFieldDefinition(id: "weight", name: "Weight", kind: .number, unit: "kg", position: 100),
            DailyFieldDefinition(id: "calories", name: "Calories", kind: .number, unit: "kcal", position: 101),
            DailyFieldDefinition(id: "solved-problems", name: "Solved problems", kind: .number, position: 102),
        ]

        try transaction {
            for definition in canonical {
                let existing = try firstRow(
                    "SELECT name, kind, unit, position, success_rule, archived FROM field_definitions WHERE id = ?",
                    [.text(definition.id)]
                )
                let needsUpdate = existing == nil
                    || existing?[0] != definition.name
                    || existing?[1] != definition.kind.rawValue
                    || existing?[2] != definition.unit
                    || Int(existing?[3] ?? "") != definition.position
                    || existing?[4] != definition.successRule
                    || existing?[5] == "1"
                guard needsUpdate else { continue }
                try upsertDefinition(definition)
                try enqueue(
                    kind: "field_definition", id: definition.id, operation: "upsert",
                    payload: try encoder.encode(definition)
                )
            }

            for (alias, canonicalID) in HabitCatalog.aliases {
                var aliasValues: [(String, String)] = []
                try query(
                    "SELECT day, value FROM field_values WHERE definition_id = ? ORDER BY day",
                    [.text(alias)]
                ) { row in
                    if let day = row.text(0), let value = row.text(1) { aliasValues.append((day, value)) }
                }
                for (day, value) in aliasValues where try scalar(
                    "SELECT value FROM field_values WHERE definition_id = ? AND day = ?",
                    [.text(canonicalID), .text(day)]
                ) == nil {
                    let hlc = nextHLC()
                    try execute(
                        "INSERT INTO field_values(definition_id, day, value, updated_hlc) VALUES(?, ?, ?, ?)",
                        [.text(canonicalID), .text(day), .text(value), .text(hlc)]
                    )
                    try enqueue(
                        kind: "field_value", id: "\(canonicalID):\(day)", operation: "upsert",
                        payload: try encoder.encode(DailyFieldValue(definitionID: canonicalID, date: day, value: value)),
                        hlc: hlc
                    )
                }
                if try scalar("SELECT archived FROM field_definitions WHERE id = ?", [.text(alias)]) == "0" {
                    try execute("UPDATE field_definitions SET archived = 1 WHERE id = ?", [.text(alias)])
                    try enqueue(kind: "field_definition", id: alias, operation: "delete", payload: Data())
                }
            }

            // Daily summaries belong to the human/AI journal. Keep every old
            // value in SQLite, but retire the input definition from the app
            // and cloud UI so no historical data is destroyed.
            if try scalar("SELECT archived FROM field_definitions WHERE id = 'daily-summary'") == "0" {
                try execute("UPDATE field_definitions SET archived = 1 WHERE id = 'daily-summary'")
                try enqueue(kind: "field_definition", id: "daily-summary", operation: "delete", payload: Data())
            }
        }
    }

    private func upsertDayPlan(_ plan: TodayPlan, recordOutbox: Bool) throws {
        for task in plan.tasks { try upsertTask(task, date: plan.date, recordOutbox: recordOutbox) }
        var initial: [String: [PlanTask]] = [:]
        for segment in plan.initialSegments {
            initial[segment.rawValue] = plan.tasks.filter {
                segment.contains($0) || $0.planningCycles(in: segment) > 0
            }
        }
        let initialData = try encoder.encode(initial)
        let modifiedData = try encoder.encode(initial)
        try execute(
            "INSERT OR REPLACE INTO day_plans(date, profile, initial_segments, initial_snapshots, modified_snapshots, updated_hlc) VALUES(?, ?, ?, ?, ?, ?)",
            [.text(dayKey(plan.date)), .text(plan.profile.rawValue), .text(plan.initialSegments.map(\.rawValue).sorted().joined(separator: ",")),
             .blob(initialData), .blob(modifiedData), .text(nextHLC())]
        )
    }

    private func upsertTask(_ task: PlanTask, date: Date, recordOutbox: Bool = true) throws {
        let data = try encoder.encode(task)
        let id = task.id.uuidString.lowercased()
        let newFields = try taskSyncFields(task, date: date)
        var changedFields = newFields
        if recordOutbox,
           let oldPayload = try scalarBlob("SELECT payload FROM tasks WHERE id = ? AND deleted = 0", [.text(id)]),
           let oldTask = try? decoder.decode(PlanTask.self, from: oldPayload),
           let oldDate = try scalar("SELECT scheduled_date FROM tasks WHERE id = ?", [.text(id)]) {
            let oldFields = try taskSyncFields(oldTask, date: parseDay(oldDate) ?? date)
            changedFields = newFields.filter { key, value in !jsonValuesEqual(oldFields[key], value) }
        }
        let hlc = changedFields.isEmpty
            ? (try scalar("SELECT updated_hlc FROM tasks WHERE id = ?", [.text(id)]) ?? nextHLC())
            : nextHLC()
        try execute(
            """
            INSERT INTO tasks(id, scheduled_date, title, start_minute, fixed_role, payload, deleted, updated_hlc)
            VALUES(?, ?, ?, ?, ?, ?, 0, ?)
            ON CONFLICT(id) DO UPDATE SET scheduled_date=excluded.scheduled_date, title=excluded.title,
              start_minute=excluded.start_minute, fixed_role=excluded.fixed_role, payload=excluded.payload,
              deleted=0, updated_hlc=excluded.updated_hlc
            """,
            [.text(id), .text(dayKey(date)), .text(task.title), .integer(task.startMinute),
             task.fixedRole.map { .text($0.rawValue) } ?? .null, .blob(data), .text(hlc)]
        )
        if recordOutbox, !changedFields.isEmpty {
            try enqueue(
                kind: "task", id: id, operation: "upsert",
                payload: try JSONSerialization.data(withJSONObject: changedFields), hlc: hlc
            )
        }
    }

    private func tombstoneTask(id: String) throws {
        let hlc = nextHLC()
        try execute("UPDATE tasks SET deleted = 1, updated_hlc = ? WHERE id = ?", [.text(hlc), .text(id)])
        try enqueue(kind: "task", id: id, operation: "delete", payload: Data(), hlc: hlc)
    }

    private func upsertDefinition(_ definition: DailyFieldDefinition) throws {
        try execute(
            """
            INSERT INTO field_definitions(id, name, kind, unit, position, success_rule, archived)
            VALUES(?, ?, ?, ?, ?, ?, 0)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, kind=excluded.kind, unit=excluded.unit,
              position=excluded.position, success_rule=excluded.success_rule, archived=0
            """,
            [.text(definition.id), .text(definition.name), .text(definition.kind.rawValue),
             definition.unit.map(SQLiteValue.text) ?? .null, .integer(definition.position),
             definition.successRule.map(SQLiteValue.text) ?? .null]
        )
    }

    private func saveTemplatesInternal(_ templates: [PlanTask]) throws {
        try execute("INSERT OR REPLACE INTO meta(key, value) VALUES('templates', ?)", [.text(try encoder.encode(templates).base64EncodedString())])
    }

    private func taskIDs(on date: Date) throws -> [String] {
        var ids: [String] = []
        try query("SELECT id FROM tasks WHERE scheduled_date = ? AND deleted = 0", [.text(dayKey(date))]) { row in
            if let id = row.text(0) { ids.append(id) }
        }
        return ids
    }

    private func updatePlanMetadata(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment
    ) throws {
        var initial = try snapshotMap(date: date, column: "initial_snapshots")
        var modified = try snapshotMap(date: date, column: "modified_snapshots")
        var initialTimes = try initialSnapshotTimes(date: date)
        if initial[segment.rawValue] == nil {
            initial[segment.rawValue] = tasks.filter {
                segment.contains($0) || $0.planningCycles(in: segment) > 0
            }
            initialTimes[segment.rawValue] = Date()
        }
        for candidate in PlanningSegment.allCases where initial[candidate.rawValue] != nil {
            modified[candidate.rawValue] = tasks.filter(candidate.contains)
        }
        let initialized = PlanningSegment.allCases.filter { initial[$0.rawValue] != nil }.map(\.rawValue).joined(separator: ",")
        try execute(
            """
            INSERT INTO day_plans(date, profile, initial_segments, initial_snapshots, modified_snapshots, initial_snapshot_times, updated_hlc)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date) DO UPDATE SET profile=excluded.profile,
              initial_segments=excluded.initial_segments, initial_snapshots=excluded.initial_snapshots,
              modified_snapshots=excluded.modified_snapshots, initial_snapshot_times=excluded.initial_snapshot_times,
              updated_hlc=excluded.updated_hlc
            """,
            [.text(dayKey(date)), .text(profile.rawValue), .text(initialized), .blob(try encoder.encode(initial)),
             .blob(try encoder.encode(modified)), .blob(try encoder.encode(initialTimes)), .text(nextHLC())]
        )
        try enqueueDayPlanRecord(date: date, profile: profile, initial: initial, modified: modified, initialTimes: initialTimes)
    }

    private func refreshPlanMetadata(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment _: PlanningSegment
    ) throws {
        let initial = try snapshotMap(date: date, column: "initial_snapshots")
        var modified = try snapshotMap(date: date, column: "modified_snapshots")
        for candidate in PlanningSegment.allCases where initial[candidate.rawValue] != nil {
            modified[candidate.rawValue] = tasks.filter(candidate.contains)
        }
        let initialized = PlanningSegment.allCases.filter { initial[$0.rawValue] != nil }.map(\.rawValue).joined(separator: ",")
        try execute(
            """
            INSERT INTO day_plans(date, profile, initial_segments, initial_snapshots, modified_snapshots, updated_hlc)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(date) DO UPDATE SET profile=excluded.profile,
              initial_segments=excluded.initial_segments, initial_snapshots=excluded.initial_snapshots,
              modified_snapshots=excluded.modified_snapshots, updated_hlc=excluded.updated_hlc
            """,
            [.text(dayKey(date)), .text(profile.rawValue), .text(initialized), .blob(try encoder.encode(initial)),
             .blob(try encoder.encode(modified)), .text(nextHLC())]
        )
        try enqueueDayPlanRecord(
            date: date, profile: profile, initial: initial, modified: modified,
            initialTimes: try initialSnapshotTimes(date: date)
        )
    }

    private func ensureDayPlan(date: Date) throws {
        let key = dayKey(date)
        guard try scalar("SELECT date FROM day_plans WHERE date = ?", [.text(key)]) == nil else { return }
        let empty = try encoder.encode([String: [PlanTask]]())
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: date).kind.rawValue
        try execute(
            "INSERT INTO day_plans(date, profile, initial_segments, initial_snapshots, modified_snapshots, updated_hlc) VALUES(?, ?, '', ?, ?, ?)",
            [.text(key), .text(profile), .blob(empty), .blob(empty), .text(nextHLC())]
        )
    }

    private func repairMissingDayPlans() throws {
        var missingDates: [Date] = []
        try query(
            """
            SELECT DISTINCT scheduled_date FROM tasks
            WHERE deleted = 0 AND scheduled_date NOT IN (SELECT date FROM day_plans)
            """
        ) { row in
            if let value = row.text(0), let date = parseDay(value) { missingDates.append(date) }
        }
        guard !missingDates.isEmpty else { return }
        try transaction {
            for date in missingDates { try ensureDayPlan(date: date) }
        }
    }

    private func snapshotMap(date: Date, column: String) throws -> [String: [PlanTask]] {
        guard column == "initial_snapshots" || column == "modified_snapshots" else { return [:] }
        guard let data = try scalarBlob("SELECT \(column) FROM day_plans WHERE date = ?", [.text(dayKey(date))]) else { return [:] }
        return (try? decoder.decode([String: [PlanTask]].self, from: data)) ?? [:]
    }

    private func initialSnapshotTimes(date: Date) throws -> [String: Date] {
        guard let data = try scalarBlob("SELECT initial_snapshot_times FROM day_plans WHERE date = ?", [.text(dayKey(date))]) else { return [:] }
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    private func enqueueDayPlanRecord(
        date: Date,
        profile: DayProfileKind,
        initial: [String: [PlanTask]],
        modified: [String: [PlanTask]],
        initialTimes: [String: Date]
    ) throws {
        let record = DayPlanCloudRecord(
            date: dayKey(date), profile: profile.rawValue,
            initialSegments: PlanningSegment.allCases.filter { initial[$0.rawValue] != nil }.map(\.rawValue),
            initialSnapshots: initial, modifiedSnapshots: modified, initialSnapshotTimes: initialTimes
        )
        try enqueue(kind: "day_plan", id: dayKey(date), operation: "upsert", payload: try encoder.encode(record))
    }

    private func enqueue(kind: String, id: String, operation: String, payload: Data, hlc: String? = nil) throws {
        let mutationHLC = hlc ?? nextHLC()
        let fields: [String: JSONValue]?
        if operation == "delete" {
            fields = nil
        } else if let object = try? JSONDecoder().decode([String: JSONValue].self, from: payload) {
            fields = object
        } else if let text = String(data: payload, encoding: .utf8) {
            fields = ["text": .string(text)]
        } else {
            fields = ["value": .string(payload.base64EncodedString())]
        }
        let envelope = SyncMutation(
            mutationID: UUID().uuidString.lowercased(), deviceID: deviceID, entityKind: kind,
            entityID: id, hlc: mutationHLC, fields: fields, deleted: operation == "delete" ? true : nil
        )
        try execute(
            "INSERT INTO outbox(mutation_id, entity_kind, entity_id, operation, hlc, payload, created_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
            [.text(envelope.mutationID), .text(kind), .text(id), .text(operation), .text(mutationHLC),
             .blob(try encoder.encode(envelope)), .double(Date().timeIntervalSince1970)]
        )
    }

    private struct SyncMutation: Codable {
        var mutationID: String
        var deviceID: String
        var entityKind: String
        var entityID: String
        var hlc: String
        var fields: [String: JSONValue]?
        var deleted: Bool?

        enum CodingKeys: String, CodingKey {
            case mutationID = "mutationId"
            case deviceID = "deviceId"
            case entityKind
            case entityID = "entityId"
            case hlc, fields, deleted
        }
    }

    private struct FieldClock {
        var hlc: String
        var deviceId: String
    }

    private func pendingFieldClocks(kind: String, id: String) throws -> [String: FieldClock] {
        var result: [String: FieldClock] = [:]
        try query(
            "SELECT payload FROM outbox WHERE entity_kind = ? AND entity_id = ? ORDER BY sequence",
            [.text(kind), .text(id.lowercased())]
        ) { row in
            guard let data = row.blob(0), let mutation = try? decoder.decode(SyncMutation.self, from: normalizedMutationPayload(data)) else { return }
            let fields = mutation.deleted == true ? ["_deleted"] : Array(mutation.fields?.keys ?? Dictionary<String, JSONValue>().keys)
            for field in fields {
                let candidate = FieldClock(hlc: mutation.hlc, deviceId: mutation.deviceID)
                if let current = result[field], !clock(candidate, isLaterThan: current) { continue }
                result[field] = candidate
            }
        }
        return result
    }

    private func clock(_ remote: RemoteEntity.Clock, isLaterThan local: FieldClock) -> Bool {
        remote.hlc > local.hlc || (remote.hlc == local.hlc && remote.deviceId > local.deviceId)
    }

    private func clock(_ candidate: FieldClock, isLaterThan current: FieldClock) -> Bool {
        candidate.hlc > current.hlc || (candidate.hlc == current.hlc && candidate.deviceId > current.deviceId)
    }

    private struct SeedMutation {
        var kind: String
        var id: String
        var operation: String
        var payload: Data
        var hlc: String?
    }

    private struct DayPlanCloudRecord: Codable {
        var date: String
        var profile: String
        var initialSegments: [String]
        var initialSnapshots: [String: [PlanTask]]
        var modifiedSnapshots: [String: [PlanTask]]
        var initialSnapshotTimes: [String: Date]?
    }

    private struct FinalPlanCloudRecord: Codable { var snapshot: String }

    private func normalizedMutationPayload(_ data: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return data }
        if object["entityId"] == nil, let legacy = object.removeValue(forKey: "entityID") {
            object["entityId"] = legacy
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }

    private struct RemotePull: Codable {
        var cursor: Int
        var entities: [RemoteEntity]
    }

    private struct RemoteEntity: Codable {
        struct Clock: Codable { var hlc: String; var deviceId: String }
        var kind: String
        var id: String
        var fields: [String: JSONValue]
        var clocks: [String: Clock]
    }

    private enum JSONValue: Codable {
        case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
            else { self = .array(try container.decode([JSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .bool(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }


        var stringValue: String? { if case .string(let value) = self { value } else { nil } }
        var intValue: Int? { if case .number(let value) = self { Int(value) } else { nil } }
        var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
        var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
        var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    }

    private func taskSyncPayload(_ task: PlanTask, date: Date) throws -> Data {
        try JSONSerialization.data(withJSONObject: taskSyncFields(task, date: date))
    }

    private func taskSyncFields(_ task: PlanTask, date: Date) throws -> [String: Any] {
        let subtasks = task.coreTasks.map { ["title": $0.title, "complete": $0.isComplete] as [String: Any] }
        let fields: [String: Any] = [
            "title": task.title,
            "date": dayKey(date),
            "time": task.hasScheduledTime ? String(format: "%02d:%02d", task.startMinute / 60, task.startMinute % 60) : NSNull(),
            "hasScheduledTime": task.hasScheduledTime,
            "cycles": task.cycles,
            "kind": task.kind.rawValue,
            "priority": task.priority,
            "difficulty": task.difficulty,
            "mvp": task.mvp,
            "subtasks": subtasks,
            "complete": task.isComplete,
            "routineOverride": task.routineOverride,
            "routineBlock": task.isRoutineBlock,
            "durationMinutes": task.durationMinutes ?? NSNull(),
            "fixedRole": task.fixedRole?.rawValue ?? NSNull(),
            "displayColor": task.displayColor?.rawValue ?? NSNull(),
            "predefinedKind": task.predefinedKind?.rawValue ?? NSNull(),
            "predefinedKey": task.predefinedKey ?? NSNull(),
            "predefinedVersion": task.predefinedVersion ?? NSNull(),
            "quickCapture": task.quickCapture == true,
        ]
        return fields
    }

    private func taskSyncFieldsJSON(_ task: PlanTask, dateText: String) throws -> [String: JSONValue] {
        let date = parseDay(dateText) ?? Date()
        let data = try JSONSerialization.data(withJSONObject: taskSyncFields(task, date: date))
        return try decoder.decode([String: JSONValue].self, from: data)
    }

    private func jsonValuesEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        guard let lhs else { return false }
        return (lhs as AnyObject).isEqual(rhs)
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

    private func nextHLC() -> String {
        String(format: "%016lld", Int64(Date().timeIntervalSince1970 * 1_000)) + ":" + deviceID
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private enum SQLiteValue {
        case text(String)
        case integer(Int)
        case double(Double)
        case blob(Data)
        case null
    }

    private struct SQLiteRow {
        let statement: OpaquePointer
        func text(_ index: Int32) -> String? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL, let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        }
        func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
        func blob(_ index: Int32) -> Data? {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: bytes, count: count)
        }
    }

    private func execute(_ sql: String, _ values: [SQLiteValue] = []) throws {
        if values.isEmpty {
            guard let db else { throw RefocusStoreError.open("database is closed") }
            var message: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
                let detail = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                sqlite3_free(message)
                throw RefocusStoreError.sqlite(detail)
            }
            return
        }
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw sqliteError() }
    }

    private func query(_ sql: String, _ values: [SQLiteValue] = [], row: (SQLiteRow) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try row(SQLiteRow(statement: statement))
            case SQLITE_DONE: return
            default: throw sqliteError()
            }
        }
    }

    private func firstRow(_ sql: String, _ values: [SQLiteValue] = []) throws -> [String?]? {
        var found: [String?]?
        try query(sql, values) { row in
            guard found == nil else { return }
            let count = sqlite3_column_count(row.statement)
            found = (0..<count).map { index in
                if sqlite3_column_type(row.statement, index) == SQLITE_BLOB, let data = row.blob(index) {
                    return data.base64EncodedString()
                }
                return row.text(index)
            }
        }
        return found
    }

    private func scalar(_ sql: String, _ values: [SQLiteValue] = []) throws -> String? {
        try firstRow(sql, values)?[0] ?? nil
    }

    private func scalarBlob(_ sql: String, _ values: [SQLiteValue] = []) throws -> Data? {
        var found: Data?
        try query(sql, values) { row in if found == nil { found = row.blob(0) } }
        return found
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw RefocusStoreError.open("database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw sqliteError() }
        return statement
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): result = sqlite3_bind_int64(statement, index, sqlite3_int64(number))
            case .double(let number): result = sqlite3_bind_double(statement, index, number)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), transient) }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw sqliteError() }
        }
    }

    private func sqliteError() -> RefocusStoreError {
        guard let db else { return .sqlite("database is closed") }
        return .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}
