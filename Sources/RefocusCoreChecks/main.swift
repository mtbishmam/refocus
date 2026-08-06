import Foundation
import RefocusCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

let calendar = WallClock.dhakaCalendar()

func date(_ value: String, format: String = "yyyy-MM-dd HH:mm:ss") throws -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = format
    guard let date = formatter.date(from: value) else { throw CheckFailure.failed("Could not parse \(value)") }
    return date
}

func time(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

func expectIndex(_ needle: String, in text: String) throws -> String.Index {
    guard let range = text.range(of: needle) else {
        throw CheckFailure.failed("Missing expected text: \(needle)")
    }
    return range.lowerBound
}

var checks = 0
func check(_ name: String, _ body: () throws -> Void) rethrows {
    try body()
    checks += 1
    print("✓ \(name)")
}

do {
    try check("11:17 joins the 11:00 focus phase") {
        let snapshot = WallClock(calendar: calendar).snapshot(at: try date("2026-08-04 11:17:00"))
        try expect(snapshot.phase == .focus, "Expected focus")
        try expect(time(snapshot.phaseStart) == "11:00", "Wrong focus start")
        try expect(time(snapshot.phaseEnd) == "11:25", "Wrong focus end")
        try expect(snapshot.secondsRemaining == 480, "Wrong countdown")
    }
    try check("11:27 joins the 11:25 screen break") {
        let snapshot = WallClock(calendar: calendar).snapshot(at: try date("2026-08-04 11:27:00"))
        try expect(snapshot.phase == .screenBreak, "Expected break")
        try expect(time(snapshot.phaseEnd) == "11:30", "Wrong break end")
    }
    try check("19:51 remains focus and 19:55 begins screen break") {
        let focus = WallClock(calendar: calendar).snapshot(at: try date("2026-08-05 19:51:00"))
        let screenBreak = WallClock(calendar: calendar).snapshot(at: try date("2026-08-05 19:55:00"))
        try expect(focus.phase == .focus, "19:51 incorrectly entered screen break")
        try expect(time(focus.phaseEnd) == "19:55", "19:51 focus should end at 19:55")
        try expect(screenBreak.phase == .screenBreak, "19:55 did not enter screen break")
        try expect(time(screenBreak.phaseEnd) == "20:00", "19:55 break should end at 20:00")
    }
    try check("Monday uses Standard Routine") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-03", format: "yyyy-MM-dd"))
        try expect(profile.kind == .standard, "Monday was not standard")
        try expect(profile.windows.contains { $0.kind == .contest && $0.startMinute == 360 && $0.endMinute == 660 }, "Morning contest missing")
    }
    try check("Tuesday keeps contest and protects university") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-04", format: "yyyy-MM-dd"))
        try expect(profile.kind == .universityLate, "Tuesday profile wrong")
        try expect(profile.windows.contains { $0.kind == .contest && $0.startMinute == 360 }, "Tuesday contest missing")
        try expect(profile.protectedWindows.contains { $0.startMinute == 750 && $0.endMinute == 1020 }, "Tuesday university missing")
        try expect(profile.windows.contains { $0.kind == .eveningRoutine && $0.startMinute == 1080 }, "Tuesday evening missing")
    }
    try check("Thursday omits contest and protects university") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-06", format: "yyyy-MM-dd"))
        try expect(profile.kind == .universityEarly, "Thursday profile wrong")
        try expect(!profile.windows.contains { $0.kind == .contest }, "Thursday should omit contest")
        try expect(profile.protectedWindows.contains { $0.startMinute == 480 && $0.endMinute == 840 }, "Thursday university missing")
    }
    try check("Friday uses only the SSC contest") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-07", format: "yyyy-MM-dd"))
        let contests = profile.windows.filter { $0.kind == .contest }
        try expect(profile.kind == .fridaySSC, "Friday profile wrong")
        try expect(contests == [RoutineWindow(540, 780, .contest, "Four-hour SSC contest")], "Friday contest wrong")
    }
    try check("Plan validation rejects university overlap") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-04", format: "yyyy-MM-dd"))
        let contest = PlanTask(
            title: "Codeforces contest", startMinute: 360, cycles: 10, kind: .contest,
            priority: "Do/Die", difficulty: "Hard", mvp: "Complete the contest",
            coreTasks: [CoreTask(title: "Setup"), CoreTask(title: "Compete"), CoreTask(title: "Review")]
        )
        let overlapping = PlanTask(title: "Bad task", startMinute: 750, cycles: 1, mvp: "Finish")
        let issues = PlanValidator().validate(tasks: [contest, overlapping], profile: profile)
        try expect(issues.contains(where: {
            if case .routineConflict(_, "Bad task", "University", 750, 1020) = $0 { return true }
            return false
        }), "University overlap not found")
        try expect(issues.contains(where: { $0.severity == .warning }), "University overlap was not overridable")
        try expect(!issues.contains(.invalidContest(task: "Codeforces contest")), "Flexible contest was rejected")
    }
    try check("Today parser ignores Later") {
        let markdown = """
        # Today - 2026-08-04

        <!-- refocus:plan v=1 profile=university-late -->
        - [ ] 06:00–11:00 → Five-hour contest
          <!-- refocus:task id=11111111-1111-1111-1111-111111111111 start=06:00 cycles=10 kind=contest priority=Do/Die difficulty=Hard -->
          - MVP → Finish the contest
          - Core tasks
            1. [ ] Setup
            2. [ ] Compete
            3. [ ] Review
        <!-- /refocus:plan -->

        # Later
        - [ ] 12:00–14:00 → Must not appear
        """
        let plan = try MarkdownPlanCodec(calendar: calendar).parseToday(markdown, date: date("2026-08-04", format: "yyyy-MM-dd"))
        try expect(plan.tasks.count == 1, "Later leaked into Today")
        try expect(plan.tasks.first?.coreTasks.count == 3, "Core tasks not parsed")
    }
    try check("Managed writes preserve Later and Inbox") {
        let original = """
        # Today - 2026-08-04

        <!-- refocus:plan v=1 profile=university-late -->
        <!-- /refocus:plan -->

        # Later
        Keep this exactly.

        # Inbox
        Raw thought.
        """
        let task = PlanTask(title: "Task", startMinute: 1080, cycles: 1, mvp: "Done")
        let updated = try MarkdownPlanCodec(calendar: calendar).replacingTodayBlock(
            in: original, date: date("2026-08-04", format: "yyyy-MM-dd"), tasks: [task], profile: .universityLate
        )
        try expect(updated.contains("Keep this exactly."), "Later was changed")
        try expect(updated.contains("Raw thought."), "Inbox was changed")
        try expect(updated.contains("18:00–18:30 → Task"), "Task not rendered")
        try expect(!updated.contains("Completion →"), "Legacy Completion field rendered")
    }
    try check("Initial and modified plans remain distinct") {
        let planDate = try date("2026-08-06", format: "yyyy-MM-dd")
        let codec = MarkdownPlanCodec(calendar: calendar)
        let initial = PlanTask(
            title: "Initial", startMinute: 840, cycles: 1, mvp: "Initial result",
            coreTasks: [CoreTask(title: "One"), CoreTask(title: "Two"), CoreTask(title: "Three")]
        )
        let modified = PlanTask(
            title: "Modified", startMinute: 870, cycles: 1, mvp: "Modified result",
            coreTasks: [CoreTask(title: "One"), CoreTask(title: "Two"), CoreTask(title: "Three")]
        )
        let markdown = "# Today - 2026-08-06\n\n\(codec.renderInitialBlock(tasks: [initial], profile: .universityEarly))\n\n\(codec.renderManagedBlock(tasks: [modified], profile: .universityEarly))"
        let parsed = try codec.parseToday(markdown, date: planDate)
        try expect(parsed.initialSegments.contains(.morning), "Morning initial plan marker was not detected")
        try expect(parsed.tasks.map(\.title) == ["Modified"], "Initial plan leaked into the live plan")
    }
    try check("Agenda Markdown round-trips future tasks") {
        let futureDate = try date("2026-08-27", format: "yyyy-MM-dd")
        let task = PlanTask(
            title: "MAT120 Exam", startMinute: 1020, cycles: 3, priority: "Do/Die", difficulty: "Hard",
            mvp: "Complete the exam", coreTasks: [CoreTask(title: "Arrive"), CoreTask(title: "Solve"), CoreTask(title: "Review")]
        )
        let codec = AgendaMarkdownCodec(calendar: calendar)
        let rendered = codec.render([AgendaTask(date: futureDate, task: task)])
        let parsed = codec.parse(rendered)
        try expect(parsed.count == 1 && parsed[0].task.title == "MAT120 Exam", "Agenda task did not round-trip")
        try expect(MarkdownPlanCodec.isoDate(parsed[0].date, calendar: calendar) == "2026-08-27", "Agenda date changed")
    }
    try check("First plan preserves unrelated Markdown") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-first-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tasksURL = temporary.appendingPathComponent("tasks.md")
        let original = """
        # Later
        Keep later exactly.

        # Inbox
        Keep inbox exactly.
        """
        try original.write(to: tasksURL, atomically: true, encoding: .utf8)
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let task = PlanTask(title: "Named task", startMinute: 1080, cycles: 1, priority: "High", difficulty: "Hard", mvp: "Concrete result")
        let planDate = try date("2026-08-05", format: "yyyy-MM-dd")
        try repository.saveToday(date: planDate, tasks: [task], profile: .standard, segment: .evening, expectedTasks: [])
        let updated = try String(contentsOf: tasksURL, encoding: .utf8)
        try expect(updated.hasPrefix("# Today - 2026-08-05"), "Current Today heading was not created")
        try expect(updated.contains("Keep later exactly."), "Later was overwritten")
        try expect(updated.contains("Keep inbox exactly."), "Inbox was overwritten")
        try expect(updated.contains("refocus:initial-plan"), "Initial plan snapshot missing")
    }
    try check("Planning gate rejects placeholder and blank core tasks") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-05", format: "yyyy-MM-dd"))
        let placeholder = PlanTask(
            title: "New task", startMinute: 720, cycles: 4, priority: "Medium", difficulty: "Moderate",
            mvp: "Concrete result", coreTasks: [CoreTask(title: ""), CoreTask(title: "Two"), CoreTask(title: "Three")]
        )
        let issues = PlanValidator().validate(tasks: [placeholder], profile: profile)
        try expect(issues.contains(.missingTaskTitle), "Placeholder task name was accepted")
        try expect(issues.contains(.emptyCoreTask(task: "New task")), "Blank core task was accepted")
    }
    try check("Hard rest blocks are red and cannot be overridden") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-06", format: "yyyy-MM-dd"))
        let task = PlanTask(
            title: "Rest collision", startMinute: 660, cycles: 1, mvp: "Done",
            coreTasks: [CoreTask(title: "One"), CoreTask(title: "Two"), CoreTask(title: "Three")],
            routineOverride: true
        )
        let issues = PlanValidator().validate(tasks: [task] + FixedPlanTasks.daily(), profile: profile, minimumCycles: 0)
        try expect(issues.contains(.hardRest(task: "Rest collision", startMinute: 660, endMinute: 720)), "11:00–12:00 rest collision missing")
        try expect(issues.first(where: {
            if case .hardRest = $0 { return true }; return false
        })?.severity == .error, "Hard rest was not red")
    }
    try check("Fixed evening blocks and flexible subtasks validate") {
        var tasks = FixedPlanTasks.daily()
        tasks[1].cycles = 2
        tasks[1].coreTasks.append(CoreTask(title: "Call family"))
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-06", format: "yyyy-MM-dd"))
        let issues = PlanValidator().validate(tasks: tasks, profile: profile, minimumCycles: 0)
        try expect(!issues.contains(where: {
            if case .overlap = $0 { return true }; return false
        }), "Allowed Plan Tomorrow/ReVision overlap was rejected")
        try expect(!issues.contains(where: {
            if case .tooFewSubtasks = $0 { return true }; return false
        }), "More than three subtasks was rejected")
    }
    try check("Contest is one flexible kind capped at ten cycles") {
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: try date("2026-08-05", format: "yyyy-MM-dd"))
        let valid = PlanTask(
            title: "Codeforces contest", startMinute: 960, cycles: 10, kind: .contest,
            priority: "High", difficulty: "Hard", mvp: "Submit the contest",
            coreTasks: [CoreTask(title: "Solve A"), CoreTask(title: "Solve B"), CoreTask(title: "Review")]
        )
        let tooLong = PlanTask(
            title: "Too long", startMinute: 360, cycles: 11, kind: .contest,
            priority: "High", difficulty: "Hard", mvp: "Finish",
            coreTasks: [CoreTask(title: "One"), CoreTask(title: "Two"), CoreTask(title: "Three")]
        )
        let validator = PlanValidator()
        try expect(!validator.validate(tasks: [valid], profile: profile, minimumCycles: 10).contains(.invalidContest(task: "Codeforces contest")), "Ten-cycle contest was rejected")
        try expect(validator.validate(tasks: [tooLong], profile: profile).contains(.invalidContest(task: "Too long")), "Eleven-cycle contest was accepted")
    }
    try check("Late planning minimum shrinks to remaining cycles") {
        let moment = try date("2026-08-05 20:15:00")
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: moment)
        try expect(PlanValidator().requiredCycles(at: moment, profile: profile, calendar: calendar) == 3, "Expected the three evening slots through 21:30")
    }
    try check("Planning minimums are independent per super-block") {
        let validator = PlanValidator()
        let thursdayMorning = try date("2026-08-06 06:00:00")
        let thursdayAfternoon = try date("2026-08-06 14:00:00")
        let thursdayEvening = try date("2026-08-06 18:00:00")
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: thursdayMorning)
        try expect(validator.requiredCycles(at: thursdayMorning, profile: profile, calendar: calendar) == 4, "Thursday morning should stop at University")
        try expect(validator.requiredCycles(at: thursdayAfternoon, profile: profile, calendar: calendar) == 6, "Thursday afternoon should count 14:00–17:00")
        try expect(validator.requiredCycles(at: thursdayEvening, profile: profile, calendar: calendar) == 7, "Evening should use seven cycles")
        let issues = validator.validate(
            tasks: FixedPlanTasks.daily(), profile: profile, minimumCycles: 4,
            countedSegment: .morning
        )
        try expect(issues.contains(.insufficientCycles(actual: 0, required: 4)), "Fixed evening cycles leaked into the morning gate")
    }
    try check("Task templates round-trip through Markdown") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-template-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let template = PlanTask(
            title: "Five-hour contest", startMinute: 360, cycles: 10, kind: .contest,
            priority: "Do/Die", difficulty: "Hard", mvp: "Finish the contest",
            coreTasks: [CoreTask(title: "Setup"), CoreTask(title: "Compete"), CoreTask(title: "Review")]
        )
        try repository.saveTemplates([template])
        let loaded = try repository.loadTemplates()
        try expect(loaded.count == 1 && loaded[0].title == template.title, "Saved template could not be loaded")
        try expect(loaded[0].cycles == 10 && loaded[0].kind == .contest, "Template fields changed")
    }
    try check("Later saves preserve Initial and refresh Modified snapshots") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-snapshot-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let planDate = try date("2026-08-05", format: "yyyy-MM-dd")
        let morning = PlanTask(title: "Morning initial", startMinute: 360, cycles: 1, mvp: "Initial")
        try repository.saveToday(date: planDate, tasks: [morning], profile: .standard, segment: .morning, expectedTasks: [])
        var changed = morning
        changed.title = "Morning modified"
        let afternoon = PlanTask(title: "Afternoon", startMinute: 720, cycles: 1, mvp: "Done")
        try repository.saveToday(date: planDate, tasks: [changed, afternoon], profile: .standard, segment: .afternoon, expectedTasks: [morning])
        let log = try String(contentsOf: repository.dailyLogURL(for: planDate), encoding: .utf8)
        try expect(log.contains("Morning initial"), "Immutable morning Initial snapshot changed")
        try expect(log.contains("Morning modified"), "Morning Modified snapshot was not refreshed")
        try expect(log.contains("initial-plan-snapshot segment=afternoon"), "Afternoon Initial snapshot missing")
    }
    try check("Daily filename is log/aug-4.md") {
        let repository = VaultRepository(vaultURL: FileManager.default.temporaryDirectory, calendar: calendar)
        let augustFourth = try date("2026-08-04", format: "yyyy-MM-dd")
        try expect(repository.dailyLogURL(for: augustFourth).lastPathComponent == "aug-4.md", "Wrong filename")
    }
    try check("Repository preserves unrelated content and detects same-plan conflicts") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tasksURL = temporary.appendingPathComponent("tasks.md")
        let original = """
        # Today - 2026-08-04

        <!-- refocus:plan v=1 profile=university-late -->
        - [ ] 18:00–18:30 → Original
          <!-- refocus:task id=11111111-1111-1111-1111-111111111111 start=18:00 cycles=1 kind=normal priority=High difficulty=Hard -->
          - MVP → Original MVP
        <!-- /refocus:plan -->

        # Later
        Keep later.

        # Completed

        ---

        # Inbox
        Keep inbox.
        """
        try original.write(to: tasksURL, atomically: true, encoding: .utf8)
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let augustFourth = try date("2026-08-04", format: "yyyy-MM-dd")
        let baseline = try repository.loadToday(date: augustFourth).tasks
        var edited = baseline
        edited[0].mvp = "Edited MVP"
        try repository.saveToday(date: augustFourth, tasks: edited, profile: .universityLate, segment: .evening, expectedTasks: baseline)
        let afterSave = try String(contentsOf: tasksURL, encoding: .utf8)
        try expect(afterSave.contains("Keep later."), "Later was overwritten")
        try expect(afterSave.contains("Keep inbox."), "Inbox was overwritten")

        let external = afterSave.replacingOccurrences(of: "Edited MVP", with: "External MVP")
        try external.write(to: tasksURL, atomically: true, encoding: .utf8)
        do {
            try repository.saveToday(date: augustFourth, tasks: edited, profile: .universityLate, segment: .evening, expectedTasks: edited)
            throw CheckFailure.failed("Expected an external-edit conflict")
        } catch VaultRepositoryError.planConflict {
            // Expected.
        }
    }
    try check("Focus check-in creates the hyphenated daily log") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-log-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let logDirectory = temporary.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let streakText = """
        # Streak Definitions
        - Solve five harder problems <!-- refocus:streak id=five-harder-problems mode=manual -->
        - Complete the minimum daily plan <!-- refocus:streak id=minimum-plan mode=planMinimum -->
        - No missed check-ins <!-- refocus:streak id=no-missed-checkins mode=noMissedCheckIns -->
        """
        try streakText.write(to: logDirectory.appendingPathComponent("streaks.md"), atomically: true, encoding: .utf8)
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        try expect(repository.streaksURL.path.hasSuffix("/log/streaks.md"), "Streak definitions are not inside log")
        let focusStart = try date("2026-08-04 11:00:00")
        let focusEnd = try date("2026-08-04 11:25:00")
        let checkIn = CheckIn(
            id: "20260804-1100", taskID: nil, taskTitle: "Do/Die",
            focusStart: focusStart, focusEnd: focusEnd, whatDid: "Solved one problem", outcome: .complete
        )
        try repository.saveCheckIn(checkIn, date: focusStart, streaks: VaultRepository.defaultStreaks)
        let logURL = repository.dailyLogURL(for: focusStart)
        let text = try String(contentsOf: logURL, encoding: .utf8)
        try expect(logURL.lastPathComponent == "aug-4.md", "Daily log filename wrong")
        try expect(text.contains("date: 2026-08-04"), "ISO frontmatter missing")
        try expect(text.contains("What I did → Solved one problem"), "Check-in missing")
        try expect(text.contains("state=blank"), "Blank streak state missing")
        let automaticDefinition = VaultRepository.defaultStreaks[2]
        try repository.setStreakValue(automaticDefinition, status: .fail, date: focusStart)
        let manuallyFailed = try String(contentsOf: logURL, encoding: .utf8)
        try expect(manuallyFailed.contains("state=fail"), "Fail streak state was not saved")
    }
    try check("Today check-ins stay above the Tomorrow section") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-checkin-section-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let today = try date("2026-08-06", format: "yyyy-MM-dd")
        let tomorrow = try date("2026-08-07", format: "yyyy-MM-dd")
        let task = PlanTask(title: "Work", startMinute: 840, cycles: 1, mvp: "Done")
        try repository.saveToday(date: today, tasks: [task], profile: .universityEarly, segment: .afternoon, expectedTasks: [])
        try repository.saveTomorrow(date: tomorrow, tasks: [task], profile: .fridaySSC)
        let checkIn = CheckIn(
            id: "20260806-1400", taskID: task.id, taskTitle: task.title,
            focusStart: try date("2026-08-06 14:00:00"), focusEnd: try date("2026-08-06 14:25:00"),
            whatDid: "Finished the task"
        )
        try repository.saveCheckIn(checkIn, date: today, streaks: VaultRepository.defaultStreaks)
        let text = try String(contentsOf: repository.tasksURL, encoding: .utf8)
        let logPosition = try expectIndex("## Screen Break Logs", in: text)
        let tomorrowPosition = try expectIndex("# Tomorrow - 2026-08-07", in: text)
        try expect(logPosition < tomorrowPosition, "Today check-in was written beneath Tomorrow")
    }
    try check("Rollover archives old Today and promotes prepared Tomorrow") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-rollover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let oldDate = try date("2026-08-06", format: "yyyy-MM-dd")
        let newDate = try date("2026-08-07", format: "yyyy-MM-dd")
        let oldTask = PlanTask(title: "Old work", startMinute: 840, cycles: 1, mvp: "Old result")
        let prepared = PlanTask(title: "Prepared tomorrow", startMinute: 360, cycles: 1, mvp: "New result")
        try repository.saveToday(date: oldDate, tasks: [oldTask], profile: .universityEarly, segment: .afternoon, expectedTasks: [])
        try repository.saveTomorrow(date: newDate, tasks: [prepared], profile: .fridaySSC)
        try repository.saveToday(date: newDate, tasks: [prepared], profile: .fridaySSC, segment: .morning, expectedTasks: [])
        let tasks = try String(contentsOf: repository.tasksURL, encoding: .utf8)
        try expect(!tasks.contains("# Today - 2026-08-06"), "Stale Today remained after rollover")
        try expect(tasks.contains("# Today - 2026-08-07"), "Prepared Tomorrow was not promoted")
        let oldLog = try String(contentsOf: repository.dailyLogURL(for: oldDate), encoding: .utf8)
        try expect(oldLog.contains("Old work"), "Old Today was not archived in its daily log")
    }
    print("\nAll \(checks) ReFocus core checks passed.")
} catch {
    fputs("ReFocus core check failed: \(error)\n", stderr)
    exit(1)
}
