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
    @Published var tomorrowTasks: [PlanTask] = []
    @Published var taskTemplates: [PlanTask] = []
    @Published var tomorrowValidationIssues: [PlanValidationIssue] = []
    @Published var tomorrowIsDirty = false
    @Published var isSavingTomorrow = false
    @Published var planMessage = "Choose your Obsidian vault."
    @Published var validationIssues: [PlanValidationIssue] = []
    @Published var dayProfile = RoutineProfileResolver().profile(for: Date())
    @Published var activeSegment = PlanValidator().segment(at: Date())
    @Published var isArmed = false
    @Published var isBreakVisible = false
    @Published var currentCheckIn: CheckIn?
    @Published var streakDefinitions: [StreakDefinition] = []
    @Published var streakSummaries: [StreakSummary] = []
    @Published var errorMessage: String?
    @Published var vaultURL: URL?
    @Published var launchAtLogin = false
    @Published var planIsDirty = false
    @Published var requiredCycleMinimum = 10
    @Published var isSavingPlan = false
    @Published var isEditingPlan = true
    @Published private(set) var hasPersistedToday = false
    @Published private(set) var initialSegments: Set<PlanningSegment> = []
    @Published var collapsedTaskIDs: Set<UUID> = []
    @Published var showCompletedSubtasks = false
    @Published var quickNote = ""
    @Published var isSavingQuickNote = false

    private let clock = WallClock()
    private let resolver = RoutineProfileResolver()
    private let validator = PlanValidator()
    private var worker: VaultWorker?
    private var watchers: [VaultWatcher] = []
    private var ticker: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var agendaSaveTask: Task<Void, Never>?
    private var agendaPlanSaveTask: Task<Void, Never>?
    private var agendaTomorrowSaveTask: Task<Void, Never>?
    private var activeBreakID: String?
    private var baselineTasks: [PlanTask] = []
    private var tomorrowBaselineTasks: [PlanTask] = []
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
        agendaSaveTask?.cancel()
        agendaPlanSaveTask?.cancel()
        agendaTomorrowSaveTask?.cancel()
    }

    var currentTask: PlanTask? {
        let minute = clock.minuteOfDay(for: snapshot.cycleStart)
        return executionTasks.first(where: { $0.contains(minuteOfDay: minute) })
    }

    var snapshot: ClockSnapshot { clockDisplay.snapshot }

    var tomorrowDate: Date {
        WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: WallClock.dhakaCalendar().startOfDay(for: now)) ?? now
    }

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

    var hasInitialPlan: Bool { initialSegments.contains(activeSegment) }

    var plannedCycles: Int { tasks.filter(activeSegment.contains).reduce(0) { $0 + $1.cycles } }

    var cycleSummaryText: String {
        "\(activeSegment.title) · \(plannedCycles) planned · \(requiredCycleMinimum) required now"
    }

    var planIsCurrent: Bool { planMessage == "Today is planned." || !tasks.isEmpty }

    var isPlanReady: Bool {
        blockingIssues(in: currentValidation(tasks)).isEmpty
    }

    var isPlanCommitted: Bool {
        hasPersistedToday && hasInitialPlan && blockingIssues(in: currentValidation(baselineTasks)).isEmpty
    }

    var executionTasks: [PlanTask] {
        planIsDirty && hasPersistedToday ? baselineTasks : tasks
    }

    var executionCycleSummaryText: String {
        let cycles = executionTasks.filter(activeSegment.contains).reduce(0) { $0 + $1.cycles }
        return "\(activeSegment.title) · \(cycles) planned · \(requiredCycleMinimum) required now"
    }

    var agendaValidationIssues: [PlanValidationIssue] {
        let groups = Dictionary(grouping: agendaTasks) { WallClock.dhakaCalendar().startOfDay(for: $0.date) }
        return groups.flatMap { date, entries in
            validator.validate(
                tasks: entries.map(\.task),
                profile: resolver.profile(for: date),
                minimumCycles: 0,
                requireFixedTasks: false,
                requireTaskDetails: false
            )
        }
    }

    var tomorrowIsReady: Bool {
        tomorrowValidationIssues.allSatisfy { $0.severity == .warning }
    }

    var tomorrowCycleSummary: String {
        PlanningSegment.allCases.map { segment in
            "\(segment.title.replacingOccurrences(of: " Block", with: "")) \(tomorrowTasks.filter(segment.contains).reduce(0) { $0 + $1.cycles })/\(tomorrowRequiredCycles(segment))"
        }.joined(separator: " · ")
    }

    var planGateMessage: String {
        guard !isPlanReady else { return "Today is ready." }
        return "Plan the \(activeSegment.title.lowercased()) before focused work begins: \(requiredCycleMinimum) available work cycles."
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
            let templatesResult = (try? await worker.loadTemplates()) ?? []
            let nextDate = WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: date) ?? date
            let tomorrowResult = try? await worker.loadTomorrow(date: nextDate)

            self.dayProfile = self.resolver.profile(for: date)
            self.activeSegment = self.validator.segment(at: date)
            self.requiredCycleMinimum = self.validator.requiredCycles(
                in: self.activeSegment, at: date, profile: self.dayProfile
            )
            switch planResult {
            case .success(let plan):
                self.hasPersistedToday = true
                self.initialSegments = plan.initialSegments
                let normalized = self.withRecurringFixedTasks(plan.tasks)
                self.tasks = normalized
                self.baselineTasks = plan.tasks
                let issues = self.currentValidation(normalized)
                self.validationIssues = issues
                let blockers = self.blockingIssues(in: issues)
                let committed = self.hasInitialPlan && blockers.isEmpty
                self.planMessage = committed ? "Today is planned." : "Today plan is incomplete."
                self.isArmed = committed
                self.planIsDirty = normalized != plan.tasks
                self.isEditingPlan = normalized != plan.tasks || (blockers.isEmpty ? self.userRequestedEditing : true)
            case .failure:
                self.hasPersistedToday = false
                self.initialSegments = []
                self.tasks = FixedPlanTasks.daily()
                self.baselineTasks = []
                self.validationIssues = self.currentValidation(self.tasks)
                self.planMessage = "Today has not been planned."
                self.isArmed = false
                self.planIsDirty = true
                self.isEditingPlan = true
            }
            self.agendaTasks = agendaResult.sorted(by: self.agendaSort)
            self.taskTemplates = templatesResult
            let scheduledTomorrow = agendaResult.filter {
                WallClock.dhakaCalendar().isDate($0.date, inSameDayAs: nextDate)
            }.map(\.task)
            var tomorrowBase = tomorrowResult?.tasks ?? []
            let existingTomorrowIDs = Set(tomorrowBase.map(\.id))
            tomorrowBase.append(contentsOf: scheduledTomorrow.filter { !existingTomorrowIDs.contains($0.id) })
            let preparedTomorrow = self.withRecurringFixedTasks(tomorrowBase)
            self.tomorrowTasks = preparedTomorrow
            self.tomorrowBaselineTasks = tomorrowResult?.tasks ?? []
            self.tomorrowIsDirty = preparedTomorrow != self.tomorrowBaselineTasks
            self.tomorrowValidationIssues = self.validateTomorrow(preparedTomorrow)
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
        let segment = activeSegment
        let planTasks = tasks
        let expectedTasks = baselineTasks
        let issues = currentValidation(tasks)
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
                    segment: segment,
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
            self.initialSegments.insert(segment)
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

    func addTomorrowTask() {
        let segment = PlanningSegment.allCases.first { candidate in
            tomorrowTasks.filter(candidate.contains).reduce(0) { $0 + $1.cycles } < tomorrowRequiredCycles(candidate)
        } ?? .evening
        let nextStart = max(
            segment.startMinute,
            tomorrowTasks.filter { $0.fixedRole == nil && segment.contains($0) }.map(\.endMinute).max() ?? segment.startMinute
        )
        tomorrowTasks.append(PlanTask(
            title: "New task", startMinute: nextStart, cycles: 1, mvp: "",
            coreTasks: [CoreTask(title: ""), CoreTask(title: ""), CoreTask(title: "")]
        ))
        markTomorrowDirty()
    }

    func saveTaskAsTemplate(_ task: PlanTask) {
        guard let worker else { return }
        var template = task
        template.isComplete = false
        template.coreTasks = template.coreTasks.map { CoreTask(title: $0.title) }
        template.fixedRole = nil
        template.routineOverride = false
        if let index = taskTemplates.firstIndex(where: { $0.title.caseInsensitiveCompare(template.title) == .orderedSame }) {
            taskTemplates[index] = template
        } else {
            taskTemplates.append(template)
        }
        let saved = taskTemplates
        Task { [weak self] in
            do { try await worker.saveTemplates(saved) }
            catch { self?.errorMessage = "Could not save task template: \(error.localizedDescription)" }
        }
    }

    func addTemplateToToday(_ template: PlanTask) {
        tasks.append(freshCopy(of: template))
        markPlanDirty()
    }

    func addTemplateToTomorrow(_ template: PlanTask) {
        tomorrowTasks.append(freshCopy(of: template))
        markTomorrowDirty()
    }

    func removeTomorrowTask(id: UUID) {
        tomorrowTasks.removeAll { $0.id == id && $0.fixedRole == nil }
        markTomorrowDirty()
    }

    func toggleTomorrowTaskCompletion(_ taskID: UUID) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == taskID }) else { return }
        tomorrowTasks[index].isComplete.toggle()
        markTomorrowDirty()
        scheduleAgendaTomorrowAutosave()
    }

    func normalizeTomorrowSubtasks(for id: UUID) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == id }) else { return }
        while tomorrowTasks[index].coreTasks.count < 3 { tomorrowTasks[index].coreTasks.append(CoreTask(title: "")) }
        markTomorrowDirty()
    }

    func addTomorrowSubtask(to id: UUID) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == id }) else { return }
        tomorrowTasks[index].coreTasks.append(CoreTask(title: ""))
        markTomorrowDirty()
    }

    func removeTomorrowSubtask(taskID: UUID, subtaskID: UUID) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == taskID }), tomorrowTasks[index].coreTasks.count > 3 else { return }
        tomorrowTasks[index].coreTasks.removeAll { $0.id == subtaskID }
        markTomorrowDirty()
    }

    func markTomorrowDirty() {
        tomorrowTasks.sort { lhs, rhs in
            lhs.startMinute == rhs.startMinute
                ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                : lhs.startMinute < rhs.startMinute
        }
        tomorrowIsDirty = tomorrowTasks != tomorrowBaselineTasks
        tomorrowValidationIssues = validateTomorrow(tomorrowTasks)
    }

    func saveTomorrowPlan() {
        guard let worker, !isSavingTomorrow else { return }
        let warningIDs = Set(tomorrowValidationIssues.compactMap { issue -> UUID? in
            if case .routineConflict(let id, _, _, _, _) = issue { return id }
            return nil
        })
        for index in tomorrowTasks.indices where warningIDs.contains(tomorrowTasks[index].id) {
            tomorrowTasks[index].routineOverride = true
        }
        tomorrowValidationIssues = validateTomorrow(tomorrowTasks)
        guard tomorrowValidationIssues.allSatisfy({ $0.severity == .warning }) else {
            errorMessage = "Tomorrow still has blocking plan errors."
            return
        }
        let date = tomorrowDate
        let planTasks = tomorrowTasks
        let profile = resolver.profile(for: date)
        let plannedIDs = Set(planTasks.map(\.id))
        let remainingAgenda = agendaTasks.filter {
            !WallClock.dhakaCalendar().isDate($0.date, inSameDayAs: date) || !plannedIDs.contains($0.id)
        }
        isSavingTomorrow = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await worker.saveTomorrow(date: date, tasks: planTasks, profile: profile.kind)
                try await worker.saveAgenda(remainingAgenda)
                self.tomorrowBaselineTasks = planTasks
                self.tomorrowIsDirty = false
                self.agendaTasks = remainingAgenda
                self.isSavingTomorrow = false
            } catch {
                self.isSavingTomorrow = false
                self.errorMessage = "Could not save Tomorrow: \(error.localizedDescription)"
            }
        }
    }

    func addTask() {
        userRequestedEditing = true
        isEditingPlan = true
        let currentCycleStart = clock.minuteOfDay(for: snapshot.cycleStart)
        let nextStart = max(
            activeSegment.startMinute,
            currentCycleStart,
            tasks.filter { $0.fixedRole == nil && activeSegment.contains($0) }.map(\.endMinute).max() ?? currentCycleStart
        )
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
        let issues = currentValidation(tasks)
        validationIssues = issues
        planIsDirty = false
        let committed = hasInitialPlan && blockingIssues(in: issues).isEmpty
        planMessage = committed ? "Today is planned." : "Today plan is incomplete."
        isArmed = committed
        isEditingPlan = !committed
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
        let issues = currentValidation(tasks)
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

    func allTasksCollapsed(_ target: [PlanTask]) -> Bool {
        !target.isEmpty && target.allSatisfy { collapsedTaskIDs.contains($0.id) }
    }

    func toggleAllTasksCollapsed(_ target: [PlanTask]) {
        let ids = Set(target.map(\.id))
        if allTasksCollapsed(target) {
            collapsedTaskIDs.subtract(ids)
        } else {
            collapsedTaskIDs.formUnion(ids)
        }
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
            tasks: sameDay, profile: resolver.profile(for: date), minimumCycles: 0,
            requireFixedTasks: false, requireTaskDetails: false
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
            tasks: sameDay, profile: resolver.profile(for: date), minimumCycles: 0,
            requireFixedTasks: false, requireTaskDetails: false
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
            requireFixedTasks: false,
            requireTaskDetails: false
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

    func updateAgendaTask(_ updated: PlanTask) {
        guard let index = agendaTasks.firstIndex(where: { $0.id == updated.id }) else { return }
        agendaTasks[index].task = updated
        agendaTasks.sort(by: agendaSort)
        agendaSaveTask?.cancel()
        agendaSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let self, let worker = self.worker else { return }
            do { try await worker.saveAgenda(self.agendaTasks) }
            catch { self.errorMessage = "Could not update agenda: \(error.localizedDescription)" }
        }
    }

    func deleteAgendaTask(_ taskID: UUID) {
        guard let worker, agendaTasks.contains(where: { $0.id == taskID }) else { return }
        agendaTasks.removeAll { $0.id == taskID }
        let remaining = agendaTasks
        Task { [weak self] in
            do { try await worker.saveAgenda(remaining) }
            catch {
                self?.errorMessage = "Could not delete agenda task: \(error.localizedDescription)"
                self?.reloadVault(force: true)
            }
        }
    }

    func scheduleAgendaTodayAutosave() {
        agendaPlanSaveTask?.cancel()
        agendaPlanSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.planIsDirty, self.isPlanReady else { return }
            self.savePlan()
        }
    }

    func scheduleAgendaTomorrowAutosave() {
        agendaTomorrowSaveTask?.cancel()
        agendaTomorrowSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.tomorrowIsDirty, self.tomorrowIsReady else { return }
            self.saveTomorrowPlan()
        }
    }

    func submitQuickNote() {
        guard let worker, !isSavingQuickNote else { return }
        let line = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        quickNote = ""
        isSavingQuickNote = true
        Task { [weak self] in
            do {
                try await worker.appendQuickNote(line)
                self?.isSavingQuickNote = false
            } catch {
                guard let self else { return }
                self.isSavingQuickNote = false
                if self.quickNote.isEmpty { self.quickNote = line }
                self.errorMessage = "Could not save quick note: \(error.localizedDescription)"
            }
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
        let next = (summary.statuses[day] ?? .blank).next
        setStreak(summary.definition, status: next, date: date)
    }

    private func setStreak(_ definition: StreakDefinition, status: StreakStatus, date: Date) {
        guard let worker else { return }
        Task { [weak self] in
            do {
                try await worker.setStreakValue(definition, status: status, date: date)
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
        let resolvedSegment = validator.segment(at: date)
        let resolvedMinimum = validator.requiredCycles(in: resolvedSegment, at: date, profile: resolvedProfile)
        if resolvedSegment != activeSegment || resolvedMinimum != requiredCycleMinimum {
            activeSegment = resolvedSegment
            requiredCycleMinimum = resolvedMinimum
            validationIssues = currentValidation(tasks)
        }

        // The sleep cutoff is a true execution boundary, not another planning
        // gate. ReFocus disarms and gets out of the way after 21:30.
        if clock.minuteOfDay(for: date) >= 1290 {
            isArmed = false
            activeBreakID = nil
            if overlayController.mode != nil { overlayController.hide() }
            isBreakVisible = false
            return
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

    private func currentValidation(_ candidate: [PlanTask]) -> [PlanValidationIssue] {
        validator.validate(
            tasks: candidate,
            profile: dayProfile,
            minimumCycles: requiredCycleMinimum,
            requireFixedTasks: true,
            requireTaskDetails: true,
            countedSegment: activeSegment
        )
    }

    private func tomorrowRequiredCycles(_ segment: PlanningSegment) -> Int {
        var parts = WallClock.dhakaCalendar().dateComponents([.year, .month, .day], from: tomorrowDate)
        parts.hour = segment.startMinute / 60
        parts.minute = segment.startMinute % 60
        let start = WallClock.dhakaCalendar().date(from: parts) ?? tomorrowDate
        return validator.requiredCycles(
            in: segment,
            at: start,
            profile: resolver.profile(for: tomorrowDate)
        )
    }

    private func validateTomorrow(_ candidate: [PlanTask]) -> [PlanValidationIssue] {
        var issues = validator.validate(
            tasks: candidate,
            profile: resolver.profile(for: tomorrowDate),
            minimumCycles: 0,
            requireFixedTasks: true,
            requireTaskDetails: true
        )
        for segment in PlanningSegment.allCases {
            let actual = candidate.filter(segment.contains).reduce(0) { $0 + $1.cycles }
            let required = tomorrowRequiredCycles(segment)
            if actual < required {
                issues.append(.insufficientSegment(segment: segment, actual: actual, required: required))
            }
        }
        return issues
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

    private func freshCopy(of template: PlanTask) -> PlanTask {
        PlanTask(
            title: template.title,
            startMinute: template.startMinute,
            cycles: template.cycles,
            kind: template.kind,
            priority: template.priority,
            difficulty: template.difficulty,
            mvp: template.mvp,
            coreTasks: template.coreTasks.map { CoreTask(title: $0.title) }
        )
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
