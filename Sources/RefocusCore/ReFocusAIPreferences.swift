import Foundation

public enum ReFocusAIPreferences {
    public static let defaultDocument = """
    # How I Work

    - Plan my day in four six-hour blocks: 00:00–06:00, 06:00–12:00, 12:00–18:00, and 18:00–00:00.
    - One cycle is 30 minutes. A task may use at most four cycles (two hours).
    - Reserve the final hour of every six-hour block for Rest: 05:00–06:00, 11:00–12:00, 17:00–18:00, and 23:00–00:00. Treat “break” as Rest.
    - Preserve Rest by default. Only schedule work inside Rest when I explicitly say to override it.
    - When I insert a task or increase a task’s duration, push every later movable task forward by the same number of cycles while preserving order.
    - If pushed work reaches Rest, continue it after Rest. Never create an overlap and never silently cross midnight.
    - In a partial plan, keep explicitly timed tasks first and put untimed tasks after the last timed task, skipping occupied slots and Rest.
    - Match close task names to existing tasks before creating duplicates, and tell me when one name was interpreted as another.
    - New AI-created tasks use a concise custom MVP and exactly three concise custom subtasks.
    - Use the app’s live Asia/Dhaka date, time, and SQLite task state. Do not store mutable facts such as today’s tasks in this document.
    """
}

public struct AITokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int
    public var cachedInputTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, totalTokens: Int = 0, cachedInputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = cachedInputTokens
    }

    public static let zero = AITokenUsage()

    public static func + (lhs: AITokenUsage, rhs: AITokenUsage) -> AITokenUsage {
        AITokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            totalTokens: lhs.totalTokens + rhs.totalTokens,
            cachedInputTokens: lhs.cachedInputTokens + rhs.cachedInputTokens
        )
    }
}
