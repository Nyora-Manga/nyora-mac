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
    let manga: HelperManga
    let chapters: [HelperChapter]
}

struct HelperPagesResponse: Decodable {
    let pages: [HelperImagePage]
}

struct HelperManga: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let altTitles: [String]
    let url: String
    let publicUrl: String
    let rating: Float
    let isNsfw: Bool
    let coverUrl: String
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
    let mangaTitle: String
    let mangaCoverUrl: String
    let sourceName: String
    let chapterId: String
    let chapterTitle: String
    let page: Int
    let percent: Float
    let updatedAt: Int64
    var id: String { mangaId }
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
