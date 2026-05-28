package com.nyora.shared.repository

import com.nyora.shared.model.Library
import com.nyora.shared.model.Manga
import com.nyora.shared.model.MangaSource

interface LibraryRepository {
    fun load(): Library
    fun save(library: Library)
    fun upsertManga(manga: Manga)
    fun upsertSource(source: MangaSource)

    /** Last-read manga, newest first. */
    fun history(limit: Int = 100): List<HistoryRow> = emptyList()

    /** Upsert a per-manga reading checkpoint. */
    fun recordHistory(
        mangaId: String,
        chapterId: String,
        chapterTitle: String,
        page: Int,
        percent: Float,
    ) {}

    /** Manga marked as favourite, newest-favourited first. */
    fun favourites(): List<Manga> = emptyList()

    fun isFavourited(mangaId: String): Boolean = false

    /** Add/remove. Returns the new state (true = now favourited). */
    fun toggleFavourite(mangaId: String): Boolean = false

    /** All bookmarks, newest first. */
    fun bookmarks(): List<BookmarkRow> = emptyList()

    fun bookmarksForChapter(mangaId: String, chapterId: String): List<BookmarkRow> = emptyList()

    fun isPageBookmarked(mangaId: String, chapterId: String, page: Int): Boolean = false

    fun addBookmark(mangaId: String, chapterId: String, chapterTitle: String, page: Int, note: String) {}

    fun removeBookmark(id: Long) {}

    fun removeBookmarkForPage(mangaId: String, chapterId: String, page: Int) {}

    /** Cached page list for a chapter, or null if missing or stale (>7d). */
    fun cachedPages(chapterUrl: String): List<com.nyora.shared.model.MangaPage>? = null

    fun cachePages(chapterUrl: String, mangaId: String, pages: List<com.nyora.shared.model.MangaPage>) {}

    fun clearChapterPageCache() {}

    /** Manga with new chapters since last sync. */
    fun updates(): List<UpdateRow> = emptyList()

    fun recordUpdateSync(
        mangaId: String,
        sourceId: String,
        currentChapterCount: Int,
        latestChapterTitle: String,
    ) {}

    fun markUpdatesSeen(mangaId: String) {}
    fun markAllUpdatesSeen() {}
}

data class HistoryRow(
    val manga: Manga,
    val chapterId: String,
    val chapterTitle: String,
    val page: Int,
    val percent: Float,
    val updatedAt: Long,
)

data class BookmarkRow(
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

data class UpdateRow(
    val mangaId: String,
    val mangaTitle: String,
    val mangaCoverUrl: String,
    val sourceId: String,
    val newChapters: Int,
    val totalChapters: Int,
    val latestChapterTitle: String,
    val lastSyncedAt: Long,
)
