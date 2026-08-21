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

    public static let defaultRestWindows = [
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

/// Editable defaults derived from the live Ikigai routine and the current
/// university timetable. IDs are stable per date and block so deleting a
/// default creates a durable tombstone instead of making it reappear.
public enum PredefinedRoutineBlocks {
    public static func daily(for date: Date, calendar: Calendar = WallClock.dhakaCalendar()) -> [PlanTask] {
        let weekday = calendar.component(.weekday, from: date)
        var blocks = [block(
            date: date, key: "morning-routine", title: "Morning Routine",
            start: 330, end: 360, description: "Audio Wakeup + Bath & Weight + Coffee & Water",
            predefinedKind: .morningRoutine, calendar: calendar
        )]

        switch weekday {
        case 7, 5: // Saturday, Thursday
            blocks += [
                university(date: date, key: "cse220", title: "CSE220 Class", detail: "CSE220-15-SHBZ-09D-17C", start: 480, end: 570, calendar: calendar),
                block(date: date, key: "cse111-220-study", title: "CSE111/220 Study", start: 570, end: 615, predefinedKind: .study, calendar: calendar),
                block(date: date, key: "sta201-study", title: "STA201 Study", start: 615, end: 660, predefinedKind: .study, calendar: calendar),
                university(date: date, key: "sta201", title: "STA201 Class", detail: "STA201-16-SFQR-09H-37C", start: 660, end: 750, calendar: calendar),
                transition(date: date, key: "return-home", start: 750, end: 780, calendar: calendar),
                rest(date: date, key: "rest-afternoon", start: 780, end: 840, calendar: calendar),
                mashup(date: date, key: "mashup-afternoon", start: 840, end: 1140, calendar: calendar),
            ]
        case 1: // Sunday
            blocks.append(mashup(date: date, key: "mashup-morning", start: 360, end: 660, calendar: calendar))
            blocks += lateUniversity(date: date, finalTitle: "CSE220 Lab", finalDetail: "CSE220L-15-TBA-09B-09L", calendar: calendar)
        case 3: // Tuesday
            blocks.append(mashup(date: date, key: "mashup-morning", start: 360, end: 660, calendar: calendar))
            blocks += lateUniversity(date: date, finalTitle: "CSE111 Lab", finalDetail: "CSE111-08-KNI-09B-11L", calendar: calendar)
        default:
            blocks += standardWorkday(date: date, calendar: calendar)
        }
        return blocks.sorted { $0.startMinute < $1.startMinute }
    }

    private static func lateUniversity(date: Date, finalTitle: String, finalDetail: String, calendar: Calendar) -> [PlanTask] {
        [
            rest(date: date, key: "rest-midday", start: 660, end: 720, calendar: calendar),
            university(date: date, key: "cse111", title: "CSE111 Class", detail: "CSE111-06-ADU-09H-35C", start: 750, end: 840, calendar: calendar),
            university(date: date, key: "university-final", title: finalTitle, detail: finalDetail, start: 840, end: 1020, calendar: calendar),
            transition(date: date, key: "return-home", start: 1020, end: 1050, calendar: calendar),
            rest(date: date, key: "rest-evening", start: 1050, end: 1080, calendar: calendar),
        ]
    }

    private static func standardWorkday(date: Date, calendar: Calendar) -> [PlanTask] {
        [
            mashup(date: date, key: "mashup-morning", start: 360, end: 660, calendar: calendar),
            rest(date: date, key: "rest-midday", start: 660, end: 720, calendar: calendar),
            block(date: date, key: "upsolve-1", title: "Upsolve 1", start: 720, end: 840, predefinedKind: .upsolve, calendar: calendar),
            block(date: date, key: "upsolve-2", title: "Upsolve 2", start: 840, end: 1020, predefinedKind: .upsolve, calendar: calendar),
            rest(date: date, key: "rest-evening", start: 1020, end: 1080, calendar: calendar),
        ]
    }

    private static func rest(date: Date, key: String, start: Int, end: Int, calendar: Calendar) -> PlanTask {
        block(
            date: date, key: key, title: "Rest", start: start, end: end,
            description: "InstaS + Bath + Food + Coffee", displayColor: .green,
            predefinedKind: .rest, calendar: calendar
        )
    }

    private static func transition(date: Date, key: String, start: Int, end: Int, calendar: Calendar) -> PlanTask {
        block(
            date: date, key: key, title: "Return Home / Transition",
            start: start, end: end, predefinedKind: .transition, calendar: calendar
        )
    }

    private static func university(
        date: Date, key: String, title: String, detail: String, start: Int, end: Int, calendar: Calendar
    ) -> PlanTask {
        var task = block(
            date: date, key: key, title: title, start: start, end: end, description: detail,
            displayColor: .red, predefinedKind: .university, calendar: calendar
        )
        // Version 4 also moves the old room/course detail out of MVP and
        // gives three-hour university blocks their canonical Lab title.
        task.predefinedVersion = 4
        return task
    }

    private static func mashup(date: Date, key: String, start: Int, end: Int, calendar: Calendar) -> PlanTask {
        let labels: [String]
        if start == 840 {
            labels = [
                "2 - 2.5 -> Skim & Write approaches, tags",
                "2.5 - 3 -> Try the most solveable one",
                "3 - 4 -> 2nd most solveable one",
                "4 - 5 -> 3rd most solveable one",
                "5 - 6 -> if 3 unsolved, then retry; else 4th",
                "6 - 7 -> if 4 unsolved, then retry; else 5th",
            ]
        } else {
            labels = [
                "6 - 6.5 -> Skim & Write approaches, tags",
                "6.5 - 7 -> Try the most solveable one",
                "7 - 8 -> 2nd most solveable one",
                "8 - 9 -> 3rd most solveable one",
                "9 - 10 -> if 3 unsolved, then retry; else 4th",
                "10 - 11 -> if 4 unsolved, then retry; else 5th",
            ]
        }
        var task = block(
            date: date, key: key, title: "5H Mashup", start: start, end: end,
            description: "Just start the contest", kind: .contest, displayColor: .yellow,
            predefinedKind: .mashup, calendar: calendar
        )
        task.priority = "High"
        task.difficulty = "Hard"
        task.coreTasks = labels.map { CoreTask(title: $0) }
        task.predefinedVersion = 4
        return task
    }

    private static func block(
        date: Date, key: String, title: String, start: Int, end: Int,
        description: String = "", kind: TaskKind = .normal, displayColor: TaskDisplayColor = .none,
        predefinedKind: PredefinedBlockKind, calendar: Calendar
    ) -> PlanTask {
        PlanTask(
            id: stableID(date: date, key: key, calendar: calendar), title: title,
            description: description,
            startMinute: start, cycles: max(1, (end - start + 29) / 30),
            kind: kind, priority: "Medium", difficulty: "Easy", mvp: "",
            routineOverride: true, routineBlock: true, durationMinutes: end - start,
            displayColor: displayColor, predefinedKind: predefinedKind,
            predefinedKey: key, predefinedVersion: 4
        )
    }

    public static func retiredIDs(for date: Date, calendar: Calendar = WallClock.dhakaCalendar()) -> [UUID] {
        guard [5, 7].contains(calendar.component(.weekday, from: date)) else { return [] }
        return ["rest-evening", "mashup-evening"].map { stableID(date: date, key: $0, calendar: calendar) }
    }

    public static func upgrade(_ existing: PlanTask, to definition: PlanTask) -> PlanTask {
        var task = existing
        let key = definition.predefinedKey ?? existing.predefinedKey
        let legacyTitles: Set<String> = [
            "Morning Routine — Audio Wakeup + Bath & Weight + Coffee & Water",
            "Rest — InstaS + Bath + Food + Coffee",
            "CSE111 Class", "CSE111L Class", "CSE220 Class", "CSE220L Class",
            "CSE220-15-SHBZ-09D-17C", "CSE220L-15-TBA-09B-09L",
            "STA201-16-SFQR-09H-37C", "CSE111-06-ADU-09H-35C", "CSE111-08-KNI-09B-11L",
        ]
        if legacyTitles.contains(task.title) || task.title.isEmpty { task.title = definition.title }
        let previousMVP = task.mvp.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDescription = task.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if currentDescription.isEmpty {
            task.description = previousMVP.isEmpty ? definition.description : previousMVP
        } else if !previousMVP.isEmpty && !currentDescription.contains(previousMVP) {
            task.description = currentDescription + "\n" + previousMVP
        }
        task.mvp = ""
        if definition.predefinedKind == .mashup {
            // Version 4 intentionally normalizes every recurring Mashup to the
            // exact contest definition requested by the user.
            task.title = definition.title
            task.startMinute = definition.startMinute
            task.durationMinutes = definition.durationMinutes
            task.cycles = definition.cycles
            task.kind = definition.kind
            task.priority = definition.priority
            task.difficulty = definition.difficulty
            task.description = definition.description
            task.coreTasks = definition.coreTasks
            task.displayColor = definition.displayColor
        } else if definition.predefinedKind == .university {
            // University color is semantic, not decorative: every class and
            // lab must remain visibly red across native/web synchronization.
            task.displayColor = .red
        } else {
            if task.displayColor == nil { task.displayColor = definition.displayColor }
        }
        task.routineBlock = true
        task.predefinedKind = definition.predefinedKind
        task.predefinedKey = key
        task.predefinedVersion = definition.predefinedVersion
        return task
    }

    public static func stableID(date: Date, key: String, calendar: Calendar = WallClock.dhakaCalendar()) -> UUID {
        let day = MarkdownPlanCodec.isoDate(date, calendar: calendar)
        let input = "refocus-routine:\(day):\(key)"
        var bytes = [UInt8](repeating: 0, count: 16)
        for salt in 0..<4 {
            var hash: UInt32 = 2_166_136_261
            for byte in "\(input)#\(salt)".utf8 {
                hash = (hash ^ UInt32(byte)) &* 16_777_619
            }
            for offset in 0..<4 {
                bytes[salt * 4 + offset] = UInt8((hash >> UInt32((3 - offset) * 8)) & 0xff)
            }
        }
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
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

    /// Returns the earliest free physical half-hour slot in a planning window.
    /// Scheduled routine and fixed blocks participate exactly like user tasks.
    public func firstUnusedSlot(
        in tasks: [PlanTask],
        startingAt minute: Int,
        before endMinute: Int
    ) -> Int? {
        var cursor = max(0, (minute / 30) * 30)
        let scheduled = tasks.filter(\.hasScheduledTime)
        while cursor + 30 <= endMinute {
            let occupied = scheduled.contains { task in
                task.startMinute < cursor + 30 && task.endMinute > cursor
            }
            if !occupied { return cursor }
            cursor += 30
        }
        return nil
    }

    public func requiredCycles(
        at date: Date,
        profile: DayProfile,
        tasks: [PlanTask]? = nil,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> Int {
        requiredCycles(
            in: segment(at: date, calendar: calendar), at: date,
            profile: profile, tasks: tasks, calendar: calendar
        )
    }

    public func segment(at date: Date, calendar: Calendar = WallClock.dhakaCalendar()) -> PlanningSegment {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if minute < 720 { return .morning }
        if minute < 1080 { return .afternoon }
        return .evening
    }

    public func requiredCycles(
        in segment: PlanningSegment,
        at date: Date,
        profile: DayProfile,
        tasks: [PlanTask]? = nil,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let currentCycleStart = (minute / 30) * 30
        let firstAvailableSlot = max(segment.startMinute, currentCycleStart)
        guard firstAvailableSlot < segment.endMinute else { return 0 }

        // Rest only consumes planning capacity while its editable predefined
        // task exists for this date. Deleting a one-hour Rest therefore
        // releases its two physical half-hour slots and raises the gate from
        // 10 to 12. Calls without loaded tasks retain the routine defaults.
        let restWindows: [RoutineWindow]
        if let tasks {
            restWindows = tasks.compactMap { task in
                guard task.hasScheduledTime,
                      task.isRoutineBlock,
                      task.predefinedKind == .rest else { return nil }
                return RoutineWindow(task.startMinute, task.endMinute, .protected, task.title)
            }
        } else {
            restWindows = FixedPlanTasks.defaultRestWindows
        }

        var available = 0
        var cursor = firstAvailableSlot
        while cursor + 30 <= segment.endMinute {
            let blocked = (profile.protectedWindows + restWindows)
                .contains { $0.overlaps(start: cursor, end: cursor + 30) }
            if !blocked { available += 1 }
            cursor += 30
        }
        return min(segment.maximumCycles, available)
    }

    public func availabilityIssue(
        in segment: PlanningSegment,
        at date: Date,
        profile: DayProfile,
        tasks: [PlanTask]? = nil,
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> PlanValidationIssue? {
        requiredCycles(in: segment, at: date, profile: profile, tasks: tasks, calendar: calendar) == 0
            ? .noAvailableCycles(segment: segment)
            : nil
    }

    public func validate(
        tasks: [PlanTask],
        profile: DayProfile,
        minimumCycles: Int = 12,
        requireFixedTasks: Bool = true,
        requireTaskDetails: Bool = true,
        countedSegment: PlanningSegment? = nil,
        scheduledDate: Date? = nil,
        now: Date = Date(),
        calendar: Calendar = WallClock.dhakaCalendar()
    ) -> [PlanValidationIssue] {
        var issues: [PlanValidationIssue] = []
        var seenTaskIDs = Set<UUID>()
        let uniqueTasks = tasks.filter { seenTaskIDs.insert($0.id).inserted }
        let totalCycles: Int
        if let countedSegment {
            totalCycles = uniqueTasks.reduce(0) { $0 + $1.planningCycles(in: countedSegment) }
        } else {
            totalCycles = uniqueTasks.filter(\.hasScheduledTime).filter(\.countsTowardPlanning).reduce(0) { $0 + $1.cycles }
        }
        if totalCycles < minimumCycles {
            issues.append(.insufficientCycles(actual: totalCycles, required: minimumCycles))
        }

        for task in uniqueTasks {
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
                if !(1...(task.isRoutineBlock ? 10 : 4)).contains(task.cycles) {
                    issues.append(.invalidCycleCount(task: displayTitle))
                }
            case .contest:
                if !(1...10).contains(task.cycles) {
                    issues.append(.invalidContest(task: displayTitle))
                }
            }

            let historical: Bool = {
                guard let scheduledDate else { return false }
                let day = calendar.startOfDay(for: scheduledDate)
                let today = calendar.startOfDay(for: now)
                if day < today { return true }
                guard day == today else { return false }
                let parts = calendar.dateComponents([.hour, .minute], from: now)
                return task.endMinute <= (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }()
            if requireTaskDetails && !historical && !task.isRoutineBlock && task.quickCapture != true {
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
            if requireTaskDetails && !historical && !task.hasScheduledTime && task.quickCapture != true {
                issues.append(.missingTime(task: displayTitle))
            }
            guard task.hasScheduledTime else { continue }
            if task.endMinute > 1290 { issues.append(.afterSleepCutoff(task: displayTitle)) }
            if !task.routineOverride && !task.isRoutineBlock {
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

        if requireFixedTasks { validateFixedTasks(uniqueTasks, issues: &issues) }

        let ordered = uniqueTasks.filter(\.hasScheduledTime).sorted { $0.startMinute < $1.startMinute }
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
