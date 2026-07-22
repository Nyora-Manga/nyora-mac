import Foundation

/// Unofficial Google Translate (client=gtx) with the manga-specific repair pass
/// ported from nyora-web's `core/translate/mt.js`. Raw gtx output reads
/// unnaturally for manga — it mistranslates set-phrase interjections, spaces out
/// repeated punctuation, inflates screams, and drops stutters. Every rule below
/// mirrors the web's, so the Mac reads the same as the web.
///
/// Batch translation joins a whole page into ONE request (||| delimiter) and,
/// on a misaligned split, BISECTS (≈log₂n requests) instead of falling back to
/// one request per bubble — much faster on the pages where the delimiter breaks.
actor GoogleTranslate {
    private let session = URLSession.shared

    // MARK: - Public API

    func translate(_ text: String, to target: String, source: String = "auto") async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard let enc = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&dt=t&sl=\(source)&tl=\(target)&q=\(enc)")
        else { return text }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try parseResponse(data)
    }

    func translateBatch(_ texts: [String], to target: String, source: String = "auto") async throws -> [String] {
        guard !texts.isEmpty else { return [] }

        // Prepare each segment: answer known interjections locally (en only), and
        // strip a leading stutter so gtx doesn't translate the stray mora as its
        // own word — we re-apply it to the English afterwards.
        struct Prep { var direct: String?; var send: String?; var src: String; var stutter: Bool }
        let prepared: [Prep] = texts.map { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = Self.stripTrailingPunct(t)
            if target == "en", let hit = Self.lexicon[bare] {
                let tail = String(t.dropFirst(bare.count))
                return Prep(direct: Self.fixPunct(hit + Self.asciiPunct(tail)), send: nil, src: t, stutter: false)
            }
            let (stripped, stut) = Self.stripStutter(t)
            return Prep(direct: nil, send: stripped, src: t, stutter: stut)
        }

        let pendingIdx = prepared.indices.filter { prepared[$0].send != nil }
        let sends = pendingIdx.map { prepared[$0].send ?? "" }
        let got = try await translateRun(sends, target: target, source: source)
        var outMap: [Int: String] = [:]
        for (k, idx) in pendingIdx.enumerated() { outMap[idx] = k < got.count ? got[k] : "" }

        return prepared.enumerated().map { i, p in
            if let d = p.direct { return d }
            return Self.polish(outMap[i] ?? "", src: p.src, stutter: p.stutter)
        }
    }

    // MARK: - Bisecting batch translate

    private func translateRun(_ texts: [String], target: String, source: String) async throws -> [String] {
        if texts.isEmpty { return [] }
        if texts.count == 1 {
            let s = (try? await translate(texts[0], to: target, source: source))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return [s]
        }
        let delim = "\n\n\n|||\n\n\n"
        if let joined = try? await translate(texts.joined(separator: delim), to: target, source: source),
           let parts = Self.splitParts(joined, texts.count) {
            return parts
        }
        // Misaligned split — bisect and recurse (halves run concurrently).
        let mid = (texts.count + 1) / 2
        async let a = translateRun(Array(texts[0..<mid]), target: target, source: source)
        async let b = translateRun(Array(texts[mid...]), target: target, source: source)
        return try await a + b
    }

    // MARK: - Parse

    private func parseResponse(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = root.first as? [[Any]]
        else { throw URLError(.cannotParseResponse) }
        return segments.compactMap { $0.first as? String }.joined()
    }

    // MARK: - Manga repair (port of mt.js) ------------------------------------

    /// Set-phrase interjections gtx reliably gets wrong (en target only).
    private static let lexicon: [String: String] = [
        "しまった": "Damn it", "ヤバい": "This is bad", "やばい": "This is bad",
        "まずい": "This is bad", "くそ": "Damn", "くそっ": "Damn it",
        "ちくしょう": "Dammit", "やめろ": "Stop it", "まさか": "No way",
        "さすが": "As expected", "よし": "All right", "なるほど": "I see",
        "うるさい": "Shut up", "てめえ": "You bastard", "ざけんな": "Screw you",
        "どういうことだ": "What do you mean", "ありえない": "Impossible",
    ]

    private static let fullwidthPunct = Set<Character>(["！", "？", "!", "?", "。", "．", ".", "…", "、", ",", " ", "\t", "\n"])

    private static func stripTrailingPunct(_ t: String) -> String {
        var arr = Array(t)
        while let last = arr.last, fullwidthPunct.contains(last) { arr.removeLast() }
        return String(arr)
    }

    private static func asciiPunct(_ s: String) -> String {
        let map: [Character: Character] = ["！": "!", "？": "?", "。": ".", "、": ",", "．": ".", "，": ","]
        return String(s.map { map[$0] ?? $0 })
    }

    private static func rx(_ pattern: String, _ s: String, _ template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }

    private static func fixPunct(_ input: String) -> String {
        var s = rx("(?<=[!?])\\s+(?=[!?])", input, "")   // "! ! !" → "!!!"
        s = s.replacingOccurrences(of: "…", with: "...")
        s = rx("\\.{4,}", s, "...")
        s = rx("\\s+([,.!?;:])", s, "$1")
        s = rx("\\s{2,}", s, " ")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clamp any run of a repeated letter in the English to the longest run in
    /// the source, so gtx-inflated screams (うわああ → "Uwaaaaaaaa") keep length.
    private static func clampRuns(_ en: String, src: String) -> String {
        var maxRun = 1, run = 0
        var prev: Character?
        for ch in src { if ch == prev { run += 1 } else { run = 1; prev = ch }; maxRun = max(maxRun, run) }
        if maxRun < 2 { return en }   // no run in source → nothing to clamp against
        let cap = max(2, maxRun)
        var out = ""
        var buf: [Character] = []
        var pc: Character?
        func flush() {
            if buf.count >= 3, let c = pc, c.isLetter {
                out += String(repeating: c, count: min(buf.count, cap))
            } else {
                out += String(buf)
            }
            buf.removeAll()
        }
        for ch in en {
            if ch == pc { buf.append(ch) } else { flush(); pc = ch; buf = [ch] }
        }
        flush()
        return out
    }

    /// A stutter is a first-mora repeat (ま、まさか / だ、誰だ). Strip it before
    /// translating; `restoreStutter` re-letters it as a scanlator would ("N-no way").
    private static func stripStutter(_ t: String) -> (String, Bool) {
        let arr = Array(t)
        guard arr.count >= 3, let first = arr.first, arr[1] == "、" || arr[1] == "," else { return (t, false) }
        var j = 2
        while j < arr.count, arr[j].isWhitespace { j += 1 }
        if j < arr.count, arr[j] == first { return (String(arr[j...]), true) }
        return (t, false)
    }

    private static func restoreStutter(_ en: String) -> String {
        guard let first = en.first, first.isLetter, first.isASCII else { return en }
        return "\(first)-\(String(first).lowercased())\(en.dropFirst())"
    }

    private static func capitalize(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    private static func polish(_ en: String, src: String, stutter: Bool) -> String {
        var out = fixPunct(en)
        out = clampRuns(out, src: src)
        if stutter { out = restoreStutter(out) }
        return capitalize(out)
    }

    /// Split a joined gtx reply back into `n` segments; nil when it can't align.
    /// Tolerates spaced pipes ("| | |") the way the web's regex does.
    private static func splitParts(_ full: String, _ n: Int) -> [String]? {
        let normalized = full.replacingOccurrences(
            of: "\\s*\\|\\s*\\|\\s*\\|\\s*", with: "\u{0001}", options: .regularExpression)
        let parts = normalized.components(separatedBy: "\u{0001}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return parts.count == n ? parts : nil
    }
}
