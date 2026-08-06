import AppKit
import Combine
import Foundation
import ServiceManagement
import RefocusCore

@MainActor
final class ClockDisplay: ObservableObject {
    @Published var snapshot = WallClock().snapshot(at: Date())
}

@MainActor
final class AppModel: ObservableObject {
    private(set) var now = Date()
    let clockDisplay = ClockDisplay()
    @Published var tasks: [PlanTask] = []
    @Published var agendaTasks: [AgendaTask] = []
    @Published var planMessage = "Choose your Obsidian vault."
    @Published var validationIssues: [PlanValidationIssue] = []
    @Published var dayProfile = RoutineProfileResolver().profile(for: Date())
    // Planning is the gate: focus and screen blocking stay off until Today is
    // a complete, valid twelve-cycle plan.
    @Published var isArmed = false
    @Published var isBreakVisible = false
    @Published var currentCheckIn: CheckIn?
    @Published var streakDefinitions: [StreakDefinition] = []
    @Published var streakSummaries: [StreakSummary] = []
    @Published var errorMessage: String?
    @Published var vaultURL: URL?
    @Published var launchAtLogin = false
    @Published var planIsDirty = false
    @Published var requiredCycleMinimum = 12
    @Published var isSavingPlan = false
    @Published var isEditingPlan = true
    @Published private(set) var hasPersistedToday = false
    @Published private(set) var hasInitialPlan = false
    @Published var collapsedTaskIDs: Set<UUID> = []
    @Published var showCompletedSubtasks = false

    private let clock = WallClock()
    private let resolver = RoutineProfileResolver()
    private let validator = PlanValidator()
    private var worker: VaultWorker?
    private var watchers: [VaultWatcher] = []
    private var ticker: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var activeBreakID: String?
    private var baselineTasks: [PlanTask] = []
    private var userRequestedEditing = false
    private var accessedSecurityScopedResource = false
    private lazy var overlayController = BreakOverlayController()

    init() {
        restoreVault()
        refreshLoginStatus()
        startTicker()
    }

    deinit {
        ticker?.cancel()
        saveTask?.cancel()
    }

    var currentTask: PlanTask? {
        let minute = clock.minuteOfDay(for: snapshot.cycleStart)
        return executionTasks.first(where: { $0.contains(minuteOfDay: minute) })
    }

    var snapshot: ClockSnapshot { clockDisplay.snapshot }

    var executionTask: PlanTask? {
        if let currentTask { return currentTask }
        guard isArmed else { return nil }
        return executionTasks.first(where: { !$0.isComplete && $0.priority.caseInsensitiveCompare("Do/Die") == .orderedSame })
    }

    var currentTaskTitle: String {
        executionTask?.title ?? (isArmed ? "Solve five harder problems" : "No active task")
    }

    var countdownText: String {
        String(format: "%02d:%02d", snapshot.secondsRemaining / 60, snapshot.secondsRemaining % 60)
    }

    var phaseTitle: String {
        snapshot.phase == .focus ? "FOCUS" : "SCREEN BREAK"
    }

    var plannedCycles: Int { tasks.reduce(0) { $0 + $1.cycles } }

    var cycleSummaryText: String {
        "\(plannedCycles) planned · \(requiredCycleMinimum) required now"
    }

    var planIsCurrent: Bool { planMessage == "Today is planned." || !tasks.isEmpty }

    var isPlanReady: Bool {
        blockingIssues(in: validator.validate(tasks: tasks, profile: dayProfile, minimumCycles: requiredCycleMinimum)).isEmpty
    }

    var isPlanCommitted: Bool {
        hasPersistedToday && blockingIssues(in: validator.validate(
            tasks: baselineTasks,
            profile: dayProfile,
            minimumCycles: requiredCycleMinimum
        )).isEmpty
    }

    var executionTasks: [PlanTask] {
        planIsDirty && hasPersistedToday ? baselineTasks : tasks
    }

    var executionCycleSummaryText: String {
        "\(executionTasks.reduce(0) { $0 + $1.cycles }) planned · \(requiredCycleMinimum) required now"
    }

    var agendaValidationIssues: [PlanValidationIssue] {
        let groups = Dictionary(grouping: agendaTasks) { WallClock.dhakaCalendar().startOfDay(for: $0.date) }
        return groups.flatMap { date, entries in
            validator.validate(
                tasks: entries.map(\.task),
                profile: resolver.profile(for: date),
                minimumCycles: 0,
                requireFixedTasks: false
            )
        }
    }

    var planGateMessage: String {
        guard !isPlanReady else { return "Today is ready." }
        return "Complete a valid \(requiredCycleMinimum)-cycle Today plan to unlock work."
    }

    func startNow() {
        guard isPlanCommitted else {
            errorMessage = planGateMessage
            return
        }
        isArmed = true
        tick()
    }

    func stopWork() {
        guard overlayController.mode != .planningGate else {
            errorMessage = planGateMessage
            return
        }
        isArmed = false
        if isBreakVisible {
            finalizeCurrentCheckIn()
            overlayController.hide()
            isBreakVisible = false
        }
    }

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Obsidian vault"
        panel.message = "Select the folder containing tasks.md and ego/ikigai.md."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Vault"
        // The planning gate uses screen-saver-level panels, so keep the vault
        // chooser above them when Settings is opened from the blocker.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("tasks.md").path),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("ego/ikigai.md").path) else {
            errorMessage = "That folder is not the expected Obsidian vault."
            return
        }
        persistVault(url)
        configureVault(url)
    }

    func reloadVault(force: Bool = false) {
        guard let worker else { return }
        if planIsDirty && !force {
            planMessage = "External changes detected — reload or save to resolve."
            return
        }
        let date = now
        Task { [weak self] in
            guard let self else { return }
            let planResult: Result<TodayPlan, Error>
            do { planResult = .success(try await worker.loadToday(date: date)) }
            catch { planResult = .failure(error) }
            let streakResult: Result<[StreakDefinition], Error>
            do { streakResult = .success(try await worker.loadStreakDefinitions()) }
            catch { streakResult = .failure(error) }
            let agendaResult = (try? await worker.loadAgenda()) ?? []

            self.dayProfile = self.resolver.profile(for: date)
            self.requiredCycleMinimum = self.validator.requiredCycles(at: date, profile: self.dayProfile)
            switch planResult {
            case .success(let plan):
                self.hasPersistedToday = true
                self.hasInitialPlan = plan.hasInitialPlan
                let normalized = self.withRecurringFixedTasks(plan.tasks)
                self.tasks = normalized
                self.baselineTasks = plan.tasks
                let issues = self.validator.validate(
                    tasks: normalized,
                    profile: self.dayProfile,
                    minimumCycles: self.requiredCycleMinimum
                )
                self.validationIssues = issues
                let blockers = self.blockingIssues(in: issues)
                self.planMessage = blockers.isEmpty ? "Today is planned." : "Today plan is incomplete."
                self.isArmed = blockers.isEmpty
                self.planIsDirty = normalized != plan.tasks
                self.isEditingPlan = normalized != plan.tasks || (blockers.isEmpty ? self.userRequestedEditing : true)
            case .failure:
                self.hasPersistedToday = false
                self.hasInitialPlan = false
                self.tasks = FixedPlanTasks.daily()
                self.baselineTasks = []
                self.validationIssues = self.validator.validate(
                    tasks: self.tasks,
                    profile: self.dayProfile,
                    minimumCycles: self.requiredCycleMinimum
                )
                self.planMessage = "Today has not been planned."
                self.isArmed = false
                self.planIsDirty = true
                self.isEditingPlan = true
            }
            self.agendaTasks = agendaResult.sorted(by: self.agendaSort)
            switch streakResult {
            case .success(let definitions): self.streakDefinitions = definitions
            case .failure: self.streakDefinitions = VaultRepository.defaultStreaks
            }
            self.reloadStreakSummaries()
        }
    }

    func savePlan() {
        guard let worker, !isSavingPlan else { return }
        // Yellow routine conflicts are an explicit per-day override. Saving
        // acknowledges them and records that choice in Markdown.
        let warningTaskIDs = Set(validationIssues.compactMap { issue -> UUID? in
            if case .routineConflict(let id, _, _, _, _) = issue { return id }
            return nil
        })
        if !warningTaskIDs.isEmpty {
            for index in tasks.indices where warningTaskIDs.contains(tasks[index].id) {
                tasks[index].routineOverride = true
            }
        }
        tasks.sort { $0.startMinute < $1.startMinute }
        let date = now
        let profile = dayProfile
        let planTasks = tasks
        let expectedTasks = baselineTasks
        let issues = validator.validate(tasks: tasks, profile: profile, minimumCycles: requiredCycleMinimum)
        validationIssues = issues
        guard blockingIssues(in: issues).isEmpty else {
            errorMessage = planGateMessage
            return
        }
        isSavingPlan = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await worker.saveToday(
                    date: date,
                    tasks: planTasks,
                    profile: profile.kind,
                    expectedTasks: expectedTasks
                )
            } catch {
                self.isSavingPlan = false
                self.planMessage = "Plan was not saved."
                self.errorMessage = "Could not save Today: \(error.localizedDescription)"
                return
            }

            // The plan file is the source of truth. Commit and unlock as soon
            // as that primary write succeeds; a secondary streak-log failure
            // must never make a successfully saved plan look unsaved.
            self.baselineTasks = planTasks
            self.hasPersistedToday = true
            self.hasInitialPlan = true
            self.planIsDirty = false
            self.planMessage = "Today is planned."
            self.isArmed = true
            self.isSavingPlan = false
            self.isEditingPlan = false
            self.userRequestedEditing = false
            self.tick()

            do {
                try await worker.updatePlanMinimum(
                    date: date,
                    completed: !issues.contains(where: {
                        if case .insufficientCycles = $0 { return true }
                        return false
                    })
                )
            } catch {
                self.errorMessage = "Today was saved, but its plan streak could not be updated: \(error.localizedDescription)"
            }
        }
    }

    func addTask() {
        userRequestedEditing = true
        isEditingPlan = true
        let currentCycleStart = clock.minuteOfDay(for: snapshot.cycleStart)
        let nextStart = max(360, currentCycleStart, tasks.map(\.endMinute).max() ?? currentCycleStart)
        tasks.append(PlanTask(
            title: "New task", startMinute: nextStart, cycles: 1, mvp: "",
            coreTasks: [CoreTask(title: ""), CoreTask(title: ""), CoreTask(title: "")]
        ))
        markPlanDirty()
    }

    func removeTasks(at offsets: IndexSet) {
        tasks.remove(atOffsets: offsets)
        markPlanDirty()
    }

    func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id && $0.fixedRole == nil }
        markPlanDirty()
    }

    func beginEditingPlan() {
        userRequestedEditing = true
        isEditingPlan = true
    }

    func cancelEditingPlan() {
        tasks = baselineTasks
        let issues = validator.validate(
            tasks: tasks,
            profile: dayProfile,
            minimumCycles: requiredCycleMinimum
        )
        validationIssues = issues
        planIsDirty = false
        planMessage = issues.isEmpty ? "Today is planned." : "Today plan is incomplete."
        isArmed = issues.isEmpty
        isEditingPlan = !issues.isEmpty
        userRequestedEditing = false
        tick()
    }

    func moveTask(id: UUID, by offset: Int) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let destination = index + offset
        guard tasks.indices.contains(destination) else { return }
        let anchor = tasks.map(\.startMinute).min() ?? clock.minuteOfDay(for: snapshot.cycleStart)
        tasks.swapAt(index, destination)
        var cursor = anchor
        for taskIndex in tasks.indices {
            tasks[taskIndex].startMinute = cursor
            cursor = tasks[taskIndex].endMinute
        }
        markPlanDirty()
    }

    func moveTasks(from source: IndexSet, to destination: Int) {
        tasks.move(fromOffsets: source, toOffset: destination)
        reflowTasks()
        markPlanDirty()
    }

    func normalizeCoreTasks(for taskIndex: Int) {
        guard tasks.indices.contains(taskIndex) else { return }
        while tasks[taskIndex].coreTasks.count < 3 { tasks[taskIndex].coreTasks.append(CoreTask(title: "")) }
        markPlanDirty()
    }

    func normalizeCoreTasks(for id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        normalizeCoreTasks(for: index)
    }

    func markPlanDirty() {
        // SwiftUI row changes also fire when a plan is reloaded from disk.
        // Compare against the loaded baseline so programmatic refreshes never
        // turn a saved plan back into a blocking, dirty plan.
        tasks.sort { lhs, rhs in
            lhs.startMinute == rhs.startMinute ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending : lhs.startMinute < rhs.startMinute
        }
        let isActuallyDirty = tasks != baselineTasks
        if isActuallyDirty != planIsDirty { planIsDirty = isActuallyDirty }
        let issues = validator.validate(tasks: tasks, profile: dayProfile, minimumCycles: requiredCycleMinimum)
        if issues != validationIssues { validationIssues = issues }
        if isPlanCommitted {
            isArmed = true
        } else if isActuallyDirty || !issues.isEmpty {
            isArmed = false
        }
    }

    func addSubtask(to taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].coreTasks.append(CoreTask(title: ""))
        markPlanDirty()
    }

    func removeSubtask(taskID: UUID, subtaskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].coreTasks.count > 3 else { return }
        tasks[index].coreTasks.removeAll { $0.id == subtaskID }
        markPlanDirty()
    }

    func toggleCollapsed(_ taskID: UUID) {
        if collapsedTaskIDs.contains(taskID) { collapsedTaskIDs.remove(taskID) } else { collapsedTaskIDs.insert(taskID) }
    }

    func setAllTasksCollapsed(_ collapsed: Bool) {
        collapsedTaskIDs = collapsed ? Set((tasks + agendaTasks.map(\.task)).map(\.id)) : []
    }

    func toggleTaskCompletion(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[index].isComplete.toggle()
        markPlanDirty()
        savePlan()
    }

    func toggleSubtaskCompletion(taskID: UUID, subtaskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let subtaskIndex = tasks[taskIndex].coreTasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        tasks[taskIndex].coreTasks[subtaskIndex].isComplete.toggle()
        markPlanDirty()
        savePlan()
    }

    func rescheduleTask(_ taskID: UUID, to date: Date) {
        guard let worker,
              let index = tasks.firstIndex(where: { $0.id == taskID }),
              !tasks[index].isComplete,
              tasks[index].fixedRole == nil else { return }
        var rescheduledTask = tasks[index]
        rescheduledTask.routineOverride = false
        let sameDay = agendaTasks.filter { WallClock.dhakaCalendar().isDate($0.date, inSameDayAs: date) }.map(\.task) + [rescheduledTask]
        let destinationIssues = validator.validate(
            tasks: sameDay, profile: resolver.profile(for: date), minimumCycles: 0, requireFixedTasks: false
        )
        let blockers = destinationIssues.filter { $0.severity == .error }
        guard blockers.isEmpty else {
            errorMessage = blockers.map(\.description).joined(separator: "\n")
            return
        }
        if destinationIssues.contains(where: { $0.severity == .warning }) { rescheduledTask.routineOverride = true }
        tasks.remove(at: index)
        let moved = AgendaTask(date: WallClock.dhakaCalendar().startOfDay(for: date), task: rescheduledTask)
        agendaTasks.append(moved)
        agendaTasks.sort(by: agendaSort)
        markPlanDirty()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await worker.saveAgenda(self.agendaTasks)
                self.savePlan()
            } catch {
                self.errorMessage = "Could not reschedule task: \(error.localizedDescription)"
            }
        }
    }

    func moveAgendaTask(_ taskID: UUID, to date: Date) {
        guard let worker, let index = agendaTasks.firstIndex(where: { $0.id == taskID }) else { return }
        var movedTask = agendaTasks[index].task
        movedTask.routineOverride = false
        let sameDay = agendaTasks.filter {
            $0.id != taskID && WallClock.dhakaCalendar().isDate($0.date, inSameDayAs: date)
        }.map(\.task) + [movedTask]
        let issues = validator.validate(
            tasks: sameDay, profile: resolver.profile(for: date), minimumCycles: 0, requireFixedTasks: false
        )
        let blockers = issues.filter { $0.severity == .error }
        guard blockers.isEmpty else {
            errorMessage = blockers.map(\.description).joined(separator: "\n")
            return
        }
        if issues.contains(where: { $0.severity == .warning }) { movedTask.routineOverride = true }
        agendaTasks[index].task = movedTask
        agendaTasks[index].date = WallClock.dhakaCalendar().startOfDay(for: date)
        agendaTasks.sort(by: agendaSort)
        Task { [weak self] in
            guard let self else { return }
            do { try await worker.saveAgenda(self.agendaTasks) }
            catch { self.errorMessage = "Could not move agenda task: \(error.localizedDescription)" }
        }
    }

    func addAgendaTask(_ task: PlanTask, on date: Date) {
        guard let worker else { return }
        var scheduledTask = task
        scheduledTask.routineOverride = false
        var entry = AgendaTask(date: WallClock.dhakaCalendar().startOfDay(for: date), task: scheduledTask)
        let sameDay = (agendaTasks + [entry]).filter { WallClock.dhakaCalendar().isDate($0.date, inSameDayAs: date) }.map(\.task)
        let issues = validator.validate(
            tasks: sameDay,
            profile: resolver.profile(for: date),
            minimumCycles: 0,
            requireFixedTasks: false
        )
        let blockers = issues.filter { $0.severity == .error }
        guard blockers.isEmpty else {
            errorMessage = blockers.map(\.description).joined(separator: "\n")
            return
        }
        if issues.contains(where: { $0.severity == .warning }) {
            scheduledTask.routineOverride = true
            entry.task = scheduledTask
        }
        agendaTasks = (agendaTasks + [entry]).sorted(by: agendaSort)
        Task { [weak self] in
            guard let self else { return }
            do { try await worker.saveAgenda(self.agendaTasks) }
            catch { self.errorMessage = "Could not add scheduled task: \(error.localizedDescription)" }
        }
    }

    func toggleAgendaTaskCompletion(_ taskID: UUID) {
        guard let worker, let index = agendaTasks.firstIndex(where: { $0.id == taskID }) else { return }
        agendaTasks[index].task.isComplete.toggle()
        Task { [weak self] in
            guard let self else { return }
            do { try await worker.saveAgenda(self.agendaTasks) }
            catch { self.errorMessage = "Could not update agenda task: \(error.localizedDescription)" }
        }
    }

    func scheduleCheckInSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.saveCurrentCheckIn()
        }
    }

    func toggleStreak(_ summary: StreakSummary, day: Int) {
        var components = WallClock.dhakaCalendar().dateComponents([.year, .month], from: now)
        components.day = day
        guard let date = WallClock.dhakaCalendar().date(from: components) else { return }
        setStreak(summary.definition, completed: !summary.completedDays.contains(day), date: date)
    }

    private func setStreak(_ definition: StreakDefinition, completed: Bool, date: Date) {
        guard let worker else { return }
        Task { [weak self] in
            do {
                try await worker.setStreakValue(definition, completed: completed, date: date)
                self?.reloadStreakSummaries()
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshLoginStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func tick(at date: Date = Date()) {
        now = date
        clockDisplay.snapshot = clock.snapshot(at: date)
        let resolvedProfile = resolver.profile(for: date)
        if resolvedProfile != dayProfile { dayProfile = resolvedProfile }
        let resolvedMinimum = validator.requiredCycles(at: date, profile: resolvedProfile)
        if resolvedMinimum != requiredCycleMinimum {
            requiredCycleMinimum = resolvedMinimum
            validationIssues = validator.validate(
                tasks: tasks,
                profile: resolvedProfile,
                minimumCycles: resolvedMinimum
            )
        }

        // An incomplete Today plan is a persistent planning gate. It is not a
        // five-minute break and therefore does not expire at a clock boundary.
        guard isPlanCommitted else {
            isArmed = false
            activeBreakID = nil
            if overlayController.mode != .planningGate {
                overlayController.showPlanning(model: self)
            }
            if !isBreakVisible { isBreakVisible = true }
            return
        }

        if overlayController.mode == .planningGate {
            overlayController.hide()
            isBreakVisible = false
        }
        let active = isArmed

        if snapshot.phase == .screenBreak && active {
            let breakID = sessionID(for: snapshot.cycleStart)
            if activeBreakID != breakID {
                activeBreakID = breakID
                beginCheckIn(id: breakID)
                isBreakVisible = true
                overlayController.showBreak(model: self)
            }
        } else if snapshot.phase == .focus {
            if overlayController.mode == .screenBreak {
                finalizeCurrentCheckIn()
                overlayController.hide()
                isBreakVisible = false
            }
            activeBreakID = nil
        } else if !active && overlayController.mode == .screenBreak {
            finalizeCurrentCheckIn()
            overlayController.hide()
            isBreakVisible = false
        }
    }

    private func beginCheckIn(id: String) {
        let focusEnd = Calendar.current.date(byAdding: .minute, value: 25, to: snapshot.cycleStart) ?? snapshot.phaseStart
        currentCheckIn = CheckIn(
            id: id,
            taskID: executionTask?.id,
            taskTitle: currentTaskTitle,
            focusStart: snapshot.cycleStart,
            focusEnd: focusEnd
        )
        saveCurrentCheckIn()
    }

    private func finalizeCurrentCheckIn() {
        guard var checkIn = currentCheckIn else { return }
        if checkIn.outcome != .interrupted {
            checkIn.outcome = checkIn.whatDid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missed : .complete
        }
        currentCheckIn = checkIn
        saveCurrentCheckIn()
    }

    private func saveCurrentCheckIn() {
        guard let worker, let checkIn = currentCheckIn else { return }
        let definitions = streakDefinitions.isEmpty ? VaultRepository.defaultStreaks : streakDefinitions
        Task { [weak self] in
            do {
                try await worker.saveCheckIn(checkIn, streaks: definitions)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func reflowTasks() {
        guard var cursor = tasks.first?.startMinute else { return }
        for index in tasks.indices {
            if tasks[index].startMinute >= clock.minuteOfDay(for: now) {
                tasks[index].startMinute = cursor
            }
            cursor = tasks[index].endMinute
        }
    }

    private func blockingIssues(in issues: [PlanValidationIssue]) -> [PlanValidationIssue] {
        issues.filter(isBlocking)
    }

    func isBlocking(_ issue: PlanValidationIssue) -> Bool {
        if issue.severity == .warning { return false }
        if hasInitialPlan, case .insufficientCycles = issue { return false }
        return true
    }

    private func withRecurringFixedTasks(_ existing: [PlanTask]) -> [PlanTask] {
        var result = existing
        for fixed in FixedPlanTasks.daily() {
            if let index = result.firstIndex(where: {
                if $0.fixedRole == fixed.fixedRole || $0.title.caseInsensitiveCompare(fixed.title) == .orderedSame { return true }
                switch fixed.fixedRole {
                case .dayAnalysis: return $0.startMinute == 1200 && $0.title.localizedCaseInsensitiveContains("day analysis")
                case .planTomorrow: return $0.startMinute == 1230 && $0.title.localizedCaseInsensitiveContains("plan tomorrow")
                case .revision: return $0.startMinute == 1260 && $0.title.localizedCaseInsensitiveContains("revision")
                case nil: return false
                }
            }) {
                result[index].fixedRole = fixed.fixedRole
                result[index].title = fixed.title
                result[index].startMinute = fixed.startMinute
                if fixed.fixedRole != .planTomorrow { result[index].cycles = 1 }
                if result[index].mvp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[index].mvp = fixed.mvp }
                for subtask in fixed.coreTasks where !result[index].coreTasks.contains(where: {
                    $0.title.caseInsensitiveCompare(subtask.title) == .orderedSame
                }) {
                    result[index].coreTasks.append(subtask)
                }
                while result[index].coreTasks.count < 3 {
                    result[index].coreTasks.append(fixed.coreTasks[result[index].coreTasks.count])
                }
            } else {
                result.append(fixed)
            }
        }
        return result.sorted(by: { $0.startMinute < $1.startMinute })
    }

    private func agendaSort(_ lhs: AgendaTask, _ rhs: AgendaTask) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return lhs.task.startMinute < rhs.task.startMinute
    }

    private func sessionID(for cycleStart: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = WallClock.dhakaCalendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: cycleStart)
    }

    private func startTicker() {
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func configureVault(_ url: URL) {
        if accessedSecurityScopedResource { vaultURL?.stopAccessingSecurityScopedResource() }
        vaultURL = url
        accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
        worker = VaultWorker(vaultURL: url)
        watchers = [VaultWatcher(url: url) { [weak self] in self?.reloadVault() }]
        let logURL = url.appendingPathComponent("log", isDirectory: true)
        if FileManager.default.fileExists(atPath: logURL.path) {
            watchers.append(VaultWatcher(url: logURL) { [weak self] in self?.reloadStreakData() })
        }
        reloadVault()
    }

    private func persistVault(_ url: URL) {
        if let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: "vaultBookmark")
        }
    }

    private func restoreVault() {
        guard let data = UserDefaults.standard.data(forKey: "vaultBookmark") else { return }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return }
        if stale { persistVault(url) }
        configureVault(url)
    }

    private func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func reloadStreakSummaries() {
        guard let worker else { return }
        let definitions = streakDefinitions
        Task { [weak self] in
            let summaries = (try? await worker.streakSummaries(for: Date(), definitions: definitions)) ?? []
            self?.streakSummaries = summaries
        }
    }

    private func reloadStreakData() {
        guard let worker else { return }
        Task { [weak self] in
            guard let self else { return }
            let definitions = (try? await worker.loadStreakDefinitions()) ?? VaultRepository.defaultStreaks
            self.streakDefinitions = definitions
            self.reloadStreakSummaries()
        }
    }
}
