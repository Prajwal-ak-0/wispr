import Foundation

// Sends the raw transcript to a local Ollama model with the hardened "format-only" prompt.
// Returns the cleaned text, or the raw text unchanged if the model is unavailable.
enum TextFormatter {
    private struct Message: Codable { let role: String; let content: String }
    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: [String: Double]
    }
    private struct ChatResponse: Codable { let message: Message }

    static func format(_ raw: String, style: Config.Style) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        var messages = [Message(role: "system", content: Config.systemPrompt + style.instruction)]
        for (user, assistant) in Config.coreFewShot {
            messages.append(Message(role: "user", content: user))
            messages.append(Message(role: "assistant", content: assistant))
        }
        let (exampleUser, exampleAssistant) = style.enumerationExample
        messages.append(Message(role: "user", content: exampleUser))
        messages.append(Message(role: "assistant", content: exampleAssistant))
        messages.append(Message(role: "user", content: "<t>\(trimmed)</t>"))

        let payload = ChatRequest(
            model: Config.ollamaModel,
            messages: messages,
            stream: false,
            options: ["temperature": Config.formatTemperature, "top_p": 0.9, "repeat_penalty": 1.05]
        )

        do {
            var request = URLRequest(url: Config.ollamaURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            request.timeoutInterval = 20

            let (data, _) = try await URLSession.shared.data(for: request)
            let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
            return sanitize(decoded.message.content, fallback: trimmed)
        } catch {
            Log.error("formatter failed, pasting raw transcript: \(error.localizedDescription)")
            return trimmed
        }
    }

    private static func sanitize(_ text: String, fallback: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("<t>") { out.removeFirst(3) }
        if out.hasSuffix("</t>") { out.removeLast(4) }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? fallback : out
    }
}
