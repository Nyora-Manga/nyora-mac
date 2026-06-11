import Foundation
import CoreSpotlight
import CoreServices
import UniformTypeIdentifiers

/// Indexes the user's library (favourites + history) into CoreSpotlight so that
/// manga can be found via macOS system search. Each item's uniqueIdentifier is
/// "nyora.manga.<mangaId>", matching the nyora:// deep-link scheme.
enum SpotlightIndexer {

    private static let domainIdentifier = "com.nyora.manga"

    /// Build searchable items from favourites and history (deduped by manga id)
    /// and submit them to the default CoreSpotlight index. Runs off the main
    /// thread; errors are ignored quietly.
    static func index(favourites: [HelperManga], history: [HelperHistoryRow]) {
        DispatchQueue.global(qos: .utility).async {
            var seen = Set<String>()
            var items: [CSSearchableItem] = []

            for manga in favourites {
                guard !manga.id.isEmpty, seen.insert(manga.id).inserted else { continue }
                let author = manga.authors.first
                items.append(makeItem(
                    id: manga.id,
                    title: manga.title,
                    description: author,
                    coverUrl: manga.largeCoverUrl ?? manga.coverUrl
                ))
            }

            for row in history {
                guard !row.mangaId.isEmpty, seen.insert(row.mangaId).inserted else { continue }
                let source = row.sourceName.isEmpty ? nil : row.sourceName
                items.append(makeItem(
                    id: row.mangaId,
                    title: row.mangaTitle,
                    description: source,
                    coverUrl: row.mangaCoverUrl
                ))
            }

            guard !items.isEmpty else { return }
            CSSearchableIndex.default().indexSearchableItems(items) { _ in }
        }
    }

    /// Remove every item this app has indexed.
    static func deindexAll() {
        CSSearchableIndex.default().deleteAllSearchableItems { _ in }
    }

    // MARK: - Private

    private static func makeItem(id: String, title: String, description: String?, coverUrl: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title
        if let description, !description.isEmpty {
            attributes.contentDescription = description
        }
        if let url = URL(string: coverUrl), url.scheme != nil {
            attributes.thumbnailURL = url
        }
        attributes.keywords = ["manga", title]

        return CSSearchableItem(
            uniqueIdentifier: "nyora.manga.\(id)",
            domainIdentifier: domainIdentifier,
            attributeSet: attributes
        )
    }
}
