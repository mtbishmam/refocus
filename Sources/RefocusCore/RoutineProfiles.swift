import Foundation

public enum RoutineWindowKind: String, Sendable {
    case work
    case contest
    case protected
    case eveningRoutine
}

public struct RoutineWindow: Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public var kind: RoutineWindowKind
    public var label: String

    public init(_ startMinute: Int, _ endMinute: Int, _ kind: RoutineWindowKind, _ label: String) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.kind = kind
        self.label = label
    }

    public func overlaps(start: Int, end: Int) -> Bool {
        start < endMinute && end > startMinute
    }
}

public struct DayProfile: Equatable, Sendable {
    public var kind: DayProfileKind
    public var windows: [RoutineWindow]

    public init(kind: DayProfileKind, windows: [RoutineWindow]) {
        self.kind = kind
        self.windows = windows
    }

    public var protectedWindows: [RoutineWindow] {
        windows.filter { $0.kind == .protected }
    }
}

public struct RoutineProfileResolver: Sendable {
    public var calendar: Calendar

    public init(calendar: Calendar = WallClock.dhakaCalendar()) {
        self.calendar = calendar
    }

    public func profile(for date: Date) -> DayProfile {
        switch calendar.component(.weekday, from: date) {
        case 7, 5: // Saturday, Thursday
            return DayProfile(kind: .universityEarly, windows: [
                RoutineWindow(360, 480, .work, "Morning ordinary block"),
                RoutineWindow(480, 840, .protected, "University"),
                RoutineWindow(840, 1290, .work, "Post-university ordinary blocks"),
            ])
        case 1, 3: // Sunday, Tuesday
            return DayProfile(kind: .universityLate, windows: [
                RoutineWindow(360, 660, .contest, "Five-hour contest"),
                RoutineWindow(690, 750, .protected, "Rest and transition"),
                RoutineWindow(750, 1020, .protected, "University"),
                RoutineWindow(1020, 1080, .protected, "Return and rest"),
                RoutineWindow(1080, 1290, .eveningRoutine, "Evening routine"),
            ])
        case 6: // Friday
            return DayProfile(kind: .fridaySSC, windows: [
                RoutineWindow(360, 540, .work, "Morning ordinary blocks"),
                RoutineWindow(540, 780, .contest, "Four-hour SSC contest"),
                RoutineWindow(780, 1290, .work, "Afternoon and evening ordinary blocks"),
            ])
        default:
            return DayProfile(kind: .standard, windows: [
                RoutineWindow(360, 660, .contest, "Five-hour contest"),
                RoutineWindow(690, 720, .protected, "Rest 1"),
                RoutineWindow(720, 1050, .work, "Upsolving"),
                RoutineWindow(1050, 1080, .protected, "Rest 2"),
                RoutineWindow(1080, 1290, .eveningRoutine, "Evening routine"),
            ])
        }
    }
}

public struct PlanValidator: Sendable {
    public init() {}

    public func requiredCycles(
        at date: Date,
        profile: DayProfile,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let firstAvailableSlot = ((minute + 29) / 30) * 30
        guard firstAvailableSlot < 1290 else { return 0 }

        var available = 0
        var cursor = firstAvailableSlot
        while cursor + 30 <= 1290 {
            let blocked = profile.protectedWindows.contains { $0.overlaps(start: cursor, end: cursor + 30) }
            if !blocked { available += 1 }
            cursor += 30
        }
        return min(12, available)
    }

    public func validate(tasks: [PlanTask], profile: DayProfile, minimumCycles: Int = 12) -> [PlanValidationIssue] {
        var issues: [PlanValidationIssue] = []
        let totalCycles = tasks.reduce(0) { $0 + $1.cycles }
        if totalCycles < minimumCycles {
            issues.append(.insufficientCycles(actual: totalCycles, required: minimumCycles))
        }

        for task in tasks {
            let cleanTitle = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayTitle = cleanTitle.isEmpty ? "Unnamed task" : cleanTitle
            if cleanTitle.isEmpty || cleanTitle.caseInsensitiveCompare("New task") == .orderedSame {
                issues.append(.missingTaskTitle)
            }
            if !["Do/Die", "High", "Medium", "Low"].contains(task.priority) {
                issues.append(.invalidPriority(task: displayTitle))
            }
            if !["Hard", "Moderate", "Easy"].contains(task.difficulty) {
                issues.append(.invalidDifficulty(task: displayTitle))
            }
            switch task.kind {
            case .normal:
                if !(1...4).contains(task.cycles) { issues.append(.invalidCycleCount(task: displayTitle)) }
            case .contest:
                if !(1...10).contains(task.cycles) {
                    issues.append(.invalidContest(task: displayTitle))
                }
            }

            if task.mvp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.missingMVP(task: displayTitle))
            }
            if task.cycles > 1 && task.coreTasks.count != 3 {
                issues.append(.wrongCoreTaskCount(task: displayTitle))
            } else if task.cycles > 1 && task.coreTasks.contains(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) {
                issues.append(.emptyCoreTask(task: displayTitle))
            }
            if task.endMinute > 1290 { issues.append(.afterSleepCutoff(task: displayTitle)) }
            if profile.protectedWindows.contains(where: { $0.overlaps(start: task.startMinute, end: task.endMinute) }) {
                issues.append(.blockedTime(task: displayTitle))
            }
        }

        let ordered = tasks.sorted { $0.startMinute < $1.startMinute }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.endMinute > pair.1.startMinute {
            issues.append(.overlap(first: pair.0.title, second: pair.1.title))
        }
        return issues
    }
}
