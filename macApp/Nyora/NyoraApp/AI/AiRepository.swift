import Foundation

actor AiRepository {
    private let session = URLSession.shared
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    func getCompletion(
        messages: [ChatMessage],
        useJsonMode: Bool = false,
        settings: TranslationSettings
    ) async throws -> String {
        let endpoint = await settings.effectiveEndpoint.hasSuffix("/")
            ? String(settings.effectiveEndpoint.dropLast())
            : settings.effectiveEndpoint
        let apiKey  = await settings.apiKey
        let model   = await settings.effectiveModel

        guard let url = URL(string: "\(endpoint)/chat/completions") else {
            throw URLError(.badURL)
        }

        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: 0.3,
            response_format: useJsonMode ? ResponseFormat(type: "json_object") : nil
        )

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try encoder.encode(body)

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let chatResp = try decoder.decode(ChatResponse.self, from: data)
        guard let content = chatResp.choices.first?.message.content else {
            throw URLError(.cannotParseResponse)
        }
        return content
    }
}
