package com.nyora.shared.repository

import app.cash.sqldelight.driver.jdbc.sqlite.JdbcSqliteDriver
import com.nyora.shared.db.NyoraDatabase
import com.nyora.shared.model.HistoryEntry
import com.nyora.shared.model.Library
import com.nyora.shared.model.Manga
import com.nyora.shared.model.MangaChapter
import com.nyora.shared.model.MangaRepo
import com.nyora.shared.model.MangaSource
import com.nyora.shared.model.MangaSourceRef
import com.nyora.shared.model.MangaState
import com.nyora.shared.model.MangaTag
import com.nyora.shared.model.SourceContentType
import com.nyora.shared.model.SourceEngine
import com.nyora.shared.model.defaultRepos
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.serializer
import java.nio.file.Files
import java.nio.file.Path
import kotlin.io.path.absolutePathString

/**
 * SQLite-backed implementation. Lives in jvmMain because it uses SQLDelight's
 * JDBC driver. The macOS-native side would swap in `NativeSqliteDriver`.
 *
 * Schema scope (Phase 2 v1):
 *   - manga             (flat row; tags/authors/chapters serialized as JSON)
 *   - manga_source      (full row)
 *
 * Out of scope this pass — handled later or kept in memory:
 *   - repos             (Library.repos, returned via defaultRepos for now)
 *   - history           (Phase 4 reader + history)
 *   - favourites / categories (Phase 5)
 */
class SqlDelightLibraryRepository(
    dbPath: Path = defaultDatabasePath(),
) : LibraryRepository {
    private val driver = JdbcSqliteDriver(
        url = "jdbc:sqlite:${dbPath.absolutePathString()}",
    ).also { driver ->
        ensureSchema(driver)
    }
    private val database = NyoraDatabase(driver)
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    private fun ensureSchema(driver: JdbcSqliteDriver) {
        // CREATE TABLE IF NOT EXISTS in the .sq files takes care of upgrades.
        NyoraDatabase.Schema.create(driver)
    }

    override fun load(): Library = database.transactionWithResult {
        val mangas = database.mangaQueries.selectAll().executeAsList().map { row -> row.toManga() }
        val sources = database.mangaSourceQueries.selectAll().executeAsList().map { row -> row.toMangaSource() }
        Library(
            mangas = mangas,
            sources = sources,
            repos = defaultRepos,
            categories = emptyList(),
            history = emptyList<HistoryEntry>(),
        )
    }

    override fun save(library: Library) {
        database.transaction {
            for (manga in library.mangas) {
                writeManga(manga)
            }
            for (source in library.sources) {
                writeSource(source)
            }
        }
    }

    override fun upsertManga(manga: Manga) {
        database.transaction { writeManga(manga) }
    }

    override fun upsertSource(source: MangaSource) {
        database.transaction { writeSource(source) }
    }

    fun togglePin(sourceId: String) {
        database.mangaSourceQueries.togglePin(sourceId)
    }

    fun count(): Pair<Long, Long> {
        return database.mangaQueries.countAll().executeAsOne() to
            database.mangaSourceQueries.countAll().executeAsOne()
    }

    // MARK: - history

    override fun history(limit: Int): List<HistoryRow> {
        return database.mangaHistoryQueries.selectRecent(limit.toLong()).executeAsList().map { row ->
            HistoryRow(
                manga = mangaRowToDomain(
                    id = row.id, title = row.title, alt_titles = row.alt_titles,
                    url = row.url, public_url = row.public_url, rating = row.rating,
                    is_nsfw = row.is_nsfw, content_rating = row.content_rating,
                    cover_url = row.cover_url, large_cover_url = row.large_cover_url,
                    state = row.state, authors = row.authors, source_ref = row.source_ref,
                    description = row.description, tags = row.tags, chapters = row.chapters,
                    unread = row.unread, progress = row.progress,
                ),
                chapterId = row.chapter_id,
                chapterTitle = row.chapter_title,
                page = row.page.toInt(),
                percent = row.percent.toFloat(),
                updatedAt = row.updated_at,
            )
        }
    }

    override fun recordHistory(
        mangaId: String,
        chapterId: String,
        chapterTitle: String,
        page: Int,
        percent: Float,
    ) {
        database.mangaHistoryQueries.upsert(
            manga_id = mangaId,
            chapter_id = chapterId,
            chapter_title = chapterTitle,
            page = page.toLong(),
            percent = percent.toDouble(),
            updated_at = System.currentTimeMillis(),
        )
    }

    // MARK: - favourites

    override fun favourites(): List<Manga> {
        return database.mangaFavouriteQueries.selectAll().executeAsList().map { row ->
            mangaRowToDomain(
                id = row.id, title = row.title, alt_titles = row.alt_titles,
                url = row.url, public_url = row.public_url, rating = row.rating,
                is_nsfw = row.is_nsfw, content_rating = row.content_rating,
                cover_url = row.cover_url, large_cover_url = row.large_cover_url,
                state = row.state, authors = row.authors, source_ref = row.source_ref,
                description = row.description, tags = row.tags, chapters = row.chapters,
                unread = row.unread, progress = row.progress,
            )
        }
    }

    override fun isFavourited(mangaId: String): Boolean {
        return database.mangaFavouriteQueries.isFavourited(mangaId).executeAsOne()
    }

    override fun toggleFavourite(mangaId: String): Boolean {
        val now = System.currentTimeMillis()
        val wasFav = isFavourited(mangaId)
        if (wasFav) {
            database.mangaFavouriteQueries.deleteByMangaId(mangaId)
        } else {
            database.mangaFavouriteQueries.insert(mangaId, now)
        }
        return !wasFav
    }

    // MARK: - bookmarks

    override fun bookmarks(): List<BookmarkRow> {
        return database.bookmarkQueries.selectAll().executeAsList().map { row ->
            BookmarkRow(
                id = row.id,
                mangaId = row.manga_id,
                mangaTitle = row.manga_title ?: row.manga_id,
                mangaCoverUrl = row.manga_cover_url.orEmpty(),
                chapterId = row.chapter_id,
                chapterTitle = row.chapter_title,
                page = row.page.toInt(),
                note = row.note,
                createdAt = row.created_at,
            )
        }
    }

    override fun bookmarksForChapter(mangaId: String, chapterId: String): List<BookmarkRow> {
        return database.bookmarkQueries.selectForChapter(mangaId, chapterId).executeAsList().map { row ->
            BookmarkRow(
                id = row.id,
                mangaId = row.manga_id,
                mangaTitle = row.manga_title ?: row.manga_id,
                mangaCoverUrl = row.manga_cover_url.orEmpty(),
                chapterId = row.chapter_id,
                chapterTitle = row.chapter_title,
                page = row.page.toInt(),
                note = row.note,
                createdAt = row.created_at,
            )
        }
    }

    override fun isPageBookmarked(mangaId: String, chapterId: String, page: Int): Boolean {
        return database.bookmarkQueries.existsForPage(mangaId, chapterId, page.toLong()).executeAsOne()
    }

    override fun addBookmark(
        mangaId: String,
        chapterId: String,
        chapterTitle: String,
        page: Int,
        note: String,
    ) {
        database.bookmarkQueries.insert(
            manga_id = mangaId,
            chapter_id = chapterId,
            chapter_title = chapterTitle,
            page = page.toLong(),
            note = note,
            created_at = System.currentTimeMillis(),
        )
    }

    override fun removeBookmark(id: Long) {
        database.bookmarkQueries.removeById(id)
    }

    override fun removeBookmarkForPage(mangaId: String, chapterId: String, page: Int) {
        database.bookmarkQueries.removeByPage(mangaId, chapterId, page.toLong())
    }

    // MARK: - chapter page cache

    override fun cachedPages(chapterUrl: String): List<com.nyora.shared.model.MangaPage>? {
        val row = database.chapterPagesQueries.selectForChapter(chapterUrl).executeAsOneOrNull() ?: return null
        val ageMs = System.currentTimeMillis() - row.fetched_at
        if (ageMs > CACHE_MAX_AGE_MS) return null
        return runCatching {
            json.decodeFromString(
                ListSerializer(com.nyora.shared.model.MangaPage.serializer()),
                row.pages_json,
            )
        }.getOrNull()
    }

    override fun cachePages(chapterUrl: String, mangaId: String, pages: List<com.nyora.shared.model.MangaPage>) {
        val payload = json.encodeToString(
            ListSerializer(com.nyora.shared.model.MangaPage.serializer()),
            pages,
        )
        database.chapterPagesQueries.upsert(
            chapter_url = chapterUrl,
            manga_id = mangaId,
            pages_json = payload,
            fetched_at = System.currentTimeMillis(),
        )
    }

    override fun clearChapterPageCache() {
        database.chapterPagesQueries.deleteAll()
    }

    // MARK: - updates

    override fun updates(): List<UpdateRow> {
        return database.mangaUpdateQueries.selectAllWithNew().executeAsList().map { row ->
            UpdateRow(
                mangaId = row.manga_id,
                mangaTitle = row.manga_title,
                mangaCoverUrl = row.manga_cover_url,
                sourceId = row.source_id,
                newChapters = row.new_chapters_count.toInt(),
                totalChapters = row.last_chapter_count.toInt(),
                latestChapterTitle = row.latest_chapter_title,
                lastSyncedAt = row.last_synced_at,
            )
        }
    }

    override fun recordUpdateSync(
        mangaId: String,
        sourceId: String,
        currentChapterCount: Int,
        latestChapterTitle: String,
    ) {
        val existing = database.mangaUpdateQueries.selectByMangaId(mangaId).executeAsOneOrNull()
        val previousCount = existing?.last_chapter_count?.toInt() ?: -1
        val diff = if (previousCount < 0) 0 else (currentChapterCount - previousCount).coerceAtLeast(0)
        val accumulated = (existing?.new_chapters_count?.toInt() ?: 0) + diff
        database.mangaUpdateQueries.upsert(
            manga_id = mangaId,
            source_id = sourceId,
            last_chapter_count = currentChapterCount.toLong(),
            new_chapters_count = accumulated.toLong(),
            latest_chapter_title = latestChapterTitle,
            last_synced_at = System.currentTimeMillis(),
        )
    }

    override fun markUpdatesSeen(mangaId: String) {
        database.mangaUpdateQueries.markSeen(mangaId)
    }

    override fun markAllUpdatesSeen() {
        database.mangaUpdateQueries.markAllSeen()
    }

    private fun mangaRowToDomain(
        id: String, title: String, alt_titles: String,
        url: String, public_url: String, rating: Double,
        is_nsfw: Long, content_rating: String?,
        cover_url: String, large_cover_url: String?,
        state: String?, authors: String, source_ref: String,
        description: String, tags: String, chapters: String,
        unread: Long, progress: Double,
    ): Manga {
        val tagSer = ListSerializer(MangaTag.serializer())
        val chapterSer = ListSerializer(MangaChapter.serializer())
        val stringList = ListSerializer(serializer<String>())
        return Manga(
            id = id,
            title = title,
            altTitles = decodeList(alt_titles, stringList),
            url = url,
            publicUrl = public_url,
            rating = rating.toFloat(),
            isNsfw = is_nsfw != 0L,
            contentRating = content_rating?.let { runCatching { com.nyora.shared.model.ContentRating.valueOf(it) }.getOrNull() },
            coverUrl = cover_url,
            largeCoverUrl = large_cover_url,
            state = state?.let { runCatching { com.nyora.shared.model.MangaState.valueOf(it) }.getOrNull() },
            authors = decodeList(authors, stringList),
            source = runCatching { json.decodeFromString(com.nyora.shared.model.MangaSourceRef.serializer(), source_ref) }
                .getOrDefault(com.nyora.shared.model.MangaSourceRef.Unknown),
            description = description,
            tags = decodeList(tags, tagSer),
            chapters = decodeList(chapters, chapterSer),
            unread = unread.toInt(),
            progress = progress.toFloat(),
        )
    }

    // MARK: - writers

    private fun writeManga(manga: Manga) {
        val tagSer = ListSerializer(MangaTag.serializer())
        val chapterSer = ListSerializer(MangaChapter.serializer())
        val stringList = ListSerializer(serializer<String>())
        database.mangaQueries.upsert(
            id = manga.id,
            title = manga.title,
            alt_titles = json.encodeToString(stringList, manga.altTitles),
            url = manga.url,
            public_url = manga.publicUrl,
            rating = manga.rating.toDouble(),
            is_nsfw = manga.isNsfw.toLong(),
            content_rating = manga.contentRating?.name,
            cover_url = manga.coverUrl,
            large_cover_url = manga.largeCoverUrl,
            state = manga.state?.name,
            authors = json.encodeToString(stringList, manga.authors),
            source_ref = json.encodeToString(MangaSourceRef.serializer(), manga.source),
            description = manga.description,
            tags = json.encodeToString(tagSer, manga.tags),
            chapters = json.encodeToString(chapterSer, manga.chapters),
            unread = manga.unread.toLong(),
            progress = manga.progress.toDouble(),
        )
    }

    private fun writeSource(source: MangaSource) {
        database.mangaSourceQueries.upsert(
            id = source.id,
            name = source.name,
            lang = source.lang,
            base_url = source.baseUrl,
            package_name = source.packageName,
            source_code_url = source.sourceCodeUrl,
            icon_url = source.iconUrl,
            version = source.version,
            version_code = source.versionCode,
            is_installed = source.isInstalled.toLong(),
            is_pinned = source.isPinned.toLong(),
            is_nsfw = source.isNsfw.toLong(),
            is_obsolete = source.isObsolete.toLong(),
            engine = source.engine.name,
            content_type = source.contentType.name,
            notes = source.notes,
            local_path = source.localPath,
            installed_at = source.installedAt,
            can_uninstall = source.canUninstall.toLong(),
        )
    }

    // MARK: - readers

    private fun com.nyora.shared.db.Manga.toManga(): Manga {
        val tagSer = ListSerializer(MangaTag.serializer())
        val chapterSer = ListSerializer(MangaChapter.serializer())
        val stringList = ListSerializer(serializer<String>())
        return Manga(
            id = id,
            title = title,
            altTitles = decodeList(alt_titles, stringList),
            url = url,
            publicUrl = public_url,
            rating = rating.toFloat(),
            isNsfw = is_nsfw != 0L,
            contentRating = content_rating?.let { runCatching { com.nyora.shared.model.ContentRating.valueOf(it) }.getOrNull() },
            coverUrl = cover_url,
            largeCoverUrl = large_cover_url,
            state = state?.let { runCatching { MangaState.valueOf(it) }.getOrNull() },
            authors = decodeList(authors, stringList),
            source = runCatching { json.decodeFromString(MangaSourceRef.serializer(), source_ref) }
                .getOrDefault(MangaSourceRef.Unknown),
            description = description,
            tags = decodeList(tags, tagSer),
            chapters = decodeList(chapters, chapterSer),
            unread = unread.toInt(),
            progress = progress.toFloat(),
        )
    }

    private fun com.nyora.shared.db.Manga_source.toMangaSource(): MangaSource = MangaSource(
        id = id,
        name = name,
        lang = lang,
        baseUrl = base_url,
        packageName = package_name,
        sourceCodeUrl = source_code_url,
        iconUrl = icon_url,
        version = version,
        versionCode = version_code,
        isInstalled = is_installed != 0L,
        isPinned = is_pinned != 0L,
        isNsfw = is_nsfw != 0L,
        isObsolete = is_obsolete != 0L,
        engine = runCatching { SourceEngine.valueOf(engine) }.getOrDefault(SourceEngine.Mihon),
        contentType = runCatching { SourceContentType.valueOf(content_type) }
            .getOrDefault(SourceContentType.Manga),
        notes = notes,
        localPath = local_path,
        installedAt = installed_at,
        canUninstall = can_uninstall != 0L,
    )

    private fun <T> decodeList(raw: String, serializer: kotlinx.serialization.KSerializer<List<T>>): List<T> {
        if (raw.isBlank() || raw == "[]") return emptyList()
        return runCatching { json.decodeFromString(serializer, raw) }.getOrDefault(emptyList())
    }

    private fun Boolean.toLong(): Long = if (this) 1L else 0L

    companion object {
        // 7 days
        private const val CACHE_MAX_AGE_MS: Long = 7L * 24 * 60 * 60 * 1000

        fun defaultDatabasePath(): Path {
            val home = Path.of(System.getProperty("user.home"))
            val base = home.resolve("Library").resolve("Application Support").resolve("Nyora")
            Files.createDirectories(base)
            return base.resolve("nyora.db")
        }
    }
}

internal fun MangaRepo.identity(): String = "$name|$indexUrl"
