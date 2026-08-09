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
        case .morning: 660
        case .afternoon: 1020
        case .evening: 1290
        }
    }

    public var maximumCycles: Int {
        switch self {
        case .morning, .afternoon: 10
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
        HabitCatalogEntry(id: "wake-up-5-5", name: "Wake up @5.5", group: .good, level: "Level 1 · Good Habits"),
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
