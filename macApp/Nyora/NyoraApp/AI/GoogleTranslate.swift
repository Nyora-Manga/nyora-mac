import Foundation

/// Unofficial Google Translate API — same endpoint the Android `me.bush.translator` library uses.
actor GoogleTranslate {
    private let session = URLSession.shared

    /// Translate a single text. Source is always auto-detected.
    func translate(_ text: String, to targetLang: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=\(targetLang)&dt=t&q=\(encoded)")
        else { return text }

        let (data, _) = try await session.data(from: url)
        return try parseResponse(data)
    }

    /// Translate multiple texts efficiently using a separator trick (same as Android).
    /// Falls back to individual requests if the separator splits incorrectly.
    func translateBatch(_ texts: [String], to targetLang: String) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        if texts.count == 1 { return [try await translate(texts[0], to: targetLang)] }

        let delimiter = "\n\n\n|||\n\n\n"
        let combined = texts.joined(separator: delimiter)

        let translated: String
        do {
            translated = try await translate(combined, to: targetLang)
        } catch {
            return try await fallbackIndividual(texts, to: targetLang)
        }

        let parts = translated
            .components(separatedBy: "|||")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if parts.count == texts.count { return parts }

        // Separator didn't survive translation — fall back to one-by-one
        return try await fallbackIndividual(texts, to: targetLang)
    }

    private func fallbackIndividual(_ texts: [String], to targetLang: String) async throws -> [String] {
        var results = [String]()
        for text in texts {
            let t = (try? await translate(text, to: targetLang)) ?? text
            results.append(t)
        }
        return results
    }

    private func parseResponse(_ data: Data) throws -> String {
        // Response shape: [ [ ["translated","original",null,null,1], ... ], null, "sl", ... ]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [[Any]]
        else { throw URLError(.cannotParseResponse) }
        return segments.compactMap { $0.first as? String }.joined()
    }
}
