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
                Text("Today").tag(DashboardTab.today)
                Text("Streaks").tag(DashboardTab.streaks)
                Text("Settings").tag(DashboardTab.settings)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Group {
                switch selectedTab {
                case .today: PlanEditorView()
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
    case today
    case streaks
    case settings
}

struct PlanEditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Today").font(.largeTitle.bold())
                    Text("\(profileName) · \(model.cycleSummaryText)")
                        .foregroundStyle(.secondary)
                    if !model.isPlanReady {
                        Text("Planning gate locked")
                            .font(.caption.bold())
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                if model.isEditingPlan {
                    if model.planMessage == "Today is planned." {
                        Button("Cancel") { model.cancelEditingPlan() }
                    }
                    Button("Add Task") { model.addTask() }
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
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.tasks.enumerated()), id: \.element.id) { index, task in
                            TaskEditorRow(task: $model.tasks[index], cyclesChanged: {
                                model.normalizeCoreTasks(for: task.id)
                            }, delete: {
                                model.removeTask(id: task.id)
                            }, moveUp: {
                                model.moveTask(id: task.id, by: -1)
                            }, moveDown: {
                                model.moveTask(id: task.id, by: 1)
                            }, canMoveUp: index > 0, canMoveDown: index < model.tasks.count - 1)
                            .id(task.id)
                            .onChange(of: task) { model.markPlanDirty() }
                            Divider()
                        }
                    }
                    .padding(.horizontal)
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
                                .foregroundStyle(.orange)
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
}

private struct TaskEditorRow: View {
    @Binding var task: PlanTask
    var cyclesChanged: () -> Void
    var delete: () -> Void
    var moveUp: () -> Void
    var moveDown: () -> Void
    var canMoveUp: Bool
    var canMoveDown: Bool

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
                .help("Delete task")
                VStack(spacing: 2) {
                    Button(action: moveUp) { Image(systemName: "chevron.up") }
                        .disabled(!canMoveUp)
                    Button(action: moveDown) { Image(systemName: "chevron.down") }
                        .disabled(!canMoveDown)
                }
                .buttonStyle(.borderless)
                .help("Reorder task")
            }

            HStack(alignment: .bottom, spacing: 14) {
                editorField("Start") {
                    TimeEditorField(minute: $task.startMinute)
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
                }
                editorField("Duration") {
                    Stepper(
                        "\(task.cycles) cycle\(task.cycles == 1 ? "" : "s")",
                        value: $task.cycles,
                        in: task.kind == .normal ? 1...4 : 1...10
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

            if task.cycles > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CORE TASKS · exactly three")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    ForEach(Array(task.coreTasks.indices), id: \.self) { index in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $task.coreTasks[index].isComplete).labelsHidden()
                            Text("\(index + 1).").foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                            TextField("Name core task \(index + 1)", text: $task.coreTasks[index].title)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 12)
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
    let task: PlanTask
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isComplete ? .green : .secondary)
                Text(task.title).font(.headline)
                tag(task.priority, color: priorityColor)
                tag(task.difficulty, color: difficultyColor)
                Spacer()
                Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text("MVP → \(task.mvp)")
                .font(.subheadline)
            ForEach(Array(task.coreTasks.enumerated()), id: \.element.id) { index, core in
                HStack(spacing: 8) {
                    Image(systemName: core.isComplete ? "checkmark.square.fill" : "square")
                    Text("\(index + 1). \(core.title)")
                }
                .font(.caption)
                .foregroundStyle(core.isComplete ? .green : .secondary)
                .padding(.leading, 28)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Color.orange.opacity(0.20) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isCurrent ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)))
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
                            Text(summary.definition.name).font(.headline)
                            Spacer()
                            Text("Current \(summary.current) · Best \(summary.longest)").foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                            ForEach(1...daysInMonth, id: \.self) { day in
                                Button {
                                    model.toggleStreak(summary, day: day)
                                } label: {
                                    Text("\(day)")
                                        .font(.caption2)
                                        .frame(maxWidth: .infinity, minHeight: 24)
                                        .foregroundStyle(summary.completedDays.contains(day) ? .white : .primary)
                                        .background(summary.completedDays.contains(day) ? Color.green : Color.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help(summary.completedDays.contains(day) ? "Clear day \(day)" : "Mark day \(day) complete")
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
                        Text("Finish Today before work begins")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                        Text("Build and save a valid \(model.requiredCycleMinimum)-cycle plan. This gate stays open until the plan is saved.")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Today").font(.title2.bold())
                    Spacer()
                    Text(model.executionCycleSummaryText).foregroundStyle(.secondary)
                }
                if model.executionTasks.isEmpty {
                    Text("Today has not been planned.").font(.headline)
                    Text("Work is locked. Complete and save a valid \(model.requiredCycleMinimum)-cycle Today plan first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.executionTasks) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: task.isComplete ? "checkmark.circle.fill" : "circle")
                                Text(task.title).font(.headline)
                                Spacer()
                                Text(MarkdownPlanCodec.time(task.startMinute) + "–" + MarkdownPlanCodec.time(task.endMinute))
                                    .monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text("MVP → \(task.mvp)").font(.subheadline)
                            ForEach(Array(task.coreTasks.enumerated()), id: \.element.id) { index, core in
                                Text("\(index + 1). \(core.title)")
                                    .font(.caption)
                                    .foregroundStyle(core.isComplete ? .green : .secondary)
                                    .padding(.leading, 28)
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
    }
}
