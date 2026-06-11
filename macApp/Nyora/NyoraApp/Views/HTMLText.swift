import SwiftUI
import AppKit

/// Renders a possibly-HTML string as styled text. Sources hand back things
/// like `<p>...<br><i>...</i></p>` for manga descriptions; raw `Text` would
/// show the tags literally.
///
/// Strategy:
///  - Parse the HTML once via `NSAttributedString` with `documentType: .html`
///    (this uses WebKit under the hood — relatively expensive, ~5–20 ms per
///    typical description).
///  - Cache the resulting `AttributedString` keyed by the raw HTML so we don't
///    re-parse on every redraw.
///  - Strip any embedded color/font from the parsed result so it inherits the
///    SwiftUI environment (system font, label color, dynamic type).
///
/// Falls back to a regex-stripped plain string if HTML parsing fails.
struct HTMLText: View {
    let html: String

    var body: some View {
        if let attributed = Self.attributedCache.value(for: html) {
            Text(attributed)
        } else {
            Text(Self.stripTags(html))
        }
    }

    /// Threadsafe-enough cache keyed on the raw HTML string.
    private static let attributedCache = HTMLCache()

    private static func stripTags(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class HTMLCache: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nyora.htmlcache", attributes: .concurrent)
    private var store: [String: AttributedString] = [:]

    func value(for html: String) -> AttributedString? {
        if let cached = queue.sync(execute: { store[html] }) {
            return cached
        }
        guard let parsed = Self.parse(html) else { return nil }
        queue.async(flags: .barrier) { [parsed] in self.store[html] = parsed }
        return parsed
    }

    /// Parses HTML into an AttributedString stripped of inline color/font so
    /// it inherits the current SwiftUI environment.
    private static func parse(_ html: String) -> AttributedString? {
        // Wrap so NSAttributedString picks up paragraph spacing sanely.
        let wrapped = """
        <span style="font-family: -apple-system; font-size: 14px; color: #000;">
        \(html.replacingOccurrences(of: "\n", with: "<br>"))
        </span>
        """
        guard let data = wrapped.data(using: .utf8) else { return nil }
        let opts: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        guard let ns = try? NSAttributedString(data: data, options: opts, documentAttributes: nil) else {
            return nil
        }
        // Strip color/font from the resulting NSAttributedString so SwiftUI's
        // environment colors take over.
        let mutable = NSMutableAttributedString(attributedString: ns)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.removeAttribute(.foregroundColor, range: full)
        mutable.removeAttribute(.backgroundColor, range: full)
        mutable.removeAttribute(.font, range: full)
        // Trim trailing whitespace/newlines NSAttributedString often leaves.
        var trimmed = mutable.string
        while trimmed.hasSuffix("\n") || trimmed.hasSuffix(" ") {
            mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
            trimmed = mutable.string
        }
        return try? AttributedString(mutable, including: \.swiftUI)
    }
}
