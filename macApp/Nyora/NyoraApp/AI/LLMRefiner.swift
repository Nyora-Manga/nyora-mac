import Foundation

/// BYOK LLM refinement — a Swift port of nyora-web's `core/translate/mt.js`
/// `refineBatch`. After Google MT drafts a page, an OpenAI- or Anthropic-compatible
/// chat model rewrites every bubble in one request, keeping them coherent and using
/// an optional series-context "reference" for character names / terminology.
///
/// The whole page's segments are joined with `|||` in reading order; the reply is
/// split back on `|||`. If the split doesn't line up 1:1, we return nil and the
/// caller keeps the fast Google text — exactly like the web.
struct LLMRefiner {
    /// One refined page, or nil when the model's reply couldn't be aligned.
    static func refine(
        originals: [String],
        drafts: [String],
        targetLangName: String,
        context: String,
        endpoint: String,
        apiKey: String,
        model: String
    ) async throws -> [String]? {
        guard !originals.isEmpty else { return [] }
        let base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        // Route to the Anthropic Messages API for an anthropic endpoint OR a Claude
        // model (covers Anthropic-compatible gateways); everything else is the
        // OpenAI /chat/completions shape. Both are first-class, matching the web.
        let isAnthropic = base.lowercased().contains("anthropic")
            || model.lowercased().hasPrefix("claude")

        let ctx = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let system =
            "You are an expert manga translator. Translate each dialogue segment into "
            + "\(targetLangName), preserving tone and keeping lines short enough for speech bubbles. "
            + "The segments come from ONE manga page in reading order — keep them coherent with each other. "
            + (ctx.isEmpty ? "" : "\nUse this series context for accurate character names and terms:\n\(ctx)\n")
            + "Reply with ONLY the translated segments, in the same order, separated by \" ||| \". "
            + "No numbering, no commentary, and exactly \(originals.count) segments."
        var user = "Original segments:\n" + originals.joined(separator: "\n|||\n")
        if drafts.count == originals.count {
            user += "\n\nDraft machine translations (improve on these):\n" + drafts.joined(separator: "\n|||\n")
        }

        let content = isAnthropic
            ? try await callAnthropic(base: base, apiKey: apiKey, model: model, system: system, user: user)
            : try await callOpenAI(base: base, apiKey: apiKey, model: model, system: system, user: user)

        let parts = content
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.count == originals.count ? parts : nil
    }

    // MARK: - OpenAI-compatible (/chat/completions)

    private static func callOpenAI(base: String, apiKey: String, model: String,
                                   system: String, user: String) async throws -> String {
        guard let url = URL(string: "\(base)/chat/completions") else { throw URLError(.badURL) }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return (message?["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anthropic (/v1/messages)

    private static func callAnthropic(base: String, apiKey: String, model: String,
                                      system: String, user: String) async throws -> String {
        guard let url = URL(string: "\(base)/v1/messages") else { throw URLError(.badURL) }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.checkStatus(resp, data)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let contentArr = json?["content"] as? [[String: Any]]
        return (contentArr?.first?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func checkStatus(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "LLMRefiner", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "AI refinement failed (\(http.statusCode)) \(msg)"])
        }
    }
}
