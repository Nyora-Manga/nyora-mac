import Foundation

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
    private var stateHandler: ((HelperState) async -> Void)?
    private let launcher = HelperLauncher()

    // MARK: Lifecycle

    func start(onStateChange handler: @escaping (HelperState) async -> Void) async {
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

    func recordHistory(mangaId: String, chapterId: String, chapterTitle: String, page: Int, percent: Float) async throws {
        struct OkResponse: Decodable { let ok: Bool }
        let q = "mangaId=\(mangaId.urlEscaped)&chapterId=\(chapterId.urlEscaped)&chapterTitle=\(chapterTitle.urlEscaped)&page=\(page)&percent=\(percent)"
        let _: OkResponse = try await post("/library/history/record?\(q)")
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

    // MARK: Internals

    private func get<T: Decodable>(_ path: String) async throws -> T {
        return try await call(path: path, method: "GET")
    }

    private func post<T: Decodable>(_ path: String) async throws -> T {
        return try await call(path: path, method: "POST")
    }

    private func call<T: Decodable>(path: String, method: String) async throws -> T {
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HelperError(error: "Non-HTTP response")
        }
        if http.statusCode >= 400 {
            if let helperErr = try? JSONDecoder().decode(HelperError.self, from: data) {
                throw helperErr
            }
            throw HelperError(error: "HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
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
                let candidate = URL(string: "http://127.0.0.1:\(port)")!
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
            isPinned: source.isPinned
        )
    }
}

extension MangaSummary {
    init(_ manga: HelperManga, sourceName: String) {
        self.init(
            id: manga.id,
            title: manga.title,
            sourceName: sourceName,
            unread: manga.unread,
            progress: manga.progress,
            tags: manga.tags.map(\.title)
        )
    }
}
