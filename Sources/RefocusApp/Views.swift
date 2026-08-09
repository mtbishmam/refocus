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
                Text("Settings").tag(DashboardTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 480)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Group {
                switch selectedTab {
                case .agenda: AgendaView()
                case .today: PlanEditorView()
                case .tomorrow: TomorrowPlanView()
                case .streaks: StreaksView()
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
    case settings
}

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
                        TimeEditorField(minute: $task.startMinute).disabled(task.fixedRole != nil)
                    } else {
                        HStack {
                            Toggle("Scheduled", isOn: Binding(
                                get: { task.hasScheduledTime },
                                set: { task.timeAssigned = $0 ? nil : false }
                            )).toggleStyle(.checkbox)
                            if task.hasScheduledTime { TimeEditorField(minute: $task.startMinute) }
                        }
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

              editorField("MVP · completion definition") {
                TextField("Describe exactly what must be true for this task to count as complete", text: $task.mvp, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
              }

              if !task.isRoutineBlock {
              VStack(alignment: .leading, spacing: 8) {
                    HStack {
                    Text("SUBTASKS · at least three")
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
                            .disabled(task.coreTasks.count <= 3)
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
        .padding(16)
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
    @State private var text: String
    @FocusState private var isFocused: Bool

    init(minute: Binding<Int>) {
        _minute = minute
        _text = State(initialValue: MarkdownPlanCodec.time(minute.wrappedValue))
    }

    var body: some View {
        TextField("HH:mm", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 82)
            .focused($isFocused)
            .onSubmit(commit)
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onChange(of: minute) { _, newValue in
                if !isFocused { text = MarkdownPlanCodec.time(newValue) }
            }
    }

    private func commit() {
        if let value = MarkdownPlanCodec.minute(text) {
            minute = value
            text = MarkdownPlanCodec.time(value)
        } else {
            text = MarkdownPlanCodec.time(minute)
        }
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

    private var badHabits: [StreakSummary] {
        model.streakSummaries.filter { HabitCatalog.entry(for: $0.definition).group == .bad }
    }

    private var goodHabits: [StreakSummary] {
        model.streakSummaries.filter { HabitCatalog.entry(for: $0.definition).group == .good }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                Text("Daily Context").font(.largeTitle.bold())
                Text("Fast structured inputs for your logs and AI context. Changes save immediately.")
                    .foregroundStyle(.secondary)
                let inputs = model.dailyFieldDefinitions.filter { $0.kind != .triState && $0.id != "daily-summary" }
                if !inputs.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
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
                            .padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                HabitDatabaseTable(title: "Bad Habits", summaries: badHabits, now: model.now)
                HabitDatabaseTable(title: "Good Habits", summaries: goodHabits, now: model.now)
            }
            .padding()
        }
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
                Text("blank → win → fail")
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
                                    Text(habitLevel(summary.definition))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
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
                        GridRow {
                            Text("Stats")
                                .font(.caption.bold())
                                .frame(width: 110, height: 38, alignment: .leading)
                                .padding(.horizontal, 8)
                                .background(Color.secondary.opacity(0.08))
                            ForEach(summaries) { summary in
                                Text("Current \(summary.current) · Max \(summary.longest)")
                                    .font(.caption2)
                                    .frame(width: 150, height: 38)
                                    .background(Color.secondary.opacity(0.08))
                                    .help("Wins \(summary.totalWins) · Fails \(summary.totalFails)")
                            }
                        }
                    }
                    .overlay(Rectangle().stroke(Color.primary.opacity(0.10)))
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.38), in: RoundedRectangle(cornerRadius: 12))
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
                .foregroundStyle(status == .blank ? Color.secondary : Color.white)
                .frame(width: 150, height: 38)
                .background(streakColor(status).opacity(status == .blank ? 0.6 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(displayName(summary.definition)) · \(dayLabel(day)): blank → win → fail → blank")
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

    private func habitLevel(_ definition: StreakDefinition) -> String {
        HabitCatalog.entry(for: definition).level
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
                    if !model.validationIssues.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.validationIssues.enumerated()), id: \.offset) { _, issue in
                                Label(issue.description, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(model.isBlocking(issue) ? .red : .yellow)
                            }
                        }
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
