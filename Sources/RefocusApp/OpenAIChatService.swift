import Foundation
import Security

enum AIChatRole: String, Sendable {
    case user
    case assistant
}

struct AIChatMessage: Identifiable, Sendable {
    let id: UUID
    var role: AIChatRole
    var text: String
    var reasoningSummary: String
    var toolActivity: [String]
    var isStreaming: Bool

    init(
        id: UUID = UUID(), role: AIChatRole, text: String,
        reasoningSummary: String = "", toolActivity: [String] = [], isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoningSummary = reasoningSummary
        self.toolActivity = toolActivity
        self.isStreaming = isStreaming
    }
}

enum AIStreamEvent: Sendable {
    case outputDelta(String)
    case reasoningDelta(String)
    case toolStarted(String)
    case toolFinished(String)
}

struct AICreateTaskArguments: Codable, Sendable {
    var date: String
    var title: String
    var description: String?
    var startTime: String?
    var cycles: Int
    var kind: String?
    var priority: String?
    var difficulty: String?
    var color: String?
    var mvp: String?
    var subtasks: [String]?

    enum CodingKeys: String, CodingKey {
        case date, title, description, cycles, kind, priority, difficulty, color, mvp, subtasks
        case startTime = "start_time"
    }
}

struct AISubtaskPatch: Codable, Sendable {
    var title: String
    var completed: Bool
}

struct AIUpdateTaskArguments: Codable, Sendable {
    var taskID: String
    var date: String?
    var title: String?
    var description: String?
    var startTime: String?
    var cycles: Int?
    var kind: String?
    var priority: String?
    var difficulty: String?
    var color: String?
    var mvp: String?
    var completed: Bool?
    var subtasks: [AISubtaskPatch]?

    enum CodingKeys: String, CodingKey {
        case date, title, description, cycles, kind, priority, difficulty, color, mvp, completed, subtasks
        case taskID = "task_id"
        case startTime = "start_time"
    }
}

struct AIRescheduleTaskArguments: Codable, Sendable {
    var taskID: String
    var date: String
    var startTime: String?

    enum CodingKeys: String, CodingKey {
        case date
        case taskID = "task_id"
        case startTime = "start_time"
    }
}

enum OpenAIKeychain {
    private static let service = "com.mtbishmam.refocus.openai"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let clean = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw OpenAIChatError.missingAPIKey }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: Data(clean.utf8)]
        let status = SecItemUpdate(identity as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = Data(clean.utf8)
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw OpenAIChatError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw OpenAIChatError.keychain(status)
        }
    }

    static func remove() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum OpenAIChatError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case api(String)
    case keychain(OSStatus)
    case toolLoopLimit

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "Add your OpenAI API key in ReFocus Settings first."
        case .invalidResponse: "OpenAI returned an unreadable response."
        case .api(let message): message
        case .keychain(let status): "Could not update macOS Keychain (\(status))."
        case .toolLoopLimit: "The assistant reached the safe tool-call limit for one prompt."
        }
    }
}

actor OpenAIResponsesClient {
    typealias ToolExecutor = @Sendable (_ name: String, _ arguments: Data) async throws -> String
    typealias EventHandler = @Sendable (AIStreamEvent) async -> Void

    private actor StreamAttemptState {
        private var streamedContent = false

        func markContentStreamed() {
            streamedContent = true
        }

        func hasStreamedContent() -> Bool {
            streamedContent
        }
    }

    private struct ToolCall: Sendable {
        var itemID: String
        var callID: String
        var name: String
        var arguments: String
    }

    func respond(
        history: [AIChatMessage],
        prompt: String,
        instructions: String,
        model: String,
        executeTool: @escaping ToolExecutor,
        onEvent: @escaping EventHandler
    ) async throws {
        guard let apiKey = OpenAIKeychain.load() else { throw OpenAIChatError.missingAPIKey }
        var previousResponseID: String?
        var conversation: [[String: Any]] = history.map { message in
            [
                "role": message.role.rawValue,
                "content": message.text,
            ]
        }
        conversation.append([
            "role": "user",
            "content": [["type": "input_text", "text": prompt]],
        ])
        var input: Any = conversation

        for _ in 0..<8 {
            let result = try await streamResponseWithRetry(
                apiKey: apiKey, model: model, instructions: instructions,
                input: input, previousResponseID: previousResponseID, onEvent: onEvent
            )
            previousResponseID = result.responseID
            guard !result.calls.isEmpty else { return }

            var outputs: [[String: Any]] = []
            for call in result.calls {
                await onEvent(.toolStarted(call.name))
                let data = Data(call.arguments.utf8)
                let output: String
                do {
                    output = try await executeTool(call.name, data)
                } catch {
                    output = "{\"ok\":false,\"error\":\"\(Self.escape(error.localizedDescription))\"}"
                }
                outputs.append([
                    "type": "function_call_output",
                    "call_id": call.callID,
                    "output": output,
                ])
                await onEvent(.toolFinished(call.name))
            }
            input = outputs
        }
        throw OpenAIChatError.toolLoopLimit
    }

    private func streamResponseWithRetry(
        apiKey: String,
        model: String,
        instructions: String,
        input: Any,
        previousResponseID: String?,
        onEvent: @escaping EventHandler
    ) async throws -> (responseID: String, calls: [ToolCall]) {
        // Rapid retries make TPM exhaustion worse: each retry is another full
        // prompt. Allow one retry, and for rate limits wait for the server's
        // requested window instead of retrying after a few hundred ms.
        let maxAttempts = 2

        for attempt in 1...maxAttempts {
            let state = StreamAttemptState()
            let attemptEvent: EventHandler = { event in
                switch event {
                case .outputDelta, .reasoningDelta:
                    await state.markContentStreamed()
                case .toolStarted, .toolFinished:
                    break
                }
                await onEvent(event)
            }

            do {
                return try await streamResponse(
                    apiKey: apiKey,
                    model: model,
                    instructions: instructions,
                    input: input,
                    previousResponseID: previousResponseID,
                    onEvent: attemptEvent
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard !Task.isCancelled,
                      attempt < maxAttempts,
                      Self.isRetryable(error),
                      !(await state.hasStreamedContent())
                else {
                    if attempt > 1 {
                        throw Self.errorAfterRetries(error, attempts: attempt)
                    }
                    throw error
                }

                let delay = Self.retryDelay(for: error)
                    ?? (Self.isRateLimit(error) ? 60.0 : Double(attempt) * 0.4)
                guard delay <= 60 else {
                    throw Self.errorAfterRetries(error, attempts: attempt)
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw OpenAIChatError.invalidResponse
    }

    private func streamResponse(
        apiKey: String,
        model: String,
        instructions: String,
        input: Any,
        previousResponseID: String?,
        onEvent: @escaping EventHandler
    ) async throws -> (responseID: String, calls: [ToolCall]) {
        var payload: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "stream": true,
            "store": true,
            "reasoning": ["effort": "low", "summary": "auto"],
            "tools": Self.tools,
            "prompt_cache_key": "refocus-ai-v1-\(model)",
        ]
        if let previousResponseID { payload["previous_response_id"] = previousResponseID }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            let detail = Self.apiMessage(from: body) ?? "No additional error details."
            let message = "OpenAI request failed (HTTP " + String(http.statusCode) + "): " + detail
            throw OpenAIChatError.api(message)
        }

        var responseID = ""
        var calls: [String: ToolCall] = [:]
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let raw = String(line.dropFirst(6))
            if raw == "[DONE]" { break }
            guard let data = raw.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "response.created", "response.completed":
                if let response = event["response"] as? [String: Any], let id = response["id"] as? String {
                    responseID = id
                }
            case "response.failed":
                let message = Self.streamFailureMessage(from: event) ?? "OpenAI response failed."
                throw OpenAIChatError.api(message)
            case "response.incomplete":
                let message = Self.streamFailureMessage(from: event) ?? "OpenAI response was incomplete."
                throw OpenAIChatError.api(message)
            case "response.output_text.delta":
                if let delta = event["delta"] as? String { await onEvent(.outputDelta(delta)) }
            case "response.reasoning_summary_text.delta":
                if let delta = event["delta"] as? String { await onEvent(.reasoningDelta(delta)) }
            case "response.output_item.added":
                guard let item = event["item"] as? [String: Any],
                      item["type"] as? String == "function_call",
                      let itemID = item["id"] as? String,
                      let callID = item["call_id"] as? String,
                      let name = item["name"] as? String
                else { continue }
                calls[itemID] = ToolCall(itemID: itemID, callID: callID, name: name, arguments: "")
            case "response.function_call_arguments.delta":
                guard let itemID = event["item_id"] as? String,
                      let delta = event["delta"] as? String,
                      calls[itemID] != nil else { continue }
                calls[itemID]?.arguments += delta
            case "response.function_call_arguments.done":
                guard let itemID = event["item_id"] as? String, calls[itemID] != nil else { continue }
                if let arguments = event["arguments"] as? String { calls[itemID]?.arguments = arguments }
            case "error":
                let message = Self.streamFailureMessage(from: event) ?? "OpenAI streaming failed."
                throw OpenAIChatError.api(message)
            default:
                continue
            }
        }
        guard !responseID.isEmpty else { throw OpenAIChatError.invalidResponse }
        return (responseID, calls.values.sorted { $0.itemID < $1.itemID })
    }

    private static func apiMessage(from body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any]
        else { return nil }
        return error["message"] as? String
    }

    private static func streamFailureMessage(from event: [String: Any]) -> String? {
        if let message = event["message"] as? String, !message.isEmpty {
            return message
        }
        if let error = event["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let response = event["response"] as? [String: Any],
           let error = response["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let response = event["response"] as? [String: Any],
           let details = response["incomplete_details"] as? [String: Any],
           let reason = details["reason"] as? String,
           !reason.isEmpty {
            return "OpenAI response was incomplete: " + reason + "."
        }
        return nil
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }
        guard let chatError = error as? OpenAIChatError else { return false }
        switch chatError {
        case .invalidResponse:
            return true
        case .api(let message):
            let normalized = message.lowercased()
            return [
                "server_error", "server error", "overloaded", "rate limit", "rate_limit",
                "timeout", "timed out", "temporarily", "try again", "connection",
                "network", "stream", "failed to generate", "http 500", "http 502",
                "http 503", "http 504", "http 429", "http 529",
            ].contains { normalized.contains($0) }
        case .missingAPIKey, .keychain, .toolLoopLimit:
            return false
        }
    }

    private static func isRateLimit(_ error: Error) -> Bool {
        guard let chatError = error as? OpenAIChatError else { return false }
        guard case .api(let message) = chatError else { return false }
        let normalized = message.lowercased()
        return normalized.contains("rate limit")
            || normalized.contains("rate_limit")
            || normalized.contains("http 429")
            || normalized.contains("tokens per min")
    }

    private static func retryDelay(for error: Error) -> TimeInterval? {
        guard let chatError = error as? OpenAIChatError,
              case .api(let message) = chatError else { return nil }
        let pattern = #"(?i)try again in\s+([0-9]+(?:\.[0-9]+)?)s"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: message, range: NSRange(message.startIndex..., in: message)
              ),
              let secondsRange = Range(match.range(at: 1), in: message),
              let seconds = Double(message[secondsRange]) else { return nil }
        return max(0, seconds)
    }

    private static func errorAfterRetries(_ error: Error, attempts: Int) -> OpenAIChatError {
        let message: String
        if let chatError = error as? OpenAIChatError, let description = chatError.errorDescription {
            message = description
        } else {
            message = error.localizedDescription
        }
        return .api(message + " (Retried " + String(attempts - 1) + " times.)")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let tools: [[String: Any]] = [
        function("get_refocus_context", "Read dated tasks, Agenda tasks, Daily metrics, and habit values. Call this before mutating records.", [
            "date": string("Date in YYYY-MM-DD. Defaults to today in Asia/Dhaka."),
        ], required: []),
        function("create_task", "Create a quick task. Supply one terse custom MVP and exactly three terse title-specific subtasks. Rest means 05:00–06:00, 11:00–12:00, 17:00–18:00, and 23:00–00:00 Asia/Dhaka; a timed work task is moved to the first valid slot after Rest by default. Only an explicit override/overrule/bypass/ignore/force instruction in the current user prompt may schedule work inside Rest; preserve the Rest row and report that override. A timed task may replace only an overlapping non-Rest predefined routine. In a partial plan, match close existing task names before creating duplicates and allocate omitted times after the last explicitly timed task.", [
            "date": string("Scheduled date in YYYY-MM-DD."),
            "title": string("Concrete task title."),
            "description": string("Optional notes or instructions."),
            "start_time": nullableString("Optional HH:mm in Asia/Dhaka. In a partial plan, omit only when the task should be allocated after the last explicitly timed task; use an untimed Agenda task only when the user explicitly asks for one."),
            "cycles": integer("Number of half-hour cycles, 1-10."),
            "kind": enumString(["normal", "contest"]),
            "priority": enumString(["Do/Die", "High", "Medium", "Low"]),
            "difficulty": enumString(["Hard", "Moderate", "Easy"]),
            "color": enumString(["none", "red", "green", "blue", "orange", "yellow", "purple"]),
            "mvp": string("Very short, task-specific completion definition."),
            "subtasks": array(of: string("Very short, task-specific subtask; provide exactly three.")),
        ], required: ["date", "title", "cycles", "mvp", "subtasks"]),
        function("update_task", "Edit any field of an existing task while preserving its stable ID. If the resulting work task overlaps protected Rest, move it after Rest unless the current user prompt explicitly says to override, overrule, bypass, ignore, or force through Rest; report any automatic move or explicit override.", [
            "task_id": string("Task UUID returned by get_refocus_context."),
            "date": nullableString("Optional replacement date YYYY-MM-DD."),
            "title": nullableString("Optional replacement title."),
            "description": nullableString("Optional replacement description; empty clears it."),
            "start_time": nullableString("Optional HH:mm; empty makes the task untimed."),
            "cycles": nullableInteger("Optional half-hour cycle count."),
            "kind": nullableEnumString(["normal", "contest"]),
            "priority": nullableEnumString(["Do/Die", "High", "Medium", "Low"]),
            "difficulty": nullableEnumString(["Hard", "Moderate", "Easy"]),
            "color": nullableEnumString(["none", "red", "green", "blue", "orange", "yellow", "purple"]),
            "mvp": nullableString("Optional replacement MVP; empty clears it."),
            "completed": nullableBoolean("Optional task completion state."),
            "subtasks": ["type": ["array", "null"], "items": ["type": "object", "properties": [
                "title": string("Subtask title."), "completed": boolean("Completion state."),
            ], "required": ["title", "completed"], "additionalProperties": false]],
        ], required: ["task_id"]),
        function("reschedule_task", "Move a task to another date and optionally assign a new time. Protected Rest is respected by default: move work after Rest and report it. Only an explicit override/overrule/bypass/ignore/force instruction in the current prompt may place work inside Rest; preserve the Rest row and report the override.", [
            "task_id": string("Task UUID returned by get_refocus_context."),
            "date": string("Destination date YYYY-MM-DD."),
            "start_time": nullableString("Optional HH:mm; empty keeps it untimed."),
        ], required: ["task_id", "date"]),
        function("append_task_description", "Append execution notes to a task Description without replacing existing notes. Use this for `cur -> did ...`.", [
            "task_id": string("Current task UUID returned by get_refocus_context."),
            "text": string("Concise account of what happened, what could improve, or how to go faster."),
        ], required: ["task_id", "text"]),
        function("delete_task", "Permanently delete one explicitly requested task. Never infer deletion.", [
            "task_id": string("Task UUID returned by get_refocus_context."),
        ], required: ["task_id"]),
        function("set_daily_metric", "Set or correct a present or historical Daily field, including metrics and habit outcomes.", [
            "date": string("Date in YYYY-MM-DD."),
            "field_id": string("Field ID returned by get_refocus_context."),
            "value": string("Number, text, or blank/win/fail for a habit."),
        ], required: ["date", "field_id", "value"]),
        function("search_vault", "Search the configured Obsidian vault for planning context. Use targeted queries instead of loading unrelated files.", [
            "query": string("Words or phrase to search."),
        ], required: ["query"]),
    ]

    private static func function(
        _ name: String, _ description: String, _ properties: [String: Any], required: [String]
    ) -> [String: Any] {
        [
            "type": "function", "name": name, "description": description, "strict": false,
            "parameters": [
                "type": "object", "properties": properties, "required": required,
                "additionalProperties": false,
            ],
        ]
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func nullableString(_ description: String) -> [String: Any] { ["type": ["string", "null"], "description": description] }
    private static func integer(_ description: String) -> [String: Any] { ["type": "integer", "description": description] }
    private static func nullableInteger(_ description: String) -> [String: Any] { ["type": ["integer", "null"], "description": description] }
    private static func boolean(_ description: String) -> [String: Any] { ["type": "boolean", "description": description] }
    private static func nullableBoolean(_ description: String) -> [String: Any] { ["type": ["boolean", "null"], "description": description] }
    private static func enumString(_ values: [String]) -> [String: Any] { ["type": "string", "enum": values] }
    private static func nullableEnumString(_ values: [String]) -> [String: Any] {
        ["type": ["string", "null"], "enum": values.map { $0 as Any } + [NSNull()]]
    }
    private static func array(of item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
}
