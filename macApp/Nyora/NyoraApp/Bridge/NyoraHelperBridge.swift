import Foundation

struct SyncPushResult: Sendable {
    let favs: Bool
    let history: Bool
}

struct SupabaseStatusResponse: Decodable, Sendable {
    let isConfigured: Bool
    let isAuthenticated: Bool
    let userId: String
    let email: String
    let lastSyncTimestamp: String
    let googleDesktopClientId: String
    let googleServerClientId: String

    private enum CodingKeys: String, CodingKey {
        case isConfigured
        case isAuthenticated
        case userId
        case email
        case lastSyncTimestamp
        case googleDesktopClientId
        case googleServerClientId
    }

    init(
        isConfigured: Bool = false,
        isAuthenticated: Bool = false,
        userId: String = "",
        email: String = "",
        lastSyncTimestamp: String = "",
        googleDesktopClientId: String = "",
        googleServerClientId: String = ""
    ) {
        self.isConfigured = isConfigured
        self.isAuthenticated = isAuthenticated
        self.userId = userId
        self.email = email
        self.lastSyncTimestamp = lastSyncTimestamp
        self.googleDesktopClientId = googleDesktopClientId
        self.googleServerClientId = googleServerClientId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isConfigured = try container.decodeIfPresent(Bool.self, forKey: .isConfigured) ?? false
        isAuthenticated = try container.decodeIfPresent(Bool.self, forKey: .isAuthenticated) ?? false
        userId = try container.decodeIfPresent(String.self, forKey: .userId) ?? ""
        email = try container.decodeIfPresent(String.self, forKey: .email) ?? ""
        lastSyncTimestamp = try container.decodeIfPresent(String.self, forKey: .lastSyncTimestamp) ?? ""
        googleDesktopClientId = try container.decodeIfPresent(String.self, forKey: .googleDesktopClientId) ?? ""
        googleServerClientId = try container.decodeIfPresent(String.self, forKey: .googleServerClientId) ?? ""
    }
}

struct SupabaseOkResponse: Decodable, Sendable {
    let ok: Bool
}

actor NyoraHelperBridge {
    struct HelperState {
        var status: HelperStatus
        var baseUrl: String
        var error: String?
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg)
    }()

    private var baseUrl: URL?
    private var stateHandler: (@Sendable (HelperState) async -> Void)?
    private let launcher = HelperLauncher()

    // MARK: Lifecycle

    func start(onStateChange handler: @Sendable @escaping (HelperState) async -> Void) async {
        stateHandler = handler
        await emit(.init(status: .starting, baseUrl: ""))

        let result = await launcher.launchIfNeeded()
        switch result {
        case .alreadyRunning, .launched:
            if let url = await waitForHelper(timeoutSeconds: 20) {
                baseUrl = url
                await emit(.init(status: .running, baseUrl: url.absoluteString))
            } else {
                let extra = await launcher.collectStderr().map { ": \($0)" } ?? ""
                await emit(.init(status: .error, baseUrl: "",
                                 error: "Helper failed to bind a port within 20s\(extra)"))
            }
        case .javaMissing:
            await emit(.init(status: .error, baseUrl: "",
                             error: "Java 17+ not found. Install with `brew install openjdk@17` or set NYORA_JAVA."))
        case .jarMissing:
            await emit(.init(status: .error, baseUrl: "",
                             error: "nyora-helper.jar not found. Run `./gradlew :shared:helperJar`."))
        case let .failed(message):
            await emit(.init(status: .error, baseUrl: "", error: "Launch failed: \(message)"))
        }
    }

    func stop() async {
        baseUrl = nil
        await launcher.terminate()
        await emit(.init(status: .stopped, baseUrl: ""))
    }

    func currentBaseUrl() -> URL? { baseUrl }

    // MARK: Sources

    func fetchSources() async throws -> [SourceSummary] {
        let response: HelperSourcesResponse = try await get("/sources")
        return response.sources.map(SourceSummary.init)
    }

    func refreshSources() async throws -> [SourceSummary] {
        let response: HelperSourcesResponse = try await post("/sources/refresh")
        return response.sources.map(SourceSummary.init)
    }

    func install(sourceId: String) async throws -> SourceSummary {
        let response: HelperSourceResponse = try await post("/sources/install?id=\(sourceId.urlEscaped)")
        return SourceSummary(response.source)
    }

    func uninstall(sourceId: String) async throws -> SourceSummary {
        let response: HelperSourceResponse = try await post("/sources/uninstall?id=\(sourceId.urlEscaped)")
        return SourceSummary(response.source)
    }

    func togglePin(sourceId: String) async throws -> [SourceSummary] {
        let response: HelperSourcesResponse = try await post("/sources/pin?id=\(sourceId.urlEscaped)")
        return response.sources.map(SourceSummary.init)
    }

    func catalog() async throws -> [HelperCatalogEntry] {
        let response: HelperCatalogResponse = try await get("/sources/catalog")
        return response.entries
    }

    // MARK: Library — history + favourites

    func history(limit: Int = 100) async throws -> [HelperHistoryRow] {
        let response: HelperHistoryResponse = try await get("/library/history?limit=\(limit)")
        return response.entries
    }

    func recordHistory(mangaId: String, sourceId: String, chapterId: String, chapterTitle: String, page: Int, percent: Float) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let q = "mangaId=\(mangaId.urlEscaped)&sourceId=\(sourceId.urlEscaped)&chapterId=\(chapterId.urlEscaped)&chapterTitle=\(chapterTitle.urlEscaped)&page=\(page)&percent=\(percent)"
        let _: OkResponse = try await post("/library/history/record?\(q)")
    }

    func removeHistory(mangaId: String) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/library/history/remove?mangaId=\(mangaId.urlEscaped)")
    }

    func clearHistory() async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/library/history/clear")
    }

    func clearDatabase() async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/library/clear")
    }

    func favourites() async throws -> [HelperManga] {
        let response: HelperFavouritesResponse = try await get("/library/favourites")
        return response.entries
    }

    func isFavourited(mangaId: String) async throws -> Bool {
        let response: HelperFavouritedResponse = try await get("/library/favourites/check?mangaId=\(mangaId.urlEscaped)")
        return response.favourited
    }

    func toggleFavourite(mangaId: String) async throws -> Bool {
        let response: HelperFavouritedResponse = try await post("/library/favourites/toggle?mangaId=\(mangaId.urlEscaped)")
        return response.favourited
    }

    // MARK: Library — bookmarks

    func bookmarks() async throws -> [HelperBookmark] {
        let response: HelperBookmarksResponse = try await get("/library/bookmarks")
        return response.entries
    }

    func addBookmark(mangaId: String, chapterId: String, chapterTitle: String, page: Int, note: String = "") async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let q = "mangaId=\(mangaId.urlEscaped)&chapterId=\(chapterId.urlEscaped)&chapterTitle=\(chapterTitle.urlEscaped)&page=\(page)&note=\(note.urlEscaped)"
        let _: OkResponse = try await post("/library/bookmarks/add?\(q)")
    }

    func removeBookmark(id: Int64) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/library/bookmarks/remove?id=\(id)")
    }

    func removeBookmarkForPage(mangaId: String, chapterId: String, page: Int) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let q = "mangaId=\(mangaId.urlEscaped)&chapterId=\(chapterId.urlEscaped)&page=\(page)"
        let _: OkResponse = try await post("/library/bookmarks/remove?\(q)")
    }

    func isPageBookmarked(mangaId: String, chapterId: String, page: Int) async throws -> Bool {
        let q = "mangaId=\(mangaId.urlEscaped)&chapterId=\(chapterId.urlEscaped)&page=\(page)"
        let response: HelperBookmarkedResponse = try await get("/library/bookmarks/check?\(q)")
        return response.bookmarked
    }

    // MARK: Library — updates

    func updates() async throws -> [HelperUpdate] {
        let response: HelperUpdatesResponse = try await get("/library/updates")
        return response.entries
    }

    func refreshUpdates() async throws -> HelperUpdatesRefreshResult {
        return try await post("/library/updates/refresh")
    }

    func markUpdatesSeen(mangaId: String? = nil) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        if let mangaId {
            let _: OkResponse = try await post("/library/updates/seen?mangaId=\(mangaId.urlEscaped)")
        } else {
            let _: OkResponse = try await post("/library/updates/seen")
        }
    }

    // MARK: Local CBZ reader

    func scanLocalFolder(_ folder: String) async throws -> [HelperLocalCbz] {
        let response: HelperLocalScanResponse = try await get("/local/scan?folder=\(folder.urlEscaped)")
        return response.entries
    }

    func openLocalChapter(_ cbzPath: String) async throws -> HelperLocalChapter {
        return try await get("/local/chapter?cbz=\(cbzPath.urlEscaped)")
    }

    // MARK: Browse

    func popular(sourceId: String, page: Int) async throws -> [MangaSummary] {
        let response: HelperBrowseResponse = try await get(
            "/sources/popular?id=\(sourceId.urlEscaped)&page=\(page)"
        )
        return response.entries.map { MangaSummary($0, sourceName: sourceId) }
    }

    func latest(sourceId: String, page: Int) async throws -> [MangaSummary] {
        let response: HelperBrowseResponse = try await get(
            "/sources/latest?id=\(sourceId.urlEscaped)&page=\(page)"
        )
        return response.entries.map { MangaSummary($0, sourceName: sourceId) }
    }

    func search(sourceId: String, query: String, page: Int) async throws -> [MangaSummary] {
        let response: HelperBrowseResponse = try await get(
            "/sources/search?id=\(sourceId.urlEscaped)&q=\(query.urlEscaped)&page=\(page)"
        )
        return response.entries.map { MangaSummary($0, sourceName: sourceId) }
    }

    // MARK: Details + pages

    func details(sourceId: String, mangaUrl: String) async throws -> HelperDetailsResponse {
        return try await get(
            "/manga/details?id=\(sourceId.urlEscaped)&url=\(mangaUrl.urlEscaped)"
        )
    }

    func pages(sourceId: String, chapterUrl: String) async throws -> [HelperImagePage] {
        let response: HelperPagesResponse = try await get(
            "/manga/pages?id=\(sourceId.urlEscaped)&url=\(chapterUrl.urlEscaped)"
        )
        return response.pages
    }

    // MARK: Image proxy

    func imageProxyURL(for page: HelperImagePage) -> URL? {
        guard let base = baseUrl else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("image"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "u", value: page.url)]
        for (k, v) in page.headers {
            items.append(URLQueryItem(name: "h", value: "\(k):\(v)"))
        }
        components?.queryItems = items
        return components?.url
    }

    // MARK: Per-manga prefs

    func mangaPrefs(mangaId: String) async throws -> HelperMangaPrefs {
        return try await get("/manga/prefs?mangaId=\(mangaId.urlEscaped)")
    }

    func saveMangaPrefs(
        mangaId: String,
        readerMode: String,
        brightness: Double,
        contrast: Double,
        saturation: Double,
        hue: Double,
        palette: String
    ) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let q = "mangaId=\(mangaId.urlEscaped)&readerMode=\(readerMode.urlEscaped)"
            + "&brightness=\(brightness)&contrast=\(contrast)&saturation=\(saturation)"
            + "&hue=\(hue)&palette=\(palette.urlEscaped)"
        let _: OkResponse = try await post("/manga/prefs/save?\(q)")
    }

    func clearMangaPrefs(mangaId: String) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/manga/prefs/clear?mangaId=\(mangaId.urlEscaped)")
    }

    // MARK: Categories

    func categories() async throws -> [HelperCategory] {
        let response: HelperCategoriesResponse = try await get("/library/categories")
        return response.categories
    }

    func createCategory(title: String) async throws -> HelperCategory {
        struct CreateResponse: Decodable { let category: HelperCategory }
        let response: CreateResponse = try await post("/library/categories/create?title=\(title.urlEscaped)")
        return response.category
    }

    func renameCategory(id: Int64, title: String) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/library/categories/rename?id=\(id)&title=\(title.urlEscaped)")
    }

    func deleteCategory(id: Int64) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/library/categories/delete?id=\(id)")
    }

    func addToCategory(mangaId: String, categoryId: Int64) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post(
            "/library/categories/add?mangaId=\(mangaId.urlEscaped)&categoryId=\(categoryId)"
        )
    }

    func removeFromCategory(mangaId: String, categoryId: Int64) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post(
            "/library/categories/remove?mangaId=\(mangaId.urlEscaped)&categoryId=\(categoryId)"
        )
    }

    func categoriesForManga(mangaId: String) async throws -> [HelperCategory] {
        let response: HelperCategoriesResponse = try await get(
            "/library/categories/manga?mangaId=\(mangaId.urlEscaped)"
        )
        return response.categories
    }

    func favouritesIn(categoryId: Int64) async throws -> [HelperManga] {
        let response: HelperFavouritesResponse = try await get(
            "/library/favourites?categoryId=\(categoryId)"
        )
        return response.entries
    }

    // MARK: Downloads

    func downloads() async throws -> [HelperDownload] {
        let response: HelperDownloadsResponse = try await get("/downloads")
        return response.entries
    }

    func startDownload(sourceId: String, mangaUrl: String, chapterUrl: String, mangaTitle: String, chapterTitle: String) async throws -> HelperDownload {
        let q = "sourceId=\(sourceId.urlEscaped)&mangaUrl=\(mangaUrl.urlEscaped)&chapterUrl=\(chapterUrl.urlEscaped)"
            + "&mangaTitle=\(mangaTitle.urlEscaped)&chapterTitle=\(chapterTitle.urlEscaped)"
        let response: HelperDownloadResponse = try await post("/downloads/start?\(q)")
        return response.entry
    }

    /// Batch-enqueue a set of chapters (range / multi-select). `chapters` = [(url, title)].
    @discardableResult
    func enqueueDownloads(sourceId: String, mangaUrl: String, mangaTitle: String,
                          chapters: [(url: String, title: String)]) async throws -> [HelperDownload] {
        guard let base = baseUrl else { throw HelperError(error: "Helper not connected") }
        guard !chapters.isEmpty else { return [] }
        let q = "sourceId=\(sourceId.urlEscaped)&mangaUrl=\(mangaUrl.urlEscaped)&mangaTitle=\(mangaTitle.urlEscaped)"
        guard var comps = URLComponents(url: base.appendingPathComponent("downloads/enqueue"), resolvingAgainstBaseURL: false) else {
            throw HelperError(error: "Bad helper URL")
        }
        comps.percentEncodedQuery = q
        guard let url = comps.url else { throw HelperError(error: "Bad helper URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: chapters.map { ["url": $0.url, "title": $0.title] })
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            if let e = try? JSONDecoder().decode(HelperError.self, from: data) { throw e }
            throw HelperError(error: "Enqueue failed")
        }
        return (try? JSONDecoder().decode(HelperDownloadsResponse.self, from: data))?.entries ?? []
    }

    func cancelDownload(id: String) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let _: OkResponse = try await post("/downloads/cancel?id=\(id.urlEscaped)")
    }

    /// Re-queue a failed/cancelled download using the job's stored chapter info.
    @discardableResult
    func retryDownload(_ d: HelperDownload) async throws -> HelperDownload {
        try await startDownload(sourceId: d.sourceId, mangaUrl: "", chapterUrl: d.chapterUrl,
                                mangaTitle: d.mangaTitle, chapterTitle: d.chapterTitle)
    }

    func downloadSettings() async throws -> HelperDownloadSettings {
        let r: HelperDownloadSettingsResponse = try await get("/downloads/settings")
        return r.settings
    }

    @discardableResult
    func setDownloadSettings(maxConcurrent: Int, format: String) async throws -> HelperDownloadSettings {
        let r: HelperDownloadSettingsResponse = try await post(
            "/downloads/settings?maxConcurrent=\(maxConcurrent)&format=\(format.urlEscaped)")
        return r.settings
    }

    // MARK: Global search

    func globalSearch(query: String) async throws -> HelperGlobalSearchResponse {
        // Global search fans out across the whole curated catalogue server-side,
        // so give the request a long timeout — it must not be aborted mid-search.
        return try await get("/search/global?q=\(query.urlEscaped)", timeout: 600)
    }

    // MARK: Stats / suggestions / alternatives

    func stats() async throws -> HelperStats {
        return try await get("/stats")
    }

    func suggestions() async throws -> [HelperSuggestedManga] {
        let response: HelperSuggestions = try await get("/suggestions")
        return response.entries
    }

    func alternatives(title: String) async throws -> [HelperAlternativeMatch] {
        let response: HelperAlternatives = try await get(
            "/manga/alternatives?title=\(title.urlEscaped)"
        )
        return response.entries
    }

    // MARK: Backup

    func backupExport() async throws -> Data {
        guard let base = baseUrl else { throw HelperError(error: "Helper not connected") }
        let url = base.appendingPathComponent("backup/export")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw HelperError(error: "Export failed")
        }
        return data
    }

    func backupImport(_ data: Data) async throws -> HelperBackupImportResult {
        guard let base = baseUrl else { throw HelperError(error: "Helper not connected") }
        let url = base.appendingPathComponent("backup/import")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (respData, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            if let err = try? JSONDecoder().decode(HelperError.self, from: respData) { throw err }
            throw HelperError(error: "Import failed")
        }
        return try JSONDecoder().decode(HelperBackupImportResult.self, from: respData)
    }

    // MARK: Filters

    func sourceFilters(sourceId: String) async throws -> [HelperSourceFilter] {
        let response: HelperSourceFilters = try await get(
            "/sources/filters?id=\(sourceId.urlEscaped)"
        )
        return response.filters
    }

    func searchWithFilters(
        sourceId: String,
        query: String,
        page: Int,
        filters: [[String: Any]]
    ) async throws -> [MangaSummary] {
        var q = "/sources/search?id=\(sourceId.urlEscaped)&page=\(page)&q=\(query.urlEscaped)"
        if !filters.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: filters, options: [])
            let json = String(decoding: data, as: UTF8.self)
            q += "&f=\(json.urlEscaped)"
        }
        let response: HelperBrowseResponse = try await get(q)
        return response.entries.map { MangaSummary($0, sourceName: sourceId) }
    }

    // MARK: Supabase

    func supabaseStatus() async throws -> SupabaseStatusResponse {
        try await get("/supabase/status")
    }

    func supabaseSignIn(idToken: String) async throws -> Bool {
        let response: SupabaseOkResponse = try await post("/supabase/signin?idToken=\(idToken.urlEscaped)")
        return response.ok
    }

    func supabaseSignOut() async throws {
        let _: SupabaseOkResponse = try await post("/supabase/signout")
    }

    func supabaseSync() async throws {
        let _: SupabaseOkResponse = try await post("/supabase/sync")
    }

    func supabaseRestoreFromCloud() async throws {
        let _: SupabaseOkResponse = try await post("/supabase/restore-from-cloud")
    }

    func supabaseHasLocalData() async throws -> Bool {
        struct Response: Decodable { let hasLocalData: Bool }
        let resp: Response = try await get("/supabase/has-local-data")
        return resp.hasLocalData
    }

    // MARK: AniList browse feed (public GraphQL — no auth needed)

    /// Fetches Trending / Popular-this-season / Top-rated manga from AniList's
    /// public GraphQL API in a single batched request. When `hideAdult` is
    /// true, `isAdult: false` is passed so NSFW titles never reach the feed.
    func anilistBrowse(hideAdult: Bool) async throws -> AniListBrowseData {
        let adultClause = hideAdult ? ", isAdult: false" : ""
        let fields = "id title { romaji english native } coverImage { large } isAdult genres averageScore"
        let query = """
        query {
          trending: Page(page: 1, perPage: 24) {
            media(type: MANGA, sort: TRENDING_DESC\(adultClause)) { \(fields) }
          }
          popular: Page(page: 1, perPage: 24) {
            media(type: MANGA, sort: POPULARITY_DESC\(adultClause)) { \(fields) }
          }
          topRated: Page(page: 1, perPage: 24) {
            media(type: MANGA, sort: SCORE_DESC\(adultClause)) { \(fields) }
          }
        }
        """
        guard let url = URL(string: "https://graphql.anilist.co") else {
            throw HelperError(error: "Bad AniList URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw HelperError(error: "AniList feed unavailable")
        }
        let decoded = try JSONDecoder().decode(AniListBrowseResponse.self, from: data)
        guard let payload = decoded.data else {
            throw HelperError(error: "AniList returned no data")
        }
        return payload
    }

    // MARK: Tracker (AniList)

    func anilistSearch(title: String, token: String) async throws -> [AniListMedia] {
        guard let base = baseUrl else { throw HelperError(error: "Helper not connected") }
        var comps = URLComponents(url: base.appendingPathComponent("tracker/anilist/search"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "title", value: title)]
        var req = URLRequest(url: comps?.url ?? base)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            throw HelperError(error: "AniList search failed")
        }
        let decoded = try JSONDecoder().decode(AniListSearchResponse.self, from: data)
        return decoded.data?.Page?.media ?? []
    }

    @discardableResult
    func anilistScrobble(mediaId: Int, progress: Int, status: String, token: String) async throws -> Bool {
        guard let base = baseUrl else { throw HelperError(error: "Helper not connected") }
        var comps = URLComponents(url: base.appendingPathComponent("tracker/anilist/scrobble"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "mediaId", value: String(mediaId)),
            URLQueryItem(name: "progress", value: String(progress)),
            URLQueryItem(name: "status", value: status),
        ]
        guard let url = comps?.url else { throw HelperError(error: "Bad URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode < 400
    }

    // MARK: Internals

    private func get<T: Decodable>(_ path: String, timeout: TimeInterval? = nil) async throws -> T {
        return try await call(path: path, method: "GET", timeout: timeout)
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        return try await call(path: path, method: "POST")
    }

    private func call<T: Decodable>(path: String, method: String, timeout: TimeInterval? = nil,
                                    triedCloudflare: Bool = false) async throws -> T {
        guard let base = baseUrl else { throw HelperError(error: "Helper not connected") }
        let url = base.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
        let withQuery: URL
        if let qIdx = path.firstIndex(of: "?") {
            let qs = path[path.index(after: qIdx)...]
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.percentEncodedQuery = String(qs)
            withQuery = comps?.url ?? url
        } else {
            withQuery = url
        }
        var request = URLRequest(url: withQuery)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HelperError(error: "Non-HTTP response")
        }
        if http.statusCode >= 400 {
            if let helperErr = try? JSONDecoder().decode(HelperError.self, from: data) {
                // Cloudflare JS challenge → solve in a WebView, push the clearance to
                // the helper's cookie jar, and retry the request once.
                if let host = helperErr.cloudflareHost, !triedCloudflare,
                   let cookieHeader = await MacCloudflareSolver.shared.solve(host: host) {
                    await postCloudflareClearance(host: host, cookieHeader: cookieHeader)
                    return try await call(path: path, method: method, timeout: timeout, triedCloudflare: true)
                }
                throw helperErr
            }
            throw HelperError(error: "HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            if let helperErr = try? JSONDecoder().decode(HelperError.self, from: data) {
                throw helperErr
            }
            let rawBody = String(decoding: data.prefix(2000), as: UTF8.self)
            print("[NyoraHelperBridge] Decode failed for \(method) \(path): \(error.localizedDescription). Body: \(rawBody)")
            throw HelperError(error: "Content unavailable for \(method) \(path). Please try again later.")
        }
    }

    /// POST a solved `cf_clearance` cookie header to the helper for `host`.
    private func postCloudflareClearance(host: String, cookieHeader: String) async {
        guard let base = baseUrl else { return }
        var comps = URLComponents(url: base.appendingPathComponent("cloudflare/clearance"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "domain", value: host)]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = cookieHeader.data(using: .utf8)
        _ = try? await session.data(for: req)
    }

    /// Polls helper.port + /health for up to `timeoutSeconds`, returning
    /// the base URL as soon as the helper responds.
    private func waitForHelper(timeoutSeconds: Int) async -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let portFile = appSupport.appendingPathComponent("Nyora/helper.port")
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while Date() < deadline {
            if let portString = try? String(contentsOf: portFile, encoding: .utf8),
               let port = Int(portString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                guard let candidate = URL(string: "http://127.0.0.1:\(port)") else { continue }
                do {
                    var req = URLRequest(url: candidate.appendingPathComponent("health"))
                    req.timeoutInterval = 0.8
                    let (_, response) = try await session.data(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        return candidate
                    }
                } catch {
                    // Not ready yet, keep polling.
                }
            }
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        }
        return nil
    }

    private func emit(_ state: HelperState) async {
        await stateHandler?(state)
    }
}

private extension String {
    var urlEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

// MARK: - Adapters from HelperDTOs to UI summaries

extension SourceSummary {
    init(_ source: HelperSource) {
        self.init(
            id: source.id,
            name: source.name,
            lang: source.lang,
            engine: source.engine,
            isInstalled: source.isInstalled,
            isPinned: source.isPinned,
            isNsfw: source.isNsfw
        )
    }
}

extension MangaSummary {
    init(_ manga: HelperManga, sourceName: String) {
        self.init(
            id: manga.id,
            title: manga.title,
            sourceName: sourceName,
            coverUrl: manga.coverUrl,
            unread: manga.unread,
            progress: manga.progress,
            tags: manga.tags.map(\.title),
            url: manga.url
        )
    }

    init(_ row: HelperHistoryRow) {
        self.init(
            id: row.mangaId,
            title: row.mangaTitle,
            sourceName: row.sourceName,
            coverUrl: row.mangaCoverUrl,
            unread: 0,
            progress: row.percent,
            tags: []
        )
    }
}
