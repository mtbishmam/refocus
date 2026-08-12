import AppKit
import SwiftUI
import RefocusCore

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuClockStatus(model: model, clock: model.clockDisplay)
            Text(model.planMessage).font(.caption).foregroundStyle(.secondary)
            Divider()
            if model.isArmed {
                Button("End Work") { model.stopWork() }
            } else {
                Button("Start Work") { model.startNow() }
                    .disabled(!model.isPlanReady)
                if !model.isPlanReady {
                    Text(model.planGateMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Button("Open Dashboard") {
                DashboardWindowController.shared.show(model: model)
            }
            Button("Choose Obsidian Vault…") { model.chooseVault() }
            Divider()
            Button("Quit ReFocus") { NSApp.terminate(nil) }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct MenuClockStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: ClockDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.phaseTitle)
                    .font(.caption.bold())
                    .foregroundStyle(clock.snapshot.phase == .focus ? .green : .orange)
                Spacer()
                Text(model.countdownText).monospacedDigit().font(.title3.bold())
            }
            Text(model.currentTaskTitle).font(.headline).lineLimit(2)
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab: DashboardTab = .today

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $selectedTab) {
                Text("Agenda").tag(DashboardTab.agenda)
                Text("Today").tag(DashboardTab.today)
                Text("Tomorrow").tag(DashboardTab.tomorrow)
                Text("Daily").tag(DashboardTab.streaks)
                Text("Diff").tag(DashboardTab.diff)
                Text("Settings").tag(DashboardTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 590)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Group {
                switch selectedTab {
                case .agenda: AgendaView()
                case .today: PlanEditorView()
                case .tomorrow: TomorrowPlanView()
                case .streaks: StreaksView()
                case .diff: DiffView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(dashboardBackground)
        .frame(minWidth: 860, minHeight: 620)
        .alert("ReFocus", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var dashboardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.075, green: 0.08, blue: 0.10)
            : Color(nsColor: .windowBackgroundColor)
    }
}

private enum DashboardTab: Hashable {
    case agenda
    case today
    case tomorrow
    case streaks
    case diff
    case settings
}

private struct DiffView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Diff").font(.largeTitle.bold())
                        Text("First saved plan vs immutable 20:00 final").foregroundStyle(.secondary)
                    }
                    Spacer()
                    DatePicker("Date", selection: Binding(get: { model.diffDate }, set: { model.loadDiff(on: $0) }), displayedComponents: .date)
                        .labelsHidden().frame(width: 150)
                }
                HStack(spacing: 8) {
                    Text(profileLabel).diffBadge(.blue)
                    Text(finalLabel).diffBadge(finalColor)
                    Text(summaryLabel).diffBadge(.secondary)
                }
                HStack(spacing: 12) {
                    ForEach(PlanDiffChange.allCases, id: \.self) { change in Text(change.rawValue.capitalized).diffBadge(color(change)) }
                }.font(.caption)
                ForEach(PlanningSegment.allCases, id: \.self) { segment in
                    DiffSegmentView(
                        segment: segment,
                        date: MarkdownPlanCodec.isoDate(model.diffDate),
                        initial: model.diffInitialSnapshots?.initial[segment],
                        initialCapturedAt: model.diffInitialSnapshots?.initialCapturedAt[segment],
                        final: finalTasks(for: segment),
                        finalStatus: finalLabel
                    )
                }
            }.padding(18)
        }
        .task { model.loadDiff(on: model.diffDate) }
    }

    private var finalSnapshot: FinalPlanSnapshot? { if case .available(let value) = model.diffFinalSnapshot { value } else { nil } }
    private var profileLabel: String { (model.diffInitialSnapshots?.profile ?? finalSnapshot?.profile).map { "Profile: \($0.rawValue)" } ?? "Profile unavailable" }
    private var finalLabel: String {
        switch model.diffFinalSnapshot {
        case .pending: "Final snapshot pending"
        case .unavailable: "Final snapshot unavailable"
        case .available(let value): "Final: \(value.capturedAt.formatted(date: .omitted, time: .shortened))"
        }
    }
    private var finalColor: Color { if case .available = model.diffFinalSnapshot { return .green }; if case .pending = model.diffFinalSnapshot { return .orange }; return .red }
    private var allRows: [PlanDiffRow] { PlanDiffEngine.rows(initial: model.diffInitialSnapshots?.initial.values.flatMap { $0 } ?? [], final: finalSnapshot?.tasks ?? [], date: MarkdownPlanCodec.isoDate(model.diffDate)) }
    private var summaryLabel: String { PlanDiffChange.allCases.filter { $0 != .unchanged }.map { change in "\(allRows.filter { $0.changes.contains(change) }.count) \(change.rawValue)" }.filter { !$0.hasPrefix("0 ") }.joined(separator: " · ").ifEmpty("No changes") }
    private func finalTasks(for segment: PlanningSegment) -> [FinalTaskSnapshot]? {
        guard let snapshot = finalSnapshot else { return nil }
        let initialIDs = Set(model.diffInitialSnapshots?.initial[segment]?.map(\.id) ?? [])
        let allInitialIDs = Set(model.diffInitialSnapshots?.initial.values.flatMap { $0.map(\.id) } ?? [])
        return snapshot.tasks.filter {
            initialIDs.contains($0.id) ||
                (!allInitialIDs.contains($0.id) && $0.scheduledDate == MarkdownPlanCodec.isoDate(model.diffDate) && segment.contains($0.task))
        }
    }
    private func color(_ change: PlanDiffChange) -> Color { switch change { case .added: .green; case .removed: .red; case .moved: .orange; case .unchanged: .secondary; default: .blue } }
}

private struct DiffSegmentView: View {
    let segment: PlanningSegment
    let date: String
    let initial: [PlanTask]?
    let initialCapturedAt: Date?
    let final: [FinalTaskSnapshot]?
    let finalStatus: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(segment.title).font(.title3.bold()); Spacer(); Text(totals).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text(initialCapturedAt.map { "Initial · \($0.formatted(date: .omitted, time: .shortened))" }
                    ?? (initial == nil ? "Initial Plan" : "Default Initial · not saved"))
                    .frame(maxWidth: .infinity)
                Text("Final Plan").frame(maxWidth: .infinity)
                Color.clear.frame(width: 86)
            }
                .font(.caption.bold()).foregroundStyle(.secondary)
            if initial == nil {
                Text("Not initialized").font(.caption).foregroundStyle(.secondary).padding(8)
            }
            if final == nil {
                Text(finalStatus).font(.caption).foregroundStyle(.secondary).padding(8)
            } else {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Group { if let task = row.initial { DiffTaskRow(task: task) } else { Text("—").foregroundStyle(.secondary) } }.frame(maxWidth: .infinity)
                        Group { if let state = row.final, !state.deleted { DiffTaskRow(task: state.task, scheduledDate: state.scheduledDate) } else { Text("—").foregroundStyle(.secondary) } }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 3) { ForEach(Array(row.changes).sorted { $0.rawValue < $1.rawValue }, id: \.self) { Text($0.rawValue.capitalized).font(.caption2.bold()) } }.frame(width: 86, alignment: .leading)
                    }
                }
            }
        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private var rows: [PlanDiffRow] { PlanDiffEngine.rows(initial: initial ?? [], final: final ?? [], date: date) }
    private var totals: String {
        let rows = PlanDiffEngine.rows(initial: initial ?? [], final: final ?? [], date: date)
        return "\(initial?.count ?? 0) initial · \(final?.filter { !$0.deleted }.count ?? 0) final · \(rows.filter { !$0.changes.contains(.unchanged) }.count) changed"
    }
}

private struct DiffTaskRow: View {
    let task: PlanTask
    var scheduledDate: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle").foregroundStyle(task.isComplete ? .green : .secondary)
                Text("\(MarkdownPlanCodec.time(task.startMinute))–\(MarkdownPlanCodec.time(task.endMinute))").monospacedDigit().foregroundStyle(.secondary)
                Text(task.title).bold().lineLimit(1); Spacer(); Text("\(task.cycles)×").foregroundStyle(.secondary)
            }.font(.caption)
            Text("\(task.kind.rawValue) · \(task.priority) · \(task.difficulty)").font(.caption2).foregroundStyle(.secondary)
            if let scheduledDate { Text("Scheduled: \(scheduledDate)").font(.caption2).foregroundStyle(.secondary) }
            if !task.mvp.isEmpty { Text("MVP: \(task.mvp)").font(.caption2).lineLimit(2) }
            ForEach(task.coreTasks) { sub in Text("\(sub.isComplete ? "☑" : "☐") \(sub.title)").font(.caption2).lineLimit(1) }
        }.padding(7).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension View { func diffBadge(_ color: Color) -> some View { self.font(.caption.bold()).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 4).background(color.opacity(0.14), in: Capsule()) } }
private extension String { func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self } }

private func taskVisible(
    _ task: PlanTask, showUser: Bool, showPredefined: Bool, showFixed: Bool
) -> Bool {
    if task.fixedRole != nil { return showFixed }
    if task.isRoutineBlock { return showPredefined }
    return showUser
}

private struct TaskVisibilityMenu: View {
    @Binding var showUser: Bool
    @Binding var showPredefined: Bool
    @Binding var showFixed: Bool

    var body: some View {
        Menu("Filter") {
            Toggle("User tasks", isOn: $showUser)
            Toggle("Predefined blocks", isOn: $showPredefined)
            Toggle("Fixed blocks", isOn: $showFixed)
            Divider()
            Button("Show All") {
                showUser = true
                showPredefined = true
                showFixed = true
            }
        }
    }
}

struct PlanEditorView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("todayFilterShowUser") private var showUserTasks = true
    @AppStorage("todayFilterShowPredefined") private var showPredefinedBlocks = true
    @AppStorage("todayFilterShowFixed") private var showFixedBlocks = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Today").font(.largeTitle.bold())
                    HStack(spacing: 7) {
                        headerTag(profileName, color: .secondary)
                        headerTag(model.activeSegment.title, color: .blue)
                        headerTag(
                            model.requiredCycleMinimum == 0
                                ? "No work cycles available"
                                : "\(model.plannedCycles) / \(model.requiredCycleMinimum) cycles",
                            color: model.isPlanCommitted ? .green : .orange
                        )
                    }
                    if let blocker = model.validationIssues.first(where: model.isBlocking) {
                        Label(blocker.description, systemImage: "lock.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    } else if !model.isPlanReady {
                        Text("Planning gate locked")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                TaskVisibilityMenu(showUser: $showUserTasks, showPredefined: $showPredefinedBlocks, showFixed: $showFixedBlocks)
                Button {
                    model.toggleAllTasksCollapsed(model.tasks)
                } label: {
                    Label(
                        model.allTasksCollapsed(model.tasks) ? "Expand All" : "Collapse All",
                        systemImage: model.allTasksCollapsed(model.tasks) ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
                    )
                }
                .buttonStyle(.borderless)
                Toggle("Show completed", isOn: $model.showCompletedSubtasks)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: true, vertical: false)
                if model.isEditingPlan {
                    if model.planMessage == "Today is planned." {
                        Button("Cancel") { model.cancelEditingPlan() }
                    }
                    Button("Add Task") { model.addTask() }
                    if !model.taskTemplates.isEmpty {
                        Menu("Use Template") {
                            ForEach(model.taskTemplates) { template in
                                Button(template.title) { model.addTemplateToToday(template) }
                            }
                        }
                    }
                    Button(model.isSavingPlan ? "Saving…" : "Save Plan") { model.savePlan() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isPlanReady || model.isSavingPlan || (!model.planIsDirty && model.isPlanCommitted))
                        .help(model.planGateMessage)
                } else {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Reload") { model.reloadVault(force: true) }
                    Button("Edit Plan") { model.beginEditingPlan() }
                        .buttonStyle(.bordered)
                }
            }
            .padding()

            if model.tasks.isEmpty {
                ContentUnavailableView(
                    "Today has not been planned",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("Complete and save a valid \(model.requiredCycleMinimum)-cycle Today plan to unlock work.")
                )
            } else if model.isEditingPlan {
                let visibleTasks = model.tasks.filter {
                    taskVisible($0, showUser: showUserTasks, showPredefined: showPredefinedBlocks, showFixed: showFixedBlocks)
                }
                ScrollView {
                    if visibleTasks.isEmpty {
                        FilteredTasksEmptyState {
                            showUserTasks = true
                            showPredefinedBlocks = true
                            showFixedBlocks = true
                        }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(Array(model.tasks.enumerated()).filter {
                                taskVisible($0.element, showUser: showUserTasks, showPredefined: showPredefinedBlocks, showFixed: showFixedBlocks)
                            }, id: \.element.id) { index, task in
                                TaskEditorRow(task: $model.tasks[index], cyclesChanged: {
                                    model.normalizeCoreTasks(for: task.id)
                                }, delete: {
                                    model.removeTask(id: task.id)
                                }, addSubtask: {
                                    model.addSubtask(to: task.id)
                                }, removeSubtask: { subtaskID in
                                    model.removeSubtask(taskID: task.id, subtaskID: subtaskID)
                                }, saveTemplate: {
                                    model.saveTaskAsTemplate(task)
                                })
                                .id(task.id)
                                .onChange(of: task) { model.markPlanDirty() }
                                .padding(.horizontal, 16)
                                .background((task.displayColor ?? .none).swiftUIColor.opacity(task.displayColor == nil ? 0.055 : 0.13), in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)))
                            }
                        }
                        .padding()
                    }
                }
            } else {
                SavedPlanView()
            }

            if !model.validationIssues.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(model.validationIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(model.isBlocking(issue) ? .red : .yellow)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 38)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var profileName: String {
        switch model.dayProfile.kind {
        case .standard: "Standard Routine"
        case .universityEarly: "Saturday/Thursday Flexible"
        case .universityLate: "Sunday/Tuesday University"
        case .fridaySSC: "Friday SSC"
        }
    }

    private func headerTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

struct TomorrowPlanView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("tomorrowFilterShowUser") private var showUserTasks = true
    @AppStorage("tomorrowFilterShowPredefined") private var showPredefinedBlocks = true
    @AppStorage("tomorrowFilterShowFixed") private var showFixedBlocks = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Tomorrow").font(.largeTitle.bold())
                    Text(model.tomorrowDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .foregroundStyle(.secondary)
                    Text(model.tomorrowCycleSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TaskVisibilityMenu(showUser: $showUserTasks, showPredefined: $showPredefinedBlocks, showFixed: $showFixedBlocks)
                Button {
                    model.toggleAllTasksCollapsed(model.tomorrowTasks)
                } label: {
                    Label(
                        model.allTasksCollapsed(model.tomorrowTasks) ? "Expand All" : "Collapse All",
                        systemImage: model.allTasksCollapsed(model.tomorrowTasks) ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
                    )
                }.buttonStyle(.borderless)
                Button("Add Task") { model.addTomorrowTask() }
                if !model.taskTemplates.isEmpty {
                    Menu("Use Template") {
                        ForEach(model.taskTemplates) { template in
                            Button(template.title) { model.addTemplateToTomorrow(template) }
                        }
                    }
                }
                Button(model.isSavingTomorrow ? "Saving…" : "Save Tomorrow") { model.saveTomorrowPlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.tomorrowIsReady || model.isSavingTomorrow || !model.tomorrowIsDirty)
            }
            .padding()

            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(model.tomorrowTasks.enumerated()).filter {
                        taskVisible($0.element, showUser: showUserTasks, showPredefined: showPredefinedBlocks, showFixed: showFixedBlocks)
                    }, id: \.element.id) { index, task in
                        TaskEditorRow(
                            task: $model.tomorrowTasks[index],
                            cyclesChanged: { model.normalizeTomorrowSubtasks(for: task.id) },
                            delete: { model.removeTomorrowTask(id: task.id) },
                            addSubtask: { model.addTomorrowSubtask(to: task.id) },
                            removeSubtask: { model.removeTomorrowSubtask(taskID: task.id, subtaskID: $0) },
                            saveTemplate: { model.saveTaskAsTemplate(task) }
                        )
                        .id(task.id)
                        .onChange(of: task) { model.markTomorrowDirty() }
                        .padding(.horizontal, 16)
                        .background((task.displayColor ?? .none).swiftUIColor.opacity(task.displayColor == nil ? 0.055 : 0.13), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)))
                    }
                }.padding()
            }

            if !model.tomorrowValidationIssues.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(model.tomorrowValidationIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? .red : .yellow)
                        }
                    }.padding(.horizontal)
                }.frame(height: 38)
            }
        }
    }
}

private struct TaskEditorRow: View {
    @EnvironmentObject private var model: AppModel
    @Binding var task: PlanTask
    var cyclesChanged: () -> Void
    var delete: () -> Void
    var addSubtask: () -> Void
    var removeSubtask: (UUID) -> Void
    var saveTemplate: () -> Void

    private let priorities = ["Do/Die", "High", "Medium", "Low"]
    private let difficulties = ["Hard", "Moderate", "Easy"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Toggle("", isOn: $task.isComplete).labelsHidden()
                Text(task.hasScheduledTime
                    ? MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute)
                    : "No time")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                Text(task.title).font(.headline)
                Spacer()
                if task.fixedRole == nil {
                    Button("Delete", role: .destructive, action: delete)
                        .buttonStyle(.borderless)
                }
                Button { model.toggleCollapsed(task.id) } label: {
                    Image(systemName: model.collapsedTaskIDs.contains(task.id) ? "chevron.down" : "chevron.up")
                        .frame(width: 56, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if !model.collapsedTaskIDs.contains(task.id) {
              editorField("Task name") {
                TextField("Rename this task", text: $task.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.headline)
                    .disabled(task.fixedRole != nil)
              }
              HStack(alignment: .bottom, spacing: 14) {
                editorField("Start") {
                    if task.fixedRole != nil || task.isRoutineBlock {
                        TimeEditorField(minute: $task.startMinute)
                            .disabled(task.fixedRole != nil)
                            .frame(width: 114, alignment: .leading)
                    } else {
                        HStack(alignment: .center, spacing: 8) {
                            Toggle("Scheduled", isOn: Binding(
                                get: { task.hasScheduledTime },
                                set: { task.timeAssigned = $0 ? nil : false }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            if task.hasScheduledTime { TimeEditorField(minute: $task.startMinute) }
                        }
                        .frame(width: 114, height: 24, alignment: .leading)
                    }
                }
                editorField("Priority") {
                    Picker("", selection: $task.priority) {
                        ForEach(priorities, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                editorField("Difficulty") {
                    Picker("", selection: $task.difficulty) {
                        ForEach(difficulties, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                editorField("Kind") {
                    Picker("", selection: $task.kind) {
                        Text("Normal").tag(TaskKind.normal)
                        Text("Contest").tag(TaskKind.contest)
                    }
                    .labelsHidden()
                    .frame(width: 180)
                    .disabled(task.fixedRole != nil)
                }
                editorField("Duration") {
                    Stepper(
                        "\(task.cycles) cycle\(task.cycles == 1 ? "" : "s")",
                        value: $task.cycles,
                        in: durationRange
                    )
                    .onChange(of: task.cycles) {
                        task.durationMinutes = nil
                        cyclesChanged()
                    }
                    .frame(width: 145)
                }
                editorField("Color") {
                    Picker("", selection: Binding(
                        get: { task.displayColor ?? TaskDisplayColor.none },
                        set: { task.displayColor = $0 == TaskDisplayColor.none ? nil : $0 }
                    )) {
                        ForEach(TaskDisplayColor.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
              }

              editorField(task.quickCapture == true ? "Optional MVP · MCP quick task" : "MVP · completion definition") {
                TextField(task.quickCapture == true ? "Optional" : "Describe exactly what must be true for this task to count as complete", text: $task.mvp, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
              }

              if !task.isRoutineBlock {
              VStack(alignment: .leading, spacing: 8) {
                    HStack {
                    Text(task.quickCapture == true ? "SUBTASKS · optional" : "SUBTASKS · at least three")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save as Template", action: saveTemplate)
                        .buttonStyle(.borderless)
                    Button("Add Subtask", action: addSubtask)
                        .buttonStyle(.borderless)
                    }
                    ForEach(Array(task.coreTasks.indices), id: \.self) { index in
                        if model.showCompletedSubtasks || !task.coreTasks[index].isComplete {
                          HStack(spacing: 8) {
                            Toggle("", isOn: $task.coreTasks[index].isComplete).labelsHidden()
                            Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                            TextField("Name subtask \(index + 1)", text: $task.coreTasks[index].title)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                removeSubtask(task.coreTasks[index].id)
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(task.coreTasks.count <= (task.quickCapture == true ? 0 : 3))
                          }
                        }
                    }
              }
              .padding(.leading, 30)
              }
            }
        }
        .padding(.vertical, 12)
    }

    private var durationRange: ClosedRange<Int> {
        switch task.fixedRole {
        case .planTomorrow: 1...2
        case .dayAnalysis, .revision: 1...1
        case nil: task.isRoutineBlock ? 1...10 : (task.kind == .normal ? 1...4 : 1...10)
        }
    }

    private func editorField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct SavedPlanView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("todayFilterShowUser") private var showUserTasks = true
    @AppStorage("todayFilterShowPredefined") private var showPredefinedBlocks = true
    @AppStorage("todayFilterShowFixed") private var showFixedBlocks = true

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                let visibleTasks = model.tasks.filter {
                    taskVisible($0, showUser: showUserTasks, showPredefined: showPredefinedBlocks, showFixed: showFixedBlocks)
                }
                if visibleTasks.isEmpty && !model.tasks.isEmpty {
                    FilteredTasksEmptyState {
                        showUserTasks = true
                        showPredefinedBlocks = true
                        showFixedBlocks = true
                    }
                } else {
                    ForEach(visibleTasks) { task in
                        SavedTaskCard(task: task, isCurrent: task.id == model.executionTask?.id)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }
}

private struct SavedTaskCard: View {
    @EnvironmentObject private var model: AppModel
    let task: PlanTask
    let isCurrent: Bool
    @State private var rescheduleDate = Date()
    @State private var showingReschedule = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Button { model.toggleTaskCompletion(task.id) } label: {
                    Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isComplete ? .green : .secondary)
                }.buttonStyle(.plain)
                Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                Text(task.title).font(.headline)
                tag(task.priority, color: priorityColor)
                tag(task.difficulty, color: difficultyColor)
                Spacer()
                if !task.isComplete && task.fixedRole == nil {
                    Button("Reschedule") {
                        rescheduleDate = WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: model.now) ?? model.now
                        showingReschedule = true
                    }
                    .buttonStyle(.borderless)
                }
                if task.fixedRole == nil {
                    Button("Delete", role: .destructive) {
                        model.removeTask(id: task.id)
                        model.scheduleAgendaTodayAutosave()
                    }
                    .buttonStyle(.borderless)
                }
                Button { model.toggleCollapsed(task.id) } label: {
                    Image(systemName: model.collapsedTaskIDs.contains(task.id) ? "chevron.down" : "chevron.up")
                        .frame(width: 56, height: 44)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if !model.collapsedTaskIDs.contains(task.id) {
              if !task.mvp.isEmpty { Text("MVP → \(task.mvp)").font(.subheadline) }
              ForEach(Array(task.coreTasks.enumerated()), id: \.element.id) { index, core in
                if model.showCompletedSubtasks || !core.isComplete {
                HStack(spacing: 8) {
                    Button { model.toggleSubtaskCompletion(taskID: task.id, subtaskID: core.id) } label: {
                        Image(systemName: core.isComplete ? "checkmark.square.fill" : "square")
                    }.buttonStyle(.plain)
                    Text("\(index + 1). \(core.title)")
                }
                .font(.caption)
                .foregroundStyle(core.isComplete ? .green : .secondary)
                .padding(.leading, 28)
                }
              }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isCurrent ? Color.orange.opacity(0.20) : (task.displayColor ?? .none).swiftUIColor.opacity(task.displayColor == nil ? 0.055 : 0.13),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCurrent ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)))
        .sheet(isPresented: $showingReschedule) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reschedule \(task.title)").font(.title2.bold())
                DatePicker(
                    "Date", selection: $rescheduleDate,
                    in: WallClock.dhakaCalendar().startOfDay(for: model.now)...,
                    displayedComponents: .date
                )
                HStack {
                    Spacer()
                    Button("Cancel") { showingReschedule = false }
                    Button("Reschedule") {
                        model.rescheduleTask(task.id, to: rescheduleDate)
                        showingReschedule = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 420)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var priorityColor: Color {
        switch task.priority {
        case "Do/Die": .red
        case "High": .orange
        case "Medium": .blue
        default: .secondary
        }
    }

    private var difficultyColor: Color {
        switch task.difficulty {
        case "Hard": .red
        case "Moderate": .purple
        default: .green
        }
    }
}

private struct TimeEditorField: View {
    @Binding var minute: Int

    var body: some View {
        Picker("Start time", selection: $minute) {
            ForEach(options, id: \.self) { value in
                Text(MarkdownPlanCodec.time(value)).tag(value)
            }
        }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 82)
    }

    private var options: [Int] {
        var values = Array(stride(from: 0, through: 23 * 60 + 30, by: 30))
        if !values.contains(minute) { values.append(minute); values.sort() }
        return values
    }
}

private enum AgendaRange: String, CaseIterable, Identifiable {
    case week = "1 Week"
    case month = "1 Month"
    case all = "All Time"
    var id: Self { self }
}

private enum AgendaPriority: String, CaseIterable, Identifiable {
    case all = "All Priorities"
    case doDie = "Do/Die"
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var id: Self { self }

    func includes(_ task: PlanTask) -> Bool {
        self == .all || task.priority == rawValue
    }
}

private struct FilteredTasksEmptyState: View {
    let showAll: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No tasks match these filters", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("The day is loaded, but the selected task categories are hidden.")
        } actions: {
            Button("Show All Tasks", action: showAll)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }
}

struct AgendaView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: AgendaRange = .month
    @State private var priority: AgendaPriority = .all
    @State private var showingAdd = false
    @AppStorage("agendaShowCompleted") private var showCompleted = false

    private var entries: [AgendaTask] {
        let calendar = WallClock.dhakaCalendar()
        let today = calendar.startOfDay(for: model.now)
        let futureLimit: Date? = switch range {
        case .week: calendar.date(byAdding: .day, value: 7, to: today)
        case .month: calendar.date(byAdding: .month, value: 1, to: today)
        case .all: nil
        }
        let todayEntries = model.tasks.map { AgendaTask(date: today, task: $0) }
        let tomorrowEntries = model.tomorrowTasks.map { AgendaTask(date: model.tomorrowDate, task: $0) }
        let liveIDs = Set((todayEntries + tomorrowEntries).map(\.id))
        return (todayEntries + tomorrowEntries + model.agendaTasks.filter { !liveIDs.contains($0.id) })
            .filter { $0.task.fixedRole == nil && !$0.task.isRoutineBlock }
            .filter { showCompleted || !$0.task.isComplete }
            .filter { priority.includes($0.task) }
            .filter { futureLimit == nil || $0.date < futureLimit! }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                let left = $0.task.hasScheduledTime ? $0.task.startMinute : Int.max
                let right = $1.task.hasScheduledTime ? $1.task.startMinute : Int.max
                return left == right
                    ? $0.task.title.localizedCaseInsensitiveCompare($1.task.title) == .orderedAscending
                    : left < right
            }
    }

    private var grouped: [(Date, [AgendaTask])] {
        let dictionary = Dictionary(grouping: entries) { WallClock.dhakaCalendar().startOfDay(for: $0.date) }
        return dictionary.keys.sorted().map { ($0, dictionary[$0, default: []]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Agenda").font(.largeTitle.bold())
                    Text("Work Overview")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                }
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(AgendaRange.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 260)
                Picker("Priority", selection: $priority) {
                    ForEach(AgendaPriority.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(width: 145)
                Toggle("Show completed", isOn: $showCompleted)
                    .toggleStyle(.checkbox)
                    .fixedSize(horizontal: true, vertical: false)
                Button("Add Task") { showingAdd = true }
                Button {
                    model.toggleAllTasksCollapsed(entries.map(\.task))
                } label: {
                    Label(
                        model.allTasksCollapsed(entries.map(\.task)) ? "Expand All" : "Collapse All",
                        systemImage: model.allTasksCollapsed(entries.map(\.task)) ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
                    )
                }
            }
            .padding()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(grouped, id: \.0) { date, items in
                        AgendaDaySection(date: date, items: items)
                    }
                }
                .padding()
            }
            if !model.agendaValidationIssues.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(model.agendaValidationIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(issue.severity == .error ? .red : .yellow)
                        }
                    }.padding(.horizontal)
                }.frame(height: 38)
            }
        }
        .sheet(isPresented: $showingAdd) { ScheduledTaskSheet(isPresented: $showingAdd) }
    }
}

private struct ScheduledTaskSheet: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    @State private var date = WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var task = PlanTask(
        title: "", startMinute: 540, cycles: 1, mvp: "", coreTasks: [], timeAssigned: false
    )

    private var canSave: Bool {
        !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Task").font(.title2.bold())
            DatePicker(
                "Date", selection: $date,
                in: WallClock.dhakaCalendar().startOfDay(for: model.now)...,
                displayedComponents: .date
            )
            TextField("Task name", text: $task.title).textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Assign a time now", isOn: Binding(
                    get: { task.hasScheduledTime },
                    set: { task.timeAssigned = $0 ? nil : false }
                ))
                if task.hasScheduledTime { TimeEditorField(minute: $task.startMinute) }
                Spacer()
            }
            Text("You can add the time, MVP, and subtasks later when you prepare the day.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add to Agenda") {
                    model.addAgendaTask(task, on: date)
                    isPresented = false
                }.buttonStyle(.borderedProminent).disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 720)
    }
}

private struct AgendaDaySection: View {
    @EnvironmentObject private var model: AppModel
    let date: Date
    let items: [AgendaTask]

    private var heading: String {
        let calendar = WallClock.dhakaCalendar()
        if calendar.isDateInToday(date) { return "Today · \(date.formatted(.dateTime.month(.abbreviated).day()))" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow · \(date.formatted(.dateTime.month(.abbreviated).day()))" }
        return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(heading).font(.title3.bold())
            ForEach(items) { entry in
                AgendaTaskRow(entry: entry)
            }
        }
    }
}

private struct AgendaTaskRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: AgendaTask
    @State private var moveDate = Date()
    @State private var showingMove = false

    private var isLiveToday: Bool {
        WallClock.dhakaCalendar().isDate(entry.date, inSameDayAs: model.now)
            && model.tasks.contains(where: { $0.id == entry.id })
    }

    private var isLiveTomorrow: Bool {
        WallClock.dhakaCalendar().isDate(entry.date, inSameDayAs: model.tomorrowDate)
            && model.tomorrowTasks.contains(where: { $0.id == entry.id })
    }

    private var isScheduledAgenda: Bool { model.agendaTasks.contains(where: { $0.id == entry.id }) }

    private var taskBinding: Binding<PlanTask> {
        Binding(
            get: {
                if isLiveToday { return model.tasks.first(where: { $0.id == entry.id }) ?? entry.task }
                if isLiveTomorrow { return model.tomorrowTasks.first(where: { $0.id == entry.id }) ?? entry.task }
                return model.agendaTasks.first(where: { $0.id == entry.id })?.task ?? entry.task
            },
            set: { updated in
                if isLiveToday, let index = model.tasks.firstIndex(where: { $0.id == entry.id }) {
                    model.tasks[index] = updated
                    model.markPlanDirty()
                    model.scheduleAgendaTodayAutosave()
                } else if isLiveTomorrow, let index = model.tomorrowTasks.firstIndex(where: { $0.id == entry.id }) {
                    model.tomorrowTasks[index] = updated
                    model.markTomorrowDirty()
                    model.scheduleAgendaTomorrowAutosave()
                } else {
                    model.updateAgendaTask(updated)
                }
            }
        )
    }

    private var cycleBinding: Binding<Int> {
        Binding(
            get: { taskBinding.wrappedValue.cycles },
            set: { value in
                var task = taskBinding.wrappedValue
                task.cycles = value
                task.durationMinutes = nil
                taskBinding.wrappedValue = task
            }
        )
    }

    private var colorBinding: Binding<TaskDisplayColor> {
        Binding(
            get: { taskBinding.wrappedValue.displayColor ?? .none },
            set: { value in
                var task = taskBinding.wrappedValue
                task.displayColor = value == .none ? nil : value
                taskBinding.wrappedValue = task
            }
        )
    }

    private var hasTimeBinding: Binding<Bool> {
        Binding(
            get: { taskBinding.wrappedValue.hasScheduledTime },
            set: { value in
                var task = taskBinding.wrappedValue
                task.timeAssigned = value ? nil : false
                taskBinding.wrappedValue = task
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    if isLiveToday {
                        model.toggleTaskCompletion(entry.id)
                    } else if isLiveTomorrow {
                        model.toggleTomorrowTaskCompletion(entry.id)
                    } else {
                        model.toggleAgendaTaskCompletion(entry.id)
                    }
                } label: {
                    Image(systemName: entry.task.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(entry.task.isComplete ? .green : .secondary)
                }.buttonStyle(.plain)
                Text(entry.task.hasScheduledTime
                    ? MarkdownPlanCodec.time(entry.task.startMinute) + "–" + MarkdownPlanCodec.time(entry.task.endMinute)
                    : "No time")
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                Text(entry.task.title).font(.headline)
                Spacer()
                if canReschedule {
                    Button("Reschedule") {
                        moveDate = defaultMoveDate
                        showingMove = true
                    }
                    .buttonStyle(.borderless)
                }
                if canDelete {
                    Button("Delete", role: .destructive) {
                        deleteEntry()
                    }
                    .buttonStyle(.borderless)
                }
                agendaTag(entry.task.priority, color: priorityColor)
                agendaTag(entry.task.difficulty, color: difficultyColor)
                Button { model.toggleCollapsed(entry.id) } label: {
                    Image(systemName: model.collapsedTaskIDs.contains(entry.id) ? "chevron.down" : "chevron.up")
                        .frame(width: 56, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.collapsedTaskIDs.contains(entry.id) ? "Expand task" : "Collapse task")
            }
            if !model.collapsedTaskIDs.contains(entry.id) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Task name", text: taskBinding.title)
                        .textFieldStyle(.roundedBorder)
                    HStack(spacing: 14) {
                        Toggle("Assign time", isOn: hasTimeBinding).toggleStyle(.checkbox)
                        if taskBinding.wrappedValue.hasScheduledTime {
                            TimeEditorField(minute: taskBinding.startMinute).frame(width: 74)
                        }
                        Text("Duration").font(.caption.bold()).foregroundStyle(.secondary)
                        Stepper(
                            "\(taskBinding.wrappedValue.cycles)×",
                            value: cycleBinding,
                            in: 1...(taskBinding.wrappedValue.kind == .contest || taskBinding.wrappedValue.isRoutineBlock ? 10 : 4)
                        ).frame(width: 92)
                        Picker("Kind", selection: taskBinding.kind) {
                            Text("Normal").tag(TaskKind.normal)
                            Text("Contest").tag(TaskKind.contest)
                        }.frame(width: 105)
                        Picker("Priority", selection: taskBinding.priority) {
                            ForEach(["Do/Die", "High", "Medium", "Low"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 120)

                        Picker("Difficulty", selection: taskBinding.difficulty) {
                            ForEach(["Hard", "Moderate", "Easy"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 120)
                        Picker("Color", selection: colorBinding) {
                            ForEach(TaskDisplayColor.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 105)
                        Spacer()
                    }
                    TextField("Optional MVP · add when preparing the task", text: taskBinding.mvp, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Text("SUBTASKS").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Subtask") {
                            var task = taskBinding.wrappedValue
                            task.coreTasks.append(CoreTask(title: ""))
                            taskBinding.wrappedValue = task
                        }.buttonStyle(.borderless)
                    }
                    ForEach(Array(taskBinding.wrappedValue.coreTasks.indices), id: \.self) { index in
                        HStack {
                            Toggle("", isOn: taskBinding.coreTasks[index].isComplete).labelsHidden()
                            TextField("Subtask \(index + 1)", text: taskBinding.coreTasks[index].title)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                var task = taskBinding.wrappedValue
                                task.coreTasks.remove(at: index)
                                taskBinding.wrappedValue = task
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                        }
                    }
                }.padding(.leading, 148)
            }
        }
        .padding(12)
        .background(rowColor.opacity(entry.task.displayColor == nil ? 0.05 : 0.13), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingMove) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reschedule \(entry.task.title)").font(.title2.bold())
                HStack {
                    Button("Today") {
                        moveDate = WallClock.dhakaCalendar().startOfDay(for: model.now)
                    }
                    Button("Tomorrow") {
                        moveDate = WallClock.dhakaCalendar().startOfDay(for: model.tomorrowDate)
                    }
                }
                DatePicker(
                    "Date", selection: $moveDate,
                    in: WallClock.dhakaCalendar().startOfDay(for: model.now)...,
                    displayedComponents: .date
                )
                .datePickerStyle(.field)
                HStack {
                    Spacer()
                    Button("Cancel") { showingMove = false }
                    Button("Reschedule") {
                        let normalized = WallClock.dhakaCalendar().startOfDay(for: moveDate)
                        if isLiveToday {
                            model.rescheduleTask(entry.id, to: normalized)
                        } else {
                            model.moveAgendaTask(entry.id, to: normalized)
                        }
                        showingMove = false
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(WallClock.dhakaCalendar().isDate(moveDate, inSameDayAs: entry.date))
                }
            }.padding(24).frame(width: 420)
        }
    }

    private var canReschedule: Bool {
        !entry.task.isComplete && entry.task.fixedRole == nil && (isLiveToday || isLiveTomorrow || isScheduledAgenda)
    }

    private var canDelete: Bool {
        entry.task.fixedRole == nil && (isLiveToday || isLiveTomorrow || isScheduledAgenda)
    }

    private func deleteEntry() {
        if isLiveToday {
            model.removeTask(id: entry.id)
            model.scheduleAgendaTodayAutosave()
        } else if isLiveTomorrow {
            model.removeTomorrowTask(id: entry.id)
            model.scheduleAgendaTomorrowAutosave()
        } else if isScheduledAgenda {
            model.deleteAgendaTask(entry.id)
        }
    }

    private var defaultMoveDate: Date {
        let calendar = WallClock.dhakaCalendar()
        let today = calendar.startOfDay(for: model.now)
        if calendar.isDate(entry.date, inSameDayAs: today) {
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today
        }
        return today
    }

    private func agendaTag(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.bold()).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.16), in: Capsule())
    }

    private var priorityColor: Color {
        switch entry.task.priority {
        case "Do/Die": .red
        case "High": .orange
        case "Medium": .blue
        default: .secondary
        }
    }

    private var difficultyColor: Color {
        switch entry.task.difficulty {
        case "Hard": .red
        case "Moderate": .purple
        default: .green
        }
    }

    private var rowColor: Color {
        switch entry.task.displayColor ?? .none {
        case .none: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .orange: .orange
        case .yellow: .yellow
        case .purple: .purple
        }
    }
}

private extension TaskDisplayColor {
    var label: String {
        switch self {
        case .none: "No Color"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .purple: "Purple"
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .none: .primary
        case .red: .red
        case .green: .green
        case .blue: .blue
        case .orange: .orange
        case .yellow: .yellow
        case .purple: .purple
        }
    }
}

struct StreaksView: View {
    @EnvironmentObject private var model: AppModel

    private var nonNegotiables: [StreakSummary] {
        model.streakSummaries.filter {
            HabitCatalog.dashboardHabitIDs.contains($0.id)
                && HabitCatalog.entry(for: $0.definition).group == .bad
        }
    }

    private var goodHabits: [StreakSummary] {
        model.streakSummaries.filter {
            HabitCatalog.dashboardHabitIDs.contains($0.id)
                && HabitCatalog.entry(for: $0.definition).group == .good
        }
    }

    private var nonNegotiablePerformance: [HabitPerformance] {
        model.dailyDashboardAnalytics.habits.filter {
            HabitCatalog.entry(for: $0.definition).group == .bad
        }
    }

    private var goodHabitPerformance: [HabitPerformance] {
        model.dailyDashboardAnalytics.habits.filter {
            HabitCatalog.entry(for: $0.definition).group == .good
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Daily Dashboard").font(.title.bold())
                    Text("Weight progress, habit performance, and fast daily tracking.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                WeightProgressDashboard(progress: model.dailyDashboardAnalytics.weight)

                HabitPerformanceDashboard(
                    nonNegotiables: nonNegotiablePerformance,
                    goodHabits: goodHabitPerformance,
                    now: model.now
                )

                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(
                        title: "Daily Context",
                        subtitle: "Changes save immediately and feed your logs and analytics."
                    )
                let inputs = model.dailyFieldDefinitions.filter { $0.kind != .triState && $0.id != "daily-summary" }
                if !inputs.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(inputs) { definition in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 4) {
                                    Text(definition.name).font(.caption.bold())
                                    if let unit = definition.unit { Text("(\(unit))").font(.caption).foregroundStyle(.secondary) }
                                }
                                TextField(
                                    definition.kind == .number ? "0" : "Add context…",
                                    text: Binding(
                                        get: { model.dailyFieldValues[definition.id, default: ""] },
                                        set: { model.setDailyField(definition, value: $0) }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                            }
                                .padding(11)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
                            }
                        }
                    }
                }
                .dashboardSurface()

                DailyMetricHistoryTable(values: model.dailyMetricHistory)

                SectionTitle(
                    title: "Detailed Tracking",
                    subtitle: "Checked means Win. A marked × means Loss; blank days are neutral."
                )
                HabitDatabaseTable(title: "Non-Negotiables", summaries: nonNegotiables, now: model.now)
                HabitDatabaseTable(title: "Good Habits", summaries: goodHabits, now: model.now)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
    }
}

private struct DailyMetricHistoryTable: View {
    let values: [DailyFieldValue]

    private struct Row: Identifiable {
        let date: String
        let weight: String
        let calories: String
        let solved: String
        var id: String { date }
    }

    private var rows: [Row] {
        let grouped = Dictionary(grouping: values, by: \.date)
        return grouped.keys.sorted(by: >).prefix(90).map { date in
            let day = grouped[date, default: []]
            return Row(
                date: date,
                weight: day.first(where: { $0.definitionID == "weight" })?.value ?? "—",
                calories: day.first(where: { $0.definitionID == "calories" })?.value ?? "—",
                solved: day.first(where: { $0.definitionID == "solved-problems" })?.value ?? "—"
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(
                title: "Daily History",
                subtitle: "Previous weight, calorie, and solved-problem entries."
            )
            if rows.isEmpty {
                Text("No metric history yet.").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                    GridRow {
                        header("Date")
                        header("Weight")
                        header("Calories")
                        header("Solved")
                    }
                    Divider().gridCellColumns(4)
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.date).monospacedDigit()
                            Text(row.weight)
                            Text(row.calories)
                            Text(row.solved)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .dashboardSurface()
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
    }
}

private struct SectionTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct WeightProgressDashboard: View {
    let progress: WeightProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                title: "Weight Progress",
                subtitle: "Recent measurements determine the ETA; the goal is fixed at 75 kg."
            )
            HStack(spacing: 0) {
                metric("Current", value: weightText(progress.currentWeight), emphasis: true)
                Divider().frame(height: 42)
                metric("Goal", value: "75.0 kg")
                Divider().frame(height: 42)
                metric("Remaining", value: weightText(progress.remaining))
                Divider().frame(height: 42)
                metric("ETA", value: progress.etaDays.map { "\($0) days" } ?? "Not enough data")
            }
            ProgressView(value: progress.progress)
                .tint(Color.accentColor)
            HStack {
                Text(progress.startingWeight.map { "Started at \(weightText($0))" } ?? "Add weight measurements to begin")
                Spacer()
                Text("Goal 75 kg")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .dashboardSurface()
    }

    private func metric(_ label: String, value: String, emphasis: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value)
                .font(emphasis ? .title3.bold() : .headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
    }

    private func weightText(_ value: Double?) -> String {
        value.map { String(format: "%.1f kg", $0) } ?? "—"
    }
}

private struct HabitPerformanceDashboard: View {
    let nonNegotiables: [HabitPerformance]
    let goodHabits: [HabitPerformance]
    let now: Date
    @State private var expandedHistory: Set<String> = []

    private var monthLabel: String {
        let formatter = DateFormatter()
        formatter.calendar = WallClock.dhakaCalendar()
        formatter.timeZone = WallClock.dhakaCalendar().timeZone
        formatter.dateFormat = "MMM"
        return formatter.string(from: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(
                title: "Habit Performance",
                subtitle: "Daily Result → Month Δ → Total Δ → Stage"
            )
            HabitSummarySection(
                title: "Non-Negotiables", habits: nonNegotiables,
                monthLabel: monthLabel, expandedHistory: $expandedHistory
            )
            Divider()
            HabitSummarySection(
                title: "Good Habits", habits: goodHabits,
                monthLabel: monthLabel, expandedHistory: $expandedHistory
            )
        }
        .dashboardSurface()
    }
}

private struct HabitSummarySection: View {
    let title: String
    let habits: [HabitPerformance]
    let monthLabel: String
    @Binding var expandedHistory: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.headline).padding(.bottom, 8)
            HStack(spacing: 12) {
                Text("HABIT").frame(maxWidth: .infinity, alignment: .leading)
                Text("STAGE").frame(width: 150, alignment: .leading)
                Text("TOTAL Δ").frame(width: 72, alignment: .trailing)
                Text(monthLabel.uppercased()).frame(width: 58, alignment: .trailing)
                Color.clear.frame(width: 24)
            }
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)

            ForEach(habits) { habit in
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        if expandedHistory.contains(habit.id) { expandedHistory.remove(habit.id) }
                        else { expandedHistory.insert(habit.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Text(displayName(habit.definition))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            StageBadge(stage: habit.stage).frame(width: 150, alignment: .leading)
                            DeltaText(value: habit.totalDelta).frame(width: 72, alignment: .trailing)
                            DeltaText(value: habit.currentMonthDelta).frame(width: 58, alignment: .trailing)
                            Image(systemName: expandedHistory.contains(habit.id) ? "chevron.up" : "chevron.down")
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if expandedHistory.contains(habit.id) {
                        HStack(spacing: 7) {
                            Text("Monthly history").font(.caption).foregroundStyle(.secondary)
                            ForEach(habit.monthlyHistory) { month in
                                HStack(spacing: 4) {
                                    Text(month.label)
                                    DeltaText(value: month.delta, compact: true)
                                }
                                .font(.caption2)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(Color.primary.opacity(0.05), in: Capsule())
                            }
                            Spacer()
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
        }
    }

    private func displayName(_ definition: StreakDefinition) -> String {
        let name = HabitCatalog.entry(for: definition).name
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }
}

private struct StageBadge: View {
    let stage: HabitStage

    var body: some View {
        Text("\(stage.symbol) \(stage.title)")
            .font(.caption.bold())
            .foregroundStyle(stageColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(stageColor.opacity(0.12), in: Capsule())
    }

    private var stageColor: Color {
        switch stage {
        case .started: .secondary
        case .awakening: .purple
        case .breakthrough: .pink
        case .ascension: .blue
        case .mastery: Color(red: 0.66, green: 0.49, blue: 0.08)
        case .perfection: .orange
        case .transcendence: .red
        }
    }
}

private struct DeltaText: View {
    let value: Int
    var compact = false

    var body: some View {
        Text(value > 0 ? "+\(value)" : "\(value)")
            .font(compact ? .caption2.bold() : .subheadline.bold())
            .monospacedDigit()
            .foregroundStyle(value > 0 ? Color.green : value < 0 ? Color.red : Color.secondary)
    }
}

private extension View {
    func dashboardSurface() -> some View {
        self
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.08)))
            .shadow(color: Color.black.opacity(0.035), radius: 10, y: 4)
    }
}

private struct HabitDatabaseTable: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let summaries: [StreakSummary]
    let now: Date

    private var days: [Int] {
        let calendar = WallClock.dhakaCalendar()
        return Array(Array(1...max(1, calendar.component(.day, from: now))).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2.bold())
                Spacer()
                Text("blank → win → loss")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if summaries.isEmpty {
                ContentUnavailableView("No habits", systemImage: "tablecells")
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                ScrollView(.horizontal) {
                    Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                        GridRow {
                            tableHeader("Date", width: 110, alignment: .leading)
                            ForEach(summaries) { summary in
                                VStack(spacing: 2) {
                                    Text(displayName(summary.definition))
                                        .font(.caption.bold())
                                        .lineLimit(2)
                                    Text("Checked = Win")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 150, height: 48)
                                .padding(.horizontal, 6)
                                .background(Color.secondary.opacity(0.08))
                            }
                        }
                        ForEach(days, id: \.self) { day in
                            GridRow {
                                Text(dayLabel(day))
                                    .font(.caption.bold())
                                    .frame(width: 110, height: 38, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .background(Color.secondary.opacity(0.045))
                                ForEach(summaries) { summary in
                                    statusButton(summary, day: day)
                                }
                            }
                        }
                    }
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.10)))
                }
            }
        }
        .dashboardSurface()
    }

    private func tableHeader(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text).font(.caption.bold())
            .frame(width: width, height: 48, alignment: alignment)
            .padding(.horizontal, 8)
            .background(Color.secondary.opacity(0.08))
    }

    private func statusButton(_ summary: StreakSummary, day: Int) -> some View {
        let status = summary.statuses[day] ?? .blank
        return Button {
            model.toggleStreak(summary, day: day)
        } label: {
            Image(systemName: statusSymbol(status))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(streakColor(status))
                .frame(width: 150, height: 38)
                .background(Color.primary.opacity(status == .blank ? 0.025 : 0.045))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(displayName(summary.definition)) · \(dayLabel(day)): blank → Win → Loss → blank")
    }

    private func dayLabel(_ day: Int) -> String {
        var parts = WallClock.dhakaCalendar().dateComponents([.year, .month], from: now)
        parts.day = day
        let date = WallClock.dhakaCalendar().date(from: parts) ?? now
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func statusSymbol(_ status: StreakStatus) -> String {
        switch status {
        case .blank: "square"
        case .win: "checkmark.square.fill"
        case .fail: "xmark.square.fill"
        }
    }

    private func streakColor(_ status: StreakStatus) -> Color {
        switch status {
        case .blank: Color.secondary.opacity(0.12)
        case .win: Color.green
        case .fail: Color.red
        }
    }

    private func displayName(_ definition: StreakDefinition) -> String {
        let name = HabitCatalog.entry(for: definition).name
        guard let first = name.first else { return name }
        return first.uppercased() + name.dropFirst()
    }

}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Vault") {
                LabeledContent("Location", value: model.vaultURL?.path ?? "Not selected")
                Button("Choose Vault…") { model.chooseVault() }
            }
            Section("Startup") {
                Toggle("Launch ReFocus when I log in", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLaunchAtLogin() }
                ))
            }
            Section("Cloud sync") {
                LabeledContent("Status", value: model.cloudSyncStatus)
                if model.cloudSyncPendingCount > 0 {
                    LabeledContent("Pending uploads", value: String(model.cloudSyncPendingCount))
                }
                if let lastSuccess = model.cloudSyncLastSuccess {
                    LabeledContent("Last synced", value: lastSuccess.formatted(date: .omitted, time: .standard))
                }
                HStack {
                    SecureField("Paste Mac pairing token", text: $model.cloudPairingToken)
                    Button("Paste") { model.pasteCloudPairingToken() }
                }
                HStack {
                    Button(model.isConnectingCloud ? "Connecting…" : "Connect") { model.saveCloudPairingToken() }
                        .disabled(
                            model.cloudPairingToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || model.isConnectingCloud
                        )
                    if model.cloudSyncPaired {
                        Button("Disconnect") { model.disconnectCloudSync() }
                    }
                    Link("Open ReFocus Web", destination: CloudSyncClient.baseURL)
                }
                if let message = model.cloudConnectionMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(model.cloudSyncPaired ? .green : .secondary)
                }
                if let issue = model.cloudSyncIssue {
                    Text(issue).font(.caption).foregroundStyle(.orange)
                }
                Text("Generate a Mac pairing token from the Connections section on the web app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Timer") {
                Text("Focus: :00–:25 and :30–:55")
                Text("Screen break: :25–:30 and :55–:00")
                Text("Screen breaks stay active around the clock while ReFocus is running.")
                Text("Timezone: Asia/Dhaka")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .padding()
    }
}

struct BreakOverlayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.055).ignoresSafeArea()
            VStack(spacing: 20) {
                BreakClockHeader(model: model, clock: model.clockDisplay)
                HStack(spacing: 0) {
                    CheckInPanel()
                    Divider().overlay(Color.white.opacity(0.2))
                    TodayPlanPanel()
                }
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 36)
            .padding(.top, 92)
        }
        .foregroundStyle(.white)
    }
}

private struct BreakClockHeader: View {
    @ObservedObject var model: AppModel
    @ObservedObject var clock: ClockDisplay

    var body: some View {
        VStack(spacing: 4) {
            Text("SCREEN BREAK").font(.caption.bold()).tracking(3).foregroundStyle(.orange)
            Text(model.countdownText).font(.system(size: 64, weight: .bold, design: .rounded)).monospacedDigit()
            Text(model.currentTaskTitle).font(.title2.bold())
        }
    }
}

struct PlanningGateOverlayView: View {
    @EnvironmentObject private var model: AppModel
    let isPrimary: Bool

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.04, blue: 0.055).ignoresSafeArea()
            if isPrimary {
                VStack(spacing: 14) {
                    VStack(spacing: 12) {
                        Text("PLAN REQUIRED")
                            .font(.system(size: 18, weight: .heavy, design: .rounded))
                            .tracking(4)
                            .foregroundStyle(.orange)
                        Text("Set the next work block before focus begins")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text(model.planGateMessage)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    DashboardView()
                        .environmentObject(model)
                        .background(Color(red: 0.075, green: 0.08, blue: 0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.white.opacity(0.16)))
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 28)
                .padding(.top, 38)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checklist")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("Plan required").font(.largeTitle.bold())
                    Text("Complete and save Today on the main display.")
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }
        }
    }
}

private struct CheckInPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Focus log").font(.title2.bold())
            checkInField("What did you do?", text: binding(\.whatDid))
            checkInField("What could you do better?", text: binding(\.better))
            checkInField("What could you do faster?", text: binding(\.faster))
            Spacer()
            Text("Only the first answer is required. Everything autosaves to today’s Markdown log.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func checkInField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func binding(_ keyPath: WritableKeyPath<CheckIn, String>) -> Binding<String> {
        Binding(
            get: { model.currentCheckIn?[keyPath: keyPath] ?? "" },
            set: { value in
                guard model.currentCheckIn != nil else { return }
                model.currentCheckIn?[keyPath: keyPath] = value
                model.scheduleCheckInSave()
            }
        )
    }
}

private struct TodayPlanPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var isEditing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Today").font(.title2.bold())
                    Spacer()
                    if isEditing {
                        Button("Cancel") {
                            model.cancelEditingPlan()
                            isEditing = false
                        }
                        Button("Add Task") { model.addTask() }
                        Button(model.isSavingPlan ? "Saving…" : "Save Changes") { model.savePlan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.isPlanReady || model.isSavingPlan || !model.planIsDirty)
                    } else {
                        Button("Edit Today") {
                            model.beginEditingPlan()
                            isEditing = true
                        }
                    }
                    Button {
                        model.toggleAllTasksCollapsed(isEditing ? model.tasks : model.executionTasks)
                    } label: {
                        let visibleTasks = isEditing ? model.tasks : model.executionTasks
                        Image(systemName: model.allTasksCollapsed(visibleTasks) ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                            .frame(width: 34, height: 32)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    if !isEditing {
                        Toggle("Show completed", isOn: $model.showCompletedSubtasks)
                            .toggleStyle(.checkbox).font(.caption)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(model.executionCycleSummaryText).foregroundStyle(.secondary)
                    }
                }
                if isEditing && !model.validationIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.validationIssues.enumerated()), id: \.offset) { _, issue in
                            Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(model.isBlocking(issue) ? .red : .yellow)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (model.validationIssues.contains(where: model.isBlocking) ? Color.red : Color.yellow).opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                if model.executionTasks.isEmpty {
                    Text("Today has not been planned.").font(.headline)
                    Text("Work is locked. Complete and save a valid \(model.requiredCycleMinimum)-cycle Today plan first.")
                        .foregroundStyle(.secondary)
                } else if isEditing {
                    ForEach(Array(model.tasks.enumerated()), id: \.element.id) { index, task in
                        TaskEditorRow(
                            task: $model.tasks[index],
                            cyclesChanged: { model.normalizeCoreTasks(for: task.id) },
                            delete: { model.removeTask(id: task.id) },
                            addSubtask: { model.addSubtask(to: task.id) },
                            removeSubtask: { model.removeSubtask(taskID: task.id, subtaskID: $0) },
                            saveTemplate: { model.saveTaskAsTemplate(task) }
                        )
                        .id(task.id)
                        .onChange(of: task) { model.markPlanDirty() }
                        .padding(.horizontal, 14)
                        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    ForEach(model.executionTasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center) {
                                Button { model.toggleTaskCompletion(task.id) } label: {
                                    Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.plain)
                                Text(task.title).font(.headline)
                                Spacer()
                                Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Button { model.toggleCollapsed(task.id) } label: {
                                    Image(systemName: model.collapsedTaskIDs.contains(task.id) ? "chevron.down" : "chevron.up")
                                        .frame(width: 56, height: 44)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if !model.collapsedTaskIDs.contains(task.id) {
                                Text("MVP → \(task.mvp)").font(.subheadline)
                                ForEach(Array(task.coreTasks.enumerated()), id: \.element.id) { index, core in
                                    if model.showCompletedSubtasks || !core.isComplete {
                                        HStack {
                                            Button { model.toggleSubtaskCompletion(taskID: task.id, subtaskID: core.id) } label: {
                                                Image(systemName: core.isComplete ? "checkmark.square.fill" : "square")
                                            }.buttonStyle(.plain)
                                            Text("\(index + 1). \(core.title)")
                                        }
                                        .font(.caption)
                                        .foregroundStyle(core.isComplete ? .green : .secondary)
                                        .padding(.leading, 28)
                                    }
                                }
                            }
                        }
                        .padding()
                        .background(task.id == model.executionTask?.id ? Color.orange.opacity(0.2) : Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: model.planIsDirty) { _, dirty in
            if !dirty { isEditing = false }
        }
    }
}
