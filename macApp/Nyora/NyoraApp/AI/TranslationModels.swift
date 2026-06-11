import Foundation
import SwiftUI

enum TranslationState: Int, Comparable {
    case translating = 0
    case downloadingModels = 1
    case mt = 2
    case refined = 3

    static func < (a: TranslationState, b: TranslationState) -> Bool { a.rawValue < b.rawValue }
}

struct TranslatedBlock: Identifiable, Equatable {
    let id: String
    let originalText: String
    var translatedText: String
    let boundingBox: CGRect      // image pixel coordinates, top-left origin
    var state: TranslationState
    var backgroundColor: Color
}

// MARK: - LLM request / response models

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatRequest: Codable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Float
    let response_format: ResponseFormat?

    init(model: String, messages: [ChatMessage], temperature: Float = 0.3, response_format: ResponseFormat? = nil) {
        self.model = model
        self.messages = messages
        self.temperature = temperature
        self.response_format = response_format
    }
}

struct ResponseFormat: Codable {
    let type: String
}

struct ChatResponse: Codable {
    struct Choice: Codable {
        let message: ChatMessage
    }
    let choices: [Choice]
}

struct DialogueBlock: Codable {
    let id: String
    let original: String
    var mt_draft: String
}

struct ChapterTranslationRequest: Codable {
    let context: String
    let source_lang: String
    let target_lang: String
    let dialogues: [DialogueBlock]

    init(source_lang: String, target_lang: String, dialogues: [DialogueBlock]) {
        self.context = "Manga Chapter Translation"
        self.source_lang = source_lang
        self.target_lang = target_lang
        self.dialogues = dialogues
    }
}

struct ChapterTranslationResponse: Codable {
    struct TranslatedDialogue: Codable {
        let id: String
        let translated: String
    }
    let reasoning: String?
    let translations: [TranslatedDialogue]
}

// MARK: - Settings (UserDefaults-backed)

@MainActor
final class TranslationSettings: ObservableObject {
    @Published var isEnabled: Bool = ud.bool(forKey: Keys.enabled) {
        didSet { Self.ud.set(isEnabled, forKey: Keys.enabled) }
    }
    @Published var sourceLang: String = ud.string(forKey: Keys.sourceLang) ?? "AUTO" {
        didSet { Self.ud.set(sourceLang, forKey: Keys.sourceLang) }
    }
    @Published var targetLang: String = ud.string(forKey: Keys.targetLang) ?? "English" {
        didSet { Self.ud.set(targetLang, forKey: Keys.targetLang) }
    }
    @Published var endpoint: String = ud.string(forKey: Keys.endpoint) ?? "" {
        didSet { Self.ud.set(endpoint, forKey: Keys.endpoint) }
    }
    @Published var apiKey: String = ud.string(forKey: Keys.apiKey) ?? "" {
        didSet { Self.ud.set(apiKey, forKey: Keys.apiKey) }
    }
    @Published var model: String = ud.string(forKey: Keys.model) ?? "" {
        didSet { Self.ud.set(model, forKey: Keys.model) }
    }
    /// When true, the translate page bypasses the LLM API and uses only the
    /// on-device MT pipeline — so an empty API key shouldn't disable the
    /// translate action. Toggle in Reader Settings.
    @Published var isOffline: Bool = ud.bool(forKey: Keys.isOffline) {
        didSet { Self.ud.set(isOffline, forKey: Keys.isOffline) }
    }
    /// When ON, every chapter auto-translates as soon as it opens —
    /// no need to press ⌘T per chapter.
    @Published var instantTranslation: Bool = ud.bool(forKey: Keys.instant) {
        didSet { Self.ud.set(instantTranslation, forKey: Keys.instant) }
    }
    @Published var tier: OcrProvider.Tier = OcrProvider.Tier(rawValue: ud.string(forKey: Keys.tier) ?? "") ?? .tuned {
        didSet { Self.ud.set(tier.rawValue, forKey: Keys.tier) }
    }

    struct Provider: Identifiable {
        let id: String
        let name: String
        let url: String
        let modelHint: String
    }

    static let providers: [Provider] = [
        Provider(id: "openai",    name: "OpenAI",       url: "https://api.openai.com/v1",          modelHint: "gpt-4o-mini"),
        Provider(id: "mistral",   name: "Mistral",      url: "https://api.mistral.ai/v1",          modelHint: "mistral-small-latest"),
        Provider(id: "groq",      name: "Groq",         url: "https://api.groq.com/openai/v1",     modelHint: "llama-3.3-70b-versatile"),
        Provider(id: "together",  name: "Together AI",  url: "https://api.together.xyz/v1",        modelHint: "meta-llama/Llama-3.3-70B-Instruct-Turbo"),
        Provider(id: "ollama",    name: "Ollama",       url: "http://localhost:11434/v1",           modelHint: "llama3.2"),
        Provider(id: "lmstudio",  name: "LM Studio",   url: "http://localhost:1234/v1",            modelHint: "local-model"),
        Provider(id: "custom",    name: "Custom",       url: "",                                   modelHint: ""),
    ]

    var effectiveEndpoint: String {
        endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var effectiveModel: String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        // fall back to the hint for the matched provider
        return Self.providers.first { $0.url == effectiveEndpoint }?.modelHint ?? "gpt-4o-mini"
    }

    private static let ud = UserDefaults.standard

    /// Compat shim. The LLM-refinement code path was removed in favour of
    /// on-device Apple Intelligence refinement. Always returns `false` so
    /// any leftover call site treats the pipeline as MT-only.
    var hasLLMConfigured: Bool { false }

    private enum Keys {
        static let enabled     = "nyora.ai.translate.enabled"
        static let sourceLang  = "nyora.ai.translate.sourceLang"
        static let targetLang  = "nyora.ai.translate.targetLang"
        static let endpoint    = "nyora.ai.translate.endpoint"
        static let apiKey      = "nyora.ai.translate.apiKey"
        static let model       = "nyora.ai.translate.model"
        static let isOffline   = "nyora.ai.translate.isOffline"
        static let instant     = "nyora.ai.translate.instant"
        static let tier        = "nyora.ai.translate.tier"
    }

    static let supportedLanguages = [
        "AUTO", "English", "Japanese", "Chinese", "Korean",
        "Spanish", "French", "German", "Portuguese", "Italian",
        "Russian", "Arabic", "Hindi", "Bengali", "Turkish",
        "Vietnamese", "Polish", "Dutch", "Thai", "Indonesian", "Greek"
    ]

    func googleLangCode(for lang: String) -> String {
        switch lang.lowercased() {
        case "english":    return "en"
        case "japanese":   return "ja"
        case "chinese":    return "zh-CN"
        case "korean":     return "ko"
        case "spanish":    return "es"
        case "french":     return "fr"
        case "german":     return "de"
        case "portuguese": return "pt"
        case "italian":    return "it"
        case "russian":    return "ru"
        case "arabic":     return "ar"
        case "hindi":      return "hi"
        case "bengali":    return "bn"
        case "turkish":    return "tr"
        case "vietnamese": return "vi"
        case "polish":     return "pl"
        case "dutch":      return "nl"
        case "thai":       return "th"
        case "indonesian": return "id"
        case "greek":      return "el"
        default:           return "en"
        }
    }

}
