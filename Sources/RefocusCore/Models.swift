import Foundation

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case normal
    case contest
}

public enum FixedTaskRole: String, Codable, CaseIterable, Sendable {
    case dayAnalysis
    case planTomorrow
    case revision
}

public enum TaskDisplayColor: String, Codable, CaseIterable, Sendable {
    case none
    case red
    case green
    case blue
    case orange
    case yellow
    case purple
}

public enum PredefinedBlockKind: String, Codable, CaseIterable, Sendable {
    case morningRoutine
    case rest
    case university
    case study
    case transition
    case mashup
    case upsolve
}

public enum PlanningSegment: String, Codable, CaseIterable, Sendable {
    case morning
    case afternoon
    case evening

    public var title: String {
        switch self {
        case .morning: "Morning Block"
        case .afternoon: "Afternoon Block"
        case .evening: "Evening Block"
        }
    }

    public var startMinute: Int {
        switch self {
        case .morning: 360
        case .afternoon: 720
        case .evening: 1080
        }
    }

    public var endMinute: Int {
        switch self {
        case .morning: 720
        case .afternoon: 1080
        case .evening: 1290
        }
    }

    public var maximumCycles: Int {
        switch self {
        case .morning, .afternoon: 12
        case .evening: 7
        }
    }

    public func contains(_ task: PlanTask) -> Bool {
        task.startMinute >= startMinute && task.endMinute <= endMinute
    }
}

public enum DayProfileKind: String, Codable, CaseIterable, Sendable {
    case standard
    case universityEarly = "university-early"
    case universityLate = "university-late"
    case fridaySSC = "friday-ssc"
}

public enum StreakMode: String, Codable, CaseIterable, Sendable {
    case manual
    case planMinimum
    case noMissedCheckIns
}

public enum StreakStatus: String, Codable, CaseIterable, Sendable {
    case blank
    case win
    case fail

    public var next: StreakStatus {
        switch self {
        case .blank: .win
        case .win: .fail
        case .fail: .blank
        }
    }
}

public enum HabitGroup: String, Codable, Sendable {
    case bad
    case good
}

public struct HabitCatalogEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var group: HabitGroup
    public var level: String

    public init(id: String, name: String, group: HabitGroup, level: String) {
        self.id = id
        self.name = name
        self.group = group
        self.level = level
    }
}

public enum HabitCatalog {
    public static let dashboardHabitIDs: Set<String> = [
        "no-all-nighter",
        "no-unplanned-insta-s-11-5-return-home-wake-up",
        "no-unplanned-entertainment",
        "no-food-after-8",
        "no-food-with-media",
        "wake-up-5-5",
        "five-harder-problems",
    ]

    public static let aliases: [String: String] = [
        "solve-5-harder-problems": "five-harder-problems",
        "solve-five-harder-problems": "five-harder-problems",
        "all-nighters": "no-all-nighter",
        "good-food-entertainment": "no-food-with-media",
        "unplanned-insta-s": "no-unplanned-insta-s-11-5-return-home-wake-up",
        "unplanned-entertainment": "no-unplanned-entertainment",
    ]

    public static let entries: [HabitCatalogEntry] = [
        HabitCatalogEntry(id: "no-all-nighter", name: "no all-nighter", group: .bad, level: "Level 1 · Non-Negotiables"),
        HabitCatalogEntry(id: "no-unplanned-insta-s-11-5-return-home-wake-up", name: "no unplanned insta s", group: .bad, level: "Level 1 · Non-Negotiables"),
        HabitCatalogEntry(id: "no-unplanned-entertainment", name: "no unplanned entertainment", group: .bad, level: "Level 1 · Non-Negotiables"),
        HabitCatalogEntry(id: "no-food-after-8", name: "no food after 8", group: .bad, level: "Level 1 · Non-Negotiables"),
        HabitCatalogEntry(id: "no-food-with-media", name: "no food with media", group: .bad, level: "Level 1 · Non-Negotiables"),
        HabitCatalogEntry(id: "wake-up-5-5", name: "Wake up @5:5", group: .good, level: "Level 1 · Good Habits"),
        HabitCatalogEntry(id: "five-harder-problems", name: "Solve 5 harder problems", group: .good, level: "Level 1 · Good Habits"),
        HabitCatalogEntry(id: "keto-only-diet", name: "Keto only diet", group: .good, level: "Level 2 · Obsession"),
        HabitCatalogEntry(id: "no-soft-drinks", name: "No soft drinks", group: .good, level: "Level 2 · Obsession"),
    ]

    public static func entry(for definition: StreakDefinition) -> HabitCatalogEntry {
        if let known = entries.first(where: { $0.id == definition.id }) { return known }
        let lower = definition.name.lowercased()
        let group: HabitGroup = lower.hasPrefix("no ") || lower.contains("all nighter") ? .bad : .good
        return HabitCatalogEntry(
            id: definition.id, name: definition.name, group: group,
            level: group == .bad ? "Imported Bad Habits" : "Imported Good Habits"
        )
    }
}

public enum HabitStage: String, Codable, CaseIterable, Sendable {
    case started
    case awakening
    case breakthrough
    case ascension
    case mastery
    case perfection
    case transcendence

    public init(totalDelta: Int) {
        switch totalDelta {
        case ...0: self = .started
        case 1...6: self = .awakening
        case 7...20: self = .breakthrough
        case 21...89: self = .ascension
        case 90...179: self = .mastery
        case 180...364: self = .perfection
        default: self = .transcendence
        }
    }

    public var title: String {
        switch self {
        case .started: "Started"
        case .awakening: "Awakening"
        case .breakthrough: "Breakthrough"
        case .ascension: "Ascension"
        case .mastery: "Mastery"
        case .perfection: "Perfection"
        case .transcendence: "Transcendence"
        }
    }

    public var symbol: String {
        switch self {
        case .started: "⚪"
        case .awakening: "🟣"
        case .breakthrough: "🔴"
        case .ascension: "🔵"
        case .mastery: "🟨"
        case .perfection: "🟧"
        case .transcendence: "🟥"
        }
    }
}

public struct HabitMonthlyDelta: Identifiable, Equatable, Sendable {
    public var id: String { monthKey }
    public var monthKey: String
    public var label: String
    public var delta: Int

    public init(monthKey: String, label: String, delta: Int) {
        self.monthKey = monthKey
        self.label = label
        self.delta = delta
    }
}

public struct HabitPerformance: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public var definition: StreakDefinition
    public var totalDelta: Int
    public var currentMonthDelta: Int
    public var stage: HabitStage
    public var monthlyHistory: [HabitMonthlyDelta]

    public init(
        definition: StreakDefinition,
        totalDelta: Int,
        currentMonthDelta: Int,
        monthlyHistory: [HabitMonthlyDelta]
    ) {
        self.definition = definition
        self.totalDelta = totalDelta
        self.currentMonthDelta = currentMonthDelta
        self.stage = HabitStage(totalDelta: totalDelta)
        self.monthlyHistory = monthlyHistory
    }
}

public struct WeightProgress: Equatable, Sendable {
    public static let goal = 75.0

    public var currentWeight: Double?
    public var startingWeight: Double?
    public var remaining: Double?
    public var etaDays: Int?
    public var progress: Double
    public var trendKgPerDay: Double?

    public init(
        currentWeight: Double? = nil,
        startingWeight: Double? = nil,
        remaining: Double? = nil,
        etaDays: Int? = nil,
        progress: Double = 0,
        trendKgPerDay: Double? = nil
    ) {
        self.currentWeight = currentWeight
        self.startingWeight = startingWeight
        self.remaining = remaining
        self.etaDays = etaDays
        self.progress = progress
        self.trendKgPerDay = trendKgPerDay
    }
}

public struct DailyDashboardAnalytics: Equatable, Sendable {
    public var habits: [HabitPerformance]
    public var weight: WeightProgress

    public init(habits: [HabitPerformance] = [], weight: WeightProgress = WeightProgress()) {
        self.habits = habits
        self.weight = weight
    }
}

public enum DailyAnalytics {
    public static func dashboard(
        definitions: [StreakDefinition],
        values: [DailyFieldValue],
        asOf now: Date,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> DailyDashboardAnalytics {
        DailyDashboardAnalytics(
            habits: habitPerformance(definitions: definitions, values: values, asOf: now, calendar: calendar),
            weight: weightProgress(values: values, asOf: now, calendar: calendar)
        )
    }

    public static func habitPerformance(
        definitions: [StreakDefinition],
        values: [DailyFieldValue],
        asOf now: Date,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> [HabitPerformance] {
        let today = calendar.startOfDay(for: now)
        let currentMonthKey = monthKey(today, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM"

        return definitions
            .filter { HabitCatalog.dashboardHabitIDs.contains($0.id) }
            .map { definition in
                var monthDeltas: [String: Int] = [:]
                for value in values where value.definitionID == definition.id {
                    guard let date = parseDay(value.date, calendar: calendar), date <= today,
                          let status = StreakStatus(rawValue: value.value) else { continue }
                    let delta = status == .win ? 1 : status == .fail ? -1 : 0
                    monthDeltas[monthKey(date, calendar: calendar), default: 0] += delta
                }
                monthDeltas[currentMonthKey, default: 0] += 0
                let history = monthDeltas.keys.sorted(by: >).map { key in
                    let date = parseMonth(key, calendar: calendar) ?? today
                    return HabitMonthlyDelta(monthKey: key, label: formatter.string(from: date), delta: monthDeltas[key, default: 0])
                }
                return HabitPerformance(
                    definition: definition,
                    totalDelta: monthDeltas.values.reduce(0, +),
                    currentMonthDelta: monthDeltas[currentMonthKey, default: 0],
                    monthlyHistory: history
                )
            }
    }

    public static func weightProgress(
        values: [DailyFieldValue],
        asOf now: Date,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> WeightProgress {
        let today = calendar.startOfDay(for: now)
        let measurements = values.compactMap { value -> (Date, Double)? in
            guard value.definitionID == "weight",
                  let date = parseDay(value.date, calendar: calendar), date <= today,
                  let weight = Double(value.value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  weight > 0 else { return nil }
            return (date, weight)
        }.sorted { $0.0 < $1.0 }

        guard let first = measurements.first, let latest = measurements.last else { return WeightProgress() }
        let remaining = max(0, latest.1 - WeightProgress.goal)
        let denominator = first.1 - WeightProgress.goal
        let progress = denominator > 0
            ? min(1, max(0, (first.1 - latest.1) / denominator))
            : (latest.1 <= WeightProgress.goal ? 1 : 0)
        if remaining == 0 {
            return WeightProgress(
                currentWeight: latest.1, startingWeight: first.1, remaining: 0,
                etaDays: 0, progress: 1, trendKgPerDay: nil
            )
        }

        let cutoff = calendar.date(byAdding: .day, value: -60, to: today) ?? today
        let recent = measurements.filter { $0.0 >= cutoff }
        guard recent.count >= 3,
              let recentFirst = recent.first,
              let recentLast = recent.last,
              recentLast.0.timeIntervalSince(recentFirst.0) >= 7 * 86_400 else {
            return WeightProgress(
                currentWeight: latest.1, startingWeight: first.1, remaining: remaining, progress: progress
            )
        }

        let origin = recentFirst.0
        let points = recent.map { ($0.0.timeIntervalSince(origin) / 86_400, $0.1) }
        let meanX = points.map(\.0).reduce(0, +) / Double(points.count)
        let meanY = points.map(\.1).reduce(0, +) / Double(points.count)
        let numerator = points.reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let divisor = points.reduce(0) { $0 + pow($1.0 - meanX, 2) }
        guard divisor > 0 else {
            return WeightProgress(
                currentWeight: latest.1, startingWeight: first.1, remaining: remaining, progress: progress
            )
        }
        let slope = numerator / divisor
        guard slope <= -0.005 else {
            return WeightProgress(
                currentWeight: latest.1, startingWeight: first.1, remaining: remaining,
                progress: progress, trendKgPerDay: slope
            )
        }
        return WeightProgress(
            currentWeight: latest.1, startingWeight: first.1, remaining: remaining,
            etaDays: Int(ceil(remaining / -slope)), progress: progress, trendKgPerDay: slope
        )
    }

    private static func parseDay(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func monthKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func parseMonth(_ value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }
}

public struct CoreTask: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var isComplete: Bool

    public init(id: UUID = UUID(), title: String, isComplete: Bool = false) {
        self.id = id
        self.title = title
        self.isComplete = isComplete
    }
}

public struct PlanTask: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startMinute: Int
    public var cycles: Int
    public var kind: TaskKind
    public var priority: String
    public var difficulty: String
    public var mvp: String
    public var coreTasks: [CoreTask]
    public var isComplete: Bool
    public var fixedRole: FixedTaskRole?
    public var routineOverride: Bool
    public var routineBlock: Bool?
    public var durationMinutes: Int?
    public var displayColor: TaskDisplayColor?
    public var predefinedKind: PredefinedBlockKind?
    public var predefinedKey: String?
    public var predefinedVersion: Int?
    /// Agenda tasks can be captured for a date before a start time is chosen.
    /// A missing value keeps older records compatible because they always had a time.
    public var timeAssigned: Bool?

    public init(
        id: UUID = UUID(),
        title: String,
        startMinute: Int,
        cycles: Int,
        kind: TaskKind = .normal,
        priority: String = "Medium",
        difficulty: String = "Moderate",
        mvp: String = "",
        coreTasks: [CoreTask] = [],
        isComplete: Bool = false,
        fixedRole: FixedTaskRole? = nil,
        routineOverride: Bool = false,
        routineBlock: Bool = false,
        durationMinutes: Int? = nil,
        displayColor: TaskDisplayColor = .none,
        predefinedKind: PredefinedBlockKind? = nil,
        predefinedKey: String? = nil,
        predefinedVersion: Int? = nil,
        timeAssigned: Bool = true
    ) {
        self.id = id
        self.title = title
        self.startMinute = startMinute
        self.cycles = cycles
        self.kind = kind
        self.priority = priority
        self.difficulty = difficulty
        self.mvp = mvp
        self.coreTasks = coreTasks
        self.isComplete = isComplete
        self.fixedRole = fixedRole
        self.routineOverride = routineOverride
        self.routineBlock = routineBlock ? true : nil
        self.durationMinutes = durationMinutes
        self.displayColor = displayColor == .none ? nil : displayColor
        self.predefinedKind = predefinedKind
        self.predefinedKey = predefinedKey
        self.predefinedVersion = predefinedVersion
        self.timeAssigned = timeAssigned ? nil : false
    }

    public var endMinute: Int { startMinute + (durationMinutes ?? cycles * 30) }
    public var hasScheduledTime: Bool { timeAssigned != false }
    public var isRoutineBlock: Bool { routineBlock == true }
    public var countsTowardPlanning: Bool {
        guard isRoutineBlock else { return true }
        return predefinedKind == .mashup || predefinedKind == .upsolve
    }

    public func planningCycles(in segment: PlanningSegment) -> Int {
        guard hasScheduledTime, countsTowardPlanning else { return 0 }
        if segment.contains(self) { return cycles }
        // A predefined five-hour contest remains one editable task even when
        // it crosses a planning-gate boundary. Count only the half-hour cycles
        // physically inside that gate.
        guard isRoutineBlock, predefinedKind == .mashup else { return 0 }
        let overlap = max(0, min(endMinute, segment.endMinute) - max(startMinute, segment.startMinute))
        return overlap / 30
    }

    public func contains(minuteOfDay: Int) -> Bool {
        minuteOfDay >= startMinute && minuteOfDay < endMinute
    }
}

public struct TodayPlan: Equatable, Sendable {
    public var date: Date
    public var profile: DayProfileKind
    public var tasks: [PlanTask]
    public var isCurrent: Bool
    public var initialSegments: Set<PlanningSegment>

    public init(
        date: Date,
        profile: DayProfileKind,
        tasks: [PlanTask],
        isCurrent: Bool = true,
        initialSegments: Set<PlanningSegment> = []
    ) {
        self.date = date
        self.profile = profile
        self.tasks = tasks
        self.isCurrent = isCurrent
        self.initialSegments = initialSegments
    }
}

/// The immutable first save and latest saved state for each initialized
/// planning block. These snapshots are runtime data; projections render only
/// their human-readable task fields.
public struct PlanSnapshots: Equatable, Sendable {
    public var profile: DayProfileKind
    public var initial: [PlanningSegment: [PlanTask]]
    public var modified: [PlanningSegment: [PlanTask]]

    public init(
        profile: DayProfileKind,
        initial: [PlanningSegment: [PlanTask]],
        modified: [PlanningSegment: [PlanTask]]
    ) {
        self.profile = profile
        self.initial = initial
        self.modified = modified
    }
}

public struct AgendaTask: Identifiable, Equatable, Sendable {
    public var id: UUID { task.id }
    public var date: Date
    public var task: PlanTask

    public init(date: Date, task: PlanTask) {
        self.date = date
        self.task = task
    }
}

public enum DailyFieldKind: String, Codable, CaseIterable, Sendable {
    case triState
    case number
    case text
}

public struct DailyFieldDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DailyFieldKind
    public var unit: String?
    public var position: Int
    public var successRule: String?

    public init(
        id: String,
        name: String,
        kind: DailyFieldKind,
        unit: String? = nil,
        position: Int = 0,
        successRule: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.unit = unit
        self.position = position
        self.successRule = successRule
    }
}

public struct DailyFieldValue: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(definitionID):\(date)" }
    public var definitionID: String
    public var date: String
    public var value: String

    public init(definitionID: String, date: String, value: String) {
        self.definitionID = definitionID
        self.date = date
        self.value = value
    }
}

public struct DayAnalysis: Codable, Equatable, Sendable {
    public var summary: String
    public var progress: String
    public var mistakes: String
    public var gains: String

    public init(summary: String = "", progress: String = "", mistakes: String = "", gains: String = "") {
        self.summary = summary
        self.progress = progress
        self.mistakes = mistakes
        self.gains = gains
    }
}

public enum ClockPhaseKind: String, Sendable {
    case focus
    case screenBreak
}

public struct ClockSnapshot: Equatable, Sendable {
    public var phase: ClockPhaseKind
    public var phaseStart: Date
    public var phaseEnd: Date
    public var cycleStart: Date
    public var secondsRemaining: Int

    public init(
        phase: ClockPhaseKind,
        phaseStart: Date,
        phaseEnd: Date,
        cycleStart: Date,
        secondsRemaining: Int
    ) {
        self.phase = phase
        self.phaseStart = phaseStart
        self.phaseEnd = phaseEnd
        self.cycleStart = cycleStart
        self.secondsRemaining = secondsRemaining
    }
}

public enum CheckInOutcome: String, Codable, Sendable {
    case complete
    case partial
    case missed
    case interrupted
}

public struct CheckIn: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var taskID: UUID?
    public var taskTitle: String
    public var focusStart: Date
    public var focusEnd: Date
    public var whatDid: String
    public var better: String
    public var faster: String
    public var outcome: CheckInOutcome
    public var emergencyReason: String?

    public init(
        id: String,
        taskID: UUID?,
        taskTitle: String,
        focusStart: Date,
        focusEnd: Date,
        whatDid: String = "",
        better: String = "",
        faster: String = "",
        outcome: CheckInOutcome = .partial,
        emergencyReason: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.focusStart = focusStart
        self.focusEnd = focusEnd
        self.whatDid = whatDid
        self.better = better
        self.faster = faster
        self.outcome = outcome
        self.emergencyReason = emergencyReason
    }
}

public struct StreakDefinition: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var mode: StreakMode

    public init(id: String, name: String, mode: StreakMode) {
        self.id = id
        self.name = name
        self.mode = mode
    }
}

public struct StreakSummary: Identifiable, Equatable, Sendable {
    public var id: String { definition.id }
    public var definition: StreakDefinition
    public var current: Int
    public var longest: Int
    public var statuses: [Int: StreakStatus]
    public var totalWins: Int
    public var totalFails: Int

    public init(
        definition: StreakDefinition,
        current: Int,
        longest: Int,
        statuses: [Int: StreakStatus],
        totalWins: Int,
        totalFails: Int
    ) {
        self.definition = definition
        self.current = current
        self.longest = longest
        self.statuses = statuses
        self.totalWins = totalWins
        self.totalFails = totalFails
    }
}

public enum ValidationSeverity: String, Sendable {
    case error
    case warning
}

public enum PlanValidationIssue: Equatable, Sendable, CustomStringConvertible {
    case insufficientCycles(actual: Int, required: Int)
    case insufficientSegment(segment: PlanningSegment, actual: Int, required: Int)
    case noAvailableCycles(segment: PlanningSegment)
    case missingTaskTitle
    case invalidCycleCount(task: String)
    case invalidContest(task: String)
    case invalidPriority(task: String)
    case invalidDifficulty(task: String)
    case missingMVP(task: String)
    case missingTime(task: String)
    case tooFewSubtasks(task: String)
    case emptyCoreTask(task: String)
    case overlap(first: String, second: String)
    case routineConflict(taskID: UUID, task: String, reason: String, startMinute: Int, endMinute: Int)
    case afterSleepCutoff(task: String)
    case missingFixedTask(name: String)
    case invalidFixedTask(name: String, requirement: String)

    public var severity: ValidationSeverity {
        switch self {
        case .routineConflict: .warning
        default: .error
        }
    }

    public var description: String {
        switch self {
        case .insufficientCycles(let actual, let required): return "Plan has \(actual)/\(required) required cycles."
        case .insufficientSegment(let segment, let actual, let required):
            return "\(segment.title) has \(actual)/\(required) required cycles."
        case .noAvailableCycles(let segment):
            return "No work cycles remain in the \(segment.title.lowercased()). Work stays locked until the next planning block."
        case .missingTaskTitle: return "Every task needs a real name."
        case .invalidCycleCount(let task): return "\(task) must use one to four cycles."
        case .invalidContest(let task): return "\(task) must use one to ten contest cycles."
        case .invalidPriority(let task): return "\(task) needs a valid priority."
        case .invalidDifficulty(let task): return "\(task) needs a valid difficulty."
        case .missingMVP(let task): return "\(task) needs a concrete MVP."
        case .missingTime(let task): return "\(task) needs a start time before it can be planned."
        case .tooFewSubtasks(let task): return "\(task) needs at least three subtasks."
        case .emptyCoreTask(let task): return "\(task) cannot contain an unnamed subtask."
        case .overlap(let first, let second): return "\(first) overlaps \(second)."
        case .routineConflict(_, let task, let reason, let start, let end):
            return "\(task) overlaps \(Self.time(start))–\(Self.time(end)), protected for \(reason)."
        case .afterSleepCutoff(let task): return "\(task) runs after the 9:30 PM cutoff."
        case .missingFixedTask(let name): return "The fixed daily block \(name) is missing."
        case .invalidFixedTask(let name, let requirement): return "\(name) must \(requirement)."
        }
    }

    private static func time(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }
}
