import Foundation
import SwiftUI

struct MangaSummary: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let sourceName: String
    let coverUrl: String
    let unread: Int
    let progress: Float
    let tags: [String]
    // The source-relative manga URL (e.g. "/manga/slug"). Required to open details
    // — `id` is a content hash, NOT a fetchable URL. Defaulted for back-compat with
    // older persisted/decoded summaries.
    var url: String = ""

    var accent: Color {
        let palette: [Color] = [.blue, .orange, .green, .yellow, .purple, .pink, .teal]
        let h = abs(id.hashValue)
        return palette[h % palette.count]
    }
}

struct SourceSummary: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let lang: String
    let engine: String
    let isInstalled: Bool
    let isPinned: Bool
    let isNsfw: Bool
    // The source's favicon/logo URL, surfaced so the Explore source grid can show
    // real source icons (falling back to a language badge). Defaulted for back-compat
    // with older decoded/persisted summaries that predate this field.
    var iconUrl: String = ""

    /// The friendly language name for this source's `lang` code (e.g. "en" → "English"),
    /// mirroring nyora-web's `langLabel`. Used by the Explore source grid + language filter.
    var languageName: String { LanguageNames.label(for: lang) }

    /// The lowercased language code (or "" if none) — the grouping key for the language filter.
    var languageCode: String { lang.lowercased() }

    /// A copy with `isInstalled` overridden — used to overlay the client-side curated
    /// "installed" set (mirroring nyora-web, where the installed set is a local curation
    /// on top of the full catalogue).
    func withInstalled(_ flag: Bool) -> SourceSummary {
        SourceSummary(id: id, name: name, lang: lang, engine: engine,
                      isInstalled: flag, isPinned: isPinned, isNsfw: isNsfw, iconUrl: iconUrl)
    }
}

/// Friendly language-name lookup, ported from nyora-web's `LANG_NAMES` map so the Explore
/// grid shows reader-facing language names instead of raw ISO codes or parser jargon.
enum LanguageNames {
    static let map: [String: String] = [
        "en": "English", "es": "Spanish", "es-419": "Spanish (LatAm)", "pt": "Portuguese",
        "pt-br": "Portuguese (BR)", "fr": "French", "de": "German", "it": "Italian", "ru": "Russian",
        "id": "Indonesian", "ar": "Arabic", "tr": "Turkish", "pl": "Polish", "vi": "Vietnamese",
        "th": "Thai", "ja": "Japanese", "ko": "Korean", "zh": "Chinese", "zh-hans": "Chinese",
        "zh-hant": "Chinese (Trad.)", "uk": "Ukrainian", "fa": "Persian", "nl": "Dutch",
        "multi": "Multi-language", "all": "Multi-language",
        "bg": "Bulgarian", "bn": "Bengali", "ca": "Catalan", "cs": "Czech", "da": "Danish",
        "el": "Greek", "fi": "Finnish", "he": "Hebrew", "hi": "Hindi", "hr": "Croatian",
        "hu": "Hungarian", "is": "Icelandic", "kn": "Kannada", "ml": "Malayalam", "ms": "Malay",
        "ne": "Nepali", "no": "Norwegian", "ro": "Romanian", "sk": "Slovak", "sl": "Slovenian",
        "sq": "Albanian", "sr": "Serbian", "sv": "Swedish", "ta": "Tamil", "ur": "Urdu",
        "fil": "Filipino", "mn": "Mongolian", "ka": "Georgian",
    ]

    static func label(for lang: String) -> String {
        let raw = lang.lowercased()
        guard !raw.isEmpty else { return "Other" }
        if let name = map[raw] { return name }
        if raw.count > 2, let name = map[String(raw.prefix(2))] { return name }
        return raw.uppercased()
    }
}

/// One entry in the Explore language-filter dropdown: a language code, its friendly label,
/// and how many sources report it. Mirrors nyora-web's `languageOptions`.
struct LanguageOption: Identifiable, Hashable {
    let code: String
    let label: String
    let count: Int
    var id: String { code }

    /// Distinct languages across `sources`, sorted by count desc then label — for the dropdown.
    static func options(from sources: [SourceSummary]) -> [LanguageOption] {
        var counts: [String: Int] = [:]
        for s in sources { counts[s.languageCode, default: 0] += 1 }
        return counts
            .map { LanguageOption(code: $0.key, label: LanguageNames.label(for: $0.key), count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.label < $1.label }
    }
}

struct ChapterSummary: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let pages: [PageSummary]
}

struct PageSummary: Identifiable, Hashable, Codable {
    let url: String
    var id: String { url }
}
