import Foundation

actor OpenAIAudioTranscriptionClient {
    private struct TranscriptResponse: Decodable {
        var text: String
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let apiKey = OpenAIKeychain.load() else { throw OpenAIChatError.missingAPIKey }
        let audio = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard !audio.isEmpty else { throw OpenAIChatError.api("The recording is empty.") }
        guard audio.count <= 25 * 1_024 * 1_024 else {
            throw OpenAIChatError.api("The recording exceeds OpenAI's 25 MB transcription upload limit.")
        }

        let boundary = "ReFocusVoice-\(UUID().uuidString)"
        var body = Data()
        Self.appendField("model", value: "gpt-transcribe", boundary: boundary, to: &body)
        Self.appendField("response_format", value: "json", boundary: boundary, to: &body)
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"recording.m4a\"\r\n".utf8))
        body.append(Data("Content-Type: audio/mp4\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenAIChatError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data) ?? "HTTP \(http.statusCode)"
            throw OpenAIChatError.api("OpenAI transcription failed: \(detail)")
        }
        let result = try JSONDecoder().decode(TranscriptResponse.self, from: data)
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw OpenAIChatError.api("No speech was detected. The original recording is kept so you can retry.")
        }
        return transcript
    }

    private static func appendField(_ name: String, value: String, boundary: String, to body: inout Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let message = error["message"] as? String else { return nil }
        return String(message.prefix(500))
    }
}
