import AppKit
import SwiftUI
import RefocusCore

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MenuClockStatus(model: model, clock: model.clockDisplay)
            Text(model.planMessage).font(.caption).foregroundStyle(.secondary)
            QuickNoteBar(compact: true)
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
                Text("Streaks").tag(DashboardTab.streaks)
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

            QuickNoteBar()
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
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

private struct QuickNoteBar: View {
    @EnvironmentObject private var model: AppModel
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            if !compact {
                Label("Quick note", systemImage: "square.and.pencil")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }
            TextField("Append one line to dump.md", text: $model.quickNote)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.submitQuickNote() }
            Button {
                model.submitQuickNote()
            } label: {
                Image(systemName: model.isSavingQuickNote ? "ellipsis" : "arrow.down.doc")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.quickNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSavingQuickNote)
            .help("Append to dump.md")
        }
    }
}

struct PlanEditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Today").font(.largeTitle.bold())
                    HStack(spacing: 7) {
                        headerTag(profileName, color: .secondary)
                        headerTag(model.activeSegment.title, color: .blue)
                        headerTag("\(model.plannedCycles) / \(model.requiredCycleMinimum) cycles", color: model.isPlanReady ? .green : .orange)
                    }
                    if !model.isPlanReady {
                        Text("Planning gate locked")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button {
                    model.toggleAllTasksCollapsed(model.tasks)
                } label: {
                    Label(
                        model.allTasksCollapsed(model.tasks) ? "Expand All" : "Collapse All",
                        systemImage: model.allTasksCollapsed(model.tasks) ? "rectangle.expand.vertical" : "rectangle.compress.vertical"
                    )
                }
                .buttonStyle(.borderless)
                Toggle("Show completed subtasks", isOn: $model.showCompletedSubtasks)
                    .toggleStyle(.checkbox)
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
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(Array(model.tasks.enumerated()), id: \.element.id) { index, task in
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
                            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.09)))
                        }
                    }
                    .padding()
                }
            } else {
                SavedPlanView()
            }

            if model.isEditingPlan && !model.validationIssues.isEmpty {
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
                    ForEach(Array(model.tomorrowTasks.enumerated()), id: \.element.id) { index, task in
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
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
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
            HStack(alignment: .bottom, spacing: 12) {
                Toggle("", isOn: $task.isComplete).labelsHidden()
                editorField("Task name") {
                    TextField("Rename this task", text: $task.title)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .disabled(task.fixedRole != nil)
                }
                .frame(minWidth: 260)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("TIME BLOCK").font(.caption2.bold()).foregroundStyle(.secondary)
                    Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                        .monospacedDigit()
                }
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(task.fixedRole != nil)
                .help("Delete task")
                Button { model.toggleCollapsed(task.id) } label: {
                    Image(systemName: model.collapsedTaskIDs.contains(task.id) ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.borderless)
            }

            if !model.collapsedTaskIDs.contains(task.id) {
              HStack(alignment: .bottom, spacing: 14) {
                editorField("Start") {
                    TimeEditorField(minute: $task.startMinute)
                        .disabled(task.fixedRole != nil)
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
                    .onChange(of: task.cycles) { cyclesChanged() }
                    .frame(width: 145)
                }
              }

              editorField("MVP · completion definition") {
                TextField("Describe exactly what must be true for this task to count as complete", text: $task.mvp, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
              }

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
        .padding(.vertical, 12)
    }

    private var durationRange: ClosedRange<Int> {
        switch task.fixedRole {
        case .planTomorrow: 1...2
        case .dayAnalysis, .revision: 1...1
        case nil: task.kind == .normal ? 1...4 : 1...10
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

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.tasks) { task in
                    SavedTaskCard(task: task, isCurrent: task.id == model.executionTask?.id)
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
            HStack(alignment: .firstTextBaseline) {
                Button { model.toggleTaskCompletion(task.id) } label: {
                    Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(task.isComplete ? .green : .secondary)
                }.buttonStyle(.plain)
                Text(task.title).font(.headline)
                tag(task.priority, color: priorityColor)
                tag(task.difficulty, color: difficultyColor)
                Spacer()
                Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button { model.toggleCollapsed(task.id) } label: {
                    Image(systemName: model.collapsedTaskIDs.contains(task.id) ? "chevron.down" : "chevron.up")
                }.buttonStyle(.plain)
            }
            if !model.collapsedTaskIDs.contains(task.id) {
              Text("MVP → \(task.mvp)")
                .font(.subheadline)
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
              if !task.isComplete && task.fixedRole == nil {
                Button("Reschedule…") {
                    rescheduleDate = WallClock.dhakaCalendar().date(byAdding: .day, value: 1, to: model.now) ?? model.now
                    showingReschedule = true
                }
                .buttonStyle(.borderless)
              }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.orange.opacity(0.20) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCurrent ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)))
        .sheet(isPresented: $showingReschedule) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reschedule \(task.title)").font(.title2.bold())
                DatePicker("Future date", selection: $rescheduleDate, in: model.now..., displayedComponents: .date)
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

struct AgendaView: View {
    @EnvironmentObject private var model: AppModel
    @State private var range: AgendaRange = .month
    @State private var priority: AgendaPriority = .all
    @State private var showingAdd = false

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
            .filter { $0.task.fixedRole == nil }
            .filter { priority.includes($0.task) }
            .filter { futureLimit == nil || $0.date < futureLimit! }
            .sorted {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.task.startMinute < $1.task.startMinute
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
                    Text("Today and scheduled work").foregroundStyle(.secondary)
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
                Button("Add Scheduled Task") { showingAdd = true }
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
        title: "", startMinute: 1080, cycles: 1, mvp: "", coreTasks: []
    )

    private var canSave: Bool {
        !task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Scheduled Task").font(.title2.bold())
            DatePicker("Date", selection: $date, in: model.now..., displayedComponents: .date)
            TextField("Task name", text: $task.title).textFieldStyle(.roundedBorder)
            HStack {
                TimeEditorField(minute: $task.startMinute)
                Picker("Priority", selection: $task.priority) {
                    ForEach(["Do/Die", "High", "Medium", "Low"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Difficulty", selection: $task.difficulty) {
                    ForEach(["Hard", "Moderate", "Easy"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Kind", selection: $task.kind) {
                    Text("Normal").tag(TaskKind.normal)
                    Text("Contest").tag(TaskKind.contest)
                }
                Stepper("\(task.cycles) cycle\(task.cycles == 1 ? "" : "s")", value: $task.cycles, in: task.kind == .normal ? 1...4 : 1...10)
            }
            TextField("MVP · completion definition", text: $task.mvp, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)
            HStack {
                Text("OPTIONAL SUBTASKS").font(.caption.bold()).foregroundStyle(.secondary)
                Spacer()
                Button("Add Subtask") { task.coreTasks.append(CoreTask(title: "")) }
            }
            ForEach(Array(task.coreTasks.indices), id: \.self) { index in
                HStack {
                    Text("\(index + 1).").foregroundStyle(.secondary)
                    TextField("Subtask", text: $task.coreTasks[index].title).textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { task.coreTasks.remove(at: index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
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
                Text(MarkdownPlanCodec.time(entry.task.startMinute) + "–" + MarkdownPlanCodec.time(entry.task.endMinute))
                    .monospacedDigit().foregroundStyle(.secondary).frame(width: 112, alignment: .leading)
                Text(entry.task.title).font(.headline)
                Spacer()
                agendaTag(entry.task.priority, color: priorityColor)
                agendaTag(entry.task.difficulty, color: difficultyColor)
                if !entry.task.isComplete && entry.task.fixedRole == nil && (isLiveToday || isScheduledAgenda) {
                    Button("Reschedule") {
                        moveDate = entry.date
                        showingMove = true
                    }.buttonStyle(.borderless)
                }
                if isScheduledAgenda && !isLiveTomorrow {
                    Button(role: .destructive) {
                        model.deleteAgendaTask(entry.id)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete from Agenda")
                }
                Button { model.toggleCollapsed(entry.id) } label: {
                    Image(systemName: model.collapsedTaskIDs.contains(entry.id) ? "chevron.down" : "chevron.up")
                        .frame(width: 38, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.collapsedTaskIDs.contains(entry.id) ? "Expand task" : "Collapse task")
            }
            if !model.collapsedTaskIDs.contains(entry.id) {
                VStack(alignment: .leading, spacing: 8) {
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
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .sheet(isPresented: $showingMove) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Reschedule \(entry.task.title)").font(.title2.bold())
                DatePicker("Future date", selection: $moveDate, in: model.now..., displayedComponents: .date)
                HStack {
                    Spacer()
                    Button("Cancel") { showingMove = false }
                    Button("Reschedule") {
                        if isLiveToday {
                            model.rescheduleTask(entry.id, to: moveDate)
                        } else {
                            model.moveAgendaTask(entry.id, to: moveDate)
                        }
                        showingMove = false
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 420)
        }
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
}

struct StreaksView: View {
    @EnvironmentObject private var model: AppModel

    private var daysInMonth: Int {
        WallClock.dhakaCalendar().range(of: .day, in: .month, for: model.now)?.count ?? 31
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("Streaks").font(.largeTitle.bold())
                ForEach(model.streakSummaries) { summary in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(displayName(summary.definition.name)).font(.headline)
                            Spacer()
                            Text("Current \(summary.current) · Max \(summary.longest) · Wins \(summary.totalWins) / Fails \(summary.totalFails)")
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                            ForEach(1...daysInMonth, id: \.self) { day in
                                Button {
                                    model.toggleStreak(summary, day: day)
                                } label: {
                                    let status = summary.statuses[day] ?? .blank
                                    Text("\(day)")
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                        .foregroundStyle(status == .blank ? Color.primary : Color.white)
                                        .background(streakColor(status))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help("Day \(day): blank → win → fail → blank")
                            }
                        }
                    }
                    .padding()
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding()
        }
    }

    private func streakColor(_ status: StreakStatus) -> Color {
        switch status {
        case .blank: Color.secondary.opacity(0.12)
        case .win: Color.green
        case .fail: Color.red
        }
    }

    private func displayName(_ name: String) -> String {
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
            Section("Timer") {
                Text("Focus: :00–:25 and :30–:55")
                Text("Screen break: :25–:30 and :55–:00")
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
                            .font(.caption.bold())
                            .tracking(3)
                            .foregroundStyle(.orange)
                        Text("Set the next work block before focus begins")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text("Save a valid \(model.activeSegment.title.lowercased()) with \(model.requiredCycleMinimum) available work cycles.")
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
                .padding(.top, 72)
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
            QuickNoteBar()
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
                        Toggle("Completed subtasks", isOn: $model.showCompletedSubtasks)
                            .toggleStyle(.checkbox).font(.caption)
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
                            HStack(alignment: .firstTextBaseline) {
                                Button { model.toggleTaskCompletion(task.id) } label: {
                                    Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                                }.buttonStyle(.plain)
                                Text(task.title).font(.headline)
                                Spacer()
                                Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Button { model.toggleCollapsed(task.id) } label: {
                                    Image(systemName: model.collapsedTaskIDs.contains(task.id) ? "chevron.down" : "chevron.up")
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
