import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var mangas: [MangaSummary] = []
    @Published var sources: [SourceSummary] = []
    @Published var browseMangas: [MangaSummary] = []
    @Published var activeMangaDetails: HelperDetailsResponse?
    @Published var activeChapter: ChapterSummary?
    @Published var isLoading: Bool = false
    @Published var statusMessage: String?
    @Published var libraryQuery: String = ""
    @Published var helperBaseUrl: String = ""
    @Published var helperStatus: HelperStatus = .stopped
    @Published var selectedSourceId: String?
    @Published var pendingNavigation: NavDestination?
    @Published var catalog: [HelperCatalogEntry] = []
    @Published var isCatalogPresented: Bool = false
    @Published var isCatalogLoading: Bool = false
    @Published var history: [HelperHistoryRow] = []
    @Published var favourites: [HelperManga] = []
    @Published var detailsIsFavourited: Bool = false
    @Published var bookmarks: [HelperBookmark] = []
    @Published var currentPageBookmarked: Bool = false
    @Published var updates: [HelperUpdate] = []
    @Published var isRefreshingUpdates: Bool = false
    @Published var localFolder: String = UserDefaults.standard.string(forKey: "nyora.local.folder") ?? "" {
        didSet { UserDefaults.standard.set(localFolder, forKey: "nyora.local.folder") }
    }
    @Published var localEntries: [HelperLocalCbz] = []

    // Reader state
    @Published var readerMode: ReaderMode = .paged
    @Published var readerPageIndex: Int = 0
    @Published var readerChapters: [HelperChapter] = []
    @Published var readerChapterIndex: Int = 0
    @Published var readerMangaId: String = ""
    @Published var readerMangaTitle: String = ""
    @Published var rtlReading: Bool = UserDefaults.standard.bool(forKey: "nyora.reader.rtl") {
        didSet { UserDefaults.standard.set(rtlReading, forKey: "nyora.reader.rtl") }
    }

    let helper = NyoraHelperBridge()
    let readerPrefs = ReaderPrefs()

    func bootstrap() async {
        statusMessage = "Locating Nyora helper…"
        await helper.start { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.helperStatus = state.status
                self.helperBaseUrl = state.baseUrl
                if state.status == .running {
                    self.statusMessage = "Helper ready"
                    await self.refreshSources()
                    await self.reloadHistory()
                    await self.reloadFavourites()
                    await self.reloadBookmarks()
                    await self.reloadUpdates()
                    if let pinned = self.sources.first(where: { $0.isPinned && $0.isInstalled }) {
                        self.selectedSourceId = pinned.id
                        await self.loadPopular(sourceId: pinned.id)
                    }
                } else if let error = state.error {
                    self.statusMessage = "Helper not ready: \(error)"
                }
            }
        }
    }

    func refreshSources() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let list = try await helper.fetchSources()
            sources = list
        } catch {
            statusMessage = "Failed to load sources: \(error.localizedDescription)"
        }
    }

    func reloadCatalog() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sources = try await helper.refreshSources()
            statusMessage = "Loaded \(sources.count) sources"
        } catch {
            statusMessage = "Catalog refresh failed: \(error.localizedDescription)"
        }
    }

    func loadPopular(sourceId: String) async {
        guard !sourceId.isEmpty else { return }
        selectedSourceId = sourceId
        isLoading = true
        defer { isLoading = false }
        do {
            browseMangas = try await helper.popular(sourceId: sourceId, page: 1)
        } catch {
            statusMessage = "Browse failed: \(error.localizedDescription)"
            browseMangas = []
        }
    }

    func searchActiveSource(query: String) async {
        guard let sid = selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id else {
            statusMessage = "No installed source to search"
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            await loadPopular(sourceId: sid)
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            browseMangas = try await helper.search(sourceId: sid, query: trimmed, page: 1)
        } catch {
            statusMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    func openDetails(_ manga: MangaSummary) async {
        guard let sid = selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id else {
            statusMessage = "No source selected"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let details = try await helper.details(sourceId: sid, mangaUrl: manga.id)
            activeMangaDetails = details
            await refreshDetailsFavouritedFlag()
            statusMessage = "Loaded \(details.chapters.count) chapters of \(details.manga.title)"
        } catch {
            statusMessage = "Details failed: \(error.localizedDescription)"
        }
    }

    func openChapter(_ chapter: HelperChapter) async {
        let chapters = activeMangaDetails?.chapters ?? []
        await openChapter(chapter, in: chapters)
    }

    func openChapter(_ chapter: HelperChapter, in chapters: [HelperChapter]) async {
        guard let sid = selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id else {
            statusMessage = "No source selected"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let pages = try await helper.pages(sourceId: sid, chapterUrl: chapter.url)
            let proxied = await pages.asyncMap { page -> PageSummary in
                if let url = await self.helper.imageProxyURL(for: page) {
                    return PageSummary(url: url.absoluteString)
                }
                return PageSummary(url: page.url)
            }
            activeChapter = ChapterSummary(id: chapter.url, title: chapter.title, pages: proxied)
            readerChapters = chapters
            readerChapterIndex = chapters.firstIndex(of: chapter) ?? 0
            if let details = activeMangaDetails {
                readerMangaId = details.manga.id
                readerMangaTitle = details.manga.title
                // Resume from saved page if the user was previously on this chapter.
                let resume = history.first { $0.mangaId == details.manga.id && $0.chapterId == chapter.url }
                readerPageIndex = min(resume?.page ?? 0, max(proxied.count - 1, 0))
            } else {
                readerPageIndex = 0
            }
            pendingNavigation = .reader
            await persistReaderPosition()
        } catch {
            statusMessage = "Pages failed: \(error.localizedDescription)"
        }
    }

    /// Persist the current reader position to history. Safe to call frequently.
    func persistReaderPosition() async {
        guard !readerMangaId.isEmpty, let chapter = activeChapter else { return }
        let pageCount = max(chapter.pages.count, 1)
        let percent = Float(readerPageIndex + 1) / Float(pageCount)
        try? await helper.recordHistory(
            mangaId: readerMangaId,
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            page: readerPageIndex,
            percent: percent
        )
    }

    func gotoChapterRelative(_ delta: Int) async {
        let newIndex = readerChapterIndex + delta
        guard readerChapters.indices.contains(newIndex) else { return }
        // Forget the saved page so we start at 0 in the new chapter.
        if let details = activeMangaDetails {
            history.removeAll { $0.mangaId == details.manga.id && $0.chapterId == readerChapters[newIndex].url }
        }
        readerPageIndex = 0
        await openChapter(readerChapters[newIndex], in: readerChapters)
    }

    func install(_ source: SourceSummary) async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await helper.install(sourceId: source.id)
            sources = try await helper.fetchSources()
            statusMessage = "Installed \(source.name)"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    func installFromCatalog(_ entry: HelperCatalogEntry) async {
        do {
            _ = try await helper.install(sourceId: entry.id)
            sources = try await helper.fetchSources()
            catalog = (try? await helper.catalog()) ?? catalog
            statusMessage = "Installed \(entry.name)"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    func openCatalog() async {
        isCatalogPresented = true
        if catalog.isEmpty { await reloadCatalogEntries() }
    }

    func reloadCatalogEntries() async {
        isCatalogLoading = true
        defer { isCatalogLoading = false }
        do {
            catalog = try await helper.catalog()
        } catch {
            statusMessage = "Catalog load failed: \(error.localizedDescription)"
        }
    }

    // MARK: - history + favourites

    func reloadHistory() async {
        do {
            history = try await helper.history()
        } catch {
            statusMessage = "History load failed: \(error.localizedDescription)"
        }
    }

    func reloadFavourites() async {
        do {
            favourites = try await helper.favourites()
        } catch {
            statusMessage = "Favourites load failed: \(error.localizedDescription)"
        }
    }

    func toggleDetailsFavourite() async {
        guard let details = activeMangaDetails else { return }
        do {
            let now = try await helper.toggleFavourite(mangaId: details.manga.id)
            detailsIsFavourited = now
            statusMessage = now ? "Added \(details.manga.title) to favourites" : "Removed from favourites"
            await reloadFavourites()
        } catch {
            statusMessage = "Favourite toggle failed: \(error.localizedDescription)"
        }
    }

    func refreshDetailsFavouritedFlag() async {
        guard let details = activeMangaDetails else {
            detailsIsFavourited = false
            return
        }
        detailsIsFavourited = (try? await helper.isFavourited(mangaId: details.manga.id)) ?? false
    }

    // MARK: - bookmarks

    func reloadBookmarks() async {
        do {
            bookmarks = try await helper.bookmarks()
        } catch {
            statusMessage = "Bookmark load failed: \(error.localizedDescription)"
        }
    }

    func refreshCurrentPageBookmarkedFlag() async {
        guard !readerMangaId.isEmpty, let chapter = activeChapter else {
            currentPageBookmarked = false
            return
        }
        currentPageBookmarked = (try? await helper.isPageBookmarked(
            mangaId: readerMangaId,
            chapterId: chapter.id,
            page: readerPageIndex
        )) ?? false
    }

    func toggleCurrentPageBookmark() async {
        guard !readerMangaId.isEmpty, let chapter = activeChapter else { return }
        do {
            if currentPageBookmarked {
                try await helper.removeBookmarkForPage(
                    mangaId: readerMangaId,
                    chapterId: chapter.id,
                    page: readerPageIndex
                )
                currentPageBookmarked = false
                statusMessage = "Bookmark removed"
            } else {
                try await helper.addBookmark(
                    mangaId: readerMangaId,
                    chapterId: chapter.id,
                    chapterTitle: chapter.title,
                    page: readerPageIndex,
                    note: ""
                )
                currentPageBookmarked = true
                statusMessage = "Bookmarked page \(readerPageIndex + 1)"
            }
            await reloadBookmarks()
        } catch {
            statusMessage = "Bookmark failed: \(error.localizedDescription)"
        }
    }

    // MARK: - updates

    func reloadUpdates() async {
        do {
            updates = try await helper.updates()
        } catch {
            statusMessage = "Updates load failed: \(error.localizedDescription)"
        }
    }

    func refreshUpdates() async {
        isRefreshingUpdates = true
        defer { isRefreshingUpdates = false }
        do {
            let result = try await helper.refreshUpdates()
            statusMessage = "Checked \(result.checked) favourites · \(result.withNew) with new chapters"
            await reloadUpdates()
        } catch {
            statusMessage = "Updates refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - local CBZ

    func scanLocalFolder() async {
        guard !localFolder.isEmpty else { return }
        do {
            localEntries = try await helper.scanLocalFolder(localFolder)
        } catch {
            statusMessage = "Local scan failed: \(error.localizedDescription)"
            localEntries = []
        }
    }

    func openLocalCbz(_ entry: HelperLocalCbz) async {
        do {
            let chapter = try await helper.openLocalChapter(entry.path)
            let pages = chapter.pageUrls.map { PageSummary(url: $0) }
            activeChapter = ChapterSummary(id: entry.path, title: chapter.name, pages: pages)
            readerChapters = []   // local CBZ is standalone
            readerChapterIndex = 0
            readerMangaId = "local:\(entry.path)"
            readerMangaTitle = entry.name
            readerPageIndex = 0
            pendingNavigation = .reader
            statusMessage = "Opened \(entry.name) (\(chapter.pageCount) pages)"
        } catch {
            statusMessage = "Failed to open: \(error.localizedDescription)"
        }
    }

    func markUpdatesSeen(_ mangaId: String) async {
        do {
            try await helper.markUpdatesSeen(mangaId: mangaId)
            await reloadUpdates()
        } catch {
            statusMessage = "Mark-seen failed: \(error.localizedDescription)"
        }
    }

    func openBookmark(_ bookmark: HelperBookmark) async {
        // Try to find the manga in details / favourites / sources, otherwise
        // try resolving via /manga/details. For now keep it simple: only handle
        // bookmarks for the currently-loaded manga.
        guard let details = activeMangaDetails,
              details.manga.id == bookmark.mangaId
        else {
            statusMessage = "Open this manga from Explore first to jump to a bookmark."
            return
        }
        if let chapter = details.chapters.first(where: { $0.url == bookmark.chapterId }) {
            await openChapter(chapter, in: details.chapters)
            readerPageIndex = bookmark.page
            pendingNavigation = .reader
            await persistReaderPosition()
        } else {
            statusMessage = "Couldn't find that chapter in the current manga."
        }
    }

    func uninstall(_ source: SourceSummary) async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await helper.uninstall(sourceId: source.id)
            sources = try await helper.fetchSources()
            statusMessage = "Uninstalled \(source.name)"
        } catch {
            statusMessage = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    func restartHelper() async {
        await helper.stop()
        await bootstrap()
    }

    func shutdownHelper() async {
        await helper.stop()
    }

    func clearMessage() { statusMessage = nil }

    func consumeNavigation() -> NavDestination? {
        let pending = pendingNavigation
        pendingNavigation = nil
        return pending
    }
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case paged
    case webtoon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .paged: return "Paged"
        case .webtoon: return "Webtoon"
        }
    }
    var systemImage: String {
        switch self {
        case .paged: return "rectangle.stack"
        case .webtoon: return "arrow.down.forward.and.arrow.up.backward.rectangle"
        }
    }
}

enum HelperStatus: Equatable {
    case stopped, starting, running, error

    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .error: return "Error"
        }
    }

    var color: Color {
        switch self {
        case .stopped: return .secondary
        case .starting: return .orange
        case .running: return .green
        case .error: return .red
        }
    }
}

private extension Collection {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        out.reserveCapacity(self.count)
        for el in self {
            out.append(await transform(el))
        }
        return out
    }
}
