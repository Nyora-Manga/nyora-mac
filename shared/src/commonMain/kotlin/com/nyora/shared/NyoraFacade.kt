package com.nyora.shared

import com.nyora.shared.extension.MangaExtensionRuntime
import com.nyora.shared.extension.MangaExtensionService
import com.nyora.shared.model.Library
import com.nyora.shared.model.Manga
import com.nyora.shared.model.MangaChapter
import com.nyora.shared.model.MangaPage
import com.nyora.shared.model.MangaSource
import com.nyora.shared.repository.LibraryRepository

/**
 * Single entry point the SwiftUI layer consumes.
 *
 * Methods on this class are *blocking* on purpose — Swift will dispatch the calls
 * onto a background queue and convert results back to `@MainActor` state. We avoid
 * coroutine types in the public surface because they don't bridge cleanly into
 * Swift today.
 */
class NyoraFacade(
    private val repository: LibraryRepository,
    private val runtime: MangaExtensionRuntime,
) {
    fun loadLibrary(): Library = repository.load()

    fun saveLibrary(library: Library) {
        repository.save(library)
    }

    fun installSource(source: MangaSource, installer: (MangaSource) -> MangaSource): MangaSource {
        val installed = installer(source)
        repository.upsertSource(installed)
        return installed
    }

    fun togglePin(sourceId: String) {
        val current = repository.load()
        val updated = current.copy(
            sources = current.sources.map {
                if (it.id == sourceId) it.copy(isPinned = !it.isPinned) else it
            },
        )
        repository.save(updated)
    }

    fun listSources(): List<MangaSource> = repository.load().sources

    fun listMangas(): List<Manga> = repository.load().mangas

    fun openExtension(source: MangaSource): MangaExtensionService = runtime.create(source)

    fun upsertManga(manga: Manga) {
        repository.upsertManga(manga)
    }

    // History + favourites delegate straight to the repository.
    fun history(limit: Int = 100) = repository.history(limit)
    fun recordHistory(mangaId: String, chapterId: String, chapterTitle: String, page: Int, percent: Float) {
        repository.recordHistory(mangaId, chapterId, chapterTitle, page, percent)
    }
    fun favourites(): List<Manga> = repository.favourites()
    fun isFavourited(mangaId: String): Boolean = repository.isFavourited(mangaId)
    fun toggleFavourite(mangaId: String): Boolean = repository.toggleFavourite(mangaId)

    fun bookmarks() = repository.bookmarks()
    fun isPageBookmarked(mangaId: String, chapterId: String, page: Int): Boolean =
        repository.isPageBookmarked(mangaId, chapterId, page)
    fun addBookmark(mangaId: String, chapterId: String, chapterTitle: String, page: Int, note: String) =
        repository.addBookmark(mangaId, chapterId, chapterTitle, page, note)
    fun removeBookmark(id: Long) = repository.removeBookmark(id)
    fun removeBookmarkForPage(mangaId: String, chapterId: String, page: Int) =
        repository.removeBookmarkForPage(mangaId, chapterId, page)

    fun cachedPages(chapterUrl: String) = repository.cachedPages(chapterUrl)
    fun cachePages(chapterUrl: String, mangaId: String, pages: List<com.nyora.shared.model.MangaPage>) =
        repository.cachePages(chapterUrl, mangaId, pages)

    fun updates() = repository.updates()
    fun recordUpdateSync(mangaId: String, sourceId: String, currentChapterCount: Int, latestChapterTitle: String) =
        repository.recordUpdateSync(mangaId, sourceId, currentChapterCount, latestChapterTitle)
    fun markUpdatesSeen(mangaId: String) = repository.markUpdatesSeen(mangaId)
    fun markAllUpdatesSeen() = repository.markAllUpdatesSeen()
}
