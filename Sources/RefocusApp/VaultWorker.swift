import Foundation
import RefocusCore

actor VaultWorker {
    private let repository: VaultRepository

    init(vaultURL: URL) {
        repository = VaultRepository(vaultURL: vaultURL)
    }

    func loadToday(date: Date) throws -> TodayPlan {
        try repository.loadToday(date: date)
    }

    func loadTomorrow(date: Date) throws -> TodayPlan {
        try repository.loadTomorrow(date: date)
    }

    func loadStreakDefinitions() throws -> [StreakDefinition] {
        try repository.loadStreakDefinitions()
    }

    func loadAgenda() throws -> [AgendaTask] {
        try repository.loadAgenda()
    }

    func saveAgenda(_ tasks: [AgendaTask]) throws {
        try repository.saveAgenda(tasks)
    }

    func loadTemplates() throws -> [PlanTask] {
        try repository.loadTemplates()
    }

    func saveTemplates(_ tasks: [PlanTask]) throws {
        try repository.saveTemplates(tasks)
    }

    func saveToday(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        segment: PlanningSegment,
        expectedTasks: [PlanTask]
    ) throws {
        try repository.saveToday(
            date: date,
            tasks: tasks,
            profile: profile,
            segment: segment,
            expectedTasks: expectedTasks
        )
    }

    func saveTomorrow(date: Date, tasks: [PlanTask], profile: DayProfileKind) throws {
        try repository.saveTomorrow(date: date, tasks: tasks, profile: profile)
    }

    func saveCheckIn(_ checkIn: CheckIn, streaks: [StreakDefinition]) throws {
        try repository.saveCheckIn(checkIn, date: checkIn.focusStart, streaks: streaks)
        try repository.updateAutomaticStreaks(date: checkIn.focusStart)
    }

    func updatePlanMinimum(date: Date, completed: Bool) throws {
        try repository.updateAutomaticStreaks(date: date, planHasMinimum: completed)
    }

    func setStreakValue(_ definition: StreakDefinition, status: StreakStatus, date: Date) throws {
        try repository.setStreakValue(definition, status: status, date: date)
    }

    func streakSummaries(for date: Date, definitions: [StreakDefinition]) throws -> [StreakSummary] {
        try repository.loadStreakSummaries(for: date, definitions: definitions)
    }
}
