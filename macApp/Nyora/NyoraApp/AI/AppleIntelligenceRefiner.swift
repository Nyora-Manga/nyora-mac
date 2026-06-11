import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Post-OCR text cleanup via Apple Intelligence's on-device language model
/// (FoundationModels framework, macOS 26+).
///
/// OCR — even a good model like manga-ocr — produces partial words, wrong
/// kanji, hallucinated tokens, and misread punctuation. Apple Intelligence's
/// ~3B parameter on-device model is fluent enough in Japanese to spot and
/// fix obvious recognition errors before we feed the text to Google
/// Translate. Runs entirely on-device, no API key, no network — free.
///
/// Gracefully no-ops on macOS < 26 or when Apple Intelligence isn't enabled.
@MainActor
final class AppleIntelligenceRefiner {
    static let shared = AppleIntelligenceRefiner()

    enum State {
        case unsupportedOS         // macOS < 26
        case unavailable(String)   // FoundationModels reports unavailable
        case ready
    }

    private(set) var state: State = .unsupportedOS
    private var refineInstructions: String {
        "You are a Japanese manga OCR cleanup assistant. " +
        "The user gives you raw OCR output that may contain wrong kanji, " +
        "missing characters, repeated tokens, or hallucinated text. " +
        "Return ONLY the corrected Japanese text, no explanations, no English, " +
        "no quotes. If the input is already clean, return it unchanged. " +
        "If the input is clearly garbage (no real Japanese sentence), return " +
        "an empty string."
    }

    /// Instructions used by the translation session. Tone-aware manga
    /// localiser persona, with strict output rules to prevent the model
    /// from adding commentary, romaji, or markdown that would bleed into
    /// the painted bubble.
    private func translateInstructions(sourceLang: String, targetLang: String) -> String {
        """
        You are an expert manga translator. Translate the given \(sourceLang) \
        dialogue into natural, fluent \(targetLang). Preserve tone, register, \
        and intensity (shouts, whispers, formal/casual). Render SFX with a \
        short evocative English equivalent. Output ONLY the translation — no \
        quotes, no source text, no notes, no romaji, no markdown. If the \
        input is empty or garbage, output nothing.
        """
    }

    /// Instructions used by the polish session. Takes an already-translated
    /// line and rewrites it as a professional manga editor would: tighter
    /// phrasing, natural register, no stiffness or literal-translation tics.
    private func polishInstructions(targetLang: String) -> String {
        """
        You are a professional manga localization editor. The user gives you \
        a single line of dialogue that has already been translated into \
        \(targetLang). Rewrite it to sound natural and idiomatic, as if it \
        were originally written by a fluent comic-book writer in \(targetLang). \
        Tighten phrasing, fix awkward word order, smooth machine-translation \
        artifacts. Preserve original meaning, tone, register, and intensity \
        (shouts stay shouts, whispers stay whispers, formal stays formal). \
        Keep the line roughly the same length so it still fits in a speech \
        bubble. Output ONLY the polished line — no quotes, no original, no \
        notes, no markdown. If the input is already perfect, return it \
        unchanged. If it's empty or unintelligible, return it unchanged.
        """
    }

    // Stored as `Any?` because @available can't decorate stored properties.
    // Three separate sessions: OCR cleanup, translation, polish — each keeps
    // its own instruction context so the model doesn't get confused between
    // roles.
    private var refineSessionStorage: Any?
    private var translateSessionStorage: Any?
    private var translateSessionTargetLang: String?
    private var polishSessionStorage: Any?
    private var polishSessionTargetLang: String?

    private init() {
        refreshAvailability()
    }

    func refreshAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                state = .ready
                // Lazily create session on first use (cheap, but we want the
                // process to start without immediately spinning the LM).
            case .unavailable(let reason):
                state = .unavailable("\(reason)")
            @unknown default:
                state = .unavailable("unknown availability")
            }
        } else {
            state = .unsupportedOS
        }
        #else
        state = .unsupportedOS
        #endif
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// Refine a batch of OCR strings. Returns one cleaned string per input,
    /// same order. On any failure (timeout, API error, parse mismatch), the
    /// corresponding original is returned unchanged so we never lose text.
    func refine(_ texts: [String]) async -> [String] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isReady, !texts.isEmpty else { return texts }

        // Process per-string so a single failure doesn't drop the whole batch.
        // The on-device LM is fast (~50-200ms per short request) and runs on
        // the ANE / GPU, so serial is fine for typical 10-20 bubbles/page.
        var out: [String] = []
        out.reserveCapacity(texts.count)

        let session = ensureSession()
        guard let session else { return texts }

        for original in texts {
            // Skip very short / clearly junk strings; the model just echoes.
            if original.count < 2 {
                out.append(original)
                continue
            }
            do {
                let prompt = "OCR output: \(original)"
                let response = try await session.respond(to: prompt)
                let cleaned = response.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Strip stray markdown quotes if the model adds them
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`「」『』"))
                if cleaned.isEmpty {
                    // Model decided this was garbage — drop to empty so the
                    // caller can skip translating noise.
                    out.append("")
                } else {
                    out.append(cleaned)
                }
            } catch {
                // On any error, keep the original — better to translate
                // imperfect OCR than to silently drop the bubble.
                out.append(original)
            }
        }
        return out
        #else
        return texts
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func ensureSession() -> LanguageModelSession? {
        if let existing = refineSessionStorage as? LanguageModelSession { return existing }
        let s = LanguageModelSession(instructions: refineInstructions)
        refineSessionStorage = s
        return s
    }

    @available(macOS 26.0, *)
    private func ensureTranslateSession(sourceLang: String, targetLang: String) -> LanguageModelSession? {
        // Re-create the session if the target language changes — instructions
        // bake the target language in, and we don't want the model to switch
        // mid-batch.
        if let existing = translateSessionStorage as? LanguageModelSession,
           translateSessionTargetLang == targetLang {
            return existing
        }
        let s = LanguageModelSession(instructions: translateInstructions(sourceLang: sourceLang, targetLang: targetLang))
        translateSessionStorage = s
        translateSessionTargetLang = targetLang
        return s
    }

    @available(macOS 26.0, *)
    private func ensurePolishSession(targetLang: String) -> LanguageModelSession? {
        if let existing = polishSessionStorage as? LanguageModelSession,
           polishSessionTargetLang == targetLang {
            return existing
        }
        let s = LanguageModelSession(instructions: polishInstructions(targetLang: targetLang))
        polishSessionStorage = s
        polishSessionTargetLang = targetLang
        return s
    }
    #endif

    /// Translate a batch of strings on-device with Apple Intelligence.
    /// Returns one translation per input in the same order; falls back to
    /// the input string on any error or refusal so a bubble never disappears.
    ///
    /// Caller should check `isReady` first and use Google Translate if false.
    func translate(_ texts: [String], sourceLang: String, targetLang: String) async -> [String] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isReady, !texts.isEmpty else { return texts }
        guard let session = ensureTranslateSession(sourceLang: sourceLang, targetLang: targetLang) else { return texts }

        var out: [String] = []
        out.reserveCapacity(texts.count)
        for original in texts {
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { out.append(""); continue }
            do {
                let response = try await session.respond(to: trimmed)
                let cleaned = response.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`「」『』"))
                // Refusal detection: Apple Intelligence's safety filter
                // sometimes declines to translate suggestive/violent manga
                // content with phrases like "I can't assist with that
                // request". Treat refusals as "no translation" so the
                // caller routes the bubble to Google Translate instead of
                // painting the refusal text into the speech balloon.
                if cleaned.isEmpty || Self.isRefusal(cleaned) {
                    out.append(original)
                } else {
                    out.append(cleaned)
                }
            } catch {
                // On any error, keep the original — caller can re-MT via
                // Google or accept the source text.
                out.append(original)
            }
        }
        return out
        #else
        return texts
        #endif
    }

    /// Polish a batch of already-translated strings. Takes the MT output and
    /// rewrites each line as a manga editor would — natural phrasing, fixed
    /// machine-translation artifacts, tone preserved. On any error or
    /// refusal returns the input unchanged so the bubble never disappears.
    func polishTranslation(_ texts: [String], targetLang: String) async -> [String] {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isReady, !texts.isEmpty else { return texts }
        guard let session = ensurePolishSession(targetLang: targetLang) else { return texts }

        var out: [String] = []
        out.reserveCapacity(texts.count)
        for original in texts {
            let trimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip near-empty inputs; the model would just echo or hallucinate.
            guard trimmed.count >= 2 else { out.append(original); continue }
            do {
                let response = try await session.respond(to: trimmed)
                let cleaned = response.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`「」『』"))
                // Refusal detection — see translate() for context. For polish
                // specifically, keep the MT text unchanged when the model
                // refuses; we'd rather show machine-translation than a
                // safety filter refusal in a speech bubble.
                if cleaned.isEmpty || Self.isRefusal(cleaned) {
                    out.append(original)
                } else {
                    out.append(cleaned)
                }
            } catch {
                out.append(original)
            }
        }
        return out
        #else
        return texts
        #endif
    }

    /// Heuristic detector for Apple Intelligence safety-filter refusals.
    /// The on-device model usually phrases refusals as a first-person
    /// statement of inability ("I can't…", "I'm unable…", "I cannot…") so
    /// we match a small set of prefixes / contained phrases. False positives
    /// would just mean we keep the original input — preferable to painting
    /// the refusal text into a speech bubble.
    static func isRefusal(_ s: String) -> Bool {
        let lower = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return false }
        // Length heuristic — most translations are < 200 chars; refusals are
        // typically 30-100 chars. A short response that matches a refusal
        // phrase is almost certainly a refusal.
        let refusalPrefixes = [
            "i can't",
            "i cannot",
            "i'm not able",
            "i am not able",
            "i'm unable",
            "i am unable",
            "i'm sorry, but",
            "i am sorry, but",
            "sorry, i can",
            "sorry, but i",
            "unfortunately, i",
            "as an ai",
            "as a language model",
        ]
        for prefix in refusalPrefixes where lower.hasPrefix(prefix) {
            return true
        }
        // Contained phrases (catch cases where the model adds a preamble).
        let refusalPhrases = [
            "can't assist with that request",
            "can't help with that request",
            "cannot assist with that request",
            "cannot help with that request",
            "unable to assist with that",
            "i don't feel comfortable",
            "i'm not comfortable",
            "violates my guidelines",
            "against my guidelines",
        ]
        for phrase in refusalPhrases where lower.contains(phrase) {
            return true
        }
        return false
    }
}
