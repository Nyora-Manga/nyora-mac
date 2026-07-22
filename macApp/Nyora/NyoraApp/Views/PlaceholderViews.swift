import SwiftUI

@MainActor
struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedSortedHistory: [HelperHistoryRow] = []
    @State private var cachedGroupedHistory: [(String, [HelperHistoryRow])] = []

    private func rebuildSortedCache() {
        let rows = appState.history

        let filteredRows: [HelperHistoryRow]
        if appState.readerPrefs.historyRetentionDays > 0 {
            let retentionLimit = Date().addingTimeInterval(-Double(appState.readerPrefs.historyRetentionDays) * 24 * 60 * 60).timeIntervalSince1970 * 1000
            filteredRows = rows.filter { Double($0.updatedAt) >= retentionLimit }
        } else {
            filteredRows = rows
        }

        switch appState.readerPrefs.historySortOrder {
        case "alpha":
            cachedSortedHistory = filteredRows.sorted { $0.mangaTitle.localizedCaseInsensitiveCompare($1.mangaTitle) == .orderedAscending }
        case "added":
            cachedSortedHistory = filteredRows.sorted { $0.updatedAt < $1.updatedAt }
        default: // "last_read"
            cachedSortedHistory = filteredRows.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    private func rebuildGroupedCache() {
        let sorted = cachedSortedHistory
        if !appState.readerPrefs.historyGrouping {
            cachedGroupedHistory = [("All", sorted)]
            return
        }
        let byDate = Dictionary(grouping: sorted) { row in
            let date = Date(timeIntervalSince1970: TimeInterval(row.updatedAt) / 1000)
            return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        }
        cachedGroupedHistory = byDate.sorted { a, b in
            (a.value.first?.updatedAt ?? 0) > (b.value.first?.updatedAt ?? 0)
        }
    }

    var body: some View {
        Group {
            if appState.history.isEmpty {
                EmptyStateView(
                    icon: "clock.arrow.circlepath",
                    title: "No reading history yet",
                    message: "Chapters you open will appear here, newest first."
                )
            } else {
                List {
                    ForEach(cachedGroupedHistory, id: \.0) { group in
                        if appState.readerPrefs.historyGrouping {
                            // A plain section header — the system draws it with the right
                            // metrics and material. The old hand-rolled uppercase caption
                            // plus accent gradient rule is what made each pane look like a
                            // different app.
                            Section(group.0) {
                                rowsSection(group.1)
                            }
                        } else {
                            rowsSection(group.1)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear {
            rebuildSortedCache()
            rebuildGroupedCache()
        }
        .onChange(of: appState.history) { _, _ in rebuildSortedCache() }
        .onChange(of: appState.readerPrefs.historySortOrder) { _, _ in rebuildSortedCache() }
        .onChange(of: appState.readerPrefs.historyRetentionDays) { _, _ in rebuildSortedCache() }
        .onChange(of: cachedSortedHistory) { _, _ in rebuildGroupedCache() }
        .onChange(of: appState.readerPrefs.historyGrouping) { _, _ in rebuildGroupedCache() }
        .toolbar {
            Button {
                Task { await appState.reloadHistory() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            
            Menu {
                Button(role: .destructive) {
                    Task { await appState.clearHistory() }
                } label: { Label("Clear all history", systemImage: "trash") }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func rowsSection(_ rows: [HelperHistoryRow]) -> some View {
        ForEach(rows, id: \.self) { row in
            HistoryRowView(
                row: row,
                accent: appState.activeCoverAccentPrimary,
                secondaryAccent: appState.activeCoverAccentSecondary
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
        }
    }
}

/// MangaBaka-powered discovery feed. Three sections — Trending Now, Popular
/// Manhwa, Top Rated — built from broad MangaBaka searches ranked client-side
/// by popularity / rating. Every search is content_rating=safe, so NSFW titles
/// never reach the feed. Tapping a cover runs a global search so the user can
/// open it in a source.
@MainActor
struct FeedView: View {
    @EnvironmentObject var appState: AppState

    @State private var trending: [AniListBrowseMedia] = []
    @State private var popular: [AniListBrowseMedia] = []
    @State private var topRated: [AniListBrowseMedia] = []
    @State private var manhwa: [AniListBrowseMedia] = []
    @State private var manhua: [AniListBrowseMedia] = []
    @State private var mangaJp: [AniListBrowseMedia] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchText: String = ""

    private var isEmpty: Bool {
        trending.isEmpty && popular.isEmpty && topRated.isEmpty
            && manhwa.isEmpty && manhua.isEmpty && mangaJp.isEmpty
    }

    var body: some View {
        Group {
            if loading && isEmpty {
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, isEmpty {
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load the feed",
                    message: error
                )
            } else if isEmpty {
                EmptyStateView(
                    icon: "newspaper",
                    title: "Nothing in the feed yet",
                    message: "Refresh to load trending manga from AniList."
                )
            } else {
                // A vertical ScrollView of horizontal shelves (App-Store style).
                // A `List` here swallowed the vertical scroll wheel whenever the
                // pointer was over a horizontal shelf; a plain ScrollView forwards
                // the orthogonal scroll to the parent, so it scrolls vertically.
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        if let hero = trending.first {
                            FeedHeroCard(media: hero) { openInSearch(hero) }
                        }
                        // The #1 trending title is the hero, so the rail skips it.
                        shelf("Trending Now", "Most popular right now", Array(trending.dropFirst()))
                        shelf("Popular Manhwa", "Korean webtoons", manhwa.isEmpty ? popular : manhwa)
                        shelf("Popular Manhua", "Chinese comics", manhua)
                        shelf("Popular Manga", "Japanese manga", mangaJp)
                        shelf("Top Rated", "Highest-scored of all time", topRated)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .searchable(text: $searchText, prompt: "Search every installed source…")
        .onSubmit(of: .search) { runUniversalSearch() }
        .task {
            if isEmpty { await load() }
        }
        .toolbar {
            Button {
                Task { await load() }
            } label: {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(loading)
        }
    }

    @ViewBuilder
    private func shelf(_ title: String, _ subtitle: String, _ items: [AniListBrowseMedia]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.title3.bold())
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { media in
                            AniListFeedCard(media: media) { openInSearch(media) }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// Run a universal search for an AniList feed entry by its title.
    private func openInSearch(_ media: AniListBrowseMedia) {
        appState.globalSearchQuery = media.bestTitle
        appState.pendingNavigation = .universalSearch
        Task { await appState.runGlobalSearch() }
    }

    /// Run a universal search for the user's typed query, then navigate to
    /// the Universal Search screen where the grouped results appear.
    private func runUniversalSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.globalSearchQuery = trimmed
        appState.pendingNavigation = .universalSearch
        Task { await appState.runGlobalSearch() }
    }

    private func load() async {
        loading = true
        error = nil
        do {
            let data = try await appState.helper.anilistBrowse(hideAdult: appState.readerPrefs.nsfwFilter)
            trending = data.trending?.media ?? []
            popular  = data.popular?.media ?? []      // MangaBaka fallback rail
            topRated = data.topRated?.media ?? []
            manhwa   = data.manhwa?.media ?? []
            manhua   = data.manhua?.media ?? []
            mangaJp  = data.manga?.media ?? []
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Premium hero for the #1 trending title — wide banner backdrop, cover thumb,
/// title, genre chips and a Read button (nyora-web discover style).
@MainActor
private struct FeedHeroCard: View {
    let media: AniListBrowseMedia
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: media.backdropURL)) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Rectangle().fill(Color.primary.opacity(0.06))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 260)
            .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.35), .black.opacity(0.88)],
                startPoint: .top, endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 16) {
                AsyncImage(url: URL(string: media.coverURL)) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.1))
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .frame(width: 100)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 12, y: 5)

                VStack(alignment: .leading, spacing: 8) {
                    Text("#1 TRENDING")
                        .font(.caption2.bold())
                        .tracking(1.2)
                        .foregroundStyle(Color.appAccent)
                    Text(media.bestTitle)
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if let genres = media.genres, !genres.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(genres.prefix(3), id: \.self) { g in
                                Text(g)
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.white.opacity(0.16), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    Button { onTap() } label: {
                        Label("Read", systemImage: "book.fill").font(.subheadline.bold())
                            .padding(.horizontal, 16).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.appAccent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .scaleEffect(hover ? 1.006 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

/// Cover card for an AniList feed entry — 2:3 art, title, optional score badge.
@MainActor
private struct AniListFeedCard: View {
    let media: AniListBrowseMedia
    let onTap: () -> Void
    @State private var hover = false

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: media.coverURL)) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .frame(width: 132)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )
                // Score badge, top-trailing.
                .overlay(alignment: .topTrailing) {
                    if let score = media.averageScore, score > 0 {
                        Text("\(score)%")
                            .font(.caption2.bold().monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(hover ? 0.35 : 0.0), radius: hover ? 12 : 0, y: hover ? 5 : 0)

                Text(media.bestTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 132, alignment: .leading)

                // Score and genre are data — kept as one plain secondary line
                // in place of the overlaid capsule badge.
                HStack(spacing: 4) {
                    if let score = media.averageScore, score > 0 {
                        Text("\(score)%")
                            .monospacedDigit()
                        if media.topGenre != nil { Text("·") }
                    }
                    if let genre = media.topGenre {
                        Text(genre)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
            }
            .frame(width: 132)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hover ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.14), value: hover)
        .onHover { hover = $0 }
    }
}

// LocalView + LocalEntryRow were removed from this file and rebuilt from scratch in
// LocalView.swift (see that file). The rewrite fixed the sidebar-scroll bug this pane had.

@MainActor
struct SuggestionsView: View {
    @EnvironmentObject var appState: AppState
    @State private var entries: [HelperSuggestedManga] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                // The backdrop is gone — the list draws the system background,
                // as in History.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyStateView(icon: "books.vertical",
                               title: "Unable to load suggestions",
                               message: error)
            } else if entries.isEmpty {
                EmptyStateView(icon: "books.vertical",
                               title: "No suggestions yet",
                               message: "Favourite a manga to see related titles from the same source.")
            } else {
                List {
                    ForEach(entries) { manga in
                        SuggestionRowView(manga: manga) { open(manga) }
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .task { await load() }
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    /// Open a suggestion's details, exactly as the old card's tap gesture did.
    private func open(_ manga: HelperSuggestedManga) {
        Task {
            let summary = MangaSummary(
                id: manga.id,
                title: manga.title,
                sourceName: "",
                coverUrl: manga.coverUrl,
                unread: 0,
                progress: 0.0,
                tags: []
            )
            await appState.openDetails(summary)
            appState.pendingNavigation = .explore
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            entries = try await appState.helper.suggestions()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

@MainActor
struct StatsView: View {
    @EnvironmentObject var appState: AppState
    @State private var stats: HelperStats?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if loading && stats == nil {
                ProgressView("Loading statistics…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, stats == nil {
                EmptyStateView(icon: "chart.bar",
                               title: "Unable to load statistics",
                               message: error)
            } else if let s = stats {
                List {
                    Section("Summary") {
                        StatsRow(label: "Chapters Read",  value: "\(s.totalChapters)",     icon: "book")
                        StatsRow(label: "Distinct Manga", value: "\(s.distinctManga)",     icon: "books.vertical")
                        StatsRow(label: "Favourites",     value: "\(s.favouritesCount)",   icon: "heart")
                        StatsRow(label: "Longest Streak", value: "\(s.longestStreakDays)d", icon: "flame")
                    }

                    if !s.topSources.isEmpty {
                        Section("Top Sources") {
                            let maxCount = s.topSources.map(\.count).max() ?? 1
                            ForEach(s.topSources, id: \.id) { row in
                                StatsSourceRow(row: row, maxCount: maxCount)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            } else {
                EmptyStateView(icon: "chart.bar", title: "No stats yet", message: "Start reading to see your statistics here.")
            }
        }
        .task { await load() }
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            stats = try await appState.helper.stats()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// One summary statistic as a stock list row — label with its symbol on the
/// leading edge, value as trailing metadata. Replaces the aurora/glass card:
/// the numbers are data, not decoration.
@MainActor
private struct StatsRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: icon)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct StatsSourceRow: View {
    let row: HelperStatsSource
    let maxCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Text(row.sourceName)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 12)

            // The share bar stays — it is the comparison, not decoration — but
            // as a stock linear ProgressView tinted with the accent.
            ProgressView(value: Double(row.count), total: Double(max(maxCount, 1)))
                .progressViewStyle(.linear)
                .tint(Color.appAccent)
                .frame(width: 80)

            Text("\(row.count)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
struct BookmarksView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.bookmarks.isEmpty {
                EmptyStateView(
                    icon: "bookmark",
                    title: "No bookmarks",
                    message: "Tap the bookmark icon in the reader to save any page."
                )
            } else {
                List {
                    ForEach(groups, id: \.mangaId) { group in
                        Section(group.mangaTitle) {
                            ForEach(group.bookmarks, id: \.id) { bookmark in
                                BookmarkRow(bookmark: bookmark) {
                                    Task { await appState.openBookmark(bookmark) }
                                } onDelete: {
                                    Task {
                                        try? await appState.helper.removeBookmark(id: bookmark.id)
                                        await appState.reloadBookmarks()
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            Button {
                Task { await appState.reloadBookmarks() }
            } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    private struct Group2 { let mangaId: String; let mangaTitle: String; let bookmarks: [HelperBookmark] }

    private var groups: [Group2] {
        let byManga = Dictionary(grouping: appState.bookmarks, by: \.mangaId)
        return byManga
            .map { Group2(mangaId: $0.key,
                          mangaTitle: $0.value.first?.mangaTitle ?? $0.key,
                          bookmarks: $0.value.sorted { $0.page < $1.page }) }
            .sorted { $0.mangaTitle.lowercased() < $1.mangaTitle.lowercased() }
    }
}

@MainActor
private struct BookmarkRow: View {
    let bookmark: HelperBookmark
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onOpen()
        } label: {
            HStack(spacing: 12) {
                // Cover thumbnail — 44×62 pt, 2:3 ratio
                AsyncImage(url: URL(string: bookmark.mangaCoverUrl)) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    default:
                        Rectangle().fill(Color.primary.opacity(0.06))
                            .overlay(Image(systemName: "book.closed.fill")
                                .foregroundStyle(.secondary))
                    }
                }
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                // Title plus a single secondary line — the page number and the
                // optional note read as one subtitle rather than three stacked rows.
                VStack(alignment: .leading, spacing: 2) {
                    Text(bookmark.chapterTitle.isEmpty ? "Chapter" : bookmark.chapterTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("Page \(bookmark.page + 1)")
                        if !bookmark.note.isEmpty {
                            Text("·")
                            Text(bookmark.note)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 12)

                // Right: relative timestamp
                Text(Date(timeIntervalSince1970: TimeInterval(bookmark.createdAt) / 1000),
                     format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { onOpen() } label: { Label("Open", systemImage: "book.pages") }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Delete Bookmark", systemImage: "trash") }
        }
    }
}

@MainActor
struct UpdatesView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.updates.isEmpty {
                updatesEmptyState
            } else {
                List {
                    ForEach(appState.updates, id: \.id) { update in
                        UpdateRow(update: update) {
                            Task { await appState.markUpdatesSeen(update.mangaId) }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .toolbar {
            Button {
                Task { await appState.refreshUpdates() }
            } label: {
                if appState.isRefreshingUpdates {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(appState.isRefreshingUpdates)
        }
    }

    private var updatesEmptyState: some View {
        VStack(spacing: 20) {
            EmptyStateView(
                icon: "arrow.triangle.2.circlepath",
                title: "No updates yet",
                message: "Scan your favourites and reading history for new chapters."
            )
            Button {
                Task { await appState.refreshUpdates() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isRefreshingUpdates)
        }
    }
}

@MainActor
private struct UpdateRow: View {
    let update: HelperUpdate
    let onMarkSeen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Cover thumbnail — 52×74 pt, 2:3 ratio
            AsyncImage(url: URL(string: update.mangaCoverUrl)) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .overlay(Image(systemName: "book.closed.fill").foregroundStyle(.secondary))
                }
            }
            .frame(width: 52, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Title plus a single secondary line — new-chapter count, latest
            // chapter and last-synced collapse into one subtitle. The count is
            // plain text rather than a gradient capsule.
            VStack(alignment: .leading, spacing: 2) {
                Text(update.mangaTitle)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text("\(update.newChapters) new")
                    if !update.latestChapterTitle.isEmpty {
                        Text("·")
                        Text(update.latestChapterTitle)
                    }
                    Text("·")
                    Text(Date(timeIntervalSince1970: TimeInterval(update.lastSyncedAt) / 1000),
                         format: .relative(presentation: .named))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            // Right: mark-seen checkmark button
            Button {
                onMarkSeen()
            } label: {
                Image(systemName: "checkmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Mark as seen")
        }
        .contentShape(Rectangle())
    }
}

@MainActor
/// Tracks the last interaction time OUTSIDE of SwiftUI state, so recording a
/// mouse-move (which happens constantly) never triggers a view re-render.
final class IdleClock { var last: Date = .now }

struct ReaderView: View {
    @EnvironmentObject var appState: AppState
    /// Drives the auto-hide of the floating chrome. Wakes on hover / click /
    /// page change, fades back out after 2.5 s.
    @State private var controlsVisible: Bool = true
    @State private var idle = IdleClock()
    private let hideAfter: TimeInterval = 2.5
    @State private var isQuickSettingsPresented: Bool = false

    /// Premium spring for the chrome — snappy but soft (Apple-grade).
    private var chromeSpring: Animation { .spring(response: 0.34, dampingFraction: 0.86) }

    var body: some View {
        Group {
            if let chapter = appState.activeChapter, !chapter.pages.isEmpty {
                ZStack(alignment: .bottom) {
                    // Immersive page content — full-bleed, no window toolbar.
                    Group {
                        switch appState.readerMode {
                        case .standard, .reversed:
                            PagedReaderV2(chapter: chapter, controlsVisible: controlsVisible, onToggleChrome: toggleChrome)
                        case .vertical, .webtoon:
                            WebtoonReaderV2(chapter: chapter, controlsVisible: controlsVisible, onToggleChrome: toggleChrome)
                        }
                    }
                    TranslationDebugBar()
                        .padding(.bottom, 84)
                        .allowsHitTesting(appState.debugHUDEnabled)
                }
                // Floating auto-hiding chrome (Apple Books) — pinned to the edges.
                .overlay(alignment: .top) {
                    if controlsVisible {
                        floatingTopBar(chapter: chapter)
                            .padding(.top, 6)
                            .padding(.horizontal, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottom) {
                    if controlsVisible {
                        ReaderScrubBar(
                            urls: chapter.pages.map(\.url),
                            page: Binding(get: { appState.readerPageIndex },
                                          set: { appState.readerPageIndex = $0 }),
                            rtl: appState.readerMode.isRTL
                        )
                        .padding(.bottom, 16)
                        .padding(.horizontal, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isQuickSettingsPresented {
                        GeometryReader { proxy in
                            quickSettingsPanel
                                .frame(maxHeight: min(500, proxy.size.height - 24), alignment: .top)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.top, 58)
                        .padding(.trailing, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(99)
                    }
                }
                .toolbar(.hidden, for: .windowToolbar)
                .onContinuousHover { phase in
                    if case .active = phase { wakeControls() }
                }
                .onChange(of: appState.readerPageIndex) { _, newIndex in
                    wakeControls()
                    // Re-prioritise colorization to the page you just moved to.
                    if appState.colorizeModeOn { appState.colorizer.setFocus(newIndex) }
                    Task { await appState.refreshCurrentPageBookmarkedFlag() }
                }
                .onChange(of: appState.readerMode) { _, _ in wakeControls() }
                .task {
                    await appState.refreshCurrentPageBookmarkedFlag()
                    await runIdleTimer()
                }
            } else {
                ReaderEmptyLanding()
            }
        }
    }

    /// Tap-the-centre-of-the-page toggles the floating chrome (Apple Books).
    private func toggleChrome() {
        idle.last = .now
        withAnimation(chromeSpring) { controlsVisible.toggle() }
    }

    /// Floating, auto-hiding top control bar (Apple Books style).
    @ViewBuilder
    private func floatingTopBar(chapter: ChapterSummary) -> some View {
        HStack(spacing: 2) {
            // Proper back button — exits the immersive reader to the library.
            Button { appState.pendingNavigation = .history } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                    Text("Back").font(.caption.weight(.semibold))
                }
                .frame(height: 30)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to library")

            Divider().frame(height: 16).opacity(0.3)

            // Chapter nav follows reading direction: the LEFT button advances the
            // way pages advance (prev-chapter in LTR, next-chapter in RTL), and the
            // RIGHT button is its opposite — so it mirrors the page-turn direction.
            barIcon("chevron.backward",
                    disabled: appState.readerMode.isRTL ? !appState.hasNextChapter : !appState.hasPrevChapter) {
                Task { await appState.gotoChapterRelative(appState.readerMode.isRTL ? 1 : -1) }
            }
            .help(appState.readerMode.isRTL ? "Next chapter" : "Previous chapter")

            VStack(spacing: 1) {
                Text(chapter.title.isEmpty ? "Chapter" : chapter.title)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Text("\(appState.readerPageIndex + 1) of \(chapter.pages.count)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 116)
            .padding(.horizontal, 2)

            barIcon("chevron.forward",
                    disabled: appState.readerMode.isRTL ? !appState.hasPrevChapter : !appState.hasNextChapter) {
                Task { await appState.gotoChapterRelative(appState.readerMode.isRTL ? -1 : 1) }
            }
            .help(appState.readerMode.isRTL ? "Previous chapter" : "Next chapter")

            Divider().frame(height: 16).opacity(0.3)

            barIcon(appState.currentPageBookmarked ? "bookmark.fill" : "bookmark",
                    tint: appState.currentPageBookmarked ? .appAccent : .primary) {
                Task { await appState.toggleCurrentPageBookmark() }
            }
            .help(appState.currentPageBookmarked ? "Remove bookmark" : "Bookmark page")

            // Auto-scroll play/pause (web-style). Long-press / right-click opens
            // the speed menu; a plain click just toggles.
            Menu {
                Button(appState.autoScrollOn ? "Stop Auto-Scroll" : "Start Auto-Scroll") {
                    appState.toggleAutoScroll()
                }
                Divider()
                Picker("Speed", selection: $appState.readerPrefs.autoScrollLevel) {
                    ForEach(1...10, id: \.self) { lvl in Text("\(lvl) / 10").tag(lvl) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: appState.autoScrollOn ? "pause.fill" : "play.fill")
                    .foregroundStyle(appState.autoScrollOn ? Color.appAccent : .primary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            } primaryAction: {
                appState.toggleAutoScroll()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(appState.autoScrollOn ? "Stop auto-scroll (A)" : "Auto-scroll (A) — hold for speed")

            Menu {
                Button { appState.translateCurrentPage() } label: {
                    Label("Translate This Page", systemImage: "character.bubble")
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(appState.isTranslatingPage)
                Divider()
                Toggle(isOn: autoTranslateBinding(chapter: chapter)) {
                    Label("Auto-Translate Chapter", systemImage: "rectangle.and.text.magnifyingglass")
                }
                Toggle(isOn: colorizeBinding) {
                    Label("Colorize Chapter", systemImage: "paintbrush.pointed")
                }
            } label: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle((appState.translateModeOn || appState.colorizeModeOn) ? Color.appAccent : .primary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("AI — translate & colorize")

            Menu {
                Picker("Reading Mode", selection: $appState.readerMode) {
                    ForEach(ReaderMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                if appState.readerMode == .standard || appState.readerMode == .reversed {
                    Divider()
                    Toggle("Right-to-Left (Manga)", isOn: $appState.rtlReading)
                    Toggle("Two-Page Layout", isOn: $appState.readerPrefs.twoPageLayout)
                }
            } label: {
                Image(systemName: appState.readerMode.systemImage)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Reading mode & layout")

            barIcon("textformat.size", tint: isQuickSettingsPresented ? .appAccent : .primary) {
                withAnimation(.easeInOut(duration: 0.2)) { isQuickSettingsPresented.toggle() }
            }
            .help("Reader settings")
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 5)
    }

    /// A flat icon button sized for the floating bar.
    @ViewBuilder
    private func barIcon(_ system: String, tint: Color = .primary, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .frame(width: 30, height: 30)
                .foregroundStyle(disabled ? AnyShapeStyle(Color.secondary.opacity(0.4)) : AnyShapeStyle(tint))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// Auto-translate the whole chapter on/off (kicks off / stops the background pass).
    private func autoTranslateBinding(chapter: ChapterSummary) -> Binding<Bool> {
        Binding(
            get: { appState.translateModeOn },
            set: { on in
                appState.translateModeOn = on
                if on { startChapterTranslation(chapter: chapter) }
                else { appState.chapterTranslator.stop() }
            }
        )
    }

    /// Colorize the whole chapter on/off (`toggleColorize` flips the internal state).
    private var colorizeBinding: Binding<Bool> {
        Binding(get: { appState.colorizeModeOn }, set: { _ in appState.toggleColorize() })
    }

    /// Toolbar button that triggers per-page translation (⌘T). The icon
    /// reflects `translationStage`: outline bubble when idle, progress
    /// spinner while OCR/MT/refine are running, and a filled accent-tinted
    /// bubble once the page has rendered balloons.
    @ViewBuilder
    private var translateToolbarButton: some View {
        let stage = appState.translationStage
        let working = stage == .downloading || stage == .ocr || stage == .mt || stage == .refining
        let hasResult = stage == .done && !appState.inImageBalloons.isEmpty
        Button {
            appState.translateCurrentPage()
        } label: {
            ZStack {
                if working {
                    ProgressView().scaleEffect(0.6).frame(width: 22, height: 22)
                } else {
                    Image(systemName: hasResult ? "character.bubble.fill" : "character.bubble")
                        .foregroundStyle(hasResult ? Color.appAccent : .primary)
                }
            }
            .frame(minWidth: 22, minHeight: 22)
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(working)
        .help(working
              ? "Translating page — \(stage.label)"
              : hasResult
                ? "Re-translate this page (⌘T)"
                : "Translate this page (⌘T)")
    }

    /// Kick off chapter-wide translation when the user flips on
    /// Auto-Translate. We hand the chapter id + every page URL to the
    /// background `ChapterTranslator`, which streams results into
    /// `appState.chapterTranslator.pageResults` for the in-page overlay.
    private func startChapterTranslation(chapter: ChapterSummary) {
        let urls = chapter.pages.compactMap { URL(string: $0.url) }
        guard !urls.isEmpty else { return }
        let src = appState.translateSettings.sourceLang
        let target = appState.translateSettings.targetLang
        let targetCode = appState.translateSettings.googleLangCode(for: target)
        appState.chapterTranslator.start(
            chapterId: chapter.id,
            pageUrls: urls,
            sourceLang: src,
            targetCode: targetCode,
            settings: appState.translateSettings,
            responseTextScale: CGFloat(appState.readerPrefs.translationResponseScale),
            startAt: appState.readerPageIndex
        )
    }

    /// Mark this moment as the last interaction and ensure the controls
    /// are visible. Called from hover, page change, mode change.
    private func wakeControls() {
        idle.last = .now          // plain object write — no re-render on mouse-move
        if !controlsVisible {
            withAnimation(chromeSpring) { controlsVisible = true }
        }
    }

    /// Polls every 0.5 s — if no interaction has happened in the last
    /// `hideAfter` seconds, fade the controls out. Runs for the lifetime
    /// of the reader view.
    private func runIdleTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if controlsVisible, !isQuickSettingsPresented,
               Date().timeIntervalSince(idle.last) > hideAfter {
                withAnimation(chromeSpring) { controlsVisible = false }
            }
        }
    }

    // MARK: - Quick Settings bindings & views

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: {
                let mangaId = appState.readerMangaId
                if !mangaId.isEmpty, let row = appState.perMangaPrefsCache[mangaId], row.present {
                    return row.brightness ?? 0
                }
                return appState.readerPrefs.brightness
            },
            set: { val in
                let mangaId = appState.readerMangaId
                if !mangaId.isEmpty, var row = appState.perMangaPrefsCache[mangaId], row.present {
                    row.brightness = val
                    appState.perMangaPrefsCache[mangaId] = row
                    Task {
                        try? await appState.helper.saveMangaPrefs(
                            mangaId: mangaId,
                            readerMode: "",
                            brightness: val,
                            contrast: row.contrast ?? 1,
                            saturation: row.saturation ?? 1,
                            hue: row.hue ?? 0,
                            palette: row.palette ?? ""
                        )
                    }
                } else {
                    appState.readerPrefs.brightness = val
                }
            }
        )
    }

    private var contrastBinding: Binding<Double> {
        Binding(
            get: {
                let mangaId = appState.readerMangaId
                if !mangaId.isEmpty, let row = appState.perMangaPrefsCache[mangaId], row.present {
                    return row.contrast ?? 1
                }
                return appState.readerPrefs.contrast
            },
            set: { val in
                let mangaId = appState.readerMangaId
                if !mangaId.isEmpty, var row = appState.perMangaPrefsCache[mangaId], row.present {
                    row.contrast = val
                    appState.perMangaPrefsCache[mangaId] = row
                    Task {
                        try? await appState.helper.saveMangaPrefs(
                            mangaId: mangaId,
                            readerMode: "",
                            brightness: row.brightness ?? 0,
                            contrast: val,
                            saturation: row.saturation ?? 1,
                            hue: row.hue ?? 0,
                            palette: row.palette ?? ""
                        )
                    }
                } else {
                    appState.readerPrefs.contrast = val
                }
            }
        )
    }

    private var saturationBinding: Binding<Double> {
        Binding(
            get: {
                let mangaId = appState.readerMangaId
                if !mangaId.isEmpty, let row = appState.perMangaPrefsCache[mangaId], row.present {
                    return row.saturation ?? 1
                }
                return appState.readerPrefs.saturation
            },
            set: { val in
                let mangaId = appState.readerMangaId
                if !mangaId.isEmpty, var row = appState.perMangaPrefsCache[mangaId], row.present {
                    row.saturation = val
                    appState.perMangaPrefsCache[mangaId] = row
                    Task {
                        try? await appState.helper.saveMangaPrefs(
                            mangaId: mangaId,
                            readerMode: "",
                            brightness: row.brightness ?? 0,
                            contrast: row.contrast ?? 1,
                            saturation: val,
                            hue: row.hue ?? 0,
                            palette: row.palette ?? ""
                        )
                    }
                } else {
                    appState.readerPrefs.saturation = val
                }
            }
        )
    }

    private func applyPreset(_ preset: ColorPreset) {
        let mangaId = appState.readerMangaId
        let adj = preset.id == "none" ? ColorAdjustments.identity : preset.adjustments
        let paletteId = preset.id == "none" ? "" : preset.id
        
        if !mangaId.isEmpty, var row = appState.perMangaPrefsCache[mangaId], row.present {
            row.brightness = adj.brightness
            row.contrast = adj.contrast
            row.saturation = adj.saturation
            row.palette = paletteId
            appState.perMangaPrefsCache[mangaId] = row
            Task {
                try? await appState.helper.saveMangaPrefs(
                    mangaId: mangaId,
                    readerMode: "",
                    brightness: adj.brightness,
                    contrast: adj.contrast,
                    saturation: adj.saturation,
                    hue: adj.hue,
                    palette: paletteId
                )
            }
        } else {
            appState.readerPrefs.brightness = adj.brightness
            appState.readerPrefs.contrast = adj.contrast
            appState.readerPrefs.saturation = adj.saturation
            appState.readerPrefs.hue = adj.hue
            appState.readerPrefs.palette = paletteId
        }
    }

    private func isPresetSelected(_ preset: ColorPreset) -> Bool {
        let mangaId = appState.readerMangaId
        let current: ColorAdjustments
        let palette: String
        if !mangaId.isEmpty, let row = appState.perMangaPrefsCache[mangaId], row.present {
            current = ColorAdjustments(
                brightness: row.brightness ?? 0,
                contrast: row.contrast ?? 1,
                saturation: row.saturation ?? 1,
                hue: row.hue ?? 0
            )
            palette = row.palette ?? ""
        } else {
            current = appState.appWideColorAdjustments
            palette = current.palette
        }

        if preset.id == "none" {
            return current.isNeutral && palette.isEmpty
        }
        return palette == preset.id || (abs(current.brightness - preset.adjustments.brightness) < 0.01 &&
                                         abs(current.contrast - preset.adjustments.contrast) < 0.01 &&
                                         abs(current.saturation - preset.adjustments.saturation) < 0.01 &&
                                         abs(current.hue - preset.adjustments.hue) < 0.01)
    }

    private var quickSettingsPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Quick Settings", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isQuickSettingsPresented = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            Divider()
            
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // SECTION: LAYOUT
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LAYOUT")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                        
                        Picker("Reader Mode", selection: $appState.readerMode) {
                            ForEach(ReaderMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(Color.appAccent)
                        .labelsHidden()
                        
                        // RTL + two-page are paged-only (RTL is meaningless in vertical).
                        if appState.readerMode == .standard || appState.readerMode == .reversed {
                            HStack {
                                Toggle("Right-to-Left (Manga)", isOn: $appState.rtlReading)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                Spacer()
                            }
                            HStack {
                                Toggle("Two-Page Layout", isOn: $appState.readerPrefs.twoPageLayout)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    
                    Divider()
                    
                    // SECTION: SCALING
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SCALING")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .tracking(0.5)
                        
                        Picker("Scale Mode", selection: $appState.readerPrefs.zoomMode) {
                            Text("Fit Screen").tag("fit_center")
                            Text("Fit Width").tag("fit_width")
                            Text("Fit Height").tag("fit_height")
                            Text("Fill Page").tag("fill")
                        }
                        .pickerStyle(.menu)
                        .tint(Color.appAccent)
                    }
                    .padding(.horizontal, 4)
                    
                    Divider()
                    
                    // SECTION: COLORS
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("COLOR CORRECTION")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)
                            Spacer()
                            Button("Reset") {
                                applyPreset(ColorPreset.allPresets.first { $0.id == "none" }!)
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        
                        // Brightness slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Brightness", systemImage: "sun.max")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", brightnessBinding.wrappedValue))
                                    .font(.caption.monospacedDigit())
                            }
                            Slider(value: brightnessBinding, in: -0.5...0.5)
                        }
                        
                        // Contrast slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Contrast", systemImage: "circle.lefthalf.filled")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", contrastBinding.wrappedValue))
                                    .font(.caption.monospacedDigit())
                            }
                            Slider(value: contrastBinding, in: 0.5...2.0)
                        }
                        
                        // Saturation slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label("Saturation", systemImage: "paintbrush")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", saturationBinding.wrappedValue))
                                    .font(.caption.monospacedDigit())
                            }
                            Slider(value: saturationBinding, in: 0.0...2.0)
                        }
                        
                        // Color Presets Horizontal Chips
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PRESETS")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(ColorPreset.allPresets) { preset in
                                        let selected = isPresetSelected(preset)
                                        Button {
                                            applyPreset(preset)
                                        } label: {
                                            Text(preset.label)
                                                .font(.caption)
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                // Selected sits on an accent capsule, so it needs the
                                                // contrasting colour, not a fixed white — the accent is
                                                // user-selectable and Yuki's is near-white.
                                                .foregroundStyle(selected ? Color.onAccent : Color.primary)
                                                .background(
                                                    selected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(Color.primary.opacity(0.08)),
                                                    in: Capsule()
                                                )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    
                    // SECTION: WEBTOON
                    if appState.readerMode == .webtoon {
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("WEBTOON OPTIONS")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .tracking(0.5)
                            
                            HStack {
                                Toggle("Page Gaps", isOn: $appState.readerPrefs.isWebtoonGapsEnabled)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                Spacer()
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Zoom-Out Margin")
                                        .font(.subheadline)
                                    Spacer()
                                    Text("\(Int(appState.readerPrefs.webtoonZoomOut * 100))%")
                                        .font(.caption.monospacedDigit())
                                }
                                Slider(value: $appState.readerPrefs.webtoonZoomOut, in: 0.0...0.5, step: 0.05)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(idealHeight: 500)
        // Genuine detached floating panel — explicit native glass surface.
        .adaptiveGlass(.rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 15, x: 0, y: 10)
    }
}

@MainActor
private struct ReaderEmptyLanding: View {
    @EnvironmentObject var appState: AppState

    private var latestHistory: HelperHistoryRow? {
        appState.history.max { $0.updatedAt < $1.updatedAt }
    }

    private var recentHistory: [HelperHistoryRow] {
        Array(appState.history.sorted { $0.updatedAt > $1.updatedAt }.prefix(3))
    }

    var body: some View {
        Group {
            if appState.history.isEmpty {
                // Nothing to resume yet. Stock empty state plus the very same
                // destinations as stock buttons — the LocalView shape.
                VStack(spacing: 12) {
                    EmptyStateView(
                        icon: "book.pages",
                        title: "Ready to Read",
                        message: "Resume a recent chapter, browse sources, or open local files. The reader sidebar appears once a chapter is loaded."
                    )
                    HStack(spacing: 12) {
                        Button {
                            appState.pendingNavigation = .explore
                        } label: { Label("Browse", systemImage: "safari") }
                        Button {
                            appState.pendingNavigation = .favourites
                        } label: { Label("Library", systemImage: "heart.text.square") }
                        Button {
                            appState.pendingNavigation = .local
                        } label: { Label("Local", systemImage: "folder") }
                    }
                }
            } else {
                landingList
            }
        }
    }

    /// The populated landing: Continue, the destinations, then recents — all as
    /// plain `List` sections. This replaces the cover mosaic + vignette + fade
    /// backdrop, the glowing hero badge and the horizontal card rail; the list
    /// draws the system background and supplies hover/selection itself.
    private var landingList: some View {
        List {
            if let latest = latestHistory {
                Section {
                    ReaderActionRow(
                        title: "Continue",
                        subtitle: latest.mangaTitle,
                        systemImage: "play.fill"
                    ) {
                        Task { await appState.openHistoryEntry(latest) }
                    }
                }
            }

            Section {
                ReaderActionRow(
                    title: "Browse",
                    subtitle: "Find manga from sources",
                    systemImage: "safari"
                ) { appState.pendingNavigation = .explore }

                ReaderActionRow(
                    title: "Library",
                    subtitle: "\(appState.favourites.count) favourites",
                    systemImage: "heart.text.square"
                ) { appState.pendingNavigation = .favourites }

                ReaderActionRow(
                    title: "Local",
                    subtitle: "Open CBZ files",
                    systemImage: "folder"
                ) { appState.pendingNavigation = .local }
            } footer: {
                // The hero's explanatory copy, kept as a stock section footer.
                Text("The reader sidebar appears once a chapter is loaded.")
            }

            if !recentHistory.isEmpty {
                Section {
                    ForEach(recentHistory) { row in
                        ReaderRecentRow(
                            row: row,
                            accent: appState.activeCoverAccentPrimary
                        ) {
                            Task { await appState.openHistoryEntry(row) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recently Read")
                        Spacer()
                        Button("View History") {
                            appState.pendingNavigation = .history
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

/// A landing destination as a plain list row — icon, title, one secondary line.
/// Was a 160×112 card with an "aurora" accent fill (three stacked gradients plus
/// a white top sheen), a gradient hairline border and a hover scale. The
/// `isPrimary` variant drew `.white` text on that accent fill, which vanished on
/// near-white accents like Yuki; a stock row has no accent surface at all, so the
/// contrast problem goes with it. `List` supplies hover and selection.
@MainActor
private struct ReaderActionRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(Color.appAccent)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A recent chapter in the `HistoryRowView` shape: cover with the progress bar
/// overlaid at its foot, title, one secondary line, trailing percentage. The
/// gradient progress capsule is now a stock `ProgressView` tinted with the same
/// accent History uses, and the cover drop shadow, the custom row padding and
/// the hand-rolled hover background are gone — `List` does hover itself.
@MainActor
private struct ReaderRecentRow: View {
    let row: HelperHistoryRow
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: row.mangaCoverUrl)) { phase in
                        if case let .success(image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                        }
                    }
                    .frame(width: 42, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    ProgressView(value: Double(row.percent))
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .scaleEffect(y: 0.5)
                        .frame(width: 42)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.mangaTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.chapterTitle.isEmpty ? "Chapter" : row.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text("\(Int((row.percent * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A single themed preview card for the color-scheme picker, mirroring the
/// android `item_color_scheme.xml`: a rounded mini surface with "Abc" text, two
/// secondary-tone bars, a primary swatch, a check when selected, and the scheme
/// name beneath. Each card derives its own light/dark surface from the active
/// appearance so the preview reads correctly in both modes.
@MainActor
private struct ColorSchemePreviewCard: View {
    let scheme: ReaderPrefs.ColorSchemeOption
    let dark: Bool
    let primary: Color
    let isSelected: Bool
    let onTap: () -> Void

    private let cardWidth: CGFloat = 92
    private let cardHeight: CGFloat = 116

    /// Derived card surface — light grey in light mode, near-black in dark mode.
    private var surface: Color {
        dark ? Color(white: 0.12) : Color(white: 0.95)
    }

    /// Secondary-tone color for the two bars. Schemes ship a `darkSecondary`;
    /// use it directly in dark mode and a slightly muted blend in light mode.
    private var secondary: Color {
        if scheme.id == "wallpaper" {
            return primary.opacity(0.45)
        }
        if let c = Color(hex: scheme.darkSecondary) {
            return dark ? c : c.opacity(0.7)
        }
        return primary.opacity(0.45)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(surface)
                        .frame(width: cardWidth, height: cardHeight)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    isSelected ? primary : Color.primary.opacity(0.12),
                                    lineWidth: isSelected ? 2 : 1
                                )
                        )

                    cardContent
                        .frame(width: cardWidth, height: cardHeight)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(primary)
                            .padding(6)
                    }
                }

                Text(scheme.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .frame(width: cardWidth)
            }
        }
        .buttonStyle(.plain)
        .help(scheme.name)
    }

    private var cardContent: some View {
        ZStack {
            // "Abc" top-left
            Text("Abc")
                .font(.system(size: 12))
                .foregroundStyle(dark ? Color.white.opacity(0.85) : Color.black.opacity(0.75))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 8)
                .padding(.leading, 8)

            // Two secondary-tone bars (40% then 70% width), bottom-anchored.
            VStack(alignment: .leading, spacing: 6) {
                Capsule()
                    .fill(secondary)
                    .frame(width: cardWidth * 0.40, height: 6)
                Capsule()
                    .fill(secondary)
                    .frame(width: cardWidth * 0.70, height: 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, 8)
            .padding(.bottom, 24)

            // Primary swatch, bottom-right.
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(primary)
                .frame(width: 16, height: 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
        }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var ocrModels = NativeOcrProvider.shared
    @ObservedObject private var colorizer = NativeColorizer.shared
    @State private var selected: SettingsCategory = .appearance
    @State private var syncPassword: String = ""
    @State private var cacheUsageBytes: Int = 0
    @State private var dbSizeBytes: Int = 0
    // Cloud-sync email/password sign-in
    @State private var nyoraSyncEmail: String = ""
    @State private var nyoraSyncPassword: String = ""
    // Tracker sign-in state
    @State private var kitsuEmail: String = ""
    @State private var kitsuPassword: String = ""
    @State private var manualTrackerToken: [String: String] = [:]
    @State private var trackerBusy: String? = nil
    // Content & language preferences ("Re-run setup") sheet.
    @State private var showPreferencesSheet = false

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 230)
            detailPage(for: selected)
                .frame(minWidth: 300)
        }
        // Total Settings min (≈460) must stay under the NavigationSplitView detail
        // column's min (480 in RootView); otherwise, when the window narrows, the
        // detail pane is 480 while Settings wants more and the right side clips.
        .task {
            cacheUsageBytes = URLCache.shared.currentDiskUsage
            dbSizeBytes = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int) ?? 0
        }
        .sheet(isPresented: $showPreferencesSheet) {
            PreferencesOnboardingView(context: .settings) {
                showPreferencesSheet = false
            }
            .environmentObject(appState)
            .frame(minWidth: 640, minHeight: 560)
        }
    }

    /// A real source list, the way System Settings draws its category column:
    /// `List(selection:)` + `.listStyle(.sidebar)`. The hand-rolled buttons with
    /// their own rounded accent-tinted background and backdrop are gone — the
    /// system draws selection, hover and the sidebar material itself.
    private var sidebar: some View {
        // Custom rows (not a native `.sidebar` List): native sidebar selection is locked
        // to the SYSTEM accent and ignores `.tint`, so an explicit Color.appAccent fill is
        // the only way to make the selection follow the chosen scheme.
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { cat in
                    SettingsCatRow(
                        title: cat.title,
                        systemImage: cat.systemImage,
                        isSelected: selected == cat
                    ) { selected = cat }
                }
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .frame(minWidth: 210, idealWidth: 230)
    }

    private struct SettingsCatRow: View {
        let title: String
        let systemImage: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hover = false
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.onAccent : Color.secondary)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.onAccent : Color.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.appAccent : (hover ? Color.primary.opacity(0.06) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { action() }
        }
    }

    /// `Form` + `.formStyle(.grouped)` is the macOS settings idiom — it supplies
    /// the grouped surface, row metrics, label column and scrolling that this
    /// pane used to draw by hand. The category title stays: the window title is
    /// owned by `RootView` ("Settings"), so this is the only thing naming the
    /// sub-page, not a duplicate of the toolbar.
    @ViewBuilder
    private func detailPage(for cat: SettingsCategory) -> some View {
        Form {
            Section {
                Text(cat.title)
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
            }

            switch cat {
            case .appearance:    appearanceSection
            case .library:       librarySection
            case .reader:        readerSection
            case .sources:       sourcesSection
            case .translation:   translationSection
            case .colorization:  colorizationSection
            case .network:       networkSection
            case .downloads:     downloadsSection
            case .tracker:       trackerSection
            case .sync:          nyoraSyncSection
            case .backup:        backupSection
            case .notifications: notificationsSection
            case .privacy:       privacySection
            case .advanced:      advancedSection
            case .about:         aboutSection
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Sub-pages

    @ViewBuilder
    private var appearanceSection: some View {
        Group {
            settingGroup("Theme") {
                pickerRow("App theme", selection: $appState.readerPrefs.appAppearance) {
                    Text("Follow system").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                toggleRow("Glass mode",
                          description: "Native macOS translucency — the desktop blurs through the panes like Finder. Off = solid background.",
                          isOn: $appState.readerPrefs.glassMode)
            }
            settingGroup("Color scheme",
                         footer: "Each scheme uses its light or dark variant to match the app appearance.") {
                accentColorContent
            }
            settingGroup("Manga list") {
                stepperRow("Cover width", value: $appState.readerPrefs.gridSize, range: 80...220, step: 10, label: "\(appState.readerPrefs.gridSize) px")
                toggleRow("Show unread badge on covers", description: "Counts new chapters since last open.", isOn: $appState.readerPrefs.showUnreadBadge)
                toggleRow("Quick filters", description: "Chips above each manga list for genre / status.", isOn: $appState.readerPrefs.quickFilter)
                pickerRow("Reading progress indicator", selection: $appState.readerPrefs.progressIndicators) {
                    Text("Circular").tag("circular"); Text("Bar").tag("bar"); Text("Off").tag("off")
                }
            }
            settingGroup("Manga details") {
                toggleRow("Collapse long descriptions", description: "Show a Read more link instead of a wall of text.", isOn: $appState.readerPrefs.descriptionCollapse)
                toggleRow("Pages thumbnails tab", description: "Page grid alongside the chapter list.", isOn: $appState.readerPrefs.pagesTab)
            }
            settingGroup("Sidebar") {
                toggleRow("Labels in sidebar", description: "Show text next to icons.", isOn: $appState.readerPrefs.navLabels)
                toggleRow("Dynamic Dock shortcuts", description: "Recently read manga appear in the Dock menu.", isOn: $appState.readerPrefs.dynamicShortcuts)
            }
        }
    }

    // MARK: - Color scheme picker

    /// Android-style horizontal scroll of themed preview cards. Each card
    /// mirrors `item_color_scheme.xml`: a mini themed surface with "Abc" text,
    /// two secondary-tone bars, a primary swatch, a check when selected, and the
    /// scheme name beneath.
    @ViewBuilder
    private var accentColorContent: some View {
        let dark = colorScheme == .dark
        // The strip keeps its themed preview cards — they ARE the control — but
        // the section now supplies the surface and the explanatory footer.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(ReaderPrefs.colorSchemes) { scheme in
                    ColorSchemePreviewCard(
                        scheme: scheme,
                        dark: dark,
                        primary: primaryColor(for: scheme, dark: dark),
                        isSelected: appState.readerPrefs.accentColor == scheme.id
                    ) {
                        appState.readerPrefs.accentColor = scheme.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Resolve the primary color a card should render with — its OWN scheme
    /// primary, or the live wallpaper/Dynamic accent for the "wallpaper" card.
    private func primaryColor(for scheme: ReaderPrefs.ColorSchemeOption, dark: Bool) -> Color {
        if scheme.id == "wallpaper" {
            return appState.readerPrefs.effectiveAccentColor
        }
        if let hex = appState.readerPrefs.primaryHex(for: scheme.id, dark: dark),
           let c = Color(hex: hex) {
            return c
        }
        return .appAccent
    }

    @ViewBuilder
    private var librarySection: some View {
        Group {
            settingGroup("History") {
                stepperRow("Retention",
                           value: $appState.readerPrefs.historyRetentionDays,
                           range: 0...365, step: 30,
                           label: appState.readerPrefs.historyRetentionDays == 0
                                ? "Forever" : "\(appState.readerPrefs.historyRetentionDays) days")
                toggleRow("Group by date", description: "Today / Yesterday / Earlier sections.", isOn: $appState.readerPrefs.historyGrouping)
                toggleRow("Keep 18+ out of history", description: "Adult-tagged manga are never written to reading history.", isOn: $appState.readerPrefs.noNsfwHistory)
                pickerRow("Sort order", selection: $appState.readerPrefs.historySortOrder) {
                    Text("Last read").tag("last_read")
                    Text("A → Z").tag("alpha")
                    Text("Recently added").tag("added")
                }
            }
            settingGroup("Search") {
                toggleRow("Hide NSFW results", description: "Adult-tagged manga skipped in searches.", isOn: $appState.readerPrefs.nsfwFilter)
            }
            settingGroup("Categories",
                         footer: "Create, rename, and delete categories from a manga's details page.") {
                infoRow("Total", value: "\(appState.categories.count)")
            }
        }
    }

    @ViewBuilder
    private var readerSection: some View {
        Group {
            settingGroup("Default mode") {
                pickerRow("Reading mode", selection: $appState.readerPrefs.defaultReaderMode) {
                    Text("Paged").tag("standard")
                    Text("Paged RTL").tag("reversed")
                    Text("Vertical").tag("vertical")
                    Text("Webtoon").tag("webtoon")
                }
                toggleRow("Auto-detect mode", description: "Switch to webtoon for very tall pages.", isOn: $appState.readerPrefs.readerModeDetect)
                pickerRow("Background", selection: $appState.readerPrefs.readerBackground) {
                    Text("Auto").tag("auto"); Text("Dark").tag("dark"); Text("Light").tag("light")
                }
            }
            settingGroup("Scaling") {
                pickerRow("Scale mode", selection: $appState.readerPrefs.zoomMode) {
                    Text("Fit screen").tag("fit_center")
                    Text("Fit width").tag("fit_width")
                    Text("Fit height").tag("fit_height")
                    Text("Fill page").tag("fill")
                }
                toggleRow("Two-pages in landscape", description: "Render adjacent pages side-by-side when the window is landscape.", isOn: $appState.readerPrefs.twoPageLayout)
                toggleRow("Show zoom buttons", description: "Floating + / - / reset controls in the corner.", isOn: $appState.readerPrefs.readerZoomButtons)
            }
            settingGroup("Webtoon") {
                toggleRow("Webtoon zoom", description: "Pinch-zoom in webtoon mode.", isOn: $appState.readerPrefs.webtoonZoom)
                if appState.readerPrefs.webtoonZoom {
                    sliderRow("Default zoom-out",
                              value: $appState.readerPrefs.webtoonZoomOut,
                              range: 0...0.5, step: 0.05,
                              label: "\(Int(appState.readerPrefs.webtoonZoomOut * 100))%")
                }
                toggleRow("Gaps between pages", description: "Visible spacing between webtoon strips.", isOn: $appState.readerPrefs.isWebtoonGapsEnabled)
                toggleRow("Pull-to-refresh in webtoon", description: "Drag the top edge to reload pages.", isOn: $appState.readerPrefs.webtoonPullGesture)
            }
            settingGroup("Navigation") {
                toggleRow("Tap zones", description: "Click the left / right thirds of the page to turn. Direction follows the reading mode (RTL flips them).", isOn: $appState.readerPrefs.tapZonesEnabled)
                toggleRow("Auto-hide controls", description: "Page counter fades after 2.5 s of mouse idle.", isOn: $appState.readerPrefs.autoHideControls)
                toggleRow("Show page numbers overlay", description: "Page counter + seekbar at the bottom.", isOn: $appState.readerPrefs.showPageNumbers)
            }
            settingGroup("Performance") {
                toggleRow("Prefetch next chapter", description: "Warm the image cache while reading.", isOn: $appState.readerPrefs.prefetchNextPages)
            }
        }
    }

    @ViewBuilder
    private var sourcesSection: some View {
        Group {
            settingGroup("Content & language") {
                toggleRow("Show 18+ sources", description: "Include adult-only sources in Explore, the catalog, sidebar, and global search.", isOn: Binding(
                    get: { !appState.hideNsfwSources },
                    set: { appState.hideNsfwSources = !$0 }
                ))
                buttonRow("Re-run setup…", systemImage: "slider.horizontal.3") {
                    showPreferencesSheet = true
                }
            }
            settingGroup("Catalog") {
                infoRow("Installed", value: "\(appState.sources.filter(\.isInstalled).count) of \(appState.sources.count)")
                buttonRow("Refresh catalog", systemImage: "arrow.clockwise") {
                    Task { @MainActor in await appState.reloadCatalog() }
                }
                buttonRow("Browse catalog…", systemImage: "plus.circle") {
                    Task { @MainActor in await appState.openCatalog() }
                }
            }
        }
    }

    @ViewBuilder
    private var translationSection: some View {
        Group {
            settingGroup("Pipeline",
                         footer: "Native GPU-accelerated ONNX OCR (manga-ocr / PaddleOCR) → Google Translate (most accurate for manga, no key). Optionally, your own LLM (below) refines each page for natural, coherent phrasing.") {
                toggleRow("Instant translation on chapter open",
                          description: "Auto-translate every page as the chapter loads. Heavy — leave off if your Mac is busy.",
                          isOn: $appState.readerPrefs.instantTranslation)
                sliderRow("Response size",
                          value: $appState.readerPrefs.translationResponseScale,
                          range: 0.75...1.6,
                          step: 0.05,
                          label: "\(Int(appState.readerPrefs.translationResponseScale * 100))%")
                pickerRow("Source language",
                          selection: bind(\.translateSettings.sourceLang)) {
                    ForEach(TranslationSettings.sourceLanguages, id: \.self) { Text($0).tag($0) }
                }
                pickerRow("Target language",
                          selection: bind(\.translateSettings.targetLang)) {
                    ForEach(TranslationSettings.supportedLanguages.filter { $0 != "AUTO" }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
            translationModelsGroup
            byokGroup
            settingGroup("Debug HUD") {
                toggleRow("Translation pipeline HUD",
                          description: "Floating chip strip in the reader showing Download → OCR → Translate → Refine timings.",
                          isOn: $appState.debugHUDEnabled)
            }
        }
    }

    /// Pre-download the on-device OCR models so the first translation of a language is instant
    /// and works offline. Models are fetched once (from the same CDNs the web app uses) and cached.
    @ViewBuilder
    private var translationModelsGroup: some View {
        settingGroup("Offline OCR models",
                     footer: "Download a language's OCR model once, then translation is instant and works offline. Japanese is the largest; Chinese also covers English.") {
            ForEach(NativeOcrProvider.downloadableLangs, id: \.key) { lang in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lang.title)
                        Text("≈ \(lang.approxMB) MB")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if ocrModels.downloadingLang == lang.key {
                        VStack(alignment: .trailing, spacing: 3) {
                            ProgressView(value: max(0, ocrModels.downloadProgress))
                                .frame(width: 130)
                            Text(ocrModels.downloadLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if ocrModels.installedLangs.contains(lang.key) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                    } else {
                        Button("Download") {
                            Task { try? await NativeOcrProvider.shared.preload(lang: lang.key) }
                        }
                        .buttonStyle(.bordered)
                        .tint(.appAccent)
                        .disabled(ocrModels.downloadingLang != nil)
                    }
                }
                .padding(.vertical, 3)
            }
            if let err = ocrModels.downloadError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    /// Picking a provider fills the endpoint (and the model hint when the model
    /// field is still empty), while keeping the endpoint field free-editable.
    private var providerBinding: Binding<String> {
        Binding(
            get: { appState.translateSettings.endpoint },
            set: { url in
                appState.translateSettings.endpoint = url
                if appState.translateSettings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let hint = TranslationSettings.providers.first(where: { $0.url == url })?.modelHint,
                   !hint.isEmpty {
                    appState.translateSettings.model = hint
                }
            }
        )
    }

    /// On-device AI colorization (manga-colorization-v2) — its own settings section
    /// (it is NOT translation). Download the model here; toggle colorization per
    /// chapter from the reader toolbar / tools sheet.
    @ViewBuilder
    private var colorizationSection: some View {
        settingGroup("AI colorization",
                     footer: "Colorize black-and-white manga on device with manga-colorization-v2, GPU-accelerated. Download the model once, then toggle “Colorize” per chapter from the reader.") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Colorizer model")
                    Text("≈ \(NativeColorizer.modelApproxMB) MB").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                switch colorizer.modelState {
                case .downloading(let p):
                    VStack(alignment: .trailing, spacing: 3) {
                        ProgressView(value: max(0, p)).frame(width: 130)
                        Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                    }
                case .ready:
                    HStack(spacing: 12) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.callout).foregroundStyle(.green)
                        Button("Remove") { colorizer.deleteModel() }
                            .buttonStyle(.borderless).tint(.red)
                    }
                case .failed(let msg):
                    VStack(alignment: .trailing, spacing: 3) {
                        Button("Retry") { Task { await colorizer.downloadModelIfNeeded() } }
                            .buttonStyle(.bordered).tint(.appAccent)
                        Text(msg).font(.caption2).foregroundStyle(.red).lineLimit(1)
                    }
                case .notInstalled:
                    Button("Download") { Task { await colorizer.downloadModelIfNeeded() } }
                        .buttonStyle(.bordered).tint(.appAccent)
                }
            }
            .padding(.vertical, 3)
        }
    }

    /// Bring-your-own-key LLM refinement (OpenAI / Anthropic compatible), the
    /// mac equivalent of the web's `cfg` in core/translate/mt.js.
    @ViewBuilder
    private var byokGroup: some View {
        settingGroup("AI refinement (BYOK)",
                     footer: "Optional. After Google translates a page, your own LLM rewrites every bubble together — more coherent and natural, using the reference below for names and terms. OpenAI- and Anthropic-compatible. Your key is stored only on this Mac.") {
            pickerRow("Provider", selection: providerBinding) {
                ForEach(TranslationSettings.providers) { p in Text(p.name).tag(p.url) }
            }
            textFieldRow("API endpoint", text: bind(\.translateSettings.endpoint),
                         placeholder: "https://api.openai.com/v1")
            textFieldRow("Model", text: bind(\.translateSettings.model),
                         placeholder: appState.translateSettings.effectiveModel)
            secureFieldRow("API key", text: bind(\.translateSettings.apiKey), placeholder: "sk-…")
            VStack(alignment: .leading, spacing: 4) {
                Text("Series reference — character names, honorifics, terminology")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: bind(\.translateSettings.context))
                    .font(.callout)
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1)))
            }
            toggleRow("Skip AI refinement",
                      description: "Use raw Google Translate only — don't call the LLM even when a key is set.",
                      isOn: bind(\.translateSettings.isOffline))
        }
    }

    @ViewBuilder
    private var networkSection: some View {
        Group {
            settingGroup("Proxy") {
                pickerRow("Proxy type", selection: $appState.readerPrefs.proxyType) {
                    Text("Direct").tag("direct"); Text("HTTP").tag("http"); Text("SOCKS5").tag("socks5")
                }
                if appState.readerPrefs.proxyType != "direct" {
                    textFieldRow("Address", text: $appState.readerPrefs.proxyAddress, placeholder: "127.0.0.1")
                    stepperRow("Port", value: $appState.readerPrefs.proxyPort, range: 0...65535, step: 1, label: "\(appState.readerPrefs.proxyPort)")
                }
            }
            settingGroup("DNS") {
                pickerRow("DNS-over-HTTPS", selection: $appState.readerPrefs.dnsOverHttps) {
                    Text("Disabled").tag("none"); Text("Cloudflare").tag("cloudflare")
                    Text("Google").tag("google"); Text("AdGuard").tag("adguard")
                    Text("Quad9").tag("quad9"); Text("Mullvad").tag("mullvad")
                }
            }
            settingGroup("Mirrors") {
                pickerRow("GitHub mirror", selection: $appState.readerPrefs.githubMirror) {
                    Text("Default").tag("KEIYOUSHI")
                    Text("FastGit").tag("FASTGIT")
                    Text("Ghproxy").tag("GHPROXY")
                }
                pickerRow("Image proxy", selection: $appState.readerPrefs.imagesProxy) {
                    Text("Off").tag("none")
                    Text("Weserv").tag("weserv")
                    Text("Statically").tag("statically")
                }
            }
            settingGroup("Resilience") {
                toggleRow("Ad / tracker blocking", description: "Strip known ad and analytics domains from source pages.", isOn: $appState.readerPrefs.isAdBlockEnabled)
                toggleRow("Ignore SSL errors", description: "Allow connections to sources with broken certificates.", isOn: $appState.readerPrefs.sslBypass)
                toggleRow("Disable connectivity check", description: "Skip the reachability ping before each request.", isOn: $appState.readerPrefs.noOffline)
            }
            settingGroup("Identity") {
                infoRow("User-Agent", value: "Nyora/1.0 (macOS)")
            }
        }
    }

    @ViewBuilder
    private var downloadsSection: some View {
        Group {
            settingGroup("Concurrency") {
                stepperRow("Max concurrent downloads",
                           value: $appState.readerPrefs.maxConcurrentDownloads,
                           range: 1...8, step: 1,
                           label: "\(appState.readerPrefs.maxConcurrentDownloads)")
            }
            settingGroup("Format") {
                pickerRow("Save chapters as", selection: $appState.readerPrefs.downloadFormat) {
                    Text("Auto").tag("auto")
                    Text("Folder of images").tag("folder")
                    Text("CBZ archive").tag("cbz")
                    Text("ZIP archive").tag("zip")
                }
            }
            settingGroup("Active") {
                let inProgress = appState.downloads.filter { !$0.isTerminal }.count
                let completed  = appState.downloads.filter { $0.status == "COMPLETED" }.count
                infoRow("In progress", value: "\(inProgress)")
                infoRow("Completed",    value: "\(completed)")
            }
        }
    }

    @ViewBuilder
    private var trackerSection: some View {
        Group {
            ForEach(TrackerService.allCases.filter { $0 != .shikimori && $0 != .bangumi && $0 != .kitsu }) { service in
                // The Keychain note is the same for every service, so it rides
                // the first section's footer instead of floating above the page.
                settingGroup(
                    service.displayName,
                    footer: service == TrackerService.allCases.first
                        ? "Link a tracking service to sync your reading progress. Tokens are stored in the macOS Keychain."
                        : nil
                ) {
                    trackerGroupContent(service)
                }
            }
        }
    }

    @ViewBuilder
    private func trackerGroupContent(_ service: TrackerService) -> some View {
        if appState.tracker.hasToken(service) {
            infoRow("Status", value: "Connected")
            toggleRow("Scrobble on chapter open",
                      description: "Update progress automatically as you read.",
                      isOn: trackerEnabledBinding(service))
            buttonRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", tint: .red) {
                appState.tracker.disconnect(service)
            }
        } else {
            switch service.grantKind {
            case .password:
                textFieldRow("Email", text: $kitsuEmail, placeholder: "you@example.com")
                secureFieldRow("Password", text: $kitsuPassword, placeholder: "••••••••")
                buttonRow(trackerBusy == service.rawValue ? "Signing in…" : "Log in",
                          systemImage: "person.crop.circle.badge.plus") {
                    connectTrackerPassword(service, email: kitsuEmail, password: kitsuPassword)
                }
            case .implicit, .authorizationCode:
                buttonRow(trackerBusy == service.rawValue ? "Connecting…" : "Connect with \(service.displayName)",
                          systemImage: "link") {
                    connectTrackerOAuth(service)
                }
            }

            secureFieldRow("Access token (manual)",
                           text: manualTrackerTokenBinding(service),
                           placeholder: "Paste a personal token")
            buttonRow("Save token", systemImage: "key.fill") {
                let value = (manualTrackerToken[service.rawValue] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                appState.tracker.setToken(service, value)
                appState.tracker.setEnabled(service, true)
                manualTrackerToken[service.rawValue] = ""
            }
        }
    }

    private func trackerEnabledBinding(_ service: TrackerService) -> Binding<Bool> {
        Binding(
            get: { appState.tracker.isEnabled(service) },
            set: { appState.tracker.setEnabled(service, $0) }
        )
    }

    private func manualTrackerTokenBinding(_ service: TrackerService) -> Binding<String> {
        Binding(
            get: { manualTrackerToken[service.rawValue] ?? "" },
            set: { manualTrackerToken[service.rawValue] = $0 }
        )
    }

    private func connectTrackerOAuth(_ service: TrackerService) {
        guard trackerBusy == nil else { return }
        trackerBusy = service.rawValue
        Task { @MainActor in
            defer { trackerBusy = nil }
            do {
                let result = try await TrackerOAuth.shared.login(service)
                appState.tracker.setToken(service, result.accessToken)
                appState.tracker.setRefreshToken(service, result.refreshToken)
                appState.tracker.setEnabled(service, true)
                appState.statusMessage = "\(service.displayName) connected"
            } catch TrackerOAuth.AuthError.cancelled {
                // user dismissed — stay silent
            } catch {
                appState.statusMessage = "\(service.displayName) sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    private func connectTrackerPassword(_ service: TrackerService, email: String, password: String) {
        let em = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !em.isEmpty, !password.isEmpty else {
            appState.statusMessage = "Enter your email and password"
            return
        }
        guard trackerBusy == nil else { return }
        trackerBusy = service.rawValue
        Task { @MainActor in
            defer { trackerBusy = nil }
            do {
                // Route password sign-in through the local helper so its Cloudflare
                // handling clears Kitsu's challenged token endpoint (a direct POST 403s).
                let result = try await appState.helper.trackerPasswordLogin(
                    slug: service.endpointSlug, username: em, password: password)
                appState.tracker.setToken(service, result.accessToken)
                appState.tracker.setRefreshToken(service, result.refreshToken)
                appState.tracker.setEnabled(service, true)
                kitsuPassword = ""
                appState.statusMessage = "\(service.displayName) connected"
            } catch {
                appState.statusMessage = "\(service.displayName) sign-in failed: \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder
    private var nyoraSyncSection: some View {
        Group {
            if let status = appState.nyoraSyncStatus {
                if status.isAuthenticated {
                    settingGroup("Account") {
                        infoRow("Signed in as", value: status.email.isEmpty ? status.userId : status.email)
                        buttonRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", tint: .red) {
                            Task { await appState.nyoraSyncSignOut() }
                        }
                    }
                    settingGroup("Sync") {
                        buttonRow("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            guard !appState.isNyoraSyncing else { return }
                            Task { await appState.nyoraSync() }
                        }
                        .disabled(appState.isNyoraSyncing)

                        infoRow("Last synced", value: status.lastSyncTimestamp)
                    }
                } else {
                    settingGroup("Account",
                                 footer: "Sign in to sync your library across devices.") {
                        infoRow("Status", value: "Not signed in")
                        textFieldRow("Email", text: $nyoraSyncEmail, placeholder: "you@example.com")
                        secureFieldRow("Password", text: $nyoraSyncPassword, placeholder: "••••••••")

                        buttonRow("Sign in", systemImage: "person.crop.circle.badge.plus") {
                            submitNyoraSyncAuth(register: false)
                        }
                        .disabled(appState.isNyoraSyncSigningIn)

                        buttonRow("Create account", systemImage: "person.badge.plus") {
                            submitNyoraSyncAuth(register: true)
                        }
                        .disabled(appState.isNyoraSyncSigningIn)
                    }
                }
            } else {
                ProgressView()
                    .padding()
                    .task {
                        await appState.refreshNyoraSyncStatus()
                    }
            }
        }
    }

    private func submitNyoraSyncAuth(register: Bool) {
        guard !appState.isNyoraSyncSigningIn else { return }
        let em = nyoraSyncEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !em.isEmpty, !nyoraSyncPassword.isEmpty else {
            appState.statusMessage = "Enter your email and password"
            return
        }
        Task { @MainActor in
            _ = register
                ? await appState.nyoraSyncRegister(email: em, password: nyoraSyncPassword)
                : await appState.nyoraSyncSignIn(email: em, password: nyoraSyncPassword)
            nyoraSyncPassword = ""
        }
    }

    @ViewBuilder
    private var backupSection: some View {
        Group {
            settingGroup("Manual backup",
                         footer: "Saves favourites, history, categories, and bookmarks to a single JSON file. Downloaded images are not included.") {
                buttonRow("Export library…", systemImage: "square.and.arrow.up") {
                    Task { @MainActor in await exportBackup() }
                }
                buttonRow("Import library…", systemImage: "square.and.arrow.down") {
                    Task { @MainActor in await importBackup() }
                }
            }
            settingGroup("Periodic backup",
                         footer: "Periodic backups will land in a follow-up release.") {
                infoRow("Status", value: "Manual only")
            }
        }
    }

    @ViewBuilder
    private var notificationsSection: some View {
        Group {
            settingGroup("Events",
                         footer: "System banners are managed in macOS System Settings → Notifications → Nyora. The toggles here control which events Nyora emits.") {
                toggleRow("New chapter notifications", description: "Banner when an updated manga has new chapters.", isOn: $appState.readerPrefs.isTrackerEnabled)
            }
        }
    }

    @ViewBuilder
    private var privacySection: some View {
        Group {
            settingGroup("Browsing") {
                toggleRow("Incognito mode", description: "Don't record chapters in history while it's on.", isOn: $appState.readerPrefs.isIncognitoModeEnabled)
                toggleRow("Confirm before quitting", description: "Show a Cmd+Q confirmation prompt.", isOn: $appState.readerPrefs.exitConfirm)
            }
            settingGroup("Lock") {
                toggleRow("Require Touch ID / password on launch", description: "Locks the app until biometric or password authentication.", isOn: $appState.readerPrefs.isBiometricProtectionEnabled)
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Group {
            settingGroup("Database") {
                infoRow("Path", value: dbPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                infoRow("Size", value: ByteCountFormatter.string(fromByteCount: Int64(dbSizeBytes), countStyle: .file))
                buttonRow("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dbPath)])
                }
            }
            settingGroup("Image cache") {
                infoRow("Disk usage",       value: ByteCountFormatter.string(fromByteCount: Int64(cacheUsageBytes), countStyle: .file))
                infoRow("Memory capacity",  value: ByteCountFormatter.string(fromByteCount: Int64(URLCache.shared.memoryCapacity), countStyle: .memory))
                infoRow("Disk capacity",    value: ByteCountFormatter.string(fromByteCount: Int64(URLCache.shared.diskCapacity), countStyle: .file))
                buttonRow("Clear image cache", systemImage: "trash", tint: .red) {
                    URLCache.shared.removeAllCachedResponses()
                    cacheUsageBytes = URLCache.shared.currentDiskUsage
                }
            }
            settingGroup("Background service") {
                // The status colour is data (green/red health), so it stays.
                LabeledContent("State") {
                    Text(appState.helperStatus.label)
                        .foregroundStyle(appState.helperStatus.color)
                }
                infoRow("Endpoint", value: appState.helperBaseUrl.isEmpty ? "—" : appState.helperBaseUrl)
                buttonRow("Restart service", systemImage: "arrow.triangle.2.circlepath") {
                    Task { @MainActor in await appState.restartHelper() }
                }
            }
            settingGroup("Danger zone",
                         footer: "Permanently removes every manga, category, favourite, and history row. Sources are reseeded on next launch.") {
                buttonRow("Wipe database", systemImage: "trash.fill", tint: .red) {
                    Task { @MainActor in await appState.clearDatabase() }
                }
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Group {
            settingGroup("App") {
                infoRow("Version", value: "1.0")
                infoRow("Build", value: "Nyora for macOS")
                infoRow("Min macOS", value: "14.0")
            }
            settingGroup("Engine") {
                infoRow("OCR", value: "Apple Vision")
                infoRow("MT",  value: "Google Translate")
                infoRow("Refinement", value: "BYOK LLM (OpenAI / Anthropic)")
            }
            settingGroup("Links") {
                LabeledContent("Official website") {
                    Link("nyora.pages.dev", destination: URL(string: "https://nyora.pages.dev")!)
                }
                LabeledContent("Source code") {
                    Link("Hasan72341/nyora-mac", destination: URL(string: "https://github.com/Hasan72341/nyora-mac")!)
                }
            }
            // Attribution is a real row, not a footer — a Section whose only
            // content is a footer is not guaranteed to draw.
            settingGroup("Credits") {
                Text("Built on top of the open-source nyora-parsers library for source connectivity. Reader UX inspired by Nyora Android.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            settingGroup("Developer",
                         footer: "Nyora — your manga library, everywhere. Available on Android, Windows, macOS, Linux, iOS and the web.") {
                LabeledContent("Md Hasan Raza") {
                    Text("Creator of Nyora")
                }
                Link("Instagram", destination: URL(string: "https://www.instagram.com/md_hasan_raza____?igsh=MXZ6eTk2Y3FsNGs3aQ==")!)
                Link("LinkedIn", destination: URL(string: "https://www.linkedin.com/in/md-hasan-raza-8817372a7/")!)
                Link("GitHub", destination: URL(string: "https://github.com/Hasan72341")!)
                Link("Email", destination: URL(string: "mailto:hasanraza96@outlook.com")!)
            }
        }
    }

    // MARK: - Storage helpers

    private var dbPath: String {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return "—" }
        return appSupport.appendingPathComponent("Nyora/nyora.db").path
    }

    @MainActor
    private func exportBackup() async {
        do {
            let data = try await appState.helper.backupExport()
            let panel = NSSavePanel()
            panel.title = "Export Nyora library"
            panel.nameFieldStringValue = "nyora-backup.json"
            panel.allowedContentTypes = [.json]
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
                appState.statusMessage = "Backup saved to \(url.lastPathComponent)"
            }
        } catch {
            appState.statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func importBackup() async {
        _ = await appState.importBackup()
    }

    // MARK: - Components

    /// A settings group is a plain `Section`. The uppercase accent-tinted caption,
    /// the linear-gradient surface and the hand-drawn hairline separators are
    /// gone — `Form`'s grouped style draws all of that natively. The optional
    /// footer is where a group's explanatory paragraph belongs on macOS.
    private func settingGroup<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// A stock `Toggle`. Two `Text`s in the label is the system title+description
    /// idiom for a grouped form — no hand-built VStack, no `.labelsHidden()`
    /// switch stranded behind a `Spacer`.
    private func toggleRow(_ title: String, description: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
            Text(description)
        }
        .tint(Color.appAccent)
    }

    private func pickerRow<V: Hashable, Content: View>(_ title: String, selection: Binding<V>, @ViewBuilder content: () -> Content) -> some View {
        Picker(title, selection: selection) { content() }
    }

    private func stepperRow(_ title: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            step: Int,
                            label: String) -> some View {
        LabeledContent(title) {
            Stepper(value: value, in: range, step: step) {
                Text(label)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func textFieldRow(_ title: String,
                              text: Binding<String>,
                              placeholder: String) -> some View {
        TextField(title, text: text, prompt: Text(placeholder))
    }

    private func secureFieldRow(_ title: String,
                                text: Binding<String>,
                                placeholder: String) -> some View {
        SecureField(title, text: text, prompt: Text(placeholder))
    }

    /// A stock `Button`. The chevron, the hover fill and the hairline are gone;
    /// a destructive tint becomes the system destructive role.
    @ViewBuilder
    private func buttonRow(_ title: String,
                            systemImage: String,
                            assetImage: String? = nil,
                            tint: Color = .appAccent,
                            action: @escaping () -> Void) -> some View {
        Button(role: tint == .red ? .destructive : nil, action: action) {
            Label {
                Text(title)
            } icon: {
                if let assetImage {
                    Image(bundleResource: assetImage).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: systemImage)
                }
            }
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// Build a Binding to a property on AppState. Use this when the property
    /// lives behind a `let`-declared sub-object (tracker, sync, translateSettings)
    /// — SwiftUI's `bind(\.tracker.x)` dynamic-member subscript fails on
    /// `let` parents, but a KeyPath bypasses that machinery.
    private func bind<T>(_ keyPath: ReferenceWritableKeyPath<AppState, T>) -> Binding<T> {
        Binding(
            get: { appState[keyPath: keyPath] },
            set: { appState[keyPath: keyPath] = $0 }
        )
    }

    /// A stock `Slider` in a labelled row, accent kept as a tint.
    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .tint(Color.appAccent)
                Text(label)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case appearance, library, reader, sources, translation, colorization, network, downloads
    case tracker, sync, backup, notifications, privacy, advanced, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance:    return "Appearance"
        case .library:       return "Library"
        case .reader:        return "Reader"
        case .sources:       return "Sources"
        case .translation:   return "Translation"
        case .colorization:  return "Colorization"
        case .network:       return "Network"
        case .downloads:     return "Downloads"
        case .tracker:       return "Tracker"
        case .sync:          return "Nyora Sync"
        case .backup:        return "Backup & restore"

        case .notifications: return "Notifications"
        case .privacy:       return "Privacy"
        case .advanced:      return "Advanced"
        case .about:         return "About"
        }
    }
    var systemImage: String {
        switch self {
        case .appearance:    return "paintpalette"
        case .library:       return "books.vertical.fill"
        case .reader:        return "book.pages.fill"
        case .sources:       return "puzzlepiece.extension.fill"
        case .translation:   return "globe"
        case .colorization:  return "paintbrush.pointed.fill"
        case .network:       return "wifi"
        case .downloads:     return "arrow.down.to.line"
        case .tracker:       return "chart.line.uptrend.xyaxis"
        case .sync:          return "arrow.triangle.2.circlepath.icloud.fill"
        case .backup:        return "externaldrive.fill.badge.checkmark"
        case .notifications: return "bell.badge.fill"
        case .privacy:       return "hand.raised.fill"
        case .advanced:      return "gearshape.2.fill"
        case .about:         return "info.circle.fill"
        }
    }
}

@MainActor
/// The empty state for every pane — one shared treatment so the panes agree with each other.
/// A large hierarchical SF Symbol in a neutral/secondary tone (the way Finder, Photos and Notes
/// draw theirs — no saturated accent disc), a title + secondary message, and an optional inline
/// action button that sits directly under the message so callers don't stack a sibling button
/// (which the full-height empty view would otherwise push off-screen).
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 360)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    // NOT .borderedProminent: a prominent button is the window's DEFAULT
                    // button and auto-grabs first-responder focus when the pane appears —
                    // macOS then scrolls to reveal that focused control, which dragged the
                    // whole sidebar up on the Local pane. A bordered, non-focusable button
                    // is a clear CTA without hijacking focus/scroll.
                    .buttonStyle(.bordered)
                    .tint(.appAccent)
                    .controlSize(.large)
                    .focusable(false)
                    .padding(.top, 4)
            }
        }
        .padding(40)
        // Centre within the space the pane gives it, rather than sizing to content and
        // getting stranded in a corner by the caller's alignment.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
struct HistoryRowView: View {
    let row: HelperHistoryRow
    let accent: Color
    let secondaryAccent: Color
    @EnvironmentObject var appState: AppState

    private var displayChapterTitle: String {
        row.chapterTitle.isEmpty ? "Chapter" : row.chapterTitle
    }

    private var displayDate: Date {
        Date(timeIntervalSince1970: TimeInterval(row.updatedAt) / 1000)
    }

    var body: some View {
        Button {
            Task { await appState.openHistoryEntry(row) }
        } label: {
            HStack(spacing: 14) {
                // Cover thumbnail 56x80 with bottom progress overlay
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: row.mangaCoverUrl)) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        case .empty, .failure:
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(0.06))
                                .shimmer()
                        @unknown default:
                            Color.primary.opacity(0.12)
                        }
                    }
                    .frame(width: 56, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    )

                    // Progress bar at bottom of cover
                    ProgressView(value: Double(row.percent))
                        .progressViewStyle(.linear)
                        .tint(accent)
                        .scaleEffect(y: 0.5)
                        .frame(width: 56)
                }

                // Metadata — title, then one secondary line. Chapter, time and source were
                // three stacked lines, which forced a tall row and left the trailing badge
                // stranded; the system list idiom is a title plus a single subtitle.
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.mangaTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text(displayChapterTitle)
                        Text("·")
                        Text(displayDate, format: .relative(presentation: .named))
                        Text("·")
                        Text(row.sourceName)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text("\(Int((row.percent * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                Task {
                    appState.selectedSourceId = row.sourceId
                    await appState.openDetails(MangaSummary(
                        id: row.mangaId,
                        title: row.mangaTitle,
                        sourceName: row.sourceName,
                        coverUrl: row.mangaCoverUrl,
                        unread: 0,
                        progress: row.percent,
                        tags: []
                    ))
                    appState.pendingNavigation = .explore
                }
            } label: {
                Label("View Info", systemImage: "info.circle")
            }
            Divider()
            Button(role: .destructive) {
                Task { await appState.removeHistory(mangaId: row.mangaId) }
            } label: {
                Label("Remove from History", systemImage: "trash")
            }
        }
    }
}

@MainActor
/// A suggestion as a stock list row — cover thumbnail, title, one secondary line.
/// Mirrors `HistoryRowView`: the vignette gradient, white overlay title, drop
/// shadow, accent glow and hover scale are gone, and `List` supplies hover and
/// selection itself.
struct SuggestionRowView: View {
    let manga: HelperSuggestedManga
    let action: () -> Void

    /// The blurb is real data the card never showed; the source id stands in
    /// when a suggestion carries no description.
    private var subtitle: String {
        let blurb = manga.description.trimmingCharacters(in: .whitespacesAndNewlines)
        return blurb.isEmpty ? manga.sourceId : blurb
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().scaledToFill()
                    case .empty, .failure:
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                            .shimmer()
                    @unknown default:
                        Color.primary.opacity(0.12)
                    }
                }
                .frame(width: 56, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(manga.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: action) {
                Label("View Info", systemImage: "info.circle")
            }
        }
    }
}
