import Foundation
import SwiftUI
import Combine
import CoreImage.CIFilterBuiltins

/// Per-page translation snapshot consumed by the translation sheet.
struct PageTranslation {
    let pageImage: NSImage?
    let entries: [Entry]
    struct Entry: Identifiable, Hashable {
        let id = UUID()
        let original: String
        let translated: String
    }
}

@MainActor
final class ReaderState: ObservableObject {
    @Published var readerMode: ReaderMode = {
        let raw = UserDefaults.standard.string(forKey: "nyora.reader.mode") ?? "standard"
        return ReaderMode(rawValue: raw) ?? .standard
    }() {
        didSet { UserDefaults.standard.set(readerMode.rawValue, forKey: "nyora.reader.mode") }
    }
    @Published var readerPageIndex: Int = 0
    @Published var readerChapters: [HelperChapter] = []
    @Published var readerChapterIndex: Int = 0
    @Published var readerMangaId: String = ""
    @Published var readerMangaTitle: String = ""
    @Published var rtlReading: Bool = UserDefaults.standard.bool(forKey: "nyora.reader.rtl") {
        didSet { UserDefaults.standard.set(rtlReading, forKey: "nyora.reader.rtl") }
    }
    @Published var activeChapter: ChapterSummary?
}

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var currentPageTranslation: [TranslatedBlock] = []
    @Published var currentPageImageSize: CGSize = .zero
    @Published var isTranslatingPage: Bool = false
    @Published var translateModeOn: Bool = false
    @Published var translationSheetPage: PageTranslation? = nil
    @Published var translationSheetLoading: Bool = false
    @Published var paintedPageURL: String? = nil
    @Published var paintedPageImage: NSImage? = nil
    @Published var inImageBalloons: [InImageBalloon] = []
    @Published var inImageImageSize: CGSize = .zero
    @Published var inImageBalloonsPageURL: String? = nil
    @Published var translationStage: TranslationStage = .idle
    @Published var translationStageTimings: [String: TimeInterval] = [:]
    @Published var debugHUDEnabled: Bool = UserDefaults.standard.bool(forKey: "nyora.debug.hud") {
        didSet { UserDefaults.standard.set(debugHUDEnabled, forKey: "nyora.debug.hud") }
    }
}

@MainActor
final class LibraryState: ObservableObject {
    @Published var history: [HelperHistoryRow] = []
    @Published var favourites: [HelperManga] = []
    @Published var bookmarks: [HelperBookmark] = []
    @Published var updates: [HelperUpdate] = []
    @Published var categories: [HelperCategory] = []
    @Published var selectedCategoryId: Int64? = nil
    @Published var favouritesInCategory: [HelperManga] = []
}

@MainActor
final class AppState: ObservableObject {
    @Published var mangas: [MangaSummary] = []
    @Published var sources: [SourceSummary] = []
    @Published var browseMangas: [MangaSummary] = []
    @Published var activeMangaDetails: HelperDetailsResponse?
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
    @Published var detailsIsFavourited: Bool = false
    @Published var currentPageBookmarked: Bool = false
    @Published var isRefreshingUpdates: Bool = false
    @Published var localFolder: String = UserDefaults.standard.string(forKey: "nyora.local.folder") ?? "" {
        didSet { UserDefaults.standard.set(localFolder, forKey: "nyora.local.folder") }
    }
    @Published var localEntries: [HelperLocalCbz] = []

    /// Non-nil drives the in-app browser sheet (presented by NyoraApp).
    @Published var inAppBrowserURL: URL? = nil

    // Ambient glow accent. Follows the user's chosen accent (Color.appAccent)
    // instead of a per-cover/purple colour, so every backdrop glow that reads
    // these renders in the accent. Names kept so existing call sites are unchanged.
    var activeCoverAccentPrimary: Color { Color.appAccent }
    var activeCoverAccentSecondary: Color { Color.appAccent }

    // Filter for NSFW sources
    @Published var hideNsfwSources: Bool = UserDefaults.standard.bool(forKey: "nyora.hideNsfw") {
        didSet { UserDefaults.standard.set(hideNsfwSources, forKey: "nyora.hideNsfw") }
    }
    var visibleSources: [SourceSummary] {
        hideNsfwSources ? sources.filter { !$0.isNsfw } : sources
    }

    // MARK: - Curated installed set (mirrors nyora-web)
    //
    // The web keeps the "installed" set client-side (localStorage), seeded from the
    // languages picked at onboarding, defaulting to "everything" when the user hasn't
    // customized. The shared engine can browse ANY source regardless of its `isInstalled`
    // flag ("just a UI guard"), so we replicate that here: a persisted id set that we
    // overlay onto every source/catalog list. `nil` ⇒ uncustomized (all sources count as
    // installed, exactly like the web's default).
    private static let curatedKey = "nyora.sources.curated.v1"
    @Published private(set) var curatedSourceIds: Set<String>? = {
        guard let arr = UserDefaults.standard.array(forKey: AppState.curatedKey) as? [String] else { return nil }
        return Set(arr)
    }()

    private func persistCuratedSources() {
        if let ids = curatedSourceIds {
            UserDefaults.standard.set(Array(ids), forKey: Self.curatedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.curatedKey)
        }
    }

    /// Overlay the curated set onto a freshly-fetched source list. With no curation the
    /// engine's own flags stand; otherwise `isInstalled` reflects the curated set.
    private func applyingCuration(_ list: [SourceSummary]) -> [SourceSummary] {
        guard let ids = curatedSourceIds else { return list }
        return list.map { $0.withInstalled(ids.contains($0.id)) }
    }

    private func applyingCuration(catalog list: [HelperCatalogEntry]) -> [HelperCatalogEntry] {
        guard let ids = curatedSourceIds else { return list }
        return list.map { $0.withInstalled(ids.contains($0.id)) }
    }

    /// Central setters so every load path applies curation consistently.
    private func setSources(_ list: [SourceSummary]) { sources = applyingCuration(list) }
    private func setCatalog(_ list: [HelperCatalogEntry]) { catalog = applyingCuration(catalog: list) }

    /// Materialize the curated set from the current installed sources when it's still `nil`
    /// (uncustomized). Needed before an individual install/uninstall can mutate it — the web
    /// does the same (its default `null` set expands to "all catalog ids" on first edit).
    private func materializeCuration() {
        guard curatedSourceIds == nil else { return }
        let base = sources.isEmpty ? [] : sources.filter(\.isInstalled).map(\.id)
        curatedSourceIds = Set(base)
    }

    // MARK: - Explore source picker (recents + pinning)

    /// Recently-used source ids, most-recent first (persisted). Powers the source picker's
    /// Recents section so the user isn't scrolling a flat 468-source list to switch.
    @Published var recentSourceIds: [String] =
        (UserDefaults.standard.array(forKey: "nyora.explore.recentSources") as? [String]) ?? []

    /// Push a source to the front of the MRU list. Called when a source is opened.
    func pushRecentSource(_ id: String) {
        guard !id.isEmpty else { return }
        var list = recentSourceIds.filter { $0 != id }
        list.insert(id, at: 0)
        recentSourceIds = Array(list.prefix(8))
        UserDefaults.standard.set(recentSourceIds, forKey: "nyora.explore.recentSources")
    }

    /// Pin / unpin a source (the engine's togglePin endpoint — previously unreachable from the
    /// UI). Updates the source list in place so the picker's Pinned section reflects it.
    func togglePinSource(_ id: String) async {
        guard let updated = try? await helper.togglePin(sourceId: id) else { return }
        setSources(updated)
    }

    /// The currently-selected source, resolved from the list.
    var activeSourceSummary: SourceSummary? {
        guard let id = selectedSourceId else { return nil }
        return sources.first { $0.id == id }
    }

    // Downloads
    @Published var downloads: [HelperDownload] = []
    @Published var downloadSettings: HelperDownloadSettings? = nil
    @Published var isBrowseLoading: Bool = false
    @Published var isDetailLoading: Bool = false
    @Published var selectedBrowseMangaId: String?

    // Per-manga reader prefs cache
    @Published var perMangaPrefsCache: [String: HelperMangaPrefs] = [:]

    // Global search
    @Published var isGlobalSearchPresented: Bool = false
    @Published var isGlobalSearching: Bool = false
    @Published var globalSearchQuery: String = ""
    @Published var globalSearchResults: [HelperGlobalSearchGroup] = []

    // Nyora Sync
    @Published var nyoraSyncStatus: NyoraSyncStatusResponse? = nil
    @Published var isNyoraSyncing: Bool = false
    @Published var isNyoraSyncSigningIn: Bool = false

    // Domain-scoped child observable objects
    let readerState = ReaderState()
    let translationState = TranslationViewModel()
    let libraryState = LibraryState()

    // Forwarding accessors — keep existing call sites compiling unchanged
    var activeChapter: ChapterSummary? {
        get { readerState.activeChapter }
        set { readerState.activeChapter = newValue }
    }
    var readerMode: ReaderMode {
        get { readerState.readerMode }
        set { readerState.readerMode = newValue }
    }
    var readerPageIndex: Int {
        get { readerState.readerPageIndex }
        set { readerState.readerPageIndex = newValue }
    }
    var readerChapters: [HelperChapter] {
        get { readerState.readerChapters }
        set { readerState.readerChapters = newValue }
    }
    var readerChapterIndex: Int {
        get { readerState.readerChapterIndex }
        set { readerState.readerChapterIndex = newValue }
    }
    var readerMangaId: String {
        get { readerState.readerMangaId }
        set { readerState.readerMangaId = newValue }
    }
    var readerMangaTitle: String {
        get { readerState.readerMangaTitle }
        set { readerState.readerMangaTitle = newValue }
    }
    /// Right-to-left reading. SINGLE source of truth = `readerMode`: `.reversed`
    /// is paged-RTL, `.standard` is paged-LTR. Deriving it from the mode (instead
    /// of a separate bool) keeps taps, arrow keys, double-page order and the
    /// page-curl all in agreement. RTL only applies to the paged modes.
    var rtlReading: Bool {
        get { readerMode.isRTL }
        set {
            guard readerMode == .standard || readerMode == .reversed else { return }
            readerMode = newValue ? .reversed : .standard
        }
    }
    var currentPageTranslation: [TranslatedBlock] {
        get { translationState.currentPageTranslation }
        set { translationState.currentPageTranslation = newValue }
    }
    var currentPageImageSize: CGSize {
        get { translationState.currentPageImageSize }
        set { translationState.currentPageImageSize = newValue }
    }
    var isTranslatingPage: Bool {
        get { translationState.isTranslatingPage }
        set { translationState.isTranslatingPage = newValue }
    }
    var translateModeOn: Bool {
        get { translationState.translateModeOn }
        set { translationState.translateModeOn = newValue }
    }
    var translationSheetPage: PageTranslation? {
        get { translationState.translationSheetPage }
        set { translationState.translationSheetPage = newValue }
    }
    var translationSheetLoading: Bool {
        get { translationState.translationSheetLoading }
        set { translationState.translationSheetLoading = newValue }
    }
    var paintedPageURL: String? {
        get { translationState.paintedPageURL }
        set { translationState.paintedPageURL = newValue }
    }
    var paintedPageImage: NSImage? {
        get { translationState.paintedPageImage }
        set { translationState.paintedPageImage = newValue }
    }
    var inImageBalloons: [InImageBalloon] {
        get { translationState.inImageBalloons }
        set { translationState.inImageBalloons = newValue }
    }
    var inImageImageSize: CGSize {
        get { translationState.inImageImageSize }
        set { translationState.inImageImageSize = newValue }
    }
    var inImageBalloonsPageURL: String? {
        get { translationState.inImageBalloonsPageURL }
        set { translationState.inImageBalloonsPageURL = newValue }
    }
    var translationStage: TranslationStage {
        get { translationState.translationStage }
        set { translationState.translationStage = newValue }
    }
    var translationStageTimings: [String: TimeInterval] {
        get { translationState.translationStageTimings }
        set { translationState.translationStageTimings = newValue }
    }
    var debugHUDEnabled: Bool {
        get { translationState.debugHUDEnabled }
        set { translationState.debugHUDEnabled = newValue }
    }
    var history: [HelperHistoryRow] {
        get { libraryState.history }
        set { libraryState.history = newValue }
    }
    var favourites: [HelperManga] {
        get { libraryState.favourites }
        set { libraryState.favourites = newValue }
    }
    var bookmarks: [HelperBookmark] {
        get { libraryState.bookmarks }
        set { libraryState.bookmarks = newValue }
    }
    var updates: [HelperUpdate] {
        get { libraryState.updates }
        set { libraryState.updates = newValue }
    }
    var categories: [HelperCategory] {
        get { libraryState.categories }
        set { libraryState.categories = newValue }
    }
    var selectedCategoryId: Int64? {
        get { libraryState.selectedCategoryId }
        set { libraryState.selectedCategoryId = newValue }
    }
    var favouritesInCategory: [HelperManga] {
        get { libraryState.favouritesInCategory }
        set { libraryState.favouritesInCategory = newValue }
    }

    let helper = NyoraHelperBridge()
    @Published var readerPrefs = ReaderPrefs()
    let translateSettings = TranslationSettings()
    let chapterTranslator = ChapterTranslator.shared
    /// Native ONNX manga colorizer (full manga-colorization-v2 pipeline, run on
    /// device). Reader binds to `colorizer.colorizedImages[pageIndex]`.
    let colorizer = NativeColorizer.shared
    /// Whether AI colorization is active for the current chapter (ephemeral,
    /// like `translateModeOn`). When on, opening/paging a chapter colorizes it.
    @Published var colorizeModeOn: Bool = false
    let tracker = TrackerSettings()

    /// Wall-clock time the current `translationStage` was entered. Used by
    /// `beginStage` / `finishStage` to compute per-stage durations.
    private var stageStartedAt: TimeInterval? = nil
    private var browseRequestToken = UUID()
    private var detailRequestToken = UUID()
    /// Supersedes an in-flight global search when a newer query starts, so late
    /// per-source results from a stale run never leak into the new result set.
    private var globalSearchToken = UUID()
    private var cancellables = Set<AnyCancellable>()

    func bootstrap() async {
        // CRITICAL: readerPageIndex / readerMode / activeChapter live on the child
        // ReaderState object. The reader tree observes AppState (@EnvironmentObject),
        // NOT ReaderState — so without this forward a page turn fires
        // readerState.objectWillChange into the void and the new page only appears
        // when the 2.5s idle-timer coincidentally repaints. UNTHROTTLED: page turns
        // are discrete user actions, not churn — any delay here IS the lag.
        readerState.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Throttled: dragging a Quick-Settings brightness/contrast/gamma/zoom slider
        // publishes at ~60-120Hz; coalesce so it can't thrash the whole reader tree.
        // Discrete toggles (two-page, mode, accent) still land within ~120ms.
        readerPrefs.objectWillChange
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward the nested translator/colorizer changes so the reader (which
        // observes AppState) re-renders the CURRENT page the instant a page is
        // painted/colorized. THROTTLED (~120 ms, latest wins) so the per-bubble /
        // per-progress churn during a chapter pass can't thrash the whole reader.
        chapterTranslator.objectWillChange
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        colorizer.objectWillChange
            .throttle(for: .milliseconds(120), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Dry-run installed OCR models on the GPU in the background so CoreML has
        // compiled their Metal programs before the first translated page needs them.
        Task { await NativeOcrProvider.shared.warmupInstalled() }

        await helper.start { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                self.helperStatus = state.status
                self.helperBaseUrl = state.baseUrl
                if state.status == .running {
                    // The helper is an implementation detail — starting it is not news.
                    // Only its *failure* (below) is worth interrupting the user for.
                    self.statusMessage = nil
                    // Fan-out the initial reloads in parallel — they touch
                    // disjoint helper endpoints, so serializing them just
                    // added latency on first launch.
                    async let sources = self.refreshSources()
                    async let history = self.reloadHistory()
                    async let favs = self.reloadFavourites()
                    async let bms = self.reloadBookmarks()
                    async let upd = self.reloadUpdates()
                    async let cats = self.reloadCategories()
                    async let dls = self.reloadDownloads()
                    async let sb = self.refreshNyoraSyncStatus()
                    _ = await (sources, history, favs, bms, upd, cats, dls, sb)
                    // Explore lands on the source-grid ("Manga sources") like the web —
                    // we deliberately do NOT auto-select a source here. The grid is the
                    // home of Explore; the user taps a source to browse it.
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
            setSources(list)
        } catch {
            statusMessage = "Failed to load sources: \(error.localizedDescription)"
        }
    }

    func reloadCatalog() async {
        isLoading = true
        defer { isLoading = false }
        do {
            setSources(try await helper.refreshSources())
            statusMessage = "Loaded \(sources.count) sources"
        } catch {
            statusMessage = "Catalog refresh failed: \(error.localizedDescription)"
        }
    }

    func loadPopular(sourceId: String) async {
        guard !sourceId.isEmpty else { return }
        pushRecentSource(sourceId)
        selectedSourceId = sourceId
        selectedBrowseMangaId = nil
        activeMangaDetails = nil
        detailsIsFavourited = false
        browseMangas = []
        isBrowseLoading = true
        let token = UUID()
        browseRequestToken = token
        do {
            let mangas = try await helper.popular(sourceId: sourceId, page: 1)
            guard browseRequestToken == token, selectedSourceId == sourceId else { return }
            browseMangas = mangas
        } catch {
            guard browseRequestToken == token else { return }
            statusMessage = "Browse failed: \(error.localizedDescription)"
            offerCloudflareSolve(for: sourceId)
            browseMangas = []
        }
        if browseRequestToken == token { isBrowseLoading = false }
    }

    func loadLatest(sourceId: String) async {
        guard !sourceId.isEmpty else { return }
        selectedSourceId = sourceId
        selectedBrowseMangaId = nil
        activeMangaDetails = nil
        detailsIsFavourited = false
        browseMangas = []
        isBrowseLoading = true
        let token = UUID()
        browseRequestToken = token
        do {
            let mangas = try await helper.latest(sourceId: sourceId, page: 1)
            guard browseRequestToken == token, selectedSourceId == sourceId else { return }
            browseMangas = mangas
        } catch {
            guard browseRequestToken == token else { return }
            statusMessage = "Browse failed: \(error.localizedDescription)"
            offerCloudflareSolve(for: sourceId)
            browseMangas = []
        }
        if browseRequestToken == token { isBrowseLoading = false }
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
        selectedBrowseMangaId = nil
        activeMangaDetails = nil
        detailsIsFavourited = false
        browseMangas = []
        isBrowseLoading = true
        let token = UUID()
        browseRequestToken = token
        do {
            let mangas = try await helper.search(sourceId: sid, query: trimmed, page: 1)
            guard browseRequestToken == token, selectedSourceId == sid else { return }
            browseMangas = mangas
        } catch {
            guard browseRequestToken == token else { return }
            statusMessage = "Search failed: \(error.localizedDescription)"
            browseMangas = []
        }
        if browseRequestToken == token { isBrowseLoading = false }
    }

    func openDetails(_ manga: MangaSummary) async {
        guard let sid = selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id else {
            statusMessage = "No source selected"
            return
        }
        selectedBrowseMangaId = manga.id
        activeMangaDetails = nil
        detailsIsFavourited = false
        isDetailLoading = true
        let token = UUID()
        detailRequestToken = token
        do {
            var details = try await helper.details(sourceId: sid, mangaUrl: manga.url)
            guard detailRequestToken == token,
                  selectedSourceId == sid,
                  selectedBrowseMangaId == manga.id
            else { return }
            // Some native parsers (e.g. Madara-family like TopManhua) return getDetails
            // without re-parsing the cover/title — they expect the caller to keep the
            // values from the browse list. Backfill from the tapped summary so the
            // overview panel never shows a blank thumbnail.
            if details.manga.coverUrl.isEmpty { details.manga.coverUrl = manga.coverUrl }
            if details.manga.title.isEmpty { details.manga.title = manga.title }
            activeMangaDetails = details
            let coverForAccent = details.manga.coverUrl
            Task.detached(priority: .background) { [weak self] in
                await self?.updateCoverAccent(from: coverForAccent)
            }
            await refreshDetailsFavouritedFlag()
            statusMessage = "Loaded \(details.chapters.count) chapters of \(details.manga.title)"
        } catch {
            guard detailRequestToken == token else { return }
            statusMessage = "Details failed: \(error.localizedDescription)"
        }
        if detailRequestToken == token { isDetailLoading = false }
    }

    func openChapter(_ chapter: HelperChapter) async {
        let chapters = activeMangaDetails?.chapters ?? []
        await openChapter(chapter, in: chapters)
    }

    func openChapter(_ chapter: HelperChapter, in chapters: [HelperChapter], startAtBeginning: Bool = false) async {
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
                if startAtBeginning {
                    // Explicit chapter advance — always start at page 1, never resume.
                    readerPageIndex = 0
                } else {
                    // Resume from saved page if the user was previously on this chapter.
                    let resume = history.first { $0.mangaId == details.manga.id && $0.chapterId == chapter.url }
                    readerPageIndex = min(resume?.page ?? 0, max(proxied.count - 1, 0))
                }
            } else {
                readerPageIndex = 0
            }
            pendingNavigation = .reader
            await persistReaderPosition()
            // Wipe stale per-page translation/balloon state on chapter change.
            clearPageTranslation()
            chapterTranslator.reset()
            // Colorized pages are per-chapter (keyed by page index) — wipe them,
            // then re-colorize the new chapter if the mode is still on.
            colorizer.reset()
            if colorizeModeOn {
                let pageUrls = proxied.compactMap { URL(string: $0.url) }
                if !pageUrls.isEmpty {
                    colorizer.start(chapterId: chapter.url, pageUrls: pageUrls, startAt: readerPageIndex)
                }
            }
            await refreshActiveMangaAdjustments()
            // Background side effects — never block the reader from opening.
            Task.detached(priority: .background) { [weak self] in
                await self?.prefetchNextChapter()
            }
            Task.detached(priority: .background) { [weak self] in
                await self?.scrobbleAllTrackers(chapter: chapter)
            }
            // Instant translation: kick off chapter-wide parallel OCR + MT
            // the moment the reader opens. Pages flow into
            // chapterTranslator.paintedImages as they finish, which the
            // reader already binds to — so flipping forward feels instant.
            //
            // start() is @MainActor — no Task.detached needed. It creates
            // its own internal Task and returns immediately, so the reader
            // opens without blocking. The HUD monitoring Task drives the
            // stage chips while pages process in the background.
            if readerPrefs.instantTranslation {
                let pageUrls = proxied.compactMap { URL(string: $0.url) }
                if !pageUrls.isEmpty {
                    chapterTranslator.start(
                        chapterId: chapter.url,
                        pageUrls: pageUrls,
                        sourceLang: translateSettings.sourceLang,
                        targetCode: translateSettings.googleLangCode(for: translateSettings.targetLang),
                        settings: translateSettings,
                        responseTextScale: CGFloat(readerPrefs.translationResponseScale),
                        startAt: readerPageIndex
                    )
                    // Drive HUD chips: poll translator state every 0.8 s
                    // and advance stages as pages complete.
                    Task { [weak self] in
                        guard let self else { return }
                        self.beginStage(.downloading, resetTimings: true)
                        // Small delay so start() can flip isRunning = true
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        while self.chapterTranslator.isRunning {
                            let done = self.chapterTranslator.completedCount
                            if done == 0 {
                                self.beginStage(.ocr)
                            } else {
                                self.beginStage(.mt)
                            }
                            try? await Task.sleep(nanoseconds: 800_000_000)
                        }
                        self.finishStage(.done)
                    }
                }
            }
        } catch {
            statusMessage = "Pages failed: \(error.localizedDescription)"
        }
    }

    /// Warm `URLCache.shared` with the next few pages of the CURRENT chapter so
    /// turning forward feels instant. The paged reader has no built-in look-ahead
    /// (`AdjustedImageView` only fetches a page once it becomes current), so every
    /// turn otherwise waits on a fresh download+decode.
    ///
    /// We GET pages `[index+1 ... index+ahead]` concurrently (bounded by `ahead`)
    /// with `.returnCacheDataElseLoad`, so `AdjustedImageView.loadImage` later
    /// finds them already cached. This only warms the cache — the display path is
    /// untouched and still renders each page as soon as it decodes.
    ///
    /// Cheap and fire-and-forget: covers/page images go through the helper image
    /// proxy (server-side Semaphore(48)), NOT the parser JS lock, so this never
    /// contends with parser calls. Call off the main thread (see callers).
    func prefetchReaderPages(around index: Int, ahead: Int = 3) async {
        guard let pages = activeChapter?.pages, !pages.isEmpty, ahead > 0 else { return }
        let lower = index + 1
        let upper = min(index + ahead, pages.count - 1)
        guard lower <= upper else { return }
        let urls: [URL] = (lower...upper).compactMap { URL(string: pages[$0].url) }
        guard !urls.isEmpty else { return }
        let session = URLSession.shared
        // Bounded fan-out: at most `ahead` (== urls.count here) concurrent GETs.
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask {
                    var req = URLRequest(url: url)
                    req.cachePolicy = .returnCacheDataElseLoad
                    _ = try? await session.data(for: req)
                }
            }
        }
    }

    /// Warm `URLCache.shared` with the first few pages of the next chapter
    /// so flipping forward feels instant.
    private func prefetchNextChapter() async {
        let nextIdx = readerChapterIndex + chapterNextStep
        guard readerChapters.indices.contains(nextIdx) else { return }
        let next = readerChapters[nextIdx]
        let sid = selectedSourceId ?? ""
        guard !sid.isEmpty,
              let pages = try? await helper.pages(sourceId: sid, chapterUrl: next.url)
        else { return }
        let session = URLSession.shared
        for page in pages.prefix(6) {
            let urlStr = await helper.imageProxyURL(for: page)?.absoluteString ?? page.url
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataElseLoad
            _ = try? await session.data(for: req)
        }
    }

    /// Best-effort progress sync to every linked + enabled tracker. For each
    /// service it resolves the remote media id once per manga (cached on
    /// `TrackerSettings.links`), then create-or-updates progress with status
    /// `reading`. Each service is independent and fails silently, so one
    /// unreachable tracker never blocks the others.
    private func scrobbleAllTrackers(chapter: HelperChapter) async {
        let mangaId = readerMangaId
        guard !mangaId.isEmpty else { return }
        let progress = max(Int(chapter.number.rounded()), 1)
        let title = readerMangaTitle
        for service in TrackerService.allCases {
            guard tracker.isEnabled(service), tracker.hasToken(service) else { continue }
            let token = tracker.token(service)
            guard !token.isEmpty else { continue }
            let slug = service.endpointSlug
            let mediaId: Int
            if let cached = tracker.links(service)[mangaId] {
                mediaId = cached
            } else {
                guard !title.isEmpty,
                      let hit = try? await helper.trackerSearch(slug: slug, title: title, token: token).first
                else { continue }
                mediaId = hit.id
                tracker.setLink(service, mangaId: mangaId, mediaId: mediaId)
            }
            _ = try? await helper.trackerScrobble(
                slug: slug,
                mediaId: mediaId,
                progress: progress,
                status: "reading",
                token: token
            )
        }
    }

    /// Persist the current reader position to history. Safe to call frequently.
    func persistReaderPosition() async {
        guard !readerMangaId.isEmpty, let chapter = activeChapter else { return }
        // Keep 18+ out of history: skip writing when the manga (or its source)
        // is adult-flagged, mirroring the NSFW source-filter detection.
        if readerPrefs.noNsfwHistory {
            let mangaIsNsfw = activeMangaDetails?.manga.isNsfw ?? false
            let sourceIsNsfw = sources.first(where: { $0.id == selectedSourceId })?.isNsfw ?? false
            if mangaIsNsfw || sourceIsNsfw { return }
        }
        let pageCount = max(chapter.pages.count, 1)
        let percent = Float(readerPageIndex + 1) / Float(pageCount)
        try? await helper.recordHistory(
            mangaId: readerMangaId,
            sourceId: selectedSourceId ?? "",
            chapterId: chapter.id,
            chapterTitle: chapter.title,
            page: readerPageIndex,
            percent: percent
        )
    }

    /// Index step to the NEXT (higher-numbered) chapter. Source chapter arrays are
    /// oldest-first on some sources (MangaDex) and newest-first on others (many
    /// scanlation sites), so detect the ordering from chapter numbers instead of
    /// assuming +1 is always "next": ascending (first < last) ⇒ +1, descending ⇒ -1.
    var chapterNextStep: Int {
        guard readerChapters.count >= 2 else { return 1 }
        let a = readerChapters.first!.number
        let b = readerChapters.last!.number
        if a != b { return a < b ? 1 : -1 }
        return 1
    }
    /// Whether a later / earlier chapter exists, honouring source order.
    var hasNextChapter: Bool { readerChapters.indices.contains(readerChapterIndex + chapterNextStep) }
    var hasPrevChapter: Bool { readerChapters.indices.contains(readerChapterIndex - chapterNextStep) }

    // MARK: Auto-scroll (matches the web reader)
    /// Session toggle — not persisted. Observed directly on AppState so the
    /// play/pause chrome button and the reader loops react live.
    @Published var autoScrollOn: Bool = false
    func toggleAutoScroll() { autoScrollOn.toggle() }
    /// Webtoon continuous speed: 24 … 258 px/sec across levels 1…10.
    var autoScrollPxPerSec: Double { 24 + Double(readerPrefs.autoScrollLevel - 1) * 26 }
    /// Paged auto-advance delay: ~8.7s … 1.7s across levels 1…10.
    var autoScrollPagedDelay: Double { max(1.5, 9.5 - Double(readerPrefs.autoScrollLevel) * 0.78) }
    func bumpAutoScrollSpeed(_ delta: Int) {
        readerPrefs.autoScrollLevel = min(10, max(1, readerPrefs.autoScrollLevel + delta))
    }

    /// `delta`: +1 = next chapter, -1 = previous (order-independent).
    func gotoChapterRelative(_ delta: Int) async {
        let newIndex = readerChapterIndex + delta * chapterNextStep
        guard readerChapters.indices.contains(newIndex) else { return }
        readerPageIndex = 0
        // Always start the new chapter at page 1 — never resume a saved position.
        await openChapter(readerChapters[newIndex], in: readerChapters, startAtBeginning: true)
    }

    func install(_ source: SourceSummary) async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await helper.install(sourceId: source.id)
            addToCuration(source.id)
            setSources(try await helper.fetchSources())
            statusMessage = "Installed \(source.name)"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    func installFromCatalog(_ entry: HelperCatalogEntry) async {
        do {
            _ = try await helper.install(sourceId: entry.id)
            addToCuration(entry.id)
            setSources(try await helper.fetchSources())
            setCatalog((try? await helper.catalog()) ?? catalog)
            statusMessage = "Installed \(entry.name)"
        } catch {
            statusMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    /// Add a source to the curated installed set (materializing the "all" default first, so
    /// installing a source from the catalogue makes it appear in Explore immediately).
    private func addToCuration(_ id: String) {
        materializeCuration()
        curatedSourceIds?.insert(id)
        persistCuratedSources()
    }

    /// Remove a source from the curated installed set (materializing first).
    private func removeFromCuration(_ id: String) {
        materializeCuration()
        curatedSourceIds?.remove(id)
        persistCuratedSources()
    }

    /// Onboarding / re-run setup: install every catalog entry in `entries` that
    /// isn't already installed, then refresh the source + catalog lists. Existing
    /// installed sources are left untouched (additive seed — we never uninstall).
    /// Mirrors nyora-web's onboarding: REPLACE the curated installed set with exactly the
    /// language-matched catalog ids. The web keeps this set client-side (the shared engine can
    /// browse any source regardless of its install flag), so this is instant and non-destructive
    /// — no per-source install storm, and it filters Explore/search/sidebar down to the chosen
    /// languages immediately. Re-run setup from Settings applies a new selection the same way.
    func seedSources(from entries: [HelperCatalogEntry]) async {
        curatedSourceIds = Set(entries.map(\.id))
        persistCuratedSources()
        // Mirror the curated set into the engine DB (one bulk call) so NyoraSync source-prefs
        // sync pushes the user's real installed set — otherwise the engine still reports its
        // seed default. Individual install/uninstall already hit the engine directly.
        _ = try? await helper.setInstalledSources(ids: Array(curatedSourceIds ?? []))
        // Re-apply to whatever is already loaded so Explore reflects the new set at once,
        // then refresh from the engine (also curated) to fill in any missing metadata.
        sources = applyingCuration(sources)
        catalog = applyingCuration(catalog: catalog)
        if let fresh = try? await helper.fetchSources() { setSources(fresh) }
        if let freshCatalog = try? await helper.catalog() { setCatalog(freshCatalog) }
    }

    func openCatalog() async {
        isCatalogPresented = true
        if catalog.isEmpty { await reloadCatalogEntries() }
    }

    func reloadCatalogEntries() async {
        isCatalogLoading = true
        defer { isCatalogLoading = false }
        do {
            setCatalog(try await helper.catalog())
        } catch {
            statusMessage = "Catalog load failed: \(error.localizedDescription)"
        }
    }

    // MARK: - history + favourites

    func reloadHistory() async {
        do {
            history = try await helper.history()
            reindexSpotlight()
        } catch {
            statusMessage = "History load failed: \(error.localizedDescription)"
        }
    }

    func removeHistory(mangaId: String) async {
        do {
            try await helper.removeHistory(mangaId: mangaId)
            await reloadHistory()
        } catch {
            statusMessage = "Failed to remove history: \(error.localizedDescription)"
        }
    }

    func clearHistory() async {
        do {
            try await helper.clearHistory()
            await reloadHistory()
            statusMessage = "Reading history cleared"
        } catch {
            statusMessage = "Failed to clear history: \(error.localizedDescription)"
        }
    }

    func clearDatabase() async {
        do {
            try await helper.clearDatabase()
            // Reset all local state
            async let s = refreshSources()
            async let h = reloadHistory()
            async let f = reloadFavourites()
            async let b = reloadBookmarks()
            _ = await (s, h, f, b)
            statusMessage = "Database wiped successfully"
        } catch {
            statusMessage = "Database wipe failed: \(error.localizedDescription)"
        }
    }

    func restartHelper() async {
        statusMessage = "Restarting helper…"
        await helper.stop()
        await bootstrap()
    }

    func reloadFavourites() async {
        do {
            favourites = try await helper.favourites()
            reindexSpotlight()
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

    /// Unconditionally removes a manga from favourites by id. Used by the
    /// Favourites grid context menus which operate on HelperManga directly
    /// (no activeMangaDetails required).
    func removeFavourite(mangaId: String) async {
        do {
            let isFav = try await helper.isFavourited(mangaId: mangaId)
            if isFav {
                _ = try await helper.toggleFavourite(mangaId: mangaId)
            }
            await reloadFavourites()
        } catch {
            statusMessage = "Remove favourite failed: \(error.localizedDescription)"
        }
    }

    /// Opens a favourited manga's details page. Tries to resolve the source
    /// from the first installed source when no direct sourceId is available.
    /// The (sourceId, mangaUrl) a saved manga belongs to — resolved from its own
    /// source ref (favourites) or from a history row — so it opens in the RIGHT
    /// (synced) source, not whatever is currently selected in Explore.
    func resolveMangaLocation(forMangaId id: String) -> (sourceId: String, mangaUrl: String)? {
        if let fav = favourites.first(where: { $0.id == id }),
           let sid = fav.resolvedSourceId, sources.contains(where: { $0.id == sid }) {
            return (sid, fav.url)
        }
        if let row = history.first(where: { $0.mangaId == id }) {
            return (row.sourceId, row.mangaUrl)
        }
        if let fav = favourites.first(where: { $0.id == id }),
           let sid = selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id {
            return (sid, fav.url)  // last resort: known url, best-guess source
        }
        return nil
    }

    func openFavouriteManga(_ manga: HelperManga) async {
        // Prefer the manga's OWN source (where it was saved), then a history match,
        // then the currently-selected / first installed source as a fallback.
        let resolved = (manga.resolvedSourceId.flatMap { sid in sources.contains(where: { $0.id == sid }) ? sid : nil })
            ?? history.first(where: { $0.mangaId == manga.id })?.sourceId
        guard let sid = resolved ?? selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id else {
            statusMessage = "No installed source — open a source in Explore first."
            return
        }
        selectedSourceId = sid
        selectedBrowseMangaId = manga.id
        activeMangaDetails = nil
        detailsIsFavourited = false
        isDetailLoading = true
        let token = UUID()
        detailRequestToken = token
        do {
            let details = try await helper.details(sourceId: sid, mangaUrl: manga.url)
            guard detailRequestToken == token else { return }
            activeMangaDetails = details
            Task.detached(priority: .background) { [weak self] in
                await self?.updateCoverAccent(from: details.manga.coverUrl)
            }
            await refreshDetailsFavouritedFlag()
            pendingNavigation = .explore
            statusMessage = "Loaded \(details.manga.title)"
        } catch {
            guard detailRequestToken == token else { return }
            statusMessage = "Couldn't open manga: \(error.localizedDescription)"
        }
        if detailRequestToken == token { isDetailLoading = false }
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
            statusMessage = "Checked \(result.checked) manga · \(result.withNew) with new chapters"
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
        // Already open & matching → jump directly.
        if let details = activeMangaDetails, details.manga.id == bookmark.mangaId {
            await jumpToBookmark(bookmark, in: details)
            return
        }
        // Otherwise resolve the manga's REAL source + url (from favourites/history)
        // and open its chapter overview in that correct source before jumping.
        guard let loc = resolveMangaLocation(forMangaId: bookmark.mangaId) else {
            statusMessage = "Couldn't find the source for this bookmark — open the manga from its source once."
            return
        }
        selectedSourceId = loc.sourceId
        activeMangaDetails = nil
        detailsIsFavourited = false
        isDetailLoading = true
        let token = UUID()
        detailRequestToken = token
        do {
            let details = try await helper.details(sourceId: loc.sourceId, mangaUrl: loc.mangaUrl)
            guard detailRequestToken == token else { return }
            activeMangaDetails = details
            selectedBrowseMangaId = details.manga.id
            isDetailLoading = false
            await refreshDetailsFavouritedFlag()
            await jumpToBookmark(bookmark, in: details)
        } catch {
            isDetailLoading = false
            statusMessage = "Couldn't open the bookmarked manga."
        }
    }

    private func jumpToBookmark(_ bookmark: HelperBookmark, in details: HelperDetailsResponse) async {
        guard let chapter = details.chapters.first(where: { $0.url == bookmark.chapterId }) else {
            statusMessage = "Couldn't find that chapter in the manga."
            return
        }
        await openChapter(chapter, in: details.chapters)
        // Override the history-resume page with the bookmark's exact page (after
        // openChapter, which sets readerPageIndex from history), then persist once.
        readerPageIndex = bookmark.page
        pendingNavigation = .reader
        await persistReaderPosition()
    }

    func uninstall(_ source: SourceSummary) async {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await helper.uninstall(sourceId: source.id)
            removeFromCuration(source.id)
            setSources(try await helper.fetchSources())
            if selectedSourceId == source.id {
                browseRequestToken = UUID()
                detailRequestToken = UUID()
                browseMangas = []
                activeMangaDetails = nil
                selectedBrowseMangaId = nil
                detailsIsFavourited = false
                isBrowseLoading = false
                isDetailLoading = false
            }
            statusMessage = "Uninstalled \(source.name)"
        } catch {
            statusMessage = "Uninstall failed: \(error.localizedDescription)"
        }
    }

    func shutdownHelper() async {
        await helper.stop()
    }

    func clearMessage() { statusMessage = nil; statusActionTitle = nil }

    // MARK: - Manual Cloudflare solve

    /// A one-tap action offered alongside `statusMessage` (e.g. "Verify" on a browse
    /// failure). nil when the current message has no action.
    @Published var statusActionTitle: String?
    private var statusActionHandler: (@MainActor () async -> Void)?

    /// True while a manual Cloudflare solve is running (drives the toolbar button state).
    @Published var isSolvingCloudflare: Bool = false

    func runStatusAction() {
        guard let handler = statusActionHandler else { return }
        Task { await handler() }
    }

    /// Open the Cloudflare verification window for the given source and, on success, refresh
    /// its browse. Wired to the Explore toolbar button and the browse-failure toast.
    func solveCloudflare(for sourceId: String) async {
        guard !sourceId.isEmpty, !isSolvingCloudflare else { return }
        isSolvingCloudflare = true
        defer { isSolvingCloudflare = false }
        statusMessage = "Finding source domain…"
        statusActionTitle = nil
        guard let host = await helper.sourceDomain(id: sourceId) else {
            statusMessage = "Couldn't determine this source's domain."
            return
        }
        statusMessage = "Complete the Cloudflare verification for \(host), then close its window."
        let ok = await helper.solveCloudflareManually(host: host)
        if ok {
            statusMessage = nil
            await loadPopular(sourceId: sourceId)
        } else {
            statusMessage = "Cloudflare verification was cancelled."
        }
    }

    /// Attach the "Verify" action to the current status message (called from browse-failure
    /// paths) so the toast offers a manual solve.
    func offerCloudflareSolve(for sourceId: String) {
        statusActionTitle = "Verify"
        statusActionHandler = { [weak self] in await self?.solveCloudflare(for: sourceId) }
    }

    func consumeNavigation() -> NavDestination? {
        let pending = pendingNavigation
        pendingNavigation = nil
        return pending
    }

    // MARK: - Color adjustments

    /// App-wide colour adjustments — bound to ReaderPrefs persisted values.
    var appWideColorAdjustments: ColorAdjustments {
        get {
            ColorAdjustments(
                brightness: readerPrefs.brightness,
                contrast:   readerPrefs.contrast,
                saturation: readerPrefs.saturation,
                hue:        readerPrefs.hue,
                palette:    readerPrefs.palette
            )
        }
        set {
            readerPrefs.brightness = newValue.brightness
            readerPrefs.contrast   = newValue.contrast
            readerPrefs.saturation = newValue.saturation
            readerPrefs.hue        = newValue.hue
            readerPrefs.palette    = newValue.palette
        }
    }

    /// Picks per-manga overrides when present, otherwise app-wide values.
    var effectiveColorAdjustments: ColorAdjustments {
        if !readerMangaId.isEmpty,
           let row = perMangaPrefsCache[readerMangaId],
           row.present {
            return ColorAdjustments(
                brightness: row.brightness ?? 0,
                contrast:   row.contrast ?? 1,
                saturation: row.saturation ?? 1,
                hue:        row.hue ?? 0,
                palette:    row.palette ?? ""
            )
        }
        return appWideColorAdjustments
    }

    /// Downloads the cover image for `urlString` and extracts a two-color
    /// accent palette using `NSImage.nyoraCoverPalette`. Network + image work
    /// runs on the caller's context (background task); only the final property
    /// assignments hop to MainActor via `MainActor.run`.
    nonisolated func updateCoverAccent(from urlString: String) async {
        // No-op: the ambient glow follows the chosen accent (Color.appAccent),
        // not a per-cover palette, so there's nothing to derive here.
    }

    /// Pulls the current manga's per-manga prefs row into the cache so the
    /// reader's colour overlay can read it synchronously.
    func refreshActiveMangaAdjustments() async {
        guard !readerMangaId.isEmpty else { return }
        let row = try? await helper.mangaPrefs(mangaId: readerMangaId)
        if let row = row { perMangaPrefsCache[readerMangaId] = row }
    }

    // MARK: - Categories

    func reloadCategories() async {
        do {
            categories = try await helper.categories()
        } catch {
            // Don't surface as user-facing — categories are non-critical.
        }
    }

    func reloadDownloads() async {
        do {
            downloads = try await helper.downloads()
        } catch {
            // Same as categories — silent on initial load.
        }
    }

    /// Batch-enqueue the given chapters of a manga for download, then refresh the queue.
    func downloadChapters(sourceId: String, manga: HelperManga, chapters: [HelperChapter]) async {
        guard !chapters.isEmpty else { return }
        do {
            try await helper.enqueueDownloads(
                sourceId: sourceId,
                mangaUrl: manga.url,
                mangaTitle: manga.title,
                chapters: chapters.map { (url: $0.url, title: $0.title) },
            )
            await reloadDownloads()
            statusMessage = "Queued \(chapters.count) chapter\(chapters.count == 1 ? "" : "s") for download"
        } catch {
            statusMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    /// Retry a failed/cancelled download.
    func retryDownload(_ d: HelperDownload) async {
        do {
            _ = try await helper.retryDownload(d)
            await reloadDownloads()
            statusMessage = "Retrying \(d.chapterTitle)"
        } catch {
            statusMessage = "Retry failed: \(error.localizedDescription)"
        }
    }

    func loadDownloadSettings() async {
        downloadSettings = try? await helper.downloadSettings()
    }

    func updateDownloadSettings(maxConcurrent: Int, format: String) async {
        do {
            downloadSettings = try await helper.setDownloadSettings(maxConcurrent: maxConcurrent, format: format)
            statusMessage = "Download settings saved"
        } catch {
            statusMessage = "Couldn't save download settings: \(error.localizedDescription)"
        }
    }

    func createCategory(_ title: String) async {
        do {
            _ = try await helper.createCategory(title: title)
            await reloadCategories()
        } catch {
            statusMessage = "Couldn't create category: \(error.localizedDescription)"
        }
    }

    func addCurrentMangaToCategory(_ categoryId: Int64) async {
        guard let id = activeMangaDetails?.manga.id else { return }
        do {
            try await helper.addToCategory(mangaId: id, categoryId: categoryId)
            await reloadCategories()
        } catch {
            statusMessage = "Couldn't update category: \(error.localizedDescription)"
        }
    }

    // MARK: - Global search

    /// Incremental, client-driven global search.
    ///
    /// Previously this made ONE blocking call to `helper.globalSearch` (the
    /// server `/search/global` endpoint), which fanned out across every
    /// installed source and returned all groups at once — so the sheet showed
    /// nothing until the slowest source finished.
    ///
    /// We now replicate the server's fan-out on the client and publish each
    /// source's group into `globalSearchResults` the moment that source returns,
    /// so `GlobalSearchSheet`'s `ForEach` renders cards source-by-source while
    /// the rest are still in flight. The server semantics are matched exactly:
    ///   - search ALL installed sources (server: `listSources().filter isInstalled`)
    ///   - take the top `perSourceLimit` (6) entries per source
    ///   - only surface sources that returned hits
    ///   - per-source errors are captured into the group's `error` field
    /// Bounded to a small number of in-flight source queries so we don't open
    /// hundreds of sockets at once (mirrors the server-side Semaphore(48) intent;
    /// the loopback helper still applies its own gate downstream).
    ///
    /// NOTE: `helper.globalSearch` (the all-at-once bridge method) is preserved
    /// for any other caller — only `runGlobalSearch` stops using it.
    ///
    /// BEHAVIOUR PARITY: the server sorted non-empty groups by hit count
    /// descending. We instead publish in completion order (fastest source
    /// first) because incremental display is the whole point; the sheet keeps
    /// its own ordering/animation. NSFW filtering is still re-applied by the
    /// sheet's `visibleResults`, so we publish the unfiltered installed set here.
    func runGlobalSearch() async {
        let trimmed = globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Supersede any in-flight run: a newer query invalidates older results.
        let token = UUID()
        globalSearchToken = token

        // Match the server's source set: all installed sources.
        let installed = sources.filter { $0.isInstalled }
        let perSourceLimit = 6
        let maxInFlight = 8   // bound fan-out; do not open hundreds of sockets at once

        globalSearchResults = []
        isGlobalSearching = true
        guard !installed.isEmpty else { isGlobalSearching = false; return }

        // Capture the bridge (an actor → Sendable) into a local so the child
        // tasks don't reach back through the @MainActor `self` to read it.
        let bridge = helper

        // Each child task returns a finished group (or nil on stale/empty).
        // bridge.searchGroup awaits off the main thread (URLSession); we only
        // touch @MainActor state (globalSearchResults) here on the main actor,
        // never holding any lock across an await.
        await withTaskGroup(of: HelperGlobalSearchGroup?.self) { group in
            var iterator = installed.makeIterator()
            var launched = 0

            // Builds one child task for a given source.
            func makeTask(for src: SourceSummary) -> @Sendable () async -> HelperGlobalSearchGroup? {
                let sourceId = src.id
                let sourceName = src.name
                return {
                    do {
                        let entries = try await bridge.searchGroup(
                            sourceId: sourceId, query: trimmed, page: 1
                        )
                        guard !entries.isEmpty else { return nil }
                        return HelperGlobalSearchGroup(
                            sourceId: sourceId,
                            sourceName: sourceName,
                            entries: Array(entries.prefix(perSourceLimit)),
                            error: nil
                        )
                    } catch {
                        // Surface the failure in the group's error field (rendered
                        // by GlobalSearchSheet) rather than dropping the source.
                        return HelperGlobalSearchGroup(
                            sourceId: sourceId,
                            sourceName: sourceName,
                            entries: [],
                            error: error.localizedDescription
                        )
                    }
                }
            }

            // Prime the window.
            while launched < maxInFlight, let src = iterator.next() {
                group.addTask(operation: makeTask(for: src))
                launched += 1
            }

            // Drain results as they arrive, refilling the window so at most
            // `maxInFlight` source queries run concurrently.
            for await result in group {
                // Drop late results from a superseded query.
                guard globalSearchToken == token else { return }
                if let result, !(result.entries.isEmpty && (result.error?.isEmpty ?? true)) {
                    globalSearchResults.append(result)
                }
                if let next = iterator.next() {
                    group.addTask(operation: makeTask(for: next))
                }
            }
        }

        // Only clear the spinner if we're still the active query.
        if globalSearchToken == token { isGlobalSearching = false }
    }

    // MARK: - Translation state helpers (consumed by reader views)

    func clearPageTranslation() {
        currentPageTranslation = []
        currentPageImageSize = .zero
        paintedPageURL = nil
        paintedPageImage = nil
    }

    /// Hook used by ⌘T — translates only the page currently displayed in
    /// the reader. Routes through `ChapterTranslator.translateSinglePage` so
    /// per-page translation uses the same bubble-detect → per-bubble OCR
    /// pipeline as chapter mode (the only path that actually reads tategaki
    /// — Vision's full-page recognizer can't, see prior diagnostic on this).
    func translateCurrentPage() {
        guard !isTranslatingPage else { return }
        guard let chapter = activeChapter,
              let page = chapter.pages[safe: readerPageIndex],
              let url = URL(string: page.url)
        else { return }
        let chapterId = chapter.id
        let pageIdx = readerPageIndex

        Task { [weak self] in
            guard let self else { return }
            await MainActor.run { self.beginStage(.ocr, resetTimings: true) }
            await MainActor.run {
                self.isTranslatingPage = true
                self.translationSheetLoading = true
            }
            // The chapter pipeline OCRs + MTs + refines internally
            // and publishes to `chapterTranslator.paintedImages[pageIdx]`,
            // which the reader already binds to. The chapter pipeline now
            // fires the `onStage` callback at each phase transition, so the
            // HUD chips advance through OCR → AI Refine →
            // Translate → Done with accurate per-stage timings.
            await self.chapterTranslator.translateSinglePage(
                chapterId: chapterId,
                pageIndex: pageIdx,
                pageUrl: url,
                sourceLang: self.translateSettings.sourceLang,
                targetCode: self.translateSettings.googleLangCode(for: self.translateSettings.targetLang),
                settings: self.translateSettings,
                responseTextScale: CGFloat(self.readerPrefs.translationResponseScale),
                onStage: { [weak self] stage in self?.beginStage(stage) }
            )

            // Mirror results onto the legacy per-page state so the
            // translation sheet + currentPageTranslation pickers stay
            // populated even though the painting now lives on chapterTranslator.
            await MainActor.run {
                let blocks = self.chapterTranslator.pageResults[pageIdx] ?? []
                let imageSize = self.chapterTranslator.pageImageSizes[pageIdx] ?? .zero
                self.currentPageTranslation = blocks
                self.currentPageImageSize = imageSize
                if let painted = self.chapterTranslator.paintedImages[pageIdx] {
                    self.paintedPageURL = page.url
                    self.paintedPageImage = painted
                }
                self.inImageBalloons = []
                self.inImageBalloonsPageURL = nil
                self.translationSheetPage = PageTranslation(
                    pageImage: self.paintedPageImage,
                    entries: blocks.map {
                        PageTranslation.Entry(
                            original: $0.originalText,
                            translated: $0.translatedText
                        )
                    }
                )
            }

            await MainActor.run {
                self.finishStage(.done)
                self.isTranslatingPage = false
                self.translationSheetLoading = false
            }
        }
    }

    // MARK: - AI colorization

    /// Toggle native ONNX colorization for the current chapter. On → downloads
    /// the model if needed (progress in Settings), then colorizes every page in
    /// the background; the reader shows each page as it finishes. Off → stops and
    /// wipes the colorized pages so the source images show again.
    func toggleColorize() {
        colorizeModeOn.toggle()
        guard colorizeModeOn else {
            colorizer.stop()
            colorizer.reset()
            return
        }
        guard let chapter = activeChapter else { return }
        let pageUrls = chapter.pages.compactMap { URL(string: $0.url) }
        guard !pageUrls.isEmpty else { return }
        colorizer.start(chapterId: chapter.id, pageUrls: pageUrls, startAt: readerPageIndex)
    }

    // MARK: - Debug HUD stage transitions

    /// Stamp `stage` as the current pipeline step, recording the wall-clock
    /// duration spent in the previous step. Called from `translateCurrentPage`.
    @MainActor
    func beginStage(_ stage: TranslationStage, resetTimings: Bool = false) {
        let now = Date().timeIntervalSinceReferenceDate
        if resetTimings {
            translationStageTimings = [:]
            stageStartedAt = now
        } else if let last = stageStartedAt {
            // Attribute the elapsed time to whichever stage just ended.
            translationStageTimings[translationStage.id] = max(0, now - last)
        }
        stageStartedAt = now
        translationStage = stage
    }

    /// Mark the pipeline finished (either `.done` or `.failed`).
    @MainActor
    func finishStage(_ stage: TranslationStage) {
        if let last = stageStartedAt {
            translationStageTimings[translationStage.id] = max(0, Date().timeIntervalSinceReferenceDate - last)
        }
        stageStartedAt = nil
        translationStage = stage
    }

    func closeTranslationSheet() {
        translationSheetPage = nil
        translationSheetLoading = false
    }

    // MARK: - Global search row tap

    /// Called by `GlobalSearchSheet` when the user taps a result row.
    func openGlobalSearchResult(group: HelperGlobalSearchGroup, manga: HelperManga) async {
        selectedSourceId = group.sourceId
        isGlobalSearchPresented = false
        do {
            let details = try await helper.details(sourceId: group.sourceId, mangaUrl: manga.url)
            activeMangaDetails = details
            pendingNavigation = .explore
            await refreshDetailsFavouritedFlag()
        } catch {
            statusMessage = "Couldn't open: \(error.localizedDescription)"
        }
    }

    // MARK: - History open

    func openHistoryEntry(_ row: HelperHistoryRow) async {
        if row.sourceId.hasPrefix("local:") || row.mangaId.hasPrefix("local:") {
            let path = String(row.mangaId.dropFirst("local:".count))
            await openLocalCbz(HelperLocalCbz(path: path, name: row.mangaTitle, sizeBytes: 0))
            return
        }
        guard !row.sourceId.isEmpty else {
            statusMessage = "This history row has no source recorded — open it from Explore instead."
            return
        }
        let effectiveSourceId = resolveOpenableSourceId(for: row.sourceId, fallbackName: row.sourceName)
        isLoading = true
        defer { isLoading = false }
        selectedSourceId = effectiveSourceId
        do {
            // The JS parser's getDetails needs the manga's page URL, not its
            // numeric library id. Fall back to mangaId only if no URL is stored.
            let mangaUrl = row.mangaUrl.isEmpty ? row.mangaId : row.mangaUrl
            let details = try await helper.details(sourceId: effectiveSourceId, mangaUrl: mangaUrl)
            activeMangaDetails = details
            Task.detached(priority: .background) { [weak self] in
                await self?.updateCoverAccent(from: details.manga.coverUrl)
            }
            await refreshDetailsFavouritedFlag()
            let chapter = details.chapters.first { $0.url == row.chapterId } ?? details.chapters.first
            if let chapter {
                await openChapter(chapter, in: details.chapters)
            } else {
                statusMessage = "Couldn't find that chapter — the source's chapter list may have changed."
                pendingNavigation = .explore
            }
        } catch {
            statusMessage = "Couldn't open from history: \(error.localizedDescription)"
        }
    }

    /// Map a (potentially defunct) source id to one we can actually open by
    /// name-matching against installed Parser sources.
    private func resolveOpenableSourceId(for sourceId: String, fallbackName: String) -> String {
        // We run JS extensions only (engine "JavaScript", ids like
        // "parser:ASURASCANS_US"). If the helper already handed us an installed
        // source id, use it directly.
        if sources.contains(where: { $0.id == sourceId && $0.engine == "JavaScript" }) {
            return sourceId
        }
        // Otherwise name-match against installed JS sources — covers legacy or
        // synced rows whose stored id no longer resolves.
        let jsMatch = sources.first { src in
            src.engine == "JavaScript" &&
            src.name.caseInsensitiveCompare(fallbackName) == .orderedSame
        }
        return jsMatch?.id ?? sourceId
    }

    // MARK: - In-app browser + deep links

    /// Opens `url` inside the app's WKWebView sheet (not the system browser).
    func openInApp(_ url: URL) { inAppBrowserURL = url }

    /// Deep-link entry point: find a manga with `id` among the already-loaded
    /// favourites / history / browse results / library and open its details.
    /// Best-effort — silent when the manga can't be resolved.
    func openMangaById(_ id: String) async {
        if let manga = favourites.first(where: { $0.id == id }) {
            await openFavouriteManga(manga)
            return
        }
        if let row = history.first(where: { $0.mangaId == id }) {
            await openHistoryEntry(row)
            return
        }
        if let summary = browseMangas.first(where: { $0.id == id })
            ?? mangas.first(where: { $0.id == id }) {
            await openDetails(summary)
            return
        }
        // Only an id is known — resolve via the first installed source and
        // route to the details pane.
        guard let sid = selectedSourceId ?? sources.first(where: { $0.isInstalled })?.id else {
            statusMessage = "No installed source — open a source in Explore first."
            return
        }
        selectedSourceId = sid
        selectedBrowseMangaId = id
        activeMangaDetails = nil
        detailsIsFavourited = false
        isDetailLoading = true
        let token = UUID()
        detailRequestToken = token
        do {
            let details = try await helper.details(sourceId: sid, mangaUrl: id)
            guard detailRequestToken == token else { return }
            activeMangaDetails = details
            Task.detached(priority: .background) { [weak self] in
                await self?.updateCoverAccent(from: details.manga.coverUrl)
            }
            await refreshDetailsFavouritedFlag()
            pendingNavigation = .explore
            statusMessage = "Loaded \(details.manga.title)"
        } catch {
            guard detailRequestToken == token else { return }
            statusMessage = "Couldn't open manga: \(error.localizedDescription)"
        }
        if detailRequestToken == token { isDetailLoading = false }
    }

    /// Parses `nyora://` URLs:
    ///   nyora://manga/<mangaId>             → open that manga's details
    ///   nyora://browse?url=<percent-encoded> → open the url in the in-app browser
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "nyora" else { return }
        switch url.host {
        case "manga":
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "/" else { return }
            Task { await openMangaById(id) }
        case "browse":
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let raw = components?.queryItems?.first(where: { $0.name == "url" })?.value,
               let target = URL(string: raw) {
                openInApp(target)
            }
        default:
            break
        }
    }

    // MARK: - Spotlight

    /// Reindexes the user's library (favourites + history) into CoreSpotlight.
    func reindexSpotlight() {
        SpotlightIndexer.index(favourites: favourites, history: history)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// One translated speech-bubble rendered as an overlay on the reader image.
/// `rect` is in image-pixel coordinates (top-left origin) — the reader maps
/// these into view-space using the current display scale.
struct InImageBalloon: Identifiable, Hashable {
    let id: UUID = UUID()
    let original: String
    let translated: String
    let rect: CGRect
}

/// Pipeline stages for the per-page translation flow, in execution order.
/// The debug HUD renders one chip per case (excluding `.idle`) and marks
/// each as pending / active / done / skipped based on the current value.
enum TranslationStage: Equatable, Identifiable {
    case idle
    case downloading       // fetching the page bitmap
    case ocr               // Apple Vision OCR + ensemble passes
    case mt                // Apple Intelligence translate (+ Google fallback)
    case refining          // Apple Intelligence polish of the translated output
    case done              // pipeline finished successfully
    case failed(String)    // pipeline aborted; user-visible reason attached

    /// Stable id for SwiftUI ForEach + timing dictionary keys.
    var id: String {
        switch self {
        case .idle:         return "idle"
        case .downloading:  return "download"
        case .ocr:          return "ocr"
        case .mt:           return "mt"
        case .refining:     return "refine"
        case .done:         return "done"
        case .failed:       return "failed"
        }
    }

    /// Ordered list rendered as chips in the HUD. `.idle` / `.failed` are
    /// terminal states and excluded. Order reflects pipeline:
    /// Download → OCR → Translate → AI Refine → Done.
    static let visibleStages: [TranslationStage] =
        [.downloading, .ocr, .mt, .refining, .done]

    var label: String {
        switch self {
        case .idle:         return "Idle"
        case .downloading:  return "Download"
        case .ocr:          return "OCR"
        case .mt:           return "Translate"
        case .refining:     return "AI Refine"
        case .done:         return "Done"
        case .failed:       return "Failed"
        }
    }

    var systemImage: String {
        switch self {
        case .idle:         return "circle.dashed"
        case .downloading:  return "arrow.down.circle"
        case .ocr:          return "text.viewfinder"
        case .mt:           return "character.bubble"
        case .refining:     return "sparkles"
        case .done:         return "checkmark.circle.fill"
        case .failed:       return "xmark.octagon.fill"
        }
    }

    /// Linear ordering used to compute pending vs done relative to the
    /// current stage. `.failed` returns -1 so every visible chip looks
    /// inactive when the pipeline aborted.
    var stepIndex: Int {
        switch self {
        case .idle:         return 0
        case .downloading:  return 1
        case .ocr:          return 2
        case .mt:           return 3
        case .refining:     return 4
        case .done:         return 5
        case .failed:       return -1
        }
    }
}

enum ReaderMode: String, CaseIterable, Identifiable {
    case standard
    case reversed
    case vertical
    case webtoon
    /// Legacy alias used by code paths predating the four-mode split.
    static let paged: ReaderMode = .standard
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Paged"
        case .reversed: return "Paged RTL"
        case .vertical: return "Vertical"
        case .webtoon:  return "Webtoon"
        }
    }
    var systemImage: String {
        switch self {
        case .standard: return "rectangle.stack"
        case .reversed: return "rectangle.stack.badge.minus"
        case .vertical: return "rectangle.split.1x2"
        case .webtoon:  return "arrow.down.forward.and.arrow.up.backward.rectangle"
        }
    }
    /// True for right-to-left reading flow (manga RTL).
    var isRTL: Bool { self == .reversed }
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
    func asyncMap<T: Sendable>(_ transform: @Sendable (Element) async -> T) async -> [T] {
        var out: [T] = []
        out.reserveCapacity(self.count)
        for el in self {
            out.append(await transform(el))
        }
        return out
    }
}

private extension NSImage {
    /// Extracts a two-color accent palette from the cover image using
    /// `CIFilter.areaAverage()` to compute the dominant hue, then derives a
    /// vivid primary and a shifted secondary color from it.
    var nyoraCoverPalette: (primary: NSColor, secondary: NSColor)? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        guard !ci.extent.isEmpty else { return nil }
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let filter = CIFilter.areaAverage()
        filter.inputImage = ci
        filter.extent = ci.extent
        guard let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let r = CGFloat(px[0]) / 255; let g = CGFloat(px[1]) / 255; let b = CGFloat(px[2]) / 255
        let base = (NSColor(calibratedRed: r, green: g, blue: b, alpha: 1).usingColorSpace(.deviceRGB)) ?? NSColor.purple
        var h: CGFloat = 0; var s: CGFloat = 0; var br: CGFloat = 0; var a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &br, alpha: &a)
        let primary = NSColor(calibratedHue: h, saturation: max(0.55, s * 1.4), brightness: max(0.65, br * 1.1), alpha: 1)
        let secondary = NSColor(calibratedHue: fmod(h + 0.10, 1.0), saturation: max(0.4, s * 1.1), brightness: max(0.58, br * 0.9), alpha: 1)
        return (primary, secondary)
    }
}

extension AppState {
    // MARK: - Nyora Sync

    func refreshNyoraSyncStatus() async {
        do {
            nyoraSyncStatus = try await helper.nyoraSyncStatus()
        } catch {
            print("NyoraSync status error: \(error)")
        }
    }

    func nyoraSyncSignIn(email: String, password: String) async -> Bool {
        await performAuth(statusMessage: "Signing in…") {
            try await self.helper.nyoraSyncSignIn(email: email, password: password)
        }
    }

    func nyoraSyncRegister(email: String, password: String) async -> Bool {
        await performAuth(statusMessage: "Creating account…") {
            try await self.helper.nyoraSyncRegister(email: email, password: password)
        }
    }

    private func performAuth(statusMessage: String, _ call: () async throws -> Bool) async -> Bool {
        isNyoraSyncSigningIn = true
        self.statusMessage = statusMessage
        defer { isNyoraSyncSigningIn = false }
        do {
            let ok = try await call()
            await refreshNyoraSyncStatus()
            if ok {
                // Actually run the sync (push local → pull cloud → reload). This block used to
                // only reload LOCAL data and set a "Syncing…" message without ever calling
                // nyoraSync(), so cloud data never arrived and the toast sat forever.
                await nyoraSync()
            } else {
                self.statusMessage = "Sign-in failed"
            }
            return ok
        } catch {
            self.statusMessage = "Sign-in failed: \(error.localizedDescription)"
            return false
        }
    }

    func nyoraSyncSignOut() async {
        do {
            try await helper.nyoraSyncSignOut()
            await refreshNyoraSyncStatus()
        } catch {
            print("NyoraSync sign out error: \(error)")
        }
    }

    func nyoraSync() async {
        isNyoraSyncing = true
        statusMessage = "Syncing your library..."
        defer { isNyoraSyncing = false }
        do {
            try await helper.nyoraSync()
            await refreshNyoraSyncStatus()
            await reloadAllDataAfterSync()
            statusMessage = "Nyora Sync complete"
        } catch {
            print("NyoraSync sync error: \(error)")
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    func nyoraSyncRestoreFromCloud() async {
        isNyoraSyncing = true
        statusMessage = "Restoring your library..."
        defer { isNyoraSyncing = false }
        do {
            try await helper.nyoraSyncRestoreFromCloud()
            await refreshNyoraSyncStatus()
            await reloadAllDataAfterSync()
            statusMessage = "Restore complete"
        } catch {
            print("NyoraSync restore error: \(error)")
            statusMessage = "Restore failed: \(error.localizedDescription)"
        }
    }

    func nyoraSyncHasLocalData() async -> Bool {
        (try? await helper.nyoraSyncHasLocalData()) ?? false
    }

    private func reloadAllDataAfterSync() async {
        // After push/pull or restore, refresh local state
        await reloadFavourites()
        await reloadHistory()
        await reloadBookmarks()
        await reloadUpdates()
        await reloadCategories()
        // Adopt the engine's merged installed set: source-prefs sync applied the pulled
        // `is_enabled` to the engine DB, so ADOPT that as the client curated set — otherwise the
        // client-side overlay would re-impose the pre-sync set and silently drop pulled changes.
        if let fresh = try? await helper.fetchSources() {
            curatedSourceIds = Set(fresh.filter(\.isInstalled).map(\.id))
            persistCuratedSources()
            setSources(fresh)
        } else {
            await refreshSources()
        }
    }

    // MARK: - Backup

    func exportBackup() async {
        do {
            let data = try await helper.backupExport()
            let panel = NSSavePanel()
            panel.title = "Export Nyora library"
            panel.nameFieldStringValue = "nyora-backup.json"
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                statusMessage = "Backup saved to \(url.lastPathComponent)"
            }
        } catch {
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func importBackup() async -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Import Nyora library"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
            let result = try await helper.backupImport(data)
            statusMessage = "Imported \(result.importedFavourites) favourites · \(result.importedHistory) history rows"
            await reloadHistory()
            await reloadFavourites()
            await reloadBookmarks()
            await reloadCategories()
            return true
        } catch {
            statusMessage = "Import failed: \(error.localizedDescription)"
            return false
        }
    }
}
