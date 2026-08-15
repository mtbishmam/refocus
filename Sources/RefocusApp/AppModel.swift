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
    @Published var dailyFieldDefinitions: [DailyFieldDefinition] = []
    @Published var dailyFieldValues: [String: String] = [:]
    @Published var dailyMetricHistory: [DailyFieldValue] = []
    @Published var dailyDashboardAnalytics = DailyDashboardAnalytics()
    @Published var diffDate = WallClock.dhakaCalendar().startOfDay(for: Date())
    @Published var diffInitialSnapshots: PlanSnapshots?
    @Published var diffFinalSnapshot: FinalSnapshotAvailability = .pending
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
    @Published var requestedTaskNameFocusID: UUID?
    @Published private(set) var taskUndoRevision = 0
    @Published var showCompletedSubtasks = false
    @Published var quickNote = ""
    @Published var isSavingQuickNote = false
    @Published var quickNoteError: String?
    private var quickNoteSubmissionID: UUID?
    @Published var cloudPairingToken = ""
    @Published var cloudSyncPaired = CloudCredentials.load() != nil
    @Published var isConnectingCloud = false
    @Published var cloudConnectionMessage: String?
    @Published var cloudSyncStatus = CloudCredentials.load() != nil ? "Ready" : "Local only"
    @Published var cloudSyncPendingCount = 0
    @Published var cloudSyncLastSuccess: Date?
    @Published var cloudSyncIssue: String?

    private let clock = WallClock()
    private let resolver = RoutineProfileResolver()
    private let validator = PlanValidator()
    private var worker: VaultWorker?
    private var watchers: [VaultWatcher] = []
    private var ticker: Task<Void, Never>?
    private var cloudSyncTicker: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var agendaSaveTask: Task<Void, Never>?
    private var agendaPlanSaveTask: Task<Void, Never>?
    private var agendaTomorrowSaveTask: Task<Void, Never>?
    private var rescheduleTaskQueue: Task<Void, Never>?
    private var dailyFieldSaveTasks: [String: Task<Void, Never>] = [:]
    private var activeBreakID: String?
    private var attemptedFinalCaptureDay: Date?
    private var baselineTasks: [PlanTask] = []
    private var tomorrowBaselineTasks: [PlanTask] = []
    private var knownTaskIDs: Set<UUID> = []
    private var userRequestedEditing = false
    private var accessedSecurityScopedResource = false
    private let taskUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 100
        return manager
    }()
    private lazy var overlayController = BreakOverlayController()

    init() {
        restoreVault()
        refreshLoginStatus()
        ensureLaunchAtLogin()
        startTicker()
    }

    deinit {
        ticker?.cancel()
        cloudSyncTicker?.cancel()
        saveTask?.cancel()
        agendaSaveTask?.cancel()
        agendaPlanSaveTask?.cancel()
        agendaTomorrowSaveTask?.cancel()
        rescheduleTaskQueue?.cancel()
        dailyFieldSaveTasks.values.forEach { $0.cancel() }
    }

    var currentTask: PlanTask? {
        let minute = clock.minuteOfDay(for: snapshot.cycleStart)
        return executionTasks.first(where: { $0.contains(minuteOfDay: minute) })
    }

    var snapshot: ClockSnapshot { clockDisplay.snapshot }

    var tomorrowDate: Date {
        WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: WallClock.dhakaCalendar().startOfDay(for: now)) ?? now
    }

    var canUndoTaskChange: Bool { taskUndoManager.canUndo }
    var canRedoTaskChange: Bool { taskUndoManager.canRedo }

    func undoTaskChange() {
        guard taskUndoManager.canUndo else { return }
        taskUndoManager.undo()
        taskUndoRevision &+= 1
    }

    func redoTaskChange() {
        guard taskUndoManager.canRedo else { return }
        taskUndoManager.redo()
        taskUndoRevision &+= 1
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

    var plannedCycles: Int {
        tasks.reduce(0) { $0 + $1.planningCycles(in: activeSegment) }
    }

    var cycleSummaryText: String {
        if requiredCycleMinimum == 0 { return "\(activeSegment.title) · no work cycles available" }
        return "\(activeSegment.title) · \(plannedCycles) planned · \(requiredCycleMinimum) required now"
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
        let cycles = executionTasks.reduce(0) { $0 + $1.planningCycles(in: activeSegment) }
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
                requireTaskDetails: false,
                scheduledDate: date,
                now: now
            )
        }
    }

    var tomorrowIsReady: Bool {
        tomorrowValidationIssues.allSatisfy { $0.severity == .warning }
    }

    var tomorrowCycleSummary: String {
        PlanningSegment.allCases.map { segment in
            "\(segment.title.replacingOccurrences(of: " Block", with: "")) \(tomorrowTasks.reduce(0) { $0 + $1.planningCycles(in: segment) })/\(tomorrowRequiredCycles(segment, tasks: tomorrowTasks))"
        }.joined(separator: " · ")
    }

    var planGateMessage: String {
        if isPlanCommitted { return "Today is ready." }
        if requiredCycleMinimum == 0 {
            return "No work cycles remain in the \(activeSegment.title.lowercased()). Work stays locked until the next planning block."
        }
        if isPlanReady { return "Save Today to unlock focused work." }
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

    func reloadVault(force: Bool = false, preservingLocalEdits: Bool = false) {
        guard let worker else { return }
        if planIsDirty && !force && !preservingLocalEdits {
            planMessage = "External changes detected — reload or save to resolve."
            return
        }
        if !preservingLocalEdits {
            taskUndoManager.removeAllActions()
            taskUndoRevision &+= 1
        }
        let localToday = tasks
        let localTodayBaseline = baselineTasks
        let hadTodayEdits = planIsDirty
        let localTomorrow = tomorrowTasks
        let localTomorrowBaseline = tomorrowBaselineTasks
        let hadTomorrowEdits = tomorrowIsDirty
        let date = now
        Task { [weak self] in
            guard let self else { return }
            let planResult: Result<TodayPlan, Error>
            do { planResult = .success(try await worker.loadToday(date: date)) }
            catch { planResult = .failure(error) }
            let streakResult: Result<[StreakDefinition], Error>
            do { streakResult = .success(try await worker.loadStreakDefinitions()) }
            catch { streakResult = .failure(error) }
            let agendaResult = (try? await worker.loadAgenda(asOf: date)) ?? []
            let fieldDefinitions = (try? await worker.loadDailyFieldDefinitions()) ?? []
            let fieldValues = (try? await worker.loadDailyFieldValues(for: date)) ?? []
            let templatesResult = (try? await worker.loadTemplates()) ?? []
            let nextDate = WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: date) ?? date
            let tomorrowResult = try? await worker.loadTomorrow(date: nextDate)

            self.dayProfile = self.resolver.profile(for: date)
            self.activeSegment = self.validator.segment(at: date)
            switch planResult {
            case .success(let plan):
                self.hasPersistedToday = true
                self.initialSegments = plan.initialSegments
                let normalized = self.withRecurringFixedTasks(plan.tasks)
                self.baselineTasks = normalized
                self.tasks = preservingLocalEdits && hadTodayEdits
                    ? self.mergeRemoteTasks(current: localToday, baseline: localTodayBaseline, remote: normalized)
                    : normalized
                self.refreshPlanningState(at: date)
                // Fixed routine tasks are deterministic parts of the saved
                // plan even when an older/local sync record omitted their task
                // rows. Validate execution against the same normalized plan
                // shown by the cycle counter so a green 3/3 cannot remain
                // trapped behind the planning overlay.
                let issues = self.currentValidation(self.tasks)
                self.validationIssues = issues
                let blockers = self.blockingIssues(in: issues)
                let committed = self.hasInitialPlan && blockers.isEmpty
                self.planMessage = committed ? "Today is planned." : "Today plan is incomplete."
                self.isArmed = committed
                self.planIsDirty = self.tasks != self.baselineTasks
                // A valid predefined-only plan remains locked until this
                // segment is explicitly saved and receives its Initial snapshot.
                self.isEditingPlan = !committed || self.planIsDirty || self.userRequestedEditing
            case .failure:
                self.hasPersistedToday = false
                self.initialSegments = []
                self.tasks = FixedPlanTasks.daily()
                self.baselineTasks = []
                self.refreshPlanningState(at: date)
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
            self.tomorrowBaselineTasks = preparedTomorrow
            self.tomorrowTasks = preservingLocalEdits && hadTomorrowEdits
                ? self.mergeRemoteTasks(current: localTomorrow, baseline: localTomorrowBaseline, remote: preparedTomorrow)
                : preparedTomorrow
            self.tomorrowIsDirty = self.tomorrowTasks != self.tomorrowBaselineTasks
            self.tomorrowValidationIssues = self.validateTomorrow(preparedTomorrow)
            self.collapseNewTasks()
            switch streakResult {
            case .success(let definitions): self.streakDefinitions = definitions
            case .failure: self.streakDefinitions = VaultRepository.defaultStreaks
            }
            self.dailyFieldDefinitions = fieldDefinitions
            self.dailyFieldValues = Dictionary(uniqueKeysWithValues: fieldValues.map { ($0.definitionID, $0.value) })
            self.reloadStreakSummaries()
            self.reloadDailyDashboardAnalytics()
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
        addTomorrowTask(in: nil)
    }

    func addTomorrowTask(in segment: PlanningSegment?) {
        let nextStart: Int
        if let segment {
            guard let slot = validator.firstUnusedSlot(
                in: tomorrowTasks, startingAt: segment.startMinute, before: segment.endMinute
            ) else {
                errorMessage = "No unused half-hour slot remains in the \(displayName(for: segment))."
                return
            }
            nextStart = slot
        } else {
            nextStart = PlanningSegment.morning.startMinute
        }
        let task = PlanTask(
            title: "New task", startMinute: nextStart, cycles: 1, mvp: "",
            coreTasks: segment == nil ? [] : [CoreTask(title: ""), CoreTask(title: ""), CoreTask(title: "")],
            quickCapture: segment == nil,
            timeAssigned: segment != nil
        )
        registerTaskUndo(actionName: "Add Task", persistence: .none)
        tomorrowTasks.append(task)
        registerNewTask(task.id)
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
        let task = freshCopy(of: template)
        registerTaskUndo(actionName: "Add Task", persistence: .none)
        tasks.append(task)
        registerNewTask(task.id)
        markPlanDirty()
    }

    func addTemplateToTomorrow(_ template: PlanTask) {
        let task = freshCopy(of: template)
        registerTaskUndo(actionName: "Add Task", persistence: .none)
        tomorrowTasks.append(task)
        registerNewTask(task.id)
        markTomorrowDirty()
    }

    func removeTomorrowTask(id: UUID, autosave: Bool = false) {
        guard tomorrowTasks.contains(where: { $0.id == id && $0.fixedRole == nil }) else { return }
        registerTaskUndo(actionName: "Delete Task", persistence: autosave ? .tomorrowAgenda : .none)
        tomorrowTasks.removeAll { $0.id == id && $0.fixedRole == nil }
        markTomorrowDirty()
        if autosave { scheduleAgendaTomorrowAutosave() }
    }

    func toggleTomorrowTaskCompletion(_ taskID: UUID) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == taskID }) else { return }
        registerTaskUndo(actionName: "Toggle Task Completion", persistence: .tomorrowAgenda)
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
        registerTaskUndo(actionName: "Add Subtask", persistence: .none)
        tomorrowTasks[index].coreTasks.append(CoreTask(title: ""))
        markTomorrowDirty()
    }

    func removeTomorrowSubtask(taskID: UUID, subtaskID: UUID) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == taskID }) else { return }
        let minimum = tomorrowTasks[index].quickCapture == true ? 0 : 3
        guard tomorrowTasks[index].coreTasks.count > minimum else { return }
        registerTaskUndo(actionName: "Delete Subtask", persistence: .none)
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

    func updateTodayTask(_ updated: PlanTask, autosave: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == updated.id }), tasks[index] != updated else { return }
        registerTaskUndo(actionName: "Edit Task", persistence: autosave ? .todayAgenda : .none)
        tasks[index] = updated
        markPlanDirty()
        if autosave { scheduleAgendaTodayAutosave() }
    }

    func updateTomorrowTask(_ updated: PlanTask, autosave: Bool = false) {
        guard let index = tomorrowTasks.firstIndex(where: { $0.id == updated.id }), tomorrowTasks[index] != updated else { return }
        registerTaskUndo(actionName: "Edit Task", persistence: autosave ? .tomorrowAgenda : .none)
        tomorrowTasks[index] = updated
        markTomorrowDirty()
        if autosave { scheduleAgendaTomorrowAutosave() }
    }

    func addTask() {
        addTask(in: nil)
    }

    func addTask(in segment: PlanningSegment?) {
        userRequestedEditing = true
        isEditingPlan = true
        let nextStart: Int
        if let segment {
            guard let slot = validator.firstUnusedSlot(
                in: tasks, startingAt: segment.startMinute, before: segment.endMinute
            ) else {
                errorMessage = "No unused half-hour slot remains in the \(displayName(for: segment))."
                return
            }
            nextStart = slot
        } else {
            nextStart = PlanningSegment.morning.startMinute
        }
        let task = PlanTask(
            title: "New task", startMinute: nextStart, cycles: 1, mvp: "",
            coreTasks: segment == nil ? [] : [CoreTask(title: ""), CoreTask(title: ""), CoreTask(title: "")],
            quickCapture: segment == nil,
            timeAssigned: segment != nil
        )
        registerTaskUndo(actionName: "Add Task", persistence: .none)
        tasks.append(task)
        registerNewTask(task.id)
        markPlanDirty()
    }

    func displayName(for segment: PlanningSegment) -> String {
        segment == .evening ? "Night Block" : segment.title
    }

    func removeTasks(at offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        registerTaskUndo(actionName: "Delete Task", persistence: .none)
        tasks.remove(atOffsets: offsets)
        markPlanDirty()
    }

    func removeTask(id: UUID, autosave: Bool = false) {
        guard tasks.contains(where: { $0.id == id && $0.fixedRole == nil }) else { return }
        registerTaskUndo(actionName: "Delete Task", persistence: autosave ? .todayAgenda : .none)
        tasks.removeAll { $0.id == id && $0.fixedRole == nil }
        markPlanDirty()
        if autosave { scheduleAgendaTodayAutosave() }
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
        let planningChanged = refreshPlanningState(at: now)
        tasks.sort { lhs, rhs in
            lhs.startMinute == rhs.startMinute ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending : lhs.startMinute < rhs.startMinute
        }
        let isActuallyDirty = tasks != baselineTasks
        if isActuallyDirty != planIsDirty { planIsDirty = isActuallyDirty }
        let issues = currentValidation(tasks)
        if planningChanged || issues != validationIssues { validationIssues = issues }
        if isPlanCommitted {
            isArmed = true
        } else if isActuallyDirty || !issues.isEmpty {
            isArmed = false
        }
    }

    func addSubtask(to taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        registerTaskUndo(actionName: "Add Subtask", persistence: .none)
        tasks[index].coreTasks.append(CoreTask(title: ""))
        markPlanDirty()
    }

    func removeSubtask(taskID: UUID, subtaskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        let minimum = tasks[index].quickCapture == true ? 0 : 3
        guard tasks[index].coreTasks.count > minimum else { return }
        registerTaskUndo(actionName: "Delete Subtask", persistence: .none)
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

    private func registerNewTask(_ id: UUID) {
        knownTaskIDs.insert(id)
        collapsedTaskIDs.remove(id)
        requestedTaskNameFocusID = id
    }

    private func collapseNewTasks() {
        let currentIDs = Set(tasks.map(\.id) + tomorrowTasks.map(\.id) + agendaTasks.map(\.id))
        collapsedTaskIDs.formUnion(currentIDs.subtracting(knownTaskIDs))
        collapsedTaskIDs.formIntersection(currentIDs)
        knownTaskIDs = currentIDs
    }

    func toggleTaskCompletion(_ taskID: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        registerTaskUndo(actionName: "Toggle Task Completion", persistence: .todayPlan)
        tasks[index].isComplete.toggle()
        markPlanDirty()
        savePlan()
    }

    func toggleSubtaskCompletion(taskID: UUID, subtaskID: UUID) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }),
              let subtaskIndex = tasks[taskIndex].coreTasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        registerTaskUndo(actionName: "Toggle Subtask Completion", persistence: .todayPlan)
        tasks[taskIndex].coreTasks[subtaskIndex].isComplete.toggle()
        markPlanDirty()
        savePlan()
    }

    func rescheduleTask(_ taskID: UUID, to date: Date) {
        moveTask(taskID, fromToday: true, to: date)
    }

    func moveAgendaTask(_ taskID: UUID, to date: Date) {
        moveTask(taskID, fromToday: false, to: date)
    }

    private func moveTask(_ taskID: UUID, fromToday: Bool, to requestedDate: Date) {
        guard let worker else { return }
        let calendar = WallClock.dhakaCalendar()
        let date = calendar.startOfDay(for: requestedDate)
        let today = calendar.startOfDay(for: now)
        let targetIsToday = calendar.isDate(date, inSameDayAs: today)
        let targetIsTomorrow = calendar.isDate(date, inSameDayAs: tomorrowDate)
        let todayIndex = fromToday ? tasks.firstIndex(where: { $0.id == taskID }) : nil
        let agendaIndex = agendaTasks.firstIndex(where: { $0.id == taskID })
        let tomorrowIndex = tomorrowTasks.firstIndex(where: { $0.id == taskID })
        guard todayIndex != nil || agendaIndex != nil || tomorrowIndex != nil else { return }

        let sourceDate: Date
        if todayIndex != nil { sourceDate = today }
        else if let agendaIndex { sourceDate = agendaTasks[agendaIndex].date }
        else { sourceDate = tomorrowDate }
        guard !calendar.isDate(sourceDate, inSameDayAs: date) else { return }

        let sourceTask: PlanTask
        if let todayIndex {
            sourceTask = tasks[todayIndex]
        } else if let agendaIndex {
            sourceTask = agendaTasks[agendaIndex].task
        } else if let tomorrowIndex {
            sourceTask = tomorrowTasks[tomorrowIndex]
        } else {
            return
        }
        guard !sourceTask.isComplete, sourceTask.fixedRole == nil else { return }

        var movedTask = sourceTask
        movedTask.routineOverride = false
        let sameDay: [PlanTask]
        if targetIsToday {
            sameDay = tasks.filter { $0.id != taskID } + [movedTask]
        } else if targetIsTomorrow {
            sameDay = tomorrowTasks.filter { $0.id != taskID } + [movedTask]
        } else {
            sameDay = agendaTasks.filter {
                $0.id != taskID && calendar.isDate($0.date, inSameDayAs: date)
            }.map(\.task) + [movedTask]
        }
        let issues = validator.validate(
            tasks: sameDay, profile: resolver.profile(for: date), minimumCycles: 0,
            requireFixedTasks: false, requireTaskDetails: false, scheduledDate: date, now: now
        )
        let blockers = issues.filter { $0.severity == .error }
        guard blockers.isEmpty else {
            errorMessage = blockers.map(\.description).joined(separator: "\n")
            return
        }
        if issues.contains(where: { $0.severity == .warning }) { movedTask.routineOverride = true }

        let sourceWasToday = todayIndex != nil
        tasks.removeAll { $0.id == taskID }
        tomorrowTasks.removeAll { $0.id == taskID }
        agendaTasks.removeAll { $0.id == taskID }

        if targetIsToday {
            tasks.append(movedTask)
            UserDefaults.standard.set(true, forKey: "todayFilterShowUser")
            markPlanDirty()
        } else if targetIsTomorrow {
            tomorrowTasks.append(movedTask)
            UserDefaults.standard.set(true, forKey: "tomorrowFilterShowUser")
            markTomorrowDirty()
        } else {
            agendaTasks.append(AgendaTask(date: date, task: movedTask))
        }
        agendaTasks.sort(by: agendaSort)
        collapseNewTasks()
        let remainingSourceTasks = tasks
        let destinationTasks = tasks
        let previousReschedule = rescheduleTaskQueue
        rescheduleTaskQueue = Task { [weak self] in
            await previousReschedule?.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            do {
                if sourceWasToday {
                    try await worker.rescheduleTodayTask(
                        taskID, to: date, sourceDate: today, remainingTasks: remainingSourceTasks,
                        profile: self.dayProfile.kind, segment: self.activeSegment
                    )
                    self.baselineTasks = remainingSourceTasks
                } else if targetIsToday {
                    try await worker.rescheduleTaskIntoToday(
                        taskID, date: today, tasks: destinationTasks,
                        profile: self.dayProfile.kind, segment: self.activeSegment
                    )
                    self.baselineTasks = destinationTasks
                    self.hasPersistedToday = true
                } else {
                    try await worker.rescheduleTask(taskID, to: date)
                }
                self.markPlanDirty()
                self.markTomorrowDirty()
                self.planMessage = self.isPlanCommitted ? "Today is planned." : "Today plan is incomplete."
            } catch {
                self.errorMessage = "Could not reschedule task: \(error.localizedDescription)"
                self.reloadVault(force: true)
            }
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
            requireTaskDetails: false,
            scheduledDate: date,
            now: now
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
        registerTaskUndo(actionName: "Add Task", persistence: .agenda)
        agendaTasks = (agendaTasks + [entry]).sorted(by: agendaSort)
        registerNewTask(entry.id)
        Task { [weak self] in
            guard let self else { return }
            do { try await worker.saveAgenda(self.agendaTasks) }
            catch { self.errorMessage = "Could not add scheduled task: \(error.localizedDescription)" }
        }
    }

    func toggleAgendaTaskCompletion(_ taskID: UUID) {
        guard let worker, let index = agendaTasks.firstIndex(where: { $0.id == taskID }) else { return }
        registerTaskUndo(actionName: "Toggle Task Completion", persistence: .agenda)
        agendaTasks[index].task.isComplete.toggle()
        Task { [weak self] in
            guard let self else { return }
            do { try await worker.saveAgenda(self.agendaTasks) }
            catch { self.errorMessage = "Could not update agenda task: \(error.localizedDescription)" }
        }
    }

    func updateAgendaTask(_ updated: PlanTask) {
        guard let index = agendaTasks.firstIndex(where: { $0.id == updated.id }), agendaTasks[index].task != updated else { return }
        registerTaskUndo(actionName: "Edit Task", persistence: .agenda)
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
        registerTaskUndo(actionName: "Delete Task", persistence: .agenda)
        agendaTasks.removeAll { $0.id == taskID }
        Task { [weak self] in
            do { try await worker.deleteTask(taskID) }
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
            guard !Task.isCancelled, let self, self.planIsDirty, let worker = self.worker else { return }
            let edited = self.tasks
            do {
                try await worker.saveAgendaEdits(date: self.now, tasks: edited, profile: self.dayProfile.kind)
                self.baselineTasks = edited
                self.markPlanDirty()
                let blockers = self.blockingIssues(in: self.currentValidation(edited))
                let committed = self.hasInitialPlan && blockers.isEmpty
                self.planMessage = committed ? "Today is planned." : "Today plan is incomplete."
                self.isArmed = committed
            } catch {
                self.errorMessage = "Could not save Agenda edit: \(error.localizedDescription)"
            }
        }
    }

    func scheduleAgendaTomorrowAutosave() {
        agendaTomorrowSaveTask?.cancel()
        agendaTomorrowSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self, self.tomorrowIsDirty, let worker = self.worker else { return }
            let edited = self.tomorrowTasks
            let profile = self.resolver.profile(for: self.tomorrowDate)
            do {
                try await worker.saveAgendaEdits(date: self.tomorrowDate, tasks: edited, profile: profile.kind)
                self.tomorrowBaselineTasks = edited
                self.markTomorrowDirty()
            } catch {
                self.errorMessage = "Could not save Tomorrow Agenda edit: \(error.localizedDescription)"
            }
        }
    }

    func submitQuickNote(onSaved: (() -> Void)? = nil) {
        guard let worker, !isSavingQuickNote else { return }
        let line = quickNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        quickNote = ""
        isSavingQuickNote = true
        quickNoteError = nil
        let submissionID = quickNoteSubmissionID ?? UUID()
        quickNoteSubmissionID = submissionID
        Task { [weak self] in
            do {
                try await worker.appendQuickNote(line, submissionID: submissionID)
                self?.isSavingQuickNote = false
                self?.quickNoteSubmissionID = nil
                onSaved?()
            } catch {
                guard let self else { return }
                self.isSavingQuickNote = false
                if self.quickNote.isEmpty { self.quickNote = line }
                self.quickNoteError = error.localizedDescription
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

    func setDailyField(_ definition: DailyFieldDefinition, value: String) {
        guard let worker else { return }
        dailyFieldValues[definition.id] = value
        let date = now
        dailyFieldSaveTasks[definition.id]?.cancel()
        dailyFieldSaveTasks[definition.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await worker.setDailyFieldValue(definition, value: value, date: date)
                self?.reloadDailyDashboardAnalytics()
            }
            catch { self?.errorMessage = "Could not save \(definition.name): \(error.localizedDescription)" }
        }
    }

    func setHistoricalDailyField(definitionID: String, dateText: String, value: String) {
        guard let worker,
              let definition = dailyFieldDefinitions.first(where: { $0.id == definitionID })
        else { return }
        let formatter = DateFormatter()
        formatter.calendar = WallClock.dhakaCalendar()
        formatter.timeZone = formatter.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateText) else { return }
        if let index = dailyMetricHistory.firstIndex(where: { $0.definitionID == definitionID && $0.date == dateText }) {
            dailyMetricHistory[index].value = value
        } else if !value.isEmpty {
            dailyMetricHistory.append(DailyFieldValue(definitionID: definitionID, date: dateText, value: value))
        }
        let key = "history:\(definitionID):\(dateText)"
        dailyFieldSaveTasks[key]?.cancel()
        dailyFieldSaveTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await worker.setDailyFieldValue(definition, value: value, date: date)
                self?.reloadDailyDashboardAnalytics()
            } catch {
                self?.errorMessage = "Could not update historical \(definition.name): \(error.localizedDescription)"
            }
        }
    }

    private func setStreak(_ definition: StreakDefinition, status: StreakStatus, date: Date) {
        guard let worker else { return }
        Task { [weak self] in
            do {
                try await worker.setStreakValue(definition, status: status, date: date)
                self?.reloadStreakSummaries()
                self?.reloadDailyDashboardAnalytics()
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

    func saveCloudPairingToken() {
        let token = cloudPairingToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let worker, !token.isEmpty, !isConnectingCloud else { return }
        isConnectingCloud = true
        cloudConnectionMessage = "Connecting…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try CloudCredentials.savePairingValue(token)
                UserDefaults.standard.set(0, forKey: "cloudSyncCursor")
                let result = try await worker.connectCloudSync()
                self.cloudSyncPaired = true
                self.cloudPairingToken = ""
                self.applyCloudSyncResult(result)
                self.cloudConnectionMessage = result.issue == nil ? "Connected and synced." : "Connected. Sync will retry automatically."
                self.isConnectingCloud = false
                self.startCloudSyncLoop()
                self.reloadVault()
            } catch {
                try? CloudCredentials.clear()
                self.cloudSyncPaired = false
                self.cloudConnectionMessage = "Connection failed: \(error.localizedDescription)"
                self.isConnectingCloud = false
                self.errorMessage = "Could not connect ReFocus sync: \(error.localizedDescription)"
            }
        }
    }

    func pasteCloudPairingToken() {
        guard let value = NSPasteboard.general.string(forType: .string) else {
            cloudConnectionMessage = "The clipboard does not contain text."
            return
        }
        cloudPairingToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        cloudConnectionMessage = nil
    }

    func disconnectCloudSync() {
        do {
            try CloudCredentials.clear()
            cloudSyncTicker?.cancel()
            cloudSyncTicker = nil
            cloudSyncPaired = false
            cloudSyncStatus = "Local only"
            cloudSyncPendingCount = 0
            cloudSyncIssue = nil
            cloudPairingToken = ""
            cloudConnectionMessage = "Disconnected."
        } catch {
            errorMessage = "Could not remove the pairing token: \(error.localizedDescription)"
        }
    }

    func tick(at date: Date = Date()) {
        let calendar = WallClock.dhakaCalendar()
        let previousDay = calendar.startOfDay(for: now)
        let currentDay = calendar.startOfDay(for: date)
        now = date
        clockDisplay.snapshot = clock.snapshot(at: date)

        // The dashboard is long-lived. If it stays open across midnight, the
        // ticker must load the new day's plan instead of continuing to show
        // yesterday's tasks (and yesterday's reschedule context).
        if previousDay != currentDay, worker != nil {
            reloadVault(force: true)
        }

        if refreshPlanningState(at: date) {
            validationIssues = currentValidation(tasks)
        }

        let minute = clock.minuteOfDay(for: date)
        if minute == 1200, attemptedFinalCaptureDay != currentDay, let worker {
            Task { [weak self] in
                do {
                    _ = try await worker.captureFinalSnapshot(on: currentDay, at: date)
                    self?.attemptedFinalCaptureDay = currentDay
                    self?.loadDiff(on: self?.diffDate ?? currentDay)
                } catch {
                    self?.errorMessage = "Final snapshot capture failed: \(error.localizedDescription)"
                }
            }
        }

        // Screen breaks are a device-level productivity guard, not a planning
        // feature. They remain active around the clock whenever ReFocus is
        // running, including after the 21:30 planning cutoff.
        if snapshot.phase == .screenBreak {
            let breakID = sessionID(for: snapshot.cycleStart)
            if activeBreakID != breakID || overlayController.mode != .screenBreak {
                activeBreakID = breakID
                beginCheckIn(id: breakID)
                isBreakVisible = true
                overlayController.showBreak(model: self)
            }
            return
        }

        if overlayController.mode == .screenBreak {
            finalizeCurrentCheckIn()
            overlayController.hide()
            isBreakVisible = false
        }
        activeBreakID = nil

        // Planning gates apply only to the active day. Outside the routine
        // window ReFocus stays quiet until the next five-minute screen break.
        guard minute >= 330 && minute < 1290 else {
            isArmed = false
            if overlayController.mode == .planningGate { overlayController.hide() }
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
    }

    func loadDiff(on date: Date) {
        diffDate = WallClock.dhakaCalendar().startOfDay(for: date)
        guard let worker else { return }
        Task { [weak self] in
            guard let self else { return }
            if let result = try? await worker.loadDiff(on: self.diffDate, now: self.now) {
                self.diffInitialSnapshots = result.0
                self.diffFinalSnapshot = result.1
            }
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

    private enum TaskUndoPersistence {
        case none
        case todayPlan
        case todayAgenda
        case tomorrowAgenda
        case agenda
    }

    private struct TaskUndoSnapshot {
        var today: [PlanTask]
        var tomorrow: [PlanTask]
        var agenda: [AgendaTask]
        var collapsed: Set<UUID>
    }

    private func currentTaskUndoSnapshot() -> TaskUndoSnapshot {
        TaskUndoSnapshot(
            today: tasks,
            tomorrow: tomorrowTasks,
            agenda: agendaTasks,
            collapsed: collapsedTaskIDs
        )
    }

    private func registerTaskUndo(actionName: String, persistence: TaskUndoPersistence) {
        let snapshot = currentTaskUndoSnapshot()
        taskUndoManager.registerUndo(withTarget: self) { target in
            target.restoreTaskUndoSnapshot(snapshot, actionName: actionName, persistence: persistence)
        }
        taskUndoManager.setActionName(actionName)
        taskUndoRevision &+= 1
    }

    private func restoreTaskUndoSnapshot(
        _ snapshot: TaskUndoSnapshot,
        actionName: String,
        persistence: TaskUndoPersistence
    ) {
        let outgoing = currentTaskUndoSnapshot()
        taskUndoManager.registerUndo(withTarget: self) { target in
            target.restoreTaskUndoSnapshot(outgoing, actionName: actionName, persistence: persistence)
        }
        taskUndoManager.setActionName(actionName)

        tasks = snapshot.today
        tomorrowTasks = snapshot.tomorrow
        agendaTasks = snapshot.agenda
        collapsedTaskIDs = snapshot.collapsed
        requestedTaskNameFocusID = nil
        markPlanDirty()
        markTomorrowDirty()
        taskUndoRevision &+= 1

        switch persistence {
        case .none:
            break
        case .todayPlan:
            savePlan()
        case .todayAgenda:
            scheduleAgendaTodayAutosave()
        case .tomorrowAgenda:
            scheduleAgendaTomorrowAutosave()
        case .agenda:
            persistAgendaTransition(from: outgoing.agenda, to: snapshot.agenda)
        }
    }

    private func persistAgendaTransition(from oldEntries: [AgendaTask], to newEntries: [AgendaTask]) {
        guard let worker else { return }
        let oldIDs = Set(oldEntries.map(\.id))
        let newIDs = Set(newEntries.map(\.id))
        Task { [weak self] in
            guard let self else { return }
            do {
                for deletedID in oldIDs.subtracting(newIDs) {
                    try await worker.deleteTask(deletedID)
                }
                try await worker.saveAgenda(newEntries)
            } catch {
                self.errorMessage = "Could not persist undone Agenda change: \(error.localizedDescription)"
                self.reloadVault(force: true)
            }
        }
    }

    private func blockingIssues(in issues: [PlanValidationIssue]) -> [PlanValidationIssue] {
        issues.filter(isBlocking)
    }

    @discardableResult
    private func refreshPlanningState(at date: Date) -> Bool {
        let resolvedProfile = resolver.profile(for: date)
        let resolvedSegment = validator.segment(at: date)
        let resolvedMinimum = validator.requiredCycles(
            in: resolvedSegment, at: date, profile: resolvedProfile, tasks: tasks
        )
        let changed = resolvedProfile != dayProfile
            || resolvedSegment != activeSegment
            || resolvedMinimum != requiredCycleMinimum
        if resolvedProfile != dayProfile { dayProfile = resolvedProfile }
        if resolvedSegment != activeSegment { activeSegment = resolvedSegment }
        if resolvedMinimum != requiredCycleMinimum { requiredCycleMinimum = resolvedMinimum }
        return changed
    }

    func isBlocking(_ issue: PlanValidationIssue) -> Bool {
        if issue.severity == .warning { return false }
        return true
    }

    private func currentValidation(_ candidate: [PlanTask]) -> [PlanValidationIssue] {
        let minimumCycles = validator.requiredCycles(
            in: activeSegment, at: now, profile: dayProfile, tasks: candidate
        )
        var issues = validator.validate(
            tasks: candidate,
            profile: dayProfile,
            minimumCycles: minimumCycles,
            requireFixedTasks: true,
            requireTaskDetails: true,
            countedSegment: activeSegment,
            scheduledDate: now,
            now: now
        )
        let minute = clock.minuteOfDay(for: now)
        if minute >= 330, minute < 1290,
           let availabilityIssue = validator.availabilityIssue(
               in: activeSegment, at: now, profile: dayProfile, tasks: candidate
           ) {
            issues.append(availabilityIssue)
        }
        return issues
    }

    private func tomorrowRequiredCycles(_ segment: PlanningSegment, tasks: [PlanTask]) -> Int {
        var parts = WallClock.dhakaCalendar().dateComponents([.year, .month, .day], from: tomorrowDate)
        parts.hour = segment.startMinute / 60
        parts.minute = segment.startMinute % 60
        let start = WallClock.dhakaCalendar().date(from: parts) ?? tomorrowDate
        return validator.requiredCycles(
            in: segment,
            at: start,
            profile: resolver.profile(for: tomorrowDate),
            tasks: tasks
        )
    }

    private func validateTomorrow(_ candidate: [PlanTask]) -> [PlanValidationIssue] {
        var issues = validator.validate(
            tasks: candidate,
            profile: resolver.profile(for: tomorrowDate),
            minimumCycles: 0,
            requireFixedTasks: true,
            requireTaskDetails: true,
            scheduledDate: tomorrowDate,
            now: now
        )
        for segment in PlanningSegment.allCases {
            let actual = candidate.reduce(0) { $0 + $1.planningCycles(in: segment) }
            let required = tomorrowRequiredCycles(segment, tasks: candidate)
            if actual < required {
                issues.append(.insufficientSegment(segment: segment, actual: actual, required: required))
            }
        }
        return issues
    }

    private func withRecurringFixedTasks(_ existing: [PlanTask]) -> [PlanTask] {
        var seen = Set<UUID>()
        var result = existing.filter { seen.insert($0.id).inserted }
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
        let left = lhs.task.hasScheduledTime ? lhs.task.startMinute : Int.max
        let right = rhs.task.hasScheduledTime ? rhs.task.startMinute : Int.max
        return left == right
            ? lhs.task.title.localizedCaseInsensitiveCompare(rhs.task.title) == .orderedAscending
            : left < right
    }

    private func freshCopy(of template: PlanTask) -> PlanTask {
        PlanTask(
            title: template.title,
            description: template.description,
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
        do {
            worker = try VaultWorker(vaultURL: url)
        } catch {
            worker = nil
            errorMessage = "Could not open ReFocus storage: \(error.localizedDescription)"
            return
        }
        // The database owns live state. iCloud Markdown is output-only, so
        // projection writes must never trigger a broad vault reload.
        watchers = []
        if let worker { Task { await worker.refreshProjections() } }
        reloadVault()
        startCloudSyncLoop()
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

    private func ensureLaunchAtLogin() {
        guard SMAppService.mainApp.status != .enabled else {
            launchAtLogin = true
            return
        }
        do {
            try SMAppService.mainApp.register()
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            errorMessage = "ReFocus could not enable launch at login: \(error.localizedDescription)"
        }
    }

    private func reloadStreakSummaries() {
        guard let worker else { return }
        let definitions = streakDefinitions
        Task { [weak self] in
            let summaries = (try? await worker.streakSummaries(for: Date(), definitions: definitions)) ?? []
            self?.streakSummaries = summaries
        }
    }

    private func reloadDailyDashboardAnalytics() {
        guard let worker else { return }
        let definitions = streakDefinitions
        let date = now
        Task { [weak self] in
            let analytics = (try? await worker.loadDailyDashboardAnalytics(for: date, definitions: definitions))
                ?? DailyDashboardAnalytics()
            self?.dailyDashboardAnalytics = analytics
            self?.dailyMetricHistory = (try? await worker.loadDailyMetricHistory()) ?? []
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

    private func startCloudSyncLoop() {
        cloudSyncTicker?.cancel()
        guard let worker else { return }
        cloudSyncTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.cloudSyncStatus = self.cloudSyncPaired ? "Syncing" : "Checking pairing"
                let result = await worker.syncNow()
                self.applyCloudSyncResult(result)
                if result.changedLocally { self.reloadVault(preservingLocalEdits: true) }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    func syncCloudNow() {
        guard let worker else { return }
        Task { [weak self] in
            guard let self else { return }
            self.cloudSyncStatus = self.cloudSyncPaired ? "Syncing" : "Checking pairing"
            let result = await worker.syncNow()
            self.applyCloudSyncResult(result)
            if result.changedLocally { self.reloadVault(preservingLocalEdits: true) }
        }
    }

    private func applyCloudSyncResult(_ result: CloudSyncResult) {
        cloudSyncPaired = result.isPaired
        cloudSyncPendingCount = result.pendingMutations
        cloudSyncIssue = result.issue
        if !result.isPaired {
            cloudSyncStatus = "Local only"
        } else if result.issue != nil {
            cloudSyncStatus = "Needs attention"
        } else {
            cloudSyncStatus = "Synced"
            cloudSyncLastSuccess = Date()
        }
    }

    private func mergeRemoteTasks(
        current: [PlanTask], baseline: [PlanTask], remote: [PlanTask]
    ) -> [PlanTask] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })
        let remoteIDs = Set(remote.map(\.id))
        var merged: [PlanTask] = []

        for remoteTask in remote {
            guard let currentTask = currentByID[remoteTask.id] else {
                if baselineByID[remoteTask.id] == nil { merged.append(remoteTask) }
                continue
            }
            guard let baselineTask = baselineByID[remoteTask.id] else {
                merged.append(currentTask)
                continue
            }
            merged.append(mergeTask(current: currentTask, baseline: baselineTask, remote: remoteTask))
        }
        for currentTask in current where !remoteIDs.contains(currentTask.id) {
            guard let baselineTask = baselineByID[currentTask.id] else {
                merged.append(currentTask)
                continue
            }
            if currentTask != baselineTask { merged.append(currentTask) }
        }
        return merged.sorted(by: taskSort)
    }

    private func mergeTask(current: PlanTask, baseline: PlanTask, remote: PlanTask) -> PlanTask {
        var value = remote
        if current.title != baseline.title { value.title = current.title }
        if current.startMinute != baseline.startMinute { value.startMinute = current.startMinute }
        if current.cycles != baseline.cycles { value.cycles = current.cycles }
        if current.kind != baseline.kind { value.kind = current.kind }
        if current.priority != baseline.priority { value.priority = current.priority }
        if current.difficulty != baseline.difficulty { value.difficulty = current.difficulty }
        if current.mvp != baseline.mvp { value.mvp = current.mvp }
        if current.coreTasks != baseline.coreTasks { value.coreTasks = current.coreTasks }
        if current.isComplete != baseline.isComplete { value.isComplete = current.isComplete }
        if current.fixedRole != baseline.fixedRole { value.fixedRole = current.fixedRole }
        if current.routineOverride != baseline.routineOverride { value.routineOverride = current.routineOverride }
        if current.routineBlock != baseline.routineBlock { value.routineBlock = current.routineBlock }
        if current.durationMinutes != baseline.durationMinutes { value.durationMinutes = current.durationMinutes }
        if current.displayColor != baseline.displayColor { value.displayColor = current.displayColor }
        if current.predefinedKind != baseline.predefinedKind { value.predefinedKind = current.predefinedKind }
        if current.predefinedKey != baseline.predefinedKey { value.predefinedKey = current.predefinedKey }
        if current.predefinedVersion != baseline.predefinedVersion { value.predefinedVersion = current.predefinedVersion }
        if current.quickCapture != baseline.quickCapture { value.quickCapture = current.quickCapture }
        if current.timeAssigned != baseline.timeAssigned { value.timeAssigned = current.timeAssigned }
        return value
    }

    private func taskSort(_ lhs: PlanTask, _ rhs: PlanTask) -> Bool {
        let left = lhs.hasScheduledTime ? lhs.startMinute : Int.max
        let right = rhs.hasScheduledTime ? rhs.startMinute : Int.max
        return left == right
            ? lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            : left < right
    }
}
