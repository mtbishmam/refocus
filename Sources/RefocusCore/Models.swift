import Foundation

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case normal
    case contest
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
        isComplete: Bool = false
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
    }

    public var endMinute: Int { startMinute + cycles * 30 }

    public func contains(minuteOfDay: Int) -> Bool {
        minuteOfDay >= startMinute && minuteOfDay < endMinute
    }
}

public struct TodayPlan: Equatable, Sendable {
    public var date: Date
    public var profile: DayProfileKind
    public var tasks: [PlanTask]
    public var isCurrent: Bool

    public init(date: Date, profile: DayProfileKind, tasks: [PlanTask], isCurrent: Bool = true) {
        self.date = date
        self.profile = profile
        self.tasks = tasks
        self.isCurrent = isCurrent
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
    public var completedDays: Set<Int>

    public init(definition: StreakDefinition, current: Int, longest: Int, completedDays: Set<Int>) {
        self.definition = definition
        self.current = current
        self.longest = longest
        self.completedDays = completedDays
    }
}

public enum PlanValidationIssue: Equatable, Sendable, CustomStringConvertible {
    case insufficientCycles(actual: Int, required: Int)
    case missingTaskTitle
    case invalidCycleCount(task: String)
    case invalidContest(task: String)
    case invalidPriority(task: String)
    case invalidDifficulty(task: String)
    case missingMVP(task: String)
    case wrongCoreTaskCount(task: String)
    case emptyCoreTask(task: String)
    case overlap(first: String, second: String)
    case blockedTime(task: String)
    case afterSleepCutoff(task: String)

    public var description: String {
        switch self {
        case .insufficientCycles(let actual, let required): return "Plan has \(actual)/\(required) required cycles."
        case .missingTaskTitle: return "Every task needs a real name."
        case .invalidCycleCount(let task): return "\(task) must use one to four cycles."
        case .invalidContest(let task): return "\(task) must use one to ten contest cycles."
        case .invalidPriority(let task): return "\(task) needs a valid priority."
        case .invalidDifficulty(let task): return "\(task) needs a valid difficulty."
        case .missingMVP(let task): return "\(task) needs a concrete MVP."
        case .wrongCoreTaskCount(let task): return "\(task) needs exactly three core tasks."
        case .emptyCoreTask(let task): return "\(task) needs three named core tasks."
        case .overlap(let first, let second): return "\(first) overlaps \(second)."
        case .blockedTime(let task): return "\(task) overlaps a protected routine exception."
        case .afterSleepCutoff(let task): return "\(task) runs after the 9:30 PM cutoff."
        }
    }
}
