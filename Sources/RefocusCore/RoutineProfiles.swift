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

public enum FixedPlanTasks {
    public static let dayAnalysisName = "Day Analysis and Streaks (CF & Git)"
    public static let planTomorrowName = "Plan Tomorrow + Miscel Tasks"
    public static let revisionName = "ReVision"

    public static let hardRestWindows = [
        RoutineWindow(660, 720, .protected, "Rest Block"),
        RoutineWindow(1020, 1080, .protected, "Rest Block"),
    ]

    public static func daily() -> [PlanTask] {
        [
            PlanTask(
                title: dayAnalysisName, startMinute: 1200, cycles: 1,
                priority: "High", difficulty: "Moderate",
                mvp: "Analyze the day and update the Codeforces and Git streaks",
                coreTasks: [
                    CoreTask(title: "Run analyze_day"),
                    CoreTask(title: "Review gains and mistakes"),
                    CoreTask(title: "Update CF and Git streaks"),
                ], fixedRole: .dayAnalysis
            ),
            PlanTask(
                title: planTomorrowName, startMinute: 1230, cycles: 1,
                priority: "High", difficulty: "Moderate",
                mvp: "Tomorrow is planned and miscellaneous tasks are processed",
                coreTasks: [
                    CoreTask(title: "Plan tomorrow"),
                    CoreTask(title: "Process miscellaneous tasks"),
                    CoreTask(title: "Reschedule unfinished tasks"),
                ], fixedRole: .planTomorrow
            ),
            PlanTask(
                title: revisionName, startMinute: 1260, cycles: 1,
                priority: "High", difficulty: "Moderate",
                mvp: "Finish the daily revision loop",
                coreTasks: [
                    CoreTask(title: "ReSolve"),
                    CoreTask(title: "ReSync"),
                    CoreTask(title: "Routes, Goals and Milestones"),
                ], fixedRole: .revision
            ),
        ]
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
                RoutineWindow(720, 750, .protected, "university transition"),
                RoutineWindow(750, 1020, .protected, "University"),
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
                RoutineWindow(720, 1050, .work, "Upsolving"),
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
        requiredCycles(in: segment(at: date, calendar: calendar), at: date, profile: profile, calendar: calendar)
    }

    public func segment(at date: Date, calendar: Calendar = WallClock.dhakaCalendar()) -> PlanningSegment {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if minute < 660 { return .morning }
        if minute < 1020 { return .afternoon }
        return .evening
    }

    public func requiredCycles(
        in segment: PlanningSegment,
        at date: Date,
        profile: DayProfile,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let currentCycleStart = (minute / 30) * 30
        let firstAvailableSlot = max(segment.startMinute, currentCycleStart)
        guard firstAvailableSlot < segment.endMinute else { return 0 }

        var available = 0
        var cursor = firstAvailableSlot
        while cursor + 30 <= segment.endMinute {
            let blocked = (profile.protectedWindows + FixedPlanTasks.hardRestWindows)
                .contains { $0.overlaps(start: cursor, end: cursor + 30) }
            if !blocked { available += 1 }
            cursor += 30
        }
        return min(segment.maximumCycles, available)
    }

    public func validate(
        tasks: [PlanTask],
        profile: DayProfile,
        minimumCycles: Int = 12,
        requireFixedTasks: Bool = true,
        requireTaskDetails: Bool = true,
        countedSegment: PlanningSegment? = nil
    ) -> [PlanValidationIssue] {
        var issues: [PlanValidationIssue] = []
        let countedTasks = countedSegment.map { segment in tasks.filter(segment.contains) } ?? tasks
        let totalCycles = countedTasks.reduce(0) { $0 + $1.cycles }
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

            if requireTaskDetails {
                if task.mvp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    issues.append(.missingMVP(task: displayTitle))
                }
                if task.coreTasks.count < 3 {
                    issues.append(.tooFewSubtasks(task: displayTitle))
                } else if task.coreTasks.contains(where: {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) {
                    issues.append(.emptyCoreTask(task: displayTitle))
                }
            }
            if task.endMinute > 1290 { issues.append(.afterSleepCutoff(task: displayTitle)) }
            for window in FixedPlanTasks.hardRestWindows where window.overlaps(start: task.startMinute, end: task.endMinute) {
                issues.append(.hardRest(task: displayTitle, startMinute: window.startMinute, endMinute: window.endMinute))
            }
            if !task.routineOverride {
                for window in profile.protectedWindows where window.overlaps(start: task.startMinute, end: task.endMinute) {
                    issues.append(.routineConflict(
                        taskID: task.id,
                        task: displayTitle,
                        reason: window.label,
                        startMinute: window.startMinute,
                        endMinute: window.endMinute
                    ))
                }
            }
        }

        if requireFixedTasks { validateFixedTasks(tasks, issues: &issues) }

        let ordered = tasks.sorted { $0.startMinute < $1.startMinute }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.endMinute > pair.1.startMinute {
            let allowedEveningOverlap = Set([pair.0.fixedRole, pair.1.fixedRole]) == Set([.planTomorrow, .revision])
                && max(pair.0.startMinute, pair.1.startMinute) >= 1260
                && min(pair.0.endMinute, pair.1.endMinute) <= 1290
            if !allowedEveningOverlap {
                issues.append(.overlap(first: pair.0.title, second: pair.1.title))
            }
        }
        return issues
    }

    private func validateFixedTasks(_ tasks: [PlanTask], issues: inout [PlanValidationIssue]) {
        let requirements: [(FixedTaskRole, String, Int, ClosedRange<Int>)] = [
            (.dayAnalysis, FixedPlanTasks.dayAnalysisName, 1200, 1...1),
            (.planTomorrow, FixedPlanTasks.planTomorrowName, 1230, 1...2),
            (.revision, FixedPlanTasks.revisionName, 1260, 1...1),
        ]
        for (role, name, start, cycles) in requirements {
            guard let task = tasks.first(where: { $0.fixedRole == role }) else {
                issues.append(.missingFixedTask(name: name))
                continue
            }
            if task.title != name || task.startMinute != start || !cycles.contains(task.cycles) {
                let duration = role == .planTomorrow ? "start at 20:30 and use one or two cycles" : "start at \(MarkdownPlanCodec.time(start)) and use one cycle"
                issues.append(.invalidFixedTask(name: name, requirement: duration))
            }
        }
    }
}
