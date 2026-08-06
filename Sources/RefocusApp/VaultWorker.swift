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

    func loadStreakDefinitions() throws -> [StreakDefinition] {
        try repository.loadStreakDefinitions()
    }

    func loadAgenda() throws -> [AgendaTask] {
        try repository.loadAgenda()
    }

    func saveAgenda(_ tasks: [AgendaTask]) throws {
        try repository.saveAgenda(tasks)
    }

    func saveToday(
        date: Date,
        tasks: [PlanTask],
        profile: DayProfileKind,
        expectedTasks: [PlanTask]
    ) throws {
        try repository.saveToday(
            date: date,
            tasks: tasks,
            profile: profile,
            expectedTasks: expectedTasks
        )
    }

    func saveCheckIn(_ checkIn: CheckIn, streaks: [StreakDefinition]) throws {
        try repository.saveCheckIn(checkIn, date: checkIn.focusStart, streaks: streaks)
        try repository.updateAutomaticStreaks(date: checkIn.focusStart)
    }

    func updatePlanMinimum(date: Date, completed: Bool) throws {
        try repository.updateAutomaticStreaks(date: date, planHasMinimum: completed)
    }

    func setStreakValue(_ definition: StreakDefinition, completed: Bool, date: Date) throws {
        try repository.setStreakValue(definition, completed: completed, date: date)
    }

    func streakSummaries(for date: Date, definitions: [StreakDefinition]) throws -> [StreakSummary] {
        try repository.loadStreakSummaries(for: date, definitions: definitions)
    }
}
