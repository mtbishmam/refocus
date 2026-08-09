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
    try check("Editable Rest blocks block collisions until removed") {
        let planDate = try date("2026-08-05", format: "yyyy-MM-dd")
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: planDate)
        let task = PlanTask(
            title: "Rest collision", startMinute: 660, cycles: 1, mvp: "Done",
            coreTasks: [CoreTask(title: "One"), CoreTask(title: "Two"), CoreTask(title: "Three")],
            routineOverride: true
        )
        let defaults = PredefinedRoutineBlocks.daily(for: planDate, calendar: calendar)
        let issues = PlanValidator().validate(tasks: [task] + defaults + FixedPlanTasks.daily(), profile: profile, minimumCycles: 0)
        try expect(issues.contains(where: {
            if case .overlap(let first, let second) = $0 { return first.contains("Rest") || second.contains("Rest") }
            return false
        }), "Rest collision was not blocked while the default remained")
        let withoutRest = defaults.filter { !$0.title.hasPrefix("Rest") }
        let customized = PlanValidator().validate(tasks: [task] + withoutRest + FixedPlanTasks.daily(), profile: profile, minimumCycles: 0)
        try expect(!customized.contains(where: {
            if case .overlap = $0 { return true }; return false
        }), "Deleted Rest default continued to block customization")
    }
    try check("Ikigai routine blocks match the weekly timetable") {
        let saturday = try date("2026-08-08", format: "yyyy-MM-dd")
        let sunday = try date("2026-08-09", format: "yyyy-MM-dd")
        let saturdayBlocks = PredefinedRoutineBlocks.daily(for: saturday, calendar: calendar)
        let sundayBlocks = PredefinedRoutineBlocks.daily(for: sunday, calendar: calendar)
        try expect(saturdayBlocks.contains { $0.title == "CSE111/220 Study" && $0.startMinute == 570 && $0.endMinute == 615 }, "Saturday 09:30–10:15 study block missing")
        try expect(saturdayBlocks.contains { $0.title == "Return Home / Transition" && $0.startMinute == 750 && $0.endMinute == 780 }, "Saturday return-home block missing")
        let saturdayMashup = saturdayBlocks.first { $0.title == "5H Mashup" }
        let sundayMashup = sundayBlocks.first { $0.title == "5H Mashup" }
        try expect(saturdayMashup?.startMinute == 840 && saturdayMashup?.endMinute == 1140, "Saturday 14:00–19:00 mashup missing")
        try expect(saturdayMashup?.priority == "High" && saturdayMashup?.difficulty == "Hard" && saturdayMashup?.kind == .contest, "Saturday mashup metadata drifted")
        try expect(saturdayMashup?.mvp == "Just start the contest" && saturdayMashup?.displayColor == .yellow, "Saturday mashup MVP or color drifted")
        try expect(saturdayMashup?.coreTasks.first?.title == "2 - 2.5 -> Skim & Write approaches, tags", "Saturday mashup subtasks did not start at 2")
        try expect(saturdayMashup?.coreTasks.last?.title == "6 - 7 -> if 4 unsolved, then retry; else 5th", "Saturday mashup subtasks did not end at 7")
        try expect(sundayMashup?.coreTasks.first?.title == "6 - 6.5 -> Skim & Write approaches, tags", "Morning mashup subtasks did not start at 6")
        try expect(sundayMashup?.coreTasks.last?.title == "10 - 11 -> if 4 unsolved, then retry; else 5th", "Morning mashup subtasks did not end at 11")
        try expect(saturdayMashup?.planningCycles(in: .afternoon) == 6, "Afternoon gate did not count the 14:00–17:00 mashup cycles")
        try expect(saturdayMashup?.planningCycles(in: .evening) == 2, "Evening gate did not count the 18:00–19:00 mashup cycles")
        if let saturdayMashup {
            let duplicateIssues = PlanValidator().validate(
                tasks: [saturdayMashup, saturdayMashup],
                profile: RoutineProfileResolver(calendar: calendar).profile(for: saturday),
                minimumCycles: 6, requireFixedTasks: false, requireTaskDetails: true,
                countedSegment: .afternoon
            )
            try expect(!duplicateIssues.contains { if case .overlap = $0 { return true }; return false }, "Duplicate task identity created a self-overlap")
            try expect(!duplicateIssues.contains { if case .insufficientCycles = $0 { return true }; return false }, "Spanning mashup reported 0/6 Afternoon cycles")
        }
        try expect(sundayBlocks.contains { $0.title == "CSE220L Class" && $0.mvp == "CSE220L-15-TBA-09B-09L" && $0.startMinute == 840 && $0.endMinute == 1020 }, "Sunday university lab missing")
        try expect(sundayBlocks.filter { $0.predefinedKind == .university }.allSatisfy { $0.displayColor == .red && $0.predefinedVersion == 3 }, "Sunday university classes are not canonical red blocks")
        if let university = sundayBlocks.first(where: { $0.title == "CSE220L Class" }) {
            var staleUniversity = university
            staleUniversity.displayColor = .orange
            staleUniversity.predefinedVersion = 2
            let upgraded = PredefinedRoutineBlocks.upgrade(staleUniversity, to: university)
            try expect(upgraded.displayColor == .red && upgraded.predefinedVersion == 3, "Existing orange university class was not repaired")
        }
        try expect(sundayBlocks.contains { $0.title == "Return Home / Transition" && $0.startMinute == 1020 && $0.endMinute == 1050 }, "Sunday return-home block missing")
        try expect(sundayBlocks.first { $0.title == "Rest" }?.countsTowardPlanning == false, "Rest counted toward the planning gate")
        try expect(Set(saturdayBlocks.map(\.id)).count == saturdayBlocks.count, "Routine IDs are not unique")
        try expect(
            PredefinedRoutineBlocks.stableID(date: saturday, key: "morning-routine", calendar: calendar).uuidString.lowercased()
                == "1027c355-0f27-51c2-8e27-c02f0d27be9c",
            "Native routine IDs drifted from the web ID algorithm"
        )
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
    try check("Live Sunday planning state uses the current morning window") {
        let sundayEarly = try date("2026-08-09 04:35:00")
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: sundayEarly)
        let validator = PlanValidator()
        try expect(validator.segment(at: sundayEarly, calendar: calendar) == .morning, "04:35 was treated as the wrong planning block")
        try expect(validator.requiredCycles(at: sundayEarly, profile: profile, calendar: calendar) == 10, "Sunday morning required cycles did not refresh")
    }
    try check("Zero available cycles remain a hard planning lock") {
        let sundayAfternoon = try date("2026-08-09 14:40:00")
        let profile = RoutineProfileResolver(calendar: calendar).profile(for: sundayAfternoon)
        let validator = PlanValidator()
        try expect(validator.requiredCycles(at: sundayAfternoon, profile: profile, calendar: calendar) == 0, "Sunday protected afternoon unexpectedly exposed work cycles")
        try expect(
            validator.availabilityIssue(in: .afternoon, at: sundayAfternoon, profile: profile, calendar: calendar)
                == .noAvailableCycles(segment: .afternoon),
            "A zero-availability planning block did not produce a hard lock issue"
        )
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
    try check("Human daily filename is journal/aug-4.md") {
        let repository = VaultRepository(vaultURL: FileManager.default.temporaryDirectory, calendar: calendar)
        let augustFourth = try date("2026-08-04", format: "yyyy-MM-dd")
        try expect(repository.dailyLogURL(for: augustFourth).lastPathComponent == "aug-4.md", "Wrong filename")
        try expect(repository.dailyLogURL(for: augustFourth).path.contains("/journal/"), "Human journal is not inside journal")
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
    try check("Legacy focus check-in creates the hyphenated journal") {
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
    try check("Unfinished stale Today tasks migrate to Agenda once") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-agenda-rollover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let oldDate = try date("2026-08-06", format: "yyyy-MM-dd")
        let newDate = try date("2026-08-07", format: "yyyy-MM-dd")
        let unfinished = PlanTask(title: "Carry this work", startMinute: 840, cycles: 1, mvp: "Carry result")
        let finished = PlanTask(title: "Already done", startMinute: 870, cycles: 1, mvp: "Done", isComplete: true)
        try repository.saveToday(date: oldDate, tasks: [unfinished, finished], profile: .universityEarly, segment: .afternoon, expectedTasks: [])
        let firstLoad = try repository.loadAgenda(asOf: newDate)
        try expect(firstLoad.map(\.task.title) == ["Carry this work"], "Only unfinished stale work migrated")
        let agendaMarkdown = try String(contentsOf: repository.agendaURL, encoding: .utf8)
        try expect(agendaMarkdown.contains("Carry this work"), "Migrated task was not persisted")
        try repository.saveAgenda([])
        let afterDelete = try repository.loadAgenda(asOf: newDate)
        try expect(afterDelete.isEmpty, "Deleted migrated task was resurrected")
    }
    try check("Quick notes append one line at the end of dump.md") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-quick-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        try "existing capture".write(to: repository.dumpURL, atomically: true, encoding: .utf8)
        try repository.appendQuickNote("first quick note")
        try repository.appendQuickNote("second quick note")
        let dump = try String(contentsOf: repository.dumpURL, encoding: .utf8)
        try expect(dump == "existing capture\nfirst quick note\nsecond quick note\n", "Quick notes were not appended cleanly")
    }
    try check("Quick capture retries are idempotent without suppressing intentional repeats") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-capture-retry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let before = try store.pendingMutations(limit: 100).count
        let submissionID = UUID().uuidString.lowercased()
        try store.appendCapture("same text", id: submissionID)
        try store.appendCapture("same text", id: submissionID)
        let after = try store.pendingMutations(limit: 100).count
        try expect(after == before + 1, "A retried capture was inserted twice")

        let writer = ProjectionWriter(vaultURL: temporary, calendar: calendar)
        try writer.appendCapture("same text")
        try writer.appendCapture("same text")
        let dump = try String(contentsOf: temporary.appendingPathComponent("dump.md"), encoding: .utf8)
        try expect(dump == "same text\nsame text\n", "Two intentional identical captures were collapsed")
    }
    try check("Archived daily logs do not repopulate Agenda") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-agenda-archive-\(UUID().uuidString)")
        let logDirectory = temporary.appendingPathComponent("log", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let archived = """
        ---
        date: 2026-08-05
        refocus_schema: 1
        ---

        # Today - 2026-08-05

        <!-- refocus:plan v=1 profile=standard -->
        - [ ] 18:00–18:30 → Archived task
          <!-- refocus:task id=11111111-1111-1111-1111-111111111111 start=18:00 cycles=1 kind=normal priority=Medium difficulty=Moderate -->
          - MVP → Archived result
        <!-- /refocus:plan -->
        """
        try archived.write(to: logDirectory.appendingPathComponent("aug-5.md"), atomically: true, encoding: .utf8)
        let repository = VaultRepository(vaultURL: temporary, calendar: calendar)
        let agenda = try repository.loadAgenda()
        try expect(agenda.isEmpty, "Archived task leaked back into Agenda")
    }
    try check("SQLite reschedule is immediate, atomic, and durable") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let source = try date("2026-08-07", format: "yyyy-MM-dd")
        let destination = try date("2026-08-08", format: "yyyy-MM-dd")
        let moved = PlanTask(title: "Move once", startMinute: 1080, cycles: 1, mvp: "Moved")
        let stays = PlanTask(title: "Stay here", startMinute: 1110, cycles: 1, mvp: "Stayed")
        try store.savePlan(date: source, tasks: [moved, stays], profile: .fridaySSC, segment: .evening)
        try store.rescheduleTask(
            id: moved.id, to: destination, sourceDate: source, remainingSourceTasks: [stays],
            profile: .fridaySSC, segment: .evening
        )
        let sourceTitles = try store.tasks(on: source).map(\.title)
        let destinationTitles = try store.tasks(on: destination).map(\.title)
        let destinationPlan = try store.loadPlan(date: destination)
        let pending = try store.pendingMutations()
        try expect(sourceTitles == ["Stay here"], "Source still contains moved task")
        try expect(destinationTitles == ["Move once"], "Destination did not receive moved task")
        try expect(destinationPlan?.tasks.map(\.title) == ["Move once"], "Destination day did not become loadable")
        try expect(destinationPlan?.initialSegments.isEmpty == true, "Rescheduling incorrectly created an Initial snapshot")
        try expect(!pending.isEmpty, "Atomic writes were not queued for sync")
        let mutation = try JSONSerialization.jsonObject(with: pending[0]) as? [String: Any]
        try expect(mutation?["entityId"] != nil, "Sync mutation omitted the server entityId key")
        try expect(mutation?["entityID"] == nil, "Sync mutation leaked the legacy entityID key")
    }
    try check("A new cloud target receives a complete local reseed") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-cloud-reseed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        let day = try date("2026-08-08", format: "yyyy-MM-dd")
        let task = PlanTask(title: "Migrate me", startMinute: 1080, cycles: 1, mvp: "Present in new D1")
        try store.importLegacy(
            today: nil, tomorrow: nil, agenda: [AgendaTask(date: day, task: task)],
            templates: [], streaks: [StreakDefinition(id: "exercise", name: "Exercise", mode: .manual)]
        )
        let oldPending = try store.pendingMutations()
        let oldIDs = oldPending.compactMap { payload -> String? in
            (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["mutationId"] as? String
        }
        try store.acknowledgeMutations(oldIDs)
        let clearedPending = try store.pendingMutations()
        try expect(clearedPending.isEmpty, "Test setup still had old outbox entries")

        let staged = try store.prepareCloudTarget("https://refocus.mtbishmam.chatgpt.site")
        let reseed = try store.pendingMutations(limit: 500)
        let kinds = Set(reseed.compactMap { payload -> String? in
            (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["entityKind"] as? String
        })
        try expect(staged > 0, "Cloud target change staged no records")
        try expect(kinds.contains("task"), "Cloud reseed omitted tasks")
        try expect(kinds.contains("field_definition"), "Cloud reseed omitted daily-field definitions")
        let repeated = try store.prepareCloudTarget("https://refocus.mtbishmam.chatgpt.site")
        try expect(repeated == 0, "Same target reseeded twice")
    }
    try check("Deleted routine defaults never reappear") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-routines-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let day = try date("2026-08-08", format: "yyyy-MM-dd")
        let initiallySeeded = try store.ensurePredefinedRoutineBlocks(on: day)
        try expect(initiallySeeded, "Routine defaults were not seeded")
        let rest = try store.tasks(on: day).first { $0.title.hasPrefix("Rest") }
        try expect(rest != nil, "Seeded routine omitted Rest")
        if let rest { try store.deleteTask(id: rest.id) }
        let reseeded = try store.ensurePredefinedRoutineBlocks(on: day)
        let activeTasks = try store.tasks(on: day)
        try expect(!reseeded, "Deleted default was inserted again")
        try expect(!activeTasks.contains { $0.id == rest?.id }, "Deleted Rest remained active")
    }
    try check("Agenda promotion appears in Today without changing Initial snapshots") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let today = try date("2026-08-07", format: "yyyy-MM-dd")
        let future = try date("2026-08-10", format: "yyyy-MM-dd")
        let existing = PlanTask(title: "Already today", startMinute: 1080, cycles: 1, mvp: "Done")
        let promoted = PlanTask(title: "Promoted", startMinute: 1110, cycles: 1, mvp: "Done")
        try store.savePlan(date: today, tasks: [existing], profile: .fridaySSC, segment: .evening)
        try store.saveScheduledEntries([AgendaTask(date: future, task: promoted)])
        try store.rescheduleTaskIntoPlan(
            id: promoted.id, to: today, destinationTasks: [existing, promoted],
            profile: .fridaySSC, segment: .evening
        )
        let plan = try store.loadPlan(date: today)
        try expect(plan?.tasks.map(\.title) == ["Already today", "Promoted"], "Promoted task is missing from Today")
        try expect(plan?.initialSegments == [.evening], "Promotion changed the initialized planning gates")
    }
    try check("Two agenda tasks can be promoted into Today without either disappearing") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-double-promote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let yesterday = try date("2026-08-08", format: "yyyy-MM-dd")
        let today = try date("2026-08-09", format: "yyyy-MM-dd")
        let first = PlanTask(title: "CP Plan", startMinute: 1080, cycles: 1, mvp: "Plan")
        let second = PlanTask(title: "Remake Routine", startMinute: 1140, cycles: 1, mvp: "Remake")
        try store.saveScheduledEntries([
            AgendaTask(date: yesterday, task: first), AgendaTask(date: yesterday, task: second),
        ])
        try store.rescheduleTaskIntoPlan(
            id: first.id, to: today, destinationTasks: [first],
            profile: .universityLate, segment: .evening
        )
        try store.rescheduleTaskIntoPlan(
            id: second.id, to: today, destinationTasks: [first, second],
            profile: .universityLate, segment: .evening
        )
        let promoted = try store.tasks(on: today)
        let remainingYesterday = try store.tasks(on: yesterday)
        try expect(Set(promoted.map(\.id)) == Set([first.id, second.id]), "One of two rapid Agenda promotions disappeared from Today")
        try expect(remainingYesterday.isEmpty, "Promoted tasks remained on yesterday")
    }
    try check("Existing scheduled tasks repair missing destination day records") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let databaseURL = temporary.appendingPathComponent("refocus.sqlite3")
        let scheduledDate = try date("2026-08-07", format: "yyyy-MM-dd")
        let scheduled = PlanTask(title: "Recovered original", startMinute: 1080, cycles: 1, mvp: "Visible")
        do {
            let store = try RefocusStore(databaseURL: databaseURL, calendar: calendar)
            try store.importLegacy(
                today: nil, tomorrow: nil,
                agenda: [AgendaTask(date: scheduledDate, task: scheduled)], templates: [], streaks: []
            )
        }
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [databaseURL.path, "DELETE FROM day_plans WHERE date = '2026-08-07'"]
        try sqlite.run()
        sqlite.waitUntilExit()
        try expect(sqlite.terminationStatus == 0, "Could not construct the legacy missing-day state")
        let reopened = try RefocusStore(databaseURL: databaseURL, calendar: calendar)
        let plan = try reopened.loadPlan(date: scheduledDate)
        try expect(plan?.tasks.map(\.title) == ["Recovered original"], "Scheduled task remained hidden after reopening")
        try expect(plan?.initialSegments.isEmpty == true, "Repair created an Initial snapshot")
    }
    try check("Daily fields persist and clean projections omit machine IDs") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-projection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        let planDate = try date("2026-08-07", format: "yyyy-MM-dd")
        let task = PlanTask(title: "Fast task", startMinute: 1080, cycles: 1, mvp: "Ship it")
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        try store.savePlan(date: planDate, tasks: [task], profile: .fridaySSC, segment: .evening)
        try store.setFieldValue(definitionID: "weight", value: "72.4", date: planDate)
        let values = try store.fieldValues(from: planDate, through: planDate)
        try expect(values.contains { $0.definitionID == "weight" && $0.value == "72.4" }, "Weight was not stored")
        let markdown = CleanMarkdownExporter(calendar: calendar).renderAgenda(
            [AgendaTask(date: planDate, task: task)], asOf: planDate
        )
        try expect(markdown.hasPrefix("# Tasks"), "Mobile projection kept the old Agenda heading")
        try expect(markdown.contains("Fast task"), "Clean Agenda omitted task")
        try expect(!markdown.contains(task.id.uuidString), "Clean Agenda leaked an internal ID")
        try expect(!markdown.contains("refocus:"), "Clean Agenda leaked a machine marker")
        let projectionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-projection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: projectionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectionDirectory) }
        try ProjectionWriter(vaultURL: projectionDirectory, calendar: calendar).exportTasks(
            [AgendaTask(date: planDate, task: task)], asOf: planDate
        )
        try expect(FileManager.default.fileExists(atPath: projectionDirectory.appendingPathComponent("tasks.md").path), "tasks.md projection was not written")
        try expect(!FileManager.default.fileExists(atPath: projectionDirectory.appendingPathComponent("agenda.md").path), "agenda.md was recreated")
    }
    try check("Habit catalog merges sources and retires Daily summary without data loss") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-habits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let databaseURL = temporary.appendingPathComponent("refocus.sqlite3")
        do {
            _ = try RefocusStore(databaseURL: databaseURL, calendar: calendar)
        }
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [databaseURL.path, """
            INSERT OR REPLACE INTO field_definitions(id,name,kind,unit,position,success_rule,archived)
            VALUES('daily-summary','Daily summary','text',NULL,999,NULL,0);
            INSERT OR REPLACE INTO field_values(definition_id,day,value,updated_hlc)
            VALUES('daily-summary','2026-08-08','Historical summary must survive','legacy');
            INSERT OR REPLACE INTO field_definitions(id,name,kind,unit,position,success_rule,archived)
            VALUES('solve-5-harder-problems','solve 5 harder problems','triState',NULL,2,NULL,0);
            INSERT OR REPLACE INTO field_values(definition_id,day,value,updated_hlc)
            VALUES('solve-5-harder-problems','2026-08-08','win','legacy');
            """]
        try sqlite.run()
        sqlite.waitUntilExit()
        try expect(sqlite.terminationStatus == 0, "Could not construct the legacy Daily summary state")

        let reopened = try RefocusStore(databaseURL: databaseURL, calendar: calendar)
        let definitions = try reopened.fieldDefinitions()
        let values = try reopened.fieldValues(
            from: try date("2026-08-08", format: "yyyy-MM-dd"),
            through: try date("2026-08-08", format: "yyyy-MM-dd")
        )
        let habitIDs = Set(definitions.filter { $0.kind == .triState }.map(\.id))
        try expect(Set(HabitCatalog.entries.map(\.id)).isSubset(of: habitIDs), "Merged Good/Bad habit definitions are incomplete")
        try expect(!definitions.contains { $0.id == "solve-5-harder-problems" }, "Legacy duplicate habit remains visible")
        try expect(values.contains { $0.definitionID == "five-harder-problems" && $0.value == "win" }, "Legacy habit value was not merged into its canonical column")
        try expect(values.contains { $0.definitionID == "solve-5-harder-problems" && $0.value == "win" }, "Legacy habit value was destructively removed")
        try expect(!definitions.contains { $0.id == "daily-summary" }, "Daily summary still appears as an app field")
        try expect(values.contains { $0.definitionID == "daily-summary" && $0.value == "Historical summary must survive" }, "Retiring Daily summary deleted its historical value")
    }
    try check("Agenda contains only user tasks and supports tasks without a time") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-agenda-user-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let day = try date("2026-08-26", format: "yyyy-MM-dd")
        let untimed = PlanTask(title: "Choose exam topics", startMinute: 540, cycles: 1, timeAssigned: false)
        let routine = PlanTask(title: "Rest", startMinute: 660, cycles: 2, routineBlock: true, predefinedKind: .rest)
        let fixed = FixedPlanTasks.daily()[0]
        try store.saveScheduledEntries([
            AgendaTask(date: day, task: untimed), AgendaTask(date: day, task: routine), AgendaTask(date: day, task: fixed),
        ])
        let agenda = try store.agenda(asOf: day)
        try expect(agenda.map(\.task.title) == ["Choose exam topics"], "Agenda included predefined or fixed blocks")
        try expect(agenda[0].task.hasScheduledTime == false, "Agenda fabricated a time for an untimed task")
        let markdown = CleanMarkdownExporter(calendar: calendar).renderAgenda(agenda, asOf: day)
        try expect(markdown.contains("Choose exam topics"), "Untimed task was omitted from the mobile projection")
        try expect(!markdown.contains("09:00"), "Mobile projection fabricated a 09:00 time")
        let issues = PlanValidator().validate(
            tasks: [untimed], profile: RoutineProfileResolver(calendar: calendar).profile(for: day),
            minimumCycles: 0, requireFixedTasks: false, requireTaskDetails: true
        )
        try expect(issues.contains(.missingTime(task: "Choose exam topics")), "Today validation accepted an untimed task")
    }
    try check("Task sync sends changed fields only and merges remote fields independently") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-field-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let day = try date("2026-08-08", format: "yyyy-MM-dd")
        var task = PlanTask(title: "Local title", startMinute: 1080, cycles: 2)
        try store.saveScheduledEntries([AgendaTask(date: day, task: task)])
        var pending = try store.pendingMutations(limit: 500)
        let initialIDs = pending.compactMap { payload in
            (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["mutationId"] as? String
        }
        try store.acknowledgeMutations(initialIDs)

        task.title = "Local title edit"
        try store.saveScheduledEntries([AgendaTask(date: day, task: task)])
        pending = try store.pendingMutations(limit: 10)
        let mutation = try JSONSerialization.jsonObject(with: pending[0]) as? [String: Any]
        let fields = mutation?["fields"] as? [String: Any]
        try expect(Set(fields?.keys ?? Dictionary<String, Any>().keys) == ["title"], "Native task update resent unchanged fields")

        let remote: [String: Any] = [
            "cursor": 2,
            "entities": [[
                "kind": "task", "id": task.id.uuidString.lowercased(),
                "fields": ["title": "Older remote title", "time": "06:00", "date": "2026-08-08"],
                "clocks": [
                    "title": ["hlc": "0000000000000001", "deviceId": "web"],
                    "time": ["hlc": "9999999999999999", "deviceId": "web"],
                    "date": ["hlc": "0000000000000001", "deviceId": "web"],
                ],
            ]],
        ]
        try store.applyRemotePull(JSONSerialization.data(withJSONObject: remote))
        let merged = try store.tasks(on: day)[0]
        try expect(merged.title == "Local title edit", "Older remote field overwrote a pending local field")
        try expect(merged.startMinute == 360, "Newer remote time did not merge beside the local title")
    }
    try check("Agenda edits persist even while the full plan is incomplete") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-agenda-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [], templates: [], streaks: [])
        let day = try date("2026-08-08", format: "yyyy-MM-dd")
        var task = PlanTask(title: "Agenda draft", startMinute: 540, cycles: 1)
        try store.saveScheduledEntries([AgendaTask(date: day, task: task)])
        task.startMinute = 600
        task.timeAssigned = false
        try store.saveAgendaEdits(date: day, tasks: [task], profile: .universityEarly)
        let saved = try store.tasks(on: day)[0]
        try expect(saved.startMinute == 600 && !saved.hasScheduledTime, "Incomplete Agenda edit stayed in memory instead of SQLite")
        let pending = try store.pendingMutations(limit: 500)
        try expect(pending.contains { payload in
            guard let mutation = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let fields = mutation["fields"] as? [String: Any] else { return false }
            return fields["hasScheduledTime"] as? Bool == false
        }, "Incomplete Agenda edit was not queued for cloud sync")
        try store.saveAgendaEdits(date: day, tasks: [], profile: .universityEarly)
        let remainingAfterDelete = try store.tasks(on: day)
        try expect(remainingAfterDelete.isEmpty, "Deleting an Agenda task did not remove it from SQLite")
        let deletionPending = try store.pendingMutations(limit: 500)
        try expect(deletionPending.contains { payload in
            guard let mutation = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
            return mutation["entityKind"] as? String == "task" && mutation["deleted"] as? Bool == true
        }, "Deleting an Agenda task did not queue a cloud tombstone")
    }
    try check("Day analysis updates Journal without entering the machine log") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-journal-\(UUID().uuidString)")
        let journalDirectory = temporary.appendingPathComponent("journal", isDirectory: true)
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let planDate = try date("2026-08-07", format: "yyyy-MM-dd")
        let journalURL = journalDirectory.appendingPathComponent("aug-7.md")
        try "# My writing\n\nKeep this exactly.\n".write(to: journalURL, atomically: true, encoding: .utf8)
        let analysis = DayAnalysis(summary: "Final summary", progress: "Moved forward", mistakes: "One miss", gains: "Clearer plan")
        let projection = ProjectionWriter(vaultURL: temporary, calendar: calendar)
        try projection.exportJournalAnalysis(date: planDate, analysis: analysis)
        let journal = try String(contentsOf: journalURL, encoding: .utf8)
        let machineLog = CleanMarkdownExporter(calendar: calendar).renderDailyLog(
            date: planDate, tasks: [], checkIns: [], definitions: [], values: [], analysis: analysis
        )
        try expect(journal.contains("Keep this exactly."), "Journal writing was overwritten")
        try expect(journal.contains("Final summary"), "Approved analysis was not written to Journal")
        try expect(!machineLog.contains("Final summary"), "Analysis leaked into the machine log")
    }
    try check("Local store stays inside the speed budget") {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("refocus-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let startupBeginning = DispatchTime.now().uptimeNanoseconds
        let store = try RefocusStore(databaseURL: temporary.appendingPathComponent("refocus.sqlite3"), calendar: calendar)
        let startupMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - startupBeginning) / 1_000_000
        let firstDay = try date("2026-08-07", format: "yyyy-MM-dd")
        let secondDay = try date("2026-08-08", format: "yyyy-MM-dd")
        let task = PlanTask(title: "Benchmark", startMinute: 1080, cycles: 1)
        try store.importLegacy(today: nil, tomorrow: nil, agenda: [AgendaTask(date: firstDay, task: task)], templates: [], streaks: [])
        var transactionTimes: [Double] = []
        for index in 0..<80 {
            let beginning = DispatchTime.now().uptimeNanoseconds
            try store.rescheduleTask(id: task.id, to: index.isMultiple(of: 2) ? secondDay : firstDay)
            transactionTimes.append(Double(DispatchTime.now().uptimeNanoseconds - beginning) / 1_000_000)
        }
        transactionTimes.sort()
        let p95 = transactionTimes[Int(Double(transactionTimes.count - 1) * 0.95)]
        try expect(startupMilliseconds < 200, "Warm store startup exceeded 200 ms (\(startupMilliseconds) ms)")
        try expect(p95 < 10, "SQLite transaction p95 exceeded 10 ms (\(p95) ms)")
    }
    print("\nAll \(checks) ReFocus core checks passed.")
} catch {
    fputs("ReFocus core check failed: \(error)\n", stderr)
    exit(1)
}
