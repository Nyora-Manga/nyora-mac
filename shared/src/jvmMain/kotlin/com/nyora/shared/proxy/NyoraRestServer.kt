package com.nyora.shared.proxy

import com.nyora.shared.NyoraFacade
import com.nyora.shared.data.ExtensionInstaller
import com.nyora.shared.data.SourceCatalogClient
import com.nyora.shared.model.Library
import com.nyora.shared.model.Manga
import com.nyora.shared.model.MangaChapter
import com.nyora.shared.model.MangaPage
import com.nyora.shared.model.MangaSource
import com.nyora.shared.reader.PageImageLoader
import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.URI
import java.net.URLDecoder
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

/**
 * REST surface for the SwiftUI client.
 *
 * Endpoints (all loopback):
 *
 *  GET    /health
 *  GET    /sources
 *  POST   /sources/refresh
 *  POST   /sources/install?id=
 *  DELETE /sources/uninstall?id=
 *  POST   /sources/pin?id=
 *  GET    /sources/popular?id=&page=
 *  GET    /sources/latest?id=&page=
 *  GET    /sources/search?id=&q=&page=
 *  GET    /manga/details?id=&url=
 *  GET    /manga/pages?id=&url=
 *  GET    /image?u=<url>&h=<header-name>:<value>&h=...
 */
class NyoraRestServer(
    private val facade: NyoraFacade,
    private val catalog: SourceCatalogClient,
    private val installer: ExtensionInstaller,
    private val pageLoader: PageImageLoader = PageImageLoader(),
    private val host: InetAddress = InetAddress.getLoopbackAddress(),
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
        prettyPrint = false
    }
    private var server: HttpServer? = null

    val baseUrl: String
        get() = server?.address?.port?.let { "http://127.0.0.1:$it" }.orEmpty()

    val isRunning: Boolean
        get() = server != null

    fun start(): String {
        if (server != null) return baseUrl
        val httpServer = HttpServer.create(InetSocketAddress(host, 0), 0).apply {
            createContext("/") { handleRoot(it) }
            createContext("/health") { respondJson(it, 200, buildJsonObject { put("status", "ok") }) }
            createContext("/sources/refresh") { handleRefresh(it) }
            createContext("/sources/catalog") { handleCatalog(it) }
            createContext("/sources/install") { handleInstall(it) }
            createContext("/sources/uninstall") { handleUninstall(it) }
            createContext("/sources/pin") { handlePin(it) }
            createContext("/sources/popular") { handleBrowse(it, BrowseMode.POPULAR) }
            createContext("/sources/latest") { handleBrowse(it, BrowseMode.LATEST) }
            createContext("/sources/search") { handleBrowse(it, BrowseMode.SEARCH) }
            createContext("/sources") { handleSources(it) }
            createContext("/manga/details") { handleDetails(it) }
            createContext("/manga/pages") { handlePages(it) }
            createContext("/image") { handleImage(it) }
            createContext("/library/history/record") { handleHistoryRecord(it) }
            createContext("/library/history") { handleHistory(it) }
            createContext("/library/favourites/toggle") { handleFavouriteToggle(it) }
            createContext("/library/favourites/check") { handleFavouriteCheck(it) }
            createContext("/library/favourites") { handleFavourites(it) }
            createContext("/library/bookmarks/add") { handleBookmarkAdd(it) }
            createContext("/library/bookmarks/remove") { handleBookmarkRemove(it) }
            createContext("/library/bookmarks/check") { handleBookmarkCheck(it) }
            createContext("/library/bookmarks") { handleBookmarks(it) }
            createContext("/library/updates/refresh") { handleUpdatesRefresh(it) }
            createContext("/library/updates/seen") { handleUpdatesSeen(it) }
            createContext("/library/updates") { handleUpdates(it) }
            createContext("/local/scan") { handleLocalScan(it) }
            createContext("/local/chapter") { handleLocalChapter(it) }
            createContext("/local/image") { handleLocalImage(it) }
            executor = Executors.newCachedThreadPool()
            start()
        }
        server = httpServer
        return baseUrl
    }

    fun stop() {
        server?.stop(0)
        server = null
    }

    private fun handleRoot(exchange: HttpExchange) {
        respondJson(exchange, 200, buildJsonObject {
            put("name", "Nyora helper")
            put("baseUrl", baseUrl)
        })
    }

    private fun handleSources(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val sources = facade.listSources()
        respondJson(exchange, 200, json.encodeToJsonElement(SourceListResponse(sources)))
    }

    private fun handleRefresh(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        try {
            val library = facade.loadLibrary()
            val installed = library.sources.filter { it.isInstalled }.associateBy { it.id }
            val builtIn = library.sources.filter { it.localPath.startsWith("classpath:") }
            val fetched = library.repos.flatMap { runCatching { catalog.fetch(it) }.getOrDefault(emptyList()) }
            val merged = (builtIn + fetched).distinctBy { it.id }.map { src ->
                val existing = installed[src.id]
                if (existing != null) {
                    src.copy(
                        isInstalled = existing.isInstalled,
                        isPinned = existing.isPinned,
                        localPath = existing.localPath,
                        installedAt = existing.installedAt,
                    )
                } else src
            }
            facade.saveLibrary(library.copy(sources = merged))
            respondJson(exchange, 200, json.encodeToJsonElement(SourceListResponse(facade.listSources())))
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Refresh failed")
        }
    }

    private fun handleCatalog(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val installed = facade.listSources().filter { it.isInstalled }.map { it.id }.toSet()
        val entries = org.koitharu.kotatsu.parsers.model.MangaParserSource.entries.map { parserSource ->
            val id = "parser:${parserSource.name}"
            CatalogEntry(
                id = id,
                name = parserSource.title,
                lang = parserSource.locale ?: "all",
                engine = com.nyora.shared.model.SourceEngine.Parser.name,
                contentType = parserSource.contentType.name,
                isBroken = parserSource.isBroken,
                isInstalled = id in installed,
            )
        }
        respondJson(exchange, 200, json.encodeToJsonElement(CatalogResponse(entries)))
    }

    private fun handleInstall(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val id = exchange.query()["id"]
        if (id.isNullOrBlank()) {
            respondError(exchange, 400, "Missing 'id'"); return
        }
        // Already in DB? Use the existing row (covers JS / Mihon sources too).
        val existing = facade.listSources().firstOrNull { it.id == id }
        if (existing != null) {
            try {
                val installed = if (id.startsWith("parser:")) {
                    // Parser sources are baked into the JAR — just flip the install bit.
                    val flipped = existing.copy(isInstalled = true, installedAt = System.currentTimeMillis())
                    facade.installSource(flipped) { it }
                } else {
                    facade.installSource(existing, installer::install)
                }
                respondJson(exchange, 200, json.encodeToJsonElement(SourceResponse(installed)))
            } catch (error: Exception) {
                respondError(exchange, 500, error.message ?: "Install failed")
            }
            return
        }
        // Not in DB yet — accept install for a catalog parser source.
        if (!id.startsWith("parser:")) {
            return respondError(exchange, 404, "Unknown source: $id")
        }
        val enumName = id.removePrefix("parser:")
        val parserSource = runCatching {
            org.koitharu.kotatsu.parsers.model.MangaParserSource.valueOf(enumName)
        }.getOrNull() ?: return respondError(exchange, 404, "Unknown parser source: $enumName")
        try {
            val source = com.nyora.shared.model.MangaSource(
                id = id,
                name = parserSource.title,
                lang = parserSource.locale ?: "all",
                baseUrl = "",
                isInstalled = true,
                engine = com.nyora.shared.model.SourceEngine.Parser,
                contentType = mapContentType(parserSource.contentType),
                notes = "Native Kotatsu parser.",
                canUninstall = true,
                installedAt = System.currentTimeMillis(),
            )
            val installed = facade.installSource(source) { it }
            respondJson(exchange, 200, json.encodeToJsonElement(SourceResponse(installed)))
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Install failed")
        }
    }

    private fun mapContentType(
        type: org.koitharu.kotatsu.parsers.model.ContentType,
    ): com.nyora.shared.model.SourceContentType = when (type) {
        org.koitharu.kotatsu.parsers.model.ContentType.MANGA -> com.nyora.shared.model.SourceContentType.Manga
        org.koitharu.kotatsu.parsers.model.ContentType.MANHWA -> com.nyora.shared.model.SourceContentType.Manhwa
        org.koitharu.kotatsu.parsers.model.ContentType.MANHUA -> com.nyora.shared.model.SourceContentType.Manhua
        org.koitharu.kotatsu.parsers.model.ContentType.HENTAI -> com.nyora.shared.model.SourceContentType.Hentai
        org.koitharu.kotatsu.parsers.model.ContentType.COMICS -> com.nyora.shared.model.SourceContentType.Comics
        org.koitharu.kotatsu.parsers.model.ContentType.NOVEL -> com.nyora.shared.model.SourceContentType.Novel
        org.koitharu.kotatsu.parsers.model.ContentType.ONE_SHOT -> com.nyora.shared.model.SourceContentType.OneShot
        org.koitharu.kotatsu.parsers.model.ContentType.DOUJINSHI -> com.nyora.shared.model.SourceContentType.Doujinshi
        org.koitharu.kotatsu.parsers.model.ContentType.IMAGE_SET -> com.nyora.shared.model.SourceContentType.ImageSet
        org.koitharu.kotatsu.parsers.model.ContentType.ARTIST_CG -> com.nyora.shared.model.SourceContentType.ArtistCg
        org.koitharu.kotatsu.parsers.model.ContentType.GAME_CG -> com.nyora.shared.model.SourceContentType.GameCg
        org.koitharu.kotatsu.parsers.model.ContentType.OTHER -> com.nyora.shared.model.SourceContentType.Other
    }

    private fun handleUninstall(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("DELETE", ignoreCase = true) &&
            !exchange.requestMethod.equals("POST", ignoreCase = true)
        ) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val id = exchange.query()["id"]
        if (id.isNullOrBlank()) {
            respondError(exchange, 400, "Missing 'id'"); return
        }
        val source = facade.listSources().firstOrNull { it.id == id }
            ?: return respondError(exchange, 404, "Unknown source: $id")
        if (!source.canUninstall) {
            respondError(exchange, 409, "Source is built-in and cannot be uninstalled"); return
        }
        try {
            val uninstalled = facade.installSource(source, installer::uninstall)
            respondJson(exchange, 200, json.encodeToJsonElement(SourceResponse(uninstalled)))
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Uninstall failed")
        }
    }

    private fun handlePin(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val id = exchange.query()["id"]
        if (id.isNullOrBlank()) {
            respondError(exchange, 400, "Missing 'id'"); return
        }
        facade.togglePin(id)
        respondJson(exchange, 200, json.encodeToJsonElement(SourceListResponse(facade.listSources())))
    }

    private enum class BrowseMode { POPULAR, LATEST, SEARCH }

    private fun handleBrowse(exchange: HttpExchange, mode: BrowseMode) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val id = params["id"] ?: return respondError(exchange, 400, "Missing 'id'")
        val page = params["page"]?.toIntOrNull() ?: 1
        val source = facade.listSources().firstOrNull { it.id == id }
            ?: return respondError(exchange, 404, "Unknown source: $id")
        try {
            val service = facade.openExtension(source)
            val result = runBlocking {
                when (mode) {
                    BrowseMode.POPULAR -> service.getPopular(page)
                    BrowseMode.LATEST -> service.getLatest(page)
                    BrowseMode.SEARCH -> service.search(params["q"].orEmpty(), page)
                }
            }
            respondJson(exchange, 200, json.encodeToJsonElement(
                BrowseResponse(
                    entries = result.entries,
                    hasNextPage = result.hasNextPage,
                ),
            ))
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Browse failed")
        }
    }

    private fun handleDetails(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val id = params["id"] ?: return respondError(exchange, 400, "Missing 'id'")
        val url = params["url"] ?: return respondError(exchange, 400, "Missing 'url'")
        val source = facade.listSources().firstOrNull { it.id == id }
            ?: return respondError(exchange, 404, "Unknown source: $id")
        try {
            val service = facade.openExtension(source)
            val details = runBlocking { service.getDetails(url) }
            val manga = details.manga.copy(
                source = com.nyora.shared.model.MangaSourceRef.Script(source.name),
                chapters = details.chapters,
            )
            facade.upsertManga(manga)
            respondJson(exchange, 200, json.encodeToJsonElement(
                DetailsResponse(manga = manga, chapters = details.chapters),
            ))
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Details failed")
        }
    }

    private fun handlePages(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val id = params["id"] ?: return respondError(exchange, 400, "Missing 'id'")
        val url = params["url"] ?: return respondError(exchange, 400, "Missing 'url'")
        val refresh = params["refresh"]?.let { it == "1" || it.equals("true", ignoreCase = true) } ?: false
        val source = facade.listSources().firstOrNull { it.id == id }
            ?: return respondError(exchange, 404, "Unknown source: $id")
        if (!refresh) {
            facade.cachedPages(url)?.let { cached ->
                respondJson(exchange, 200, json.encodeToJsonElement(PagesResponse(pages = cached)))
                return
            }
        }
        try {
            val service = facade.openExtension(source)
            val chapter = MangaChapter(id = url, title = url, url = url)
            val pages = runBlocking { service.getPageList(chapter) }
            // Cache for the next request. `id` here is the source id; we don't
            // know the manga id at this point, so leave it as the source id —
            // the cache uses chapter_url as the unique key.
            facade.cachePages(url, id, pages)
            respondJson(exchange, 200, json.encodeToJsonElement(PagesResponse(pages = pages)))
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Pages failed")
        }
    }

    // MARK: - library: history

    private fun handleHistory(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val limit = exchange.query()["limit"]?.toIntOrNull() ?: 100
        val rows = facade.history(limit).map { HistoryRowDto(
            mangaId = it.manga.id,
            mangaTitle = it.manga.title,
            mangaCoverUrl = it.manga.coverUrl,
            sourceName = (it.manga.source as? com.nyora.shared.model.MangaSourceRef.Parser)?.name
                ?: (it.manga.source as? com.nyora.shared.model.MangaSourceRef.Script)?.name
                ?: it.manga.source.name,
            chapterId = it.chapterId,
            chapterTitle = it.chapterTitle,
            page = it.page,
            percent = it.percent,
            updatedAt = it.updatedAt,
        ) }
        respondJson(exchange, 200, json.encodeToJsonElement(HistoryResponse(rows)))
    }

    private fun handleHistoryRecord(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val mangaId = params["mangaId"] ?: return respondError(exchange, 400, "Missing 'mangaId'")
        val chapterId = params["chapterId"].orEmpty()
        val chapterTitle = params["chapterTitle"].orEmpty()
        val page = params["page"]?.toIntOrNull() ?: 0
        val percent = params["percent"]?.toFloatOrNull() ?: 0f
        facade.recordHistory(mangaId, chapterId, chapterTitle, page, percent)
        respondJson(exchange, 200, buildJsonObject { put("ok", true) })
    }

    // MARK: - library: favourites

    private fun handleFavourites(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        respondJson(exchange, 200, json.encodeToJsonElement(FavouritesResponse(facade.favourites())))
    }

    private fun handleFavouriteToggle(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val mangaId = exchange.query()["mangaId"]
            ?: return respondError(exchange, 400, "Missing 'mangaId'")
        val nowFavourited = facade.toggleFavourite(mangaId)
        respondJson(exchange, 200, buildJsonObject { put("favourited", nowFavourited) })
    }

    private fun handleFavouriteCheck(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val mangaId = exchange.query()["mangaId"]
            ?: return respondError(exchange, 400, "Missing 'mangaId'")
        respondJson(exchange, 200, buildJsonObject { put("favourited", facade.isFavourited(mangaId)) })
    }

    // MARK: - local: cbz / folder reader

    private fun handleLocalScan(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val folder = exchange.query()["folder"] ?: return respondError(exchange, 400, "Missing 'folder'")
        val dir = java.nio.file.Path.of(folder)
        if (!java.nio.file.Files.isDirectory(dir)) {
            return respondError(exchange, 404, "Not a directory: $folder")
        }
        val entries = try {
            java.nio.file.Files.list(dir).use { stream ->
                stream
                    .filter { it.fileName.toString().endsWith(".cbz", ignoreCase = true) ||
                             it.fileName.toString().endsWith(".cbr", ignoreCase = true) ||
                             it.fileName.toString().endsWith(".zip", ignoreCase = true) }
                    .sorted()
                    .map { p ->
                        LocalCbzEntry(
                            path = p.toAbsolutePath().toString(),
                            name = p.fileName.toString().removeSuffix(".cbz").removeSuffix(".CBZ"),
                            sizeBytes = runCatching { java.nio.file.Files.size(p) }.getOrDefault(0L),
                        )
                    }
                    .toList()
            }
        } catch (e: Exception) {
            return respondError(exchange, 500, e.message ?: "Scan failed")
        }
        respondJson(exchange, 200, json.encodeToJsonElement(LocalScanResponse(entries)))
    }

    private fun handleLocalChapter(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val cbz = exchange.query()["cbz"] ?: return respondError(exchange, 400, "Missing 'cbz'")
        val path = java.nio.file.Path.of(cbz)
        if (!java.nio.file.Files.isRegularFile(path)) {
            return respondError(exchange, 404, "Not a file: $cbz")
        }
        val entries: List<String> = try {
            java.util.zip.ZipFile(path.toFile()).use { zf ->
                val all = mutableListOf<String>()
                val enum = zf.entries()
                while (enum.hasMoreElements()) {
                    val e = enum.nextElement()
                    if (!e.isDirectory && isImageEntry(e.name)) all.add(e.name)
                }
                all.sorted()
            }
        } catch (e: Exception) {
            return respondError(exchange, 500, e.message ?: "Open failed")
        }
        // Use the helper's loopback host:port as the base for image URLs.
        val base = "http://127.0.0.1:${server!!.address.port}"
        val pageUrls = entries.map { entry ->
            val encCbz = java.net.URLEncoder.encode(cbz, java.nio.charset.StandardCharsets.UTF_8)
            val encEntry = java.net.URLEncoder.encode(entry, java.nio.charset.StandardCharsets.UTF_8)
            "$base/local/image?cbz=$encCbz&entry=$encEntry"
        }
        respondJson(exchange, 200, json.encodeToJsonElement(LocalChapterResponse(
            name = path.fileName.toString().removeSuffix(".cbz").removeSuffix(".CBZ"),
            pageCount = entries.size,
            pageUrls = pageUrls,
        )))
    }

    private fun handleLocalImage(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val cbz = params["cbz"] ?: return respondError(exchange, 400, "Missing 'cbz'")
        val entry = params["entry"] ?: return respondError(exchange, 400, "Missing 'entry'")
        val path = java.nio.file.Path.of(cbz)
        if (!java.nio.file.Files.isRegularFile(path)) {
            return respondError(exchange, 404, "Not a file: $cbz")
        }
        try {
            java.util.zip.ZipFile(path.toFile()).use { zf ->
                val zipEntry = zf.getEntry(entry)
                    ?: return respondError(exchange, 404, "Entry not found: $entry")
                val bytes = zf.getInputStream(zipEntry).readBytes()
                val contentType = guessContentType(entry, bytes)
                exchange.responseHeaders.add("Content-Type", contentType)
                exchange.responseHeaders.add("Cache-Control", "private, max-age=86400")
                exchange.sendResponseHeaders(200, bytes.size.toLong())
                exchange.responseBody.use { it.write(bytes) }
            }
        } catch (e: Exception) {
            respondError(exchange, 500, e.message ?: "Read failed")
        }
    }

    private fun isImageEntry(name: String): Boolean {
        val lower = name.lowercase()
        return lower.endsWith(".jpg") || lower.endsWith(".jpeg") ||
            lower.endsWith(".png") || lower.endsWith(".webp") ||
            lower.endsWith(".gif") || lower.endsWith(".avif")
    }

    // MARK: - library: updates

    private fun handleUpdates(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val rows = facade.updates().map { UpdateDto(
            mangaId = it.mangaId,
            mangaTitle = it.mangaTitle,
            mangaCoverUrl = it.mangaCoverUrl,
            sourceId = it.sourceId,
            newChapters = it.newChapters,
            totalChapters = it.totalChapters,
            latestChapterTitle = it.latestChapterTitle,
            lastSyncedAt = it.lastSyncedAt,
        ) }
        respondJson(exchange, 200, json.encodeToJsonElement(UpdatesResponse(rows)))
    }

    private fun handleUpdatesRefresh(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        var checked = 0
        var withNew = 0
        try {
            val favourites = facade.favourites()
            for (manga in favourites) {
                // Need a source to fetch from. Pick the source matching the manga.source ref name, or skip.
                val sourceName = manga.source.name
                val source = facade.listSources().firstOrNull { src ->
                    src.isInstalled && (src.name == sourceName || src.id.endsWith(":$sourceName"))
                } ?: continue
                runCatching {
                    val service = facade.openExtension(source)
                    val details = runBlocking { service.getDetails(manga.url.ifBlank { manga.id }) }
                    val count = details.chapters.size
                    val latestTitle = details.chapters.firstOrNull()?.title.orEmpty()
                    val before = (facade.updates().firstOrNull { it.mangaId == manga.id }?.totalChapters ?: -1)
                    facade.recordUpdateSync(
                        mangaId = manga.id,
                        sourceId = source.id,
                        currentChapterCount = count,
                        latestChapterTitle = latestTitle,
                    )
                    checked++
                    if (before in 0 until count) withNew++
                }
            }
        } catch (error: Exception) {
            respondError(exchange, 500, error.message ?: "Updates refresh failed"); return
        }
        respondJson(exchange, 200, buildJsonObject {
            put("checked", checked)
            put("withNew", withNew)
        })
    }

    private fun handleUpdatesSeen(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val mangaId = exchange.query()["mangaId"]
        if (mangaId.isNullOrBlank()) {
            facade.markAllUpdatesSeen()
        } else {
            facade.markUpdatesSeen(mangaId)
        }
        respondJson(exchange, 200, buildJsonObject { put("ok", true) })
    }

    // MARK: - library: bookmarks

    private fun handleBookmarks(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val rows = facade.bookmarks().map { BookmarkDto(
            id = it.id,
            mangaId = it.mangaId,
            mangaTitle = it.mangaTitle,
            mangaCoverUrl = it.mangaCoverUrl,
            chapterId = it.chapterId,
            chapterTitle = it.chapterTitle,
            page = it.page,
            note = it.note,
            createdAt = it.createdAt,
        ) }
        respondJson(exchange, 200, json.encodeToJsonElement(BookmarksResponse(rows)))
    }

    private fun handleBookmarkAdd(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val mangaId = params["mangaId"] ?: return respondError(exchange, 400, "Missing 'mangaId'")
        val chapterId = params["chapterId"].orEmpty()
        val chapterTitle = params["chapterTitle"].orEmpty()
        val page = params["page"]?.toIntOrNull() ?: 0
        val note = params["note"].orEmpty()
        facade.addBookmark(mangaId, chapterId, chapterTitle, page, note)
        respondJson(exchange, 200, buildJsonObject { put("ok", true) })
    }

    private fun handleBookmarkRemove(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("POST", ignoreCase = true) &&
            !exchange.requestMethod.equals("DELETE", ignoreCase = true)
        ) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val id = params["id"]?.toLongOrNull()
        if (id != null) {
            facade.removeBookmark(id)
        } else {
            val mangaId = params["mangaId"] ?: return respondError(exchange, 400, "Missing 'mangaId' or 'id'")
            val chapterId = params["chapterId"].orEmpty()
            val page = params["page"]?.toIntOrNull() ?: 0
            facade.removeBookmarkForPage(mangaId, chapterId, page)
        }
        respondJson(exchange, 200, buildJsonObject { put("ok", true) })
    }

    private fun handleBookmarkCheck(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        val params = exchange.query()
        val mangaId = params["mangaId"] ?: return respondError(exchange, 400, "Missing 'mangaId'")
        val chapterId = params["chapterId"].orEmpty()
        val page = params["page"]?.toIntOrNull() ?: 0
        respondJson(exchange, 200, buildJsonObject {
            put("bookmarked", facade.isPageBookmarked(mangaId, chapterId, page))
        })
    }

    private fun handleImage(exchange: HttpExchange) {
        if (!exchange.requestMethod.equals("GET", ignoreCase = true)) {
            respondText(exchange, 405, "Method not allowed"); return
        }
        // Accept ?u=<url>&h=Name:Value (repeated). Multi-value query params live
        // in the raw query string, so parse manually.
        val rawQuery = exchange.requestURI.rawQuery.orEmpty()
        val pairs = rawQuery.split('&').mapNotNull { p ->
            val idx = p.indexOf('=')
            if (idx <= 0) null else URLDecoder.decode(p.substring(0, idx), StandardCharsets.UTF_8) to
                URLDecoder.decode(p.substring(idx + 1), StandardCharsets.UTF_8)
        }
        val url = pairs.firstOrNull { it.first == "u" }?.second
            ?: return respondError(exchange, 400, "Missing 'u'")
        val headers = pairs.filter { it.first == "h" }.mapNotNull { (_, v) ->
            val colon = v.indexOf(':'); if (colon <= 0) null else v.substring(0, colon) to v.substring(colon + 1)
        }.toMap()
        try {
            val bytes = pageLoader.loadBytes(url, headers)
            val contentType = guessContentType(url, bytes)
            exchange.responseHeaders.add("Content-Type", contentType)
            exchange.responseHeaders.add("Cache-Control", "private, max-age=86400")
            exchange.sendResponseHeaders(200, bytes.size.toLong())
            exchange.responseBody.use { it.write(bytes) }
        } catch (error: Exception) {
            respondError(exchange, 502, error.message ?: "Image proxy failed")
        }
    }

    private fun guessContentType(url: String, bytes: ByteArray): String {
        when {
            url.endsWith(".png", ignoreCase = true) -> return "image/png"
            url.endsWith(".webp", ignoreCase = true) -> return "image/webp"
            url.endsWith(".gif", ignoreCase = true) -> return "image/gif"
            url.endsWith(".jpg", ignoreCase = true) ||
                url.endsWith(".jpeg", ignoreCase = true) -> return "image/jpeg"
            url.endsWith(".avif", ignoreCase = true) -> return "image/avif"
        }
        // URL lacks a known extension — sniff magic bytes.
        return sniffImageType(bytes) ?: "application/octet-stream"
    }

    private fun sniffImageType(bytes: ByteArray): String? {
        if (bytes.size < 12) return null
        // JPEG: FF D8 FF
        if (bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()) {
            return "image/jpeg"
        }
        // PNG: 89 50 4E 47 0D 0A 1A 0A
        if (bytes[0] == 0x89.toByte() && bytes[1] == 0x50.toByte() &&
            bytes[2] == 0x4E.toByte() && bytes[3] == 0x47.toByte()
        ) return "image/png"
        // GIF: "GIF8"
        if (bytes[0] == 0x47.toByte() && bytes[1] == 0x49.toByte() &&
            bytes[2] == 0x46.toByte() && bytes[3] == 0x38.toByte()
        ) return "image/gif"
        // WEBP: RIFF....WEBP
        if (bytes[0] == 0x52.toByte() && bytes[1] == 0x49.toByte() &&
            bytes[2] == 0x46.toByte() && bytes[3] == 0x46.toByte() &&
            bytes[8] == 0x57.toByte() && bytes[9] == 0x45.toByte() &&
            bytes[10] == 0x42.toByte() && bytes[11] == 0x50.toByte()
        ) return "image/webp"
        // AVIF / HEIC: bytes 4..11 spell "ftypavif" / "ftypheic" / "ftypheix" etc.
        if (bytes[4] == 0x66.toByte() && bytes[5] == 0x74.toByte() &&
            bytes[6] == 0x79.toByte() && bytes[7] == 0x70.toByte()
        ) {
            val brand = String(bytes, 8, 4)
            return when (brand) {
                "avif", "avis" -> "image/avif"
                "heic", "heix", "mif1", "msf1" -> "image/heic"
                else -> null
            }
        }
        return null
    }

    private fun HttpExchange.query(): Map<String, String> {
        val raw = requestURI.rawQuery ?: return emptyMap()
        return raw.split('&').mapNotNull { p ->
            val idx = p.indexOf('=')
            if (idx <= 0) null else URLDecoder.decode(p.substring(0, idx), StandardCharsets.UTF_8) to
                URLDecoder.decode(p.substring(idx + 1), StandardCharsets.UTF_8)
        }.toMap()
    }

    private fun respondJson(exchange: HttpExchange, status: Int, body: kotlinx.serialization.json.JsonElement) {
        val bytes = json.encodeToString(kotlinx.serialization.json.JsonElement.serializer(), body)
            .toByteArray(StandardCharsets.UTF_8)
        exchange.responseHeaders.add("Content-Type", "application/json; charset=utf-8")
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }

    private fun respondText(exchange: HttpExchange, status: Int, text: String) {
        val bytes = text.toByteArray(StandardCharsets.UTF_8)
        exchange.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
        exchange.sendResponseHeaders(status, bytes.size.toLong())
        exchange.responseBody.use { it.write(bytes) }
    }

    private fun respondError(exchange: HttpExchange, status: Int, message: String) {
        respondJson(exchange, status, buildJsonObject { put("error", message) })
    }
}

@kotlinx.serialization.Serializable
private data class SourceListResponse(val sources: List<MangaSource>)

@kotlinx.serialization.Serializable
private data class SourceResponse(val source: MangaSource)

@kotlinx.serialization.Serializable
private data class BrowseResponse(
    val entries: List<Manga>,
    val hasNextPage: Boolean,
)

@kotlinx.serialization.Serializable
private data class DetailsResponse(
    val manga: Manga,
    val chapters: List<MangaChapter>,
)

@kotlinx.serialization.Serializable
private data class PagesResponse(val pages: List<MangaPage>)

@kotlinx.serialization.Serializable
private data class CatalogResponse(val entries: List<CatalogEntry>)

@kotlinx.serialization.Serializable
private data class HistoryResponse(val entries: List<HistoryRowDto>)

@kotlinx.serialization.Serializable
private data class HistoryRowDto(
    val mangaId: String,
    val mangaTitle: String,
    val mangaCoverUrl: String,
    val sourceName: String,
    val chapterId: String,
    val chapterTitle: String,
    val page: Int,
    val percent: Float,
    val updatedAt: Long,
)

@kotlinx.serialization.Serializable
private data class FavouritesResponse(val entries: List<Manga>)

@kotlinx.serialization.Serializable
private data class LocalScanResponse(val entries: List<LocalCbzEntry>)

@kotlinx.serialization.Serializable
private data class LocalCbzEntry(val path: String, val name: String, val sizeBytes: Long)

@kotlinx.serialization.Serializable
private data class LocalChapterResponse(val name: String, val pageCount: Int, val pageUrls: List<String>)

@kotlinx.serialization.Serializable
private data class UpdatesResponse(val entries: List<UpdateDto>)

@kotlinx.serialization.Serializable
private data class UpdateDto(
    val mangaId: String,
    val mangaTitle: String,
    val mangaCoverUrl: String,
    val sourceId: String,
    val newChapters: Int,
    val totalChapters: Int,
    val latestChapterTitle: String,
    val lastSyncedAt: Long,
)

@kotlinx.serialization.Serializable
private data class BookmarksResponse(val entries: List<BookmarkDto>)

@kotlinx.serialization.Serializable
private data class BookmarkDto(
    val id: Long,
    val mangaId: String,
    val mangaTitle: String,
    val mangaCoverUrl: String,
    val chapterId: String,
    val chapterTitle: String,
    val page: Int,
    val note: String,
    val createdAt: Long,
)

@kotlinx.serialization.Serializable
private data class CatalogEntry(
    val id: String,
    val name: String,
    val lang: String,
    val engine: String,
    val contentType: String,
    val isBroken: Boolean,
    val isInstalled: Boolean,
)
