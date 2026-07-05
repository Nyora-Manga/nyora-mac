import Foundation

/// Decoded shapes that mirror what NyoraRestServer encodes.
/// Property names match the Kotlin field names so default JSON decoding works.

struct HelperSourcesResponse: Decodable {
    let sources: [HelperSource]
}

struct HelperSourceResponse: Decodable {
    let source: HelperSource
}

struct HelperSource: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let lang: String
    let baseUrl: String
    let packageName: String
    let sourceCodeUrl: String
    let iconUrl: String
    let version: String
    let versionCode: Int
    let isInstalled: Bool
    let isPinned: Bool
    let isNsfw: Bool
    let isObsolete: Bool
    let engine: String
    let contentType: String
    let notes: String
    let localPath: String
    let installedAt: Int
    let canUninstall: Bool
}

struct HelperBrowseResponse: Decodable {
    let entries: [HelperManga]
    let hasNextPage: Bool
}

struct HelperDetailsResponse: Decodable {
    var manga: HelperManga
    let chapters: [HelperChapter]
}

struct HelperPagesResponse: Decodable {
    let pages: [HelperImagePage]
}

struct HelperManga: Decodable, Identifiable, Hashable {
    let id: String
    var title: String
    let altTitles: [String]
    let url: String
    let publicUrl: String
    let rating: Float
    let isNsfw: Bool
    var coverUrl: String
    let largeCoverUrl: String?
    let authors: [String]
    let description: String
    let tags: [HelperTag]
    let chapters: [HelperChapter]
    let unread: Int
    let progress: Float
}

struct HelperChapter: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let number: Float
    let volume: Int
    let url: String
    let scanlator: String?
    let uploadDate: Int
    let branch: String?
    let pages: [HelperImagePage]
    let index: Int
}

struct HelperImagePage: Decodable, Hashable {
    let url: String
    let headers: [String: String]
}

struct HelperTag: Decodable, Hashable {
    let key: String
    let title: String
}

struct HelperError: Decodable, LocalizedError {
    let error: String
    var errorDescription: String? { error }

    /// The helper signals a Cloudflare JS challenge as "Cloudflare challenge: <host>".
    /// Returns the host so the app can solve it in a WebView and push the clearance back.
    var cloudflareHost: String? {
        let marker = "Cloudflare challenge: "
        guard error.hasPrefix(marker) else { return nil }
        let host = error.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? nil : host
    }
}

struct HelperCatalogResponse: Decodable {
    let entries: [HelperCatalogEntry]
}

struct HelperCatalogEntry: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let lang: String
    let engine: String
    let contentType: String
    let isBroken: Bool
    let isInstalled: Bool
}

struct HelperHistoryResponse: Decodable {
    let entries: [HelperHistoryRow]
}

struct HelperHistoryRow: Decodable, Identifiable, Hashable {
    let mangaId: String
    let mangaUrl: String
    let mangaTitle: String
    let mangaCoverUrl: String
    let sourceId: String
    let sourceName: String
    let chapterId: String
    let chapterTitle: String
    let page: Int
    let percent: Float
    let updatedAt: Int64
    var id: String { mangaId + "/" + chapterId }
}

struct HelperFavouritesResponse: Decodable {
    let entries: [HelperManga]
}

struct HelperFavouritedResponse: Decodable {
    let favourited: Bool
}

struct HelperBookmarksResponse: Decodable {
    let entries: [HelperBookmark]
}

struct HelperBookmark: Decodable, Identifiable, Hashable {
    let id: Int64
    let mangaId: String
    let mangaTitle: String
    let mangaCoverUrl: String
    let chapterId: String
    let chapterTitle: String
    let page: Int
    let note: String
    let createdAt: Int64
}

struct HelperBookmarkedResponse: Decodable {
    let bookmarked: Bool
}

struct HelperUpdatesResponse: Decodable {
    let entries: [HelperUpdate]
}

struct HelperUpdate: Decodable, Identifiable, Hashable {
    let mangaId: String
    let mangaTitle: String
    let mangaCoverUrl: String
    let sourceId: String
    let newChapters: Int
    let totalChapters: Int
    let latestChapterTitle: String
    let lastSyncedAt: Int64
    var id: String { mangaId }
}

struct HelperUpdatesRefreshResult: Decodable {
    let checked: Int
    let withNew: Int
}

struct HelperLocalScanResponse: Decodable {
    let entries: [HelperLocalCbz]
}

struct HelperLocalCbz: Decodable, Identifiable, Hashable {
    let path: String
    let name: String
    let sizeBytes: Int64
    var id: String { path }
}

struct HelperLocalChapter: Decodable {
    let name: String
    let pageCount: Int
    let pageUrls: [String]
}

// MARK: - Categories

struct HelperCategoriesResponse: Decodable {
    let categories: [HelperCategory]
}

struct HelperCategory: Decodable, Identifiable, Hashable {
    let id: Int64
    let title: String
    let mangaCount: Int
}

// MARK: - Per-manga prefs

struct HelperMangaPrefs: Decodable {
    var mangaId: String?
    var readerMode: String?
    var brightness: Double?
    var contrast: Double?
    var saturation: Double?
    var hue: Double?
    var palette: String?
    var present: Bool
}

// MARK: - Downloads

struct HelperDownloadsResponse: Decodable { let entries: [HelperDownload] }
struct HelperDownloadResponse: Decodable { let entry: HelperDownload }

struct HelperDownloadSettings: Decodable, Hashable {
    let maxConcurrentDownloads: Int
    let format: String   // AUTO | FOLDER | CBZ | ZIP
}
struct HelperDownloadSettingsResponse: Decodable { let settings: HelperDownloadSettings }

struct HelperDownload: Decodable, Identifiable, Hashable {
    let id: String
    let sourceId: String
    let mangaTitle: String
    let chapterTitle: String
    let chapterUrl: String
    let totalPages: Int
    let completedPages: Int
    let failedPages: Int
    let status: String
    let filePath: String?
    let error: String?
    let startedAt: Int64
    let finishedAt: Int64?

    var progressFraction: Double {
        guard totalPages > 0 else { return 0 }
        return Double(completedPages) / Double(totalPages)
    }
    var isTerminal: Bool { status == "COMPLETED" || status == "FAILED" || status == "CANCELLED" }
}

// MARK: - Global search

struct HelperGlobalSearchResponse: Decodable {
    let query: String
    let groups: [HelperGlobalSearchGroup]
}

struct HelperGlobalSearchGroup: Decodable, Identifiable, Hashable {
    let sourceId: String
    let sourceName: String
    let entries: [HelperManga]
    let error: String?
    var id: String { sourceId }
}

// MARK: - Stats / suggestions / alternatives / backup / filters

struct HelperStats: Decodable {
    let totalChapters: Int
    let distinctManga: Int
    let favouritesCount: Int
    let longestStreakDays: Int
    let topSources: [HelperStatsSource]
}

struct HelperStatsSource: Decodable, Identifiable, Hashable {
    let sourceId: String
    let sourceName: String
    let count: Int
    var id: String { sourceId }
}

struct HelperSuggestions: Decodable {
    let entries: [HelperSuggestedManga]
}

struct HelperSuggestedManga: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let coverUrl: String
    let sourceId: String
    let publicUrl: String
    let description: String
}

struct HelperAlternatives: Decodable {
    let entries: [HelperAlternativeMatch]
}

struct HelperAlternativeMatch: Decodable, Hashable, Identifiable {
    let sourceId: String
    let sourceName: String
    let manga: HelperSuggestedManga
    var id: String { sourceId + "/" + manga.id }
}

struct HelperBackupImportResult: Decodable {
    let ok: Bool
    let importedFavourites: Int
    let importedHistory: Int
}

struct HelperSourceFilters: Decodable {
    let filters: [HelperSourceFilter]
}

struct HelperSourceFilter: Decodable, Identifiable, Hashable {
    let name: String
    let typeName: String
    let values: [String]
    var id: String { name }
}

// MARK: - Tracker (AniList)

struct AniListSearchResponse: Decodable {
    let data: AniListSearchData?
}
struct AniListSearchData: Decodable { let Page: AniListSearchPage? }
struct AniListSearchPage: Decodable { let media: [AniListMedia] }
struct AniListMedia: Decodable, Identifiable, Hashable {
    let id: Int
    let title: AniListTitle
    let coverImage: AniListCover?
    let chapters: Int?
    var bestTitle: String { title.romaji ?? title.english ?? title.native ?? "Untitled" }
}
struct AniListTitle: Decodable, Hashable {
    let romaji: String?
    let english: String?
    let native: String?
}
struct AniListCover: Decodable, Hashable { let large: String? }

// MARK: - AniList browse feed (public GraphQL — trending / popular / top-rated)

struct AniListBrowseResponse: Decodable {
    let data: AniListBrowseData?
}

struct AniListBrowseData: Decodable {
    let trending: AniListBrowsePage?
    let popular: AniListBrowsePage?
    let topRated: AniListBrowsePage?
}

struct AniListBrowsePage: Decodable {
    let media: [AniListBrowseMedia]
}

struct AniListBrowseMedia: Decodable, Identifiable, Hashable {
    let id: Int
    let title: AniListTitle
    let coverImage: AniListCover?
    let isAdult: Bool?
    let genres: [String]?
    let averageScore: Int?

    var bestTitle: String { title.english ?? title.romaji ?? title.native ?? "Untitled" }
    var coverURL: String { coverImage?.large ?? "" }
    var topGenre: String? { genres?.first }
}

// MARK: - MangaBaka discovery feed (public REST — search-first, ranked client-side)
//
// AniList disabled its public API, so the discovery feed now comes from the
// MangaBaka series database (https://api.mangabaka.dev). The API is search-first
// (there is NO trending/sort endpoint), so we fetch broad/filtered searches and
// rank them client-side by global popularity or rating. Response shape:
//   { status, pagination, data:[ series ] }
// Each series is mapped onto the existing `AniListBrowseMedia` shape so the
// FeedView UI is unchanged.

struct MangaBakaSearchResponse: Decodable {
    let data: [MangaBakaSeries]?
}

struct MangaBakaImage: Decodable { let x1: String? }
struct MangaBakaRaw: Decodable { let url: String? }

struct MangaBakaCover: Decodable {
    let x350: MangaBakaImage?
    let x250: MangaBakaImage?
    let raw: MangaBakaRaw?
}

struct MangaBakaPopularityGlobal: Decodable { let current: Int? }
struct MangaBakaPopularity: Decodable { let global: MangaBakaPopularityGlobal? }

struct MangaBakaSeries: Decodable {
    let id: Int?
    let title: String?
    let romanizedTitle: String?
    let nativeTitle: String?
    let cover: MangaBakaCover?
    let genres: [String]?
    let rating: Double?
    let popularity: MangaBakaPopularity?
    let type: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case id, title, cover, genres, rating, popularity, type, state
        case romanizedTitle = "romanized_title"
        case nativeTitle = "native_title"
    }

    /// Sortable global-popularity number pulled out of the nested shape.
    var popularityScore: Int { popularity?.global?.current ?? 0 }

    /// Best available cover: prefer CDN thumbnails, fall back to the raw image.
    var coverURL: String { cover?.x350?.x1 ?? cover?.x250?.x1 ?? cover?.raw?.url ?? "" }

    var displayTitle: String { title ?? romanizedTitle ?? nativeTitle ?? "Untitled" }

    /// Worth showing only with a cover and a real title — the DB is full of
    /// 1–2 char placeholder / merged entries we don't want on the grid.
    var isUsable: Bool {
        state != "merged"
            && !coverURL.isEmpty
            && (title ?? "").trimmingCharacters(in: .whitespaces).count >= 3
    }

    /// "school_life" -> "School Life"
    private static func prettyGenre(_ g: String) -> String {
        g.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Map onto the AniList-media shape the FeedView already renders.
    func toBrowseMedia() -> AniListBrowseMedia {
        AniListBrowseMedia(
            id: id ?? abs(displayTitle.hashValue),
            title: AniListTitle(
                romaji: romanizedTitle ?? displayTitle,
                english: title ?? displayTitle,
                native: nativeTitle
            ),
            coverImage: AniListCover(large: coverURL),
            isAdult: false,
            genres: (genres ?? []).map { Self.prettyGenre($0) },
            averageScore: rating.map { Int($0.rounded()) }
        )
    }
}
