import SwiftUI

@MainActor
struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var cachedSortedHistory: [HelperHistoryRow] = []
    @State private var cachedGroupedHistory: [(String, [HelperHistoryRow])] = []

    private var historyBackdrop: some View {
        // Flat backdrop. The old triple RadialGradient got composited under the
        // List on every scrolled frame, which is what made History stutter
        // (Feed got the same treatment and is now smooth).
        Color.appBackground.ignoresSafeArea()
    }

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
                            Section(header:
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(group.0)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                    Rectangle()
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.appAccent.opacity(0.4), Color.clear],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 1)
                                }
                            ) {
                                rowsSection(group.1)
                            }
                        } else {
                            rowsSection(group.1)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(historyBackdrop)
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

/// AniList-powered discovery feed. Three batched sections — Trending Now,
/// Popular This Season, Top Rated — pulled from AniList's public GraphQL.
/// NSFW titles are filtered server-side when the library NSFW filter is on.
/// Tapping a cover runs a global search so the user can open it in a source.
@MainActor
struct FeedView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var trending: [AniListBrowseMedia] = []
    @State private var popular: [AniListBrowseMedia] = []
    @State private var topRated: [AniListBrowseMedia] = []
    @State private var loading = false
    @State private var error: String?
    @State private var searchText: String = ""

    private var isEmpty: Bool {
        trending.isEmpty && popular.isEmpty && topRated.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28, pinnedViews: []) {
                feedHeader
                searchBar

                if loading && isEmpty {
                    ProgressView("Loading feed…")
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if let error, isEmpty {
                    EmptyStateView(
                        icon: "wifi.exclamationmark",
                        title: "Couldn't load the feed",
                        message: error
                    )
                    .frame(minHeight: 240)
                } else if isEmpty {
                    EmptyStateView(
                        icon: "newspaper",
                        title: "Nothing in the feed yet",
                        message: "Refresh to load trending manga from AniList."
                    )
                    .frame(minHeight: 240)
                } else {
                    section("Trending Now", "What the community is reading right now", trending)
                    section("Popular This Season", "Most-followed ongoing series", popular)
                    section("Top Rated", "Highest-scored manga of all time", topRated)
                }
            }
            .padding(.vertical, 20)
        }
        .background(feedBackdrop)
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

    private var feedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Feed")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("Discover what's trending on AniList.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
    }

    /// Universal search entry — runs a search across every installed source
    /// (via AppState) and hands the user off to the Universal Search screen.
    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search every installed source…", text: $searchText)
                .textFieldStyle(.plain)
                .onSubmit { runUniversalSearch() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22)
    }

    private var feedBackdrop: some View {
        Color.appBackground.ignoresSafeArea()
    }

    @ViewBuilder
    private func section(_ title: String, _ subtitle: String, _ items: [AniListBrowseMedia]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 14) {
                        ForEach(items) { media in
                            AniListFeedCard(media: media) {
                                openInSearch(media)
                            }
                        }
                    }
                    .padding(.horizontal, 22)
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
            popular  = data.popular?.media ?? []
            topRated = data.topRated?.media ?? []
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

/// Cover card for an AniList feed entry — 2:3 art, title, optional score badge.
@MainActor
private struct AniListFeedCard: View {
    let media: AniListBrowseMedia
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AsyncImage(url: URL(string: media.coverURL)) { phase in
                        switch phase {
                        case let .success(image):
                            image.resizable().scaledToFill()
                        default:
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.06))
                                .shimmer()
                        }
                    }
                    .aspectRatio(2.0 / 3.0, contentMode: .fill)
                    .frame(width: 132)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .clear, .black.opacity(0.55)],
                            startPoint: .top, endPoint: .bottom
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    )

                    if let score = media.averageScore, score > 0 {
                        Text("\(score)%")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(8)
                    }
                }

                Text(media.bestTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: 132, alignment: .leading)

                if let genre = media.topGenre {
                    Text(genre)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 132)
            .opacity(isHovered ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

@MainActor
struct LocalView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            if appState.localFolder.isEmpty {
                localEmptyState
            } else if appState.localEntries.isEmpty {
                localNoCbzState
            } else {
                localList
            }
        }
        .toolbar {
            Button { pickFolder() } label: { Label("Choose Folder", systemImage: "folder.badge.plus") }
            Button {
                Task { await appState.scanLocalFolder() }
            } label: { Label("Rescan", systemImage: "arrow.clockwise") }
            .disabled(appState.localFolder.isEmpty)
        }
        .task {
            if !appState.localFolder.isEmpty && appState.localEntries.isEmpty {
                await appState.scanLocalFolder()
            }
        }
    }

    // MARK: - Empty state (no folder picked)

    private var localEmptyState: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 26) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.appAccent.opacity(0.18), Color.appAccent.opacity(0.05)],
                                center: .center,
                                startRadius: 0,
                                endRadius: 40
                            )
                        )
                        .frame(width: 80, height: 80)

                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.appAccent)
                }

                VStack(spacing: 8) {
                    Text("No Folder Selected")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("Choose a folder containing .cbz files. They will show up here as readable chapters.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                Button("Choose Folder") { pickFolder() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No CBZ files found state

    private var localNoCbzState: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 24) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color.appAccent.opacity(0.18), Color.appAccent.opacity(0.05)],
                                center: .center,
                                startRadius: 0,
                                endRadius: 40
                            )
                        )
                        .frame(width: 80, height: 80)

                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.appAccent)
                }

                VStack(spacing: 8) {
                    Text("No CBZ files found")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text(appState.localFolder)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 560)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 24)
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await appState.scanLocalFolder() }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .allowsHitTesting(false)
                    )

                    Button("Choose Folder") { pickFolder() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.18), Color.clear],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                )
                                .allowsHitTesting(false)
                        )
                }
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List of CBZ entries

    private var localList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(appState.localEntries) { entry in
                    LocalEntryRow(entry: entry, formatter: byteFormatter) {
                        Task { await appState.openLocalCbz(entry) }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Helpers

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder that contains .cbz manga files"
        if panel.runModal() == .OK, let url = panel.url {
            appState.localFolder = url.path
            Task { await appState.scanLocalFolder() }
        }
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }
}

@MainActor
private struct LocalCTAButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [Color.appAccent.opacity(0.92), Color.appAccent.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: Color.appAccent.opacity(isHovered ? 0.50 : 0.22), radius: isHovered ? 16 : 8, y: 4)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.38, dampingFraction: 0.65), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

@MainActor
private struct LocalEntryRow: View {
    let entry: HelperLocalCbz
    let formatter: ByteCountFormatter
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 14) {
                // File icon with gradient background
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.appAccent.opacity(0.20), Color.appAccent.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.appAccent)
                }

                Text(entry.name)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                // Size chip badge (glass)
                Text(formatter.string(fromByteCount: entry.sizeBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isHovered
                        ? AnyShapeStyle(LinearGradient(
                            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.03)],
                            startPoint: .leading,
                            endPoint: .trailing
                          ))
                        : AnyShapeStyle(Color.clear)
                    )
            )
            .animation(.spring(response: 0.38, dampingFraction: 0.65), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

@MainActor
struct SuggestionsView: View {
    @EnvironmentObject var appState: AppState
    @State private var entries: [HelperSuggestedManga] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                ZStack {
                    Color.appBackground.ignoresSafeArea()
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let error {
                EmptyStateView(icon: "sparkles",
                               title: "Unable to load suggestions",
                               message: error)
            } else if entries.isEmpty {
                EmptyStateView(icon: "sparkles",
                               title: "No suggestions yet",
                               message: "Favourite a manga to see related titles from the same source.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: CGFloat(appState.readerPrefs.gridSize), maximum: CGFloat(appState.readerPrefs.gridSize) * 1.4), spacing: 14)], spacing: 14) {
                        ForEach(entries) { manga in
                            SuggestionCard(manga: manga)
                                .onTapGesture {
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
                        }
                    }
                    .padding(18)
                }
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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

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
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {

                        // Hero header
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Reading Stats")
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                            Text(Self.dateFormatter.string(from: Date()))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 4)

                        // Stat cards grid — adaptive min 130
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 130), spacing: 14)],
                            spacing: 14
                        ) {
                            StatsCard(label: "Chapters Read",  value: "\(s.totalChapters)",
                                      icon: "book.fill",
                                      gradient: [Color.appAccent.opacity(0.85), Color.appAccent.opacity(0.45)],    delay: 0.00)
                            StatsCard(label: "Distinct Manga", value: "\(s.distinctManga)",
                                      icon: "books.vertical.fill",
                                      gradient: [Color.appAccent.opacity(0.85), Color.appAccent.opacity(0.45)],  delay: 0.06)
                            StatsCard(label: "Favourites",     value: "\(s.favouritesCount)",
                                      icon: "heart.fill",
                                      gradient: [Color.appAccent.opacity(0.85), Color.appAccent.opacity(0.45)],     delay: 0.12)
                            StatsCard(label: "Longest Streak", value: "\(s.longestStreakDays)d",
                                      icon: "flame.fill",
                                      gradient: [Color.appAccent.opacity(0.85), Color.appAccent.opacity(0.45)], delay: 0.18)
                        }

                        // Top sources section
                        if !s.topSources.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("TOP SOURCES")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .tracking(1.2)

                                let maxCount = s.topSources.map(\.count).max() ?? 1
                                ForEach(Array(s.topSources.enumerated()), id: \.element.id) { idx, row in
                                    StatsSourceRow(row: row, maxCount: maxCount, delay: Double(idx) * 0.06)
                                }
                            }
                        }
                    }
                    .padding(22)
                }
                .background(statsBackdrop)
            } else {
                EmptyStateView(icon: "chart.bar", title: "No stats yet", message: "Start reading to see your statistics here.")
            }
        }
        .background(statsBackdrop)
        .task { await load() }
        .toolbar {
            Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    private var statsBackdrop: some View {
        ZStack {
            Color.appBackground
            if colorScheme == .dark {
                RadialGradient(
                    colors: [Color.appAccent.opacity(0.12), Color.clear],
                    center: .topLeading, startRadius: 10, endRadius: 380
                )
                RadialGradient(
                    colors: [Color.appAccent.opacity(0.10), Color.clear],
                    center: .bottomTrailing, startRadius: 10, endRadius: 340
                )
            }
        }
        .ignoresSafeArea()
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

@MainActor
private struct StatsCard: View {
    let label: String
    let value: String
    let icon: String
    let gradient: [Color]
    let delay: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
            Text(value)
                .font(.title.bold().monospacedDigit())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            // AURORA FILL: base accent linear (0.85 -> 0.45) layered with a
            // bright accent radial spot anchored at .topLeading + a dimmer
            // accent spot at .bottomTrailing for organic single-hue depth.
            ZStack {
                LinearGradient(
                    stops: [
                        .init(color: statsBaseTop, location: 0),
                        .init(color: statsBaseTop.opacity(0.78), location: 0.55),
                        .init(color: statsBaseBottom, location: 1)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    stops: [
                        .init(color: Color.appAccent.opacity(0.40), location: 0),
                        .init(color: Color.appAccent.opacity(0.18), location: 0.45),
                        .init(color: .clear, location: 1)
                    ],
                    center: .topLeading, startRadius: 0, endRadius: 150
                )
                RadialGradient(
                    stops: [
                        .init(color: Color.appAccent.opacity(0.22), location: 0),
                        .init(color: .clear, location: 1)
                    ],
                    center: .bottomTrailing, startRadius: 0, endRadius: 130
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [Color.white.opacity(0.20), Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .legacyConicBorder()
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: (gradient.first ?? Color.appAccent).opacity(0.30), radius: 12, y: 5)
        .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
    }

    private var statsBaseTop: Color {
        gradient.first ?? Color.appAccent.opacity(0.85)
    }

    private var statsBaseBottom: Color {
        if gradient.count > 1 { return gradient[1] }
        return (gradient.first ?? Color.appAccent).opacity(0.45)
    }
}

/// Modern angular/conic border modifier — a rotating-light edge on macOS 15+,
/// gracefully degrading to a straight vertical accent stroke on macOS 14.
/// Single-hue: all stops derive from `Color.appAccent`.
@MainActor
private struct LegacyConicBorderModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var lineWidth: CGFloat = 0.8

    func body(content: Content) -> some View {
        content.overlay {
            if #available(macOS 15.0, *) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            stops: [
                                .init(color: Color.white.opacity(0.40), location: 0.00),
                                .init(color: Color.appAccent.opacity(0.10), location: 0.25),
                                .init(color: Color.white.opacity(0.28), location: 0.50),
                                .init(color: Color.appAccent.opacity(0.08), location: 0.75),
                                .init(color: Color.white.opacity(0.40), location: 1.00)
                            ],
                            center: .center
                        ),
                        lineWidth: lineWidth
                    )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.22), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            }
        }
    }
}

private extension View {
    func legacyConicBorder(cornerRadius: CGFloat = 18, lineWidth: CGFloat = 0.8) -> some View {
        modifier(LegacyConicBorderModifier(cornerRadius: cornerRadius, lineWidth: lineWidth))
    }
}

@MainActor
private struct StatsSourceRow: View {
    let row: HelperStatsSource
    let maxCount: Int
    let delay: Double

    var body: some View {
        HStack(spacing: 12) {
            Text(row.sourceName)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer()

            Text("\(row.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 3)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent, Color.appAccent.opacity(0.55)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 3)
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: Double(row.count) / Double(max(maxCount, 1)), anchor: .leading)
            }
            .frame(width: 80)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22, pinnedViews: []) {
                        ForEach(groups, id: \.mangaId) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.mangaTitle.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                                    .tracking(1.4)
                                    .padding(.leading, 4)

                                VStack(spacing: 0) {
                                    ForEach(Array(group.bookmarks.enumerated()), id: \.element.id) { idx, bookmark in
                                        if idx > 0 {
                                            Divider().opacity(0.4).padding(.leading, 68)
                                        }
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
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.015)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(18)
                }
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
    @State private var isHovered = false

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

                // Middle: chapter title, page number, optional note
                VStack(alignment: .leading, spacing: 3) {
                    Text(bookmark.chapterTitle.isEmpty ? "Chapter" : bookmark.chapterTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Page \(bookmark.page + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !bookmark.note.isEmpty {
                        Text(bookmark.note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)

                // Right: relative timestamp
                Text(Date(timeIntervalSince1970: TimeInterval(bookmark.createdAt) / 1000),
                     format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(Color.primary.opacity(isHovered ? 0.05 : 0))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(appState.updates.enumerated()), id: \.element.id) { idx, update in
                            if idx > 0 {
                                Divider().opacity(0.4).padding(.leading, 78)
                            }
                            UpdateRow(update: update) {
                                Task { await appState.markUpdatesSeen(update.mangaId) }
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.015)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .padding(16)
                }
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
            .buttonStyle(.borderedProminent)
            .tint(Color.appAccent)
            .controlSize(.regular)
            .disabled(appState.isRefreshingUpdates)
            .opacity(appState.isRefreshingUpdates ? 0.5 : 1.0)
        }
    }
}

@MainActor
private struct UpdateRow: View {
    let update: HelperUpdate
    let onMarkSeen: () -> Void
    @State private var isHovered = false
    @State private var markHovered = false

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

            // Middle: title, new-chapters badge + latest chapter, last synced
            VStack(alignment: .leading, spacing: 5) {
                Text(update.mangaTitle)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    // New-chapters badge
                    Text("+\(update.newChapters)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.appAccent, in: Capsule())

                    if !update.latestChapterTitle.isEmpty {
                        Text(update.latestChapterTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(Date(timeIntervalSince1970: TimeInterval(update.lastSyncedAt) / 1000),
                     format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            // Right: mark-seen checkmark button
            Button {
                onMarkSeen()
            } label: {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(markHovered ? Color.green : Color.appAccent.opacity(0.6))
                    .animation(.easeOut(duration: 0.15), value: markHovered)
            }
            .buttonStyle(.borderless)
            .onHover { markHovered = $0 }
            .help("Mark as seen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(Color.primary.opacity(isHovered ? 0.05 : 0))
        .onHover { isHovered = $0 }
    }
}

@MainActor
struct ReaderView: View {
    @EnvironmentObject var appState: AppState
    /// Drives the auto-hide of the page-counter and any in-content controls.
    /// Wakes on hover / click / page change, fades back out after 2.5 s.
    @State private var controlsVisible: Bool = true
    @State private var lastInteractionAt: Date = .now
    private let hideAfter: TimeInterval = 2.5
    @State private var isQuickSettingsPresented: Bool = false

    var body: some View {
        Group {
            if let chapter = appState.activeChapter, !chapter.pages.isEmpty {
                ZStack(alignment: .topTrailing) {
                    ZStack(alignment: .bottom) {
                        Group {
                            // V2 readers: clean implementations with zoom, click
                            // zones, in-image balloon overlay, keyboard nav.
                            switch appState.readerMode {
                            case .standard, .reversed:
                                PagedReaderV2(chapter: chapter, controlsVisible: controlsVisible)
                            case .vertical:
                                PagedReaderV2(chapter: chapter, controlsVisible: controlsVisible)
                            case .webtoon:
                                WebtoonReaderV2(chapter: chapter, controlsVisible: controlsVisible)
                            }
                        }
                        TranslationDebugBar()
                            .padding(.bottom, 18)
                            .allowsHitTesting(appState.debugHUDEnabled)
                    }

                    if isQuickSettingsPresented {
                        GeometryReader { proxy in
                            quickSettingsPanel
                                .frame(maxHeight: min(500, proxy.size.height - 24), alignment: .top)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.top, 12)
                        .padding(.trailing, 16)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                        .zIndex(99)
                    }
                }
                .toolbar { readerToolbar(chapter: chapter) }
                .onContinuousHover { phase in
                    if case .active = phase { wakeControls() }
                }
                .onChange(of: appState.readerPageIndex) { _, _ in
                    wakeControls()
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

    @ToolbarContentBuilder
    private func readerToolbar(chapter: ChapterSummary) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await appState.gotoChapterRelative(-1) }
            } label: { Label("Previous Chapter", systemImage: "backward") }
            .disabled(appState.readerChapterIndex <= 0)

            Text(chapter.title.isEmpty ? "Chapter" : chapter.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 120)

            Button {
                Task { await appState.gotoChapterRelative(1) }
            } label: { Label("Next Chapter", systemImage: "forward") }
            .disabled(appState.readerChapterIndex >= appState.readerChapters.count - 1)

            Button {
                Task { await appState.toggleCurrentPageBookmark() }
            } label: {
                Label(
                    appState.currentPageBookmarked ? "Remove Bookmark" : "Bookmark Page",
                    systemImage: appState.currentPageBookmarked ? "bookmark.fill" : "bookmark"
                )
            }
            .help(appState.currentPageBookmarked ? "Remove bookmark from current page" : "Bookmark current page")

            // Translate current page (⌘T). Icon reflects the pipeline:
            //   .idle      → outline bubble
            //   running    → progress spinner
            //   .done      → filled bubble in accent colour
            translateToolbarButton

            // Chapter-wide auto-translate toggle. When on, ChapterTranslator
            // runs through every page in the background as you read.
            Button {
                appState.translateModeOn.toggle()
                if appState.translateModeOn {
                    startChapterTranslation(chapter: chapter)
                } else {
                    appState.chapterTranslator.stop()
                }
            } label: {
                Label(
                    appState.translateModeOn ? "Auto-Translate On" : "Auto-Translate Off",
                    systemImage: appState.translateModeOn
                        ? "rectangle.and.text.magnifyingglass.rtl"
                        : "rectangle.and.text.magnifyingglass"
                )
                .foregroundStyle(appState.translateModeOn ? Color.appAccent : .primary)
            }
            .help(appState.translateModeOn
                  ? "Stop translating this chapter"
                  : "Translate every page of this chapter in the background")

            Button {
                appState.rtlReading.toggle()
            } label: {
                Label(
                    appState.rtlReading ? "Left-to-Right" : "Right-to-Left",
                    systemImage: "arrow.left.arrow.right"
                )
            }
            .help(appState.rtlReading ? "Switch to left-to-right reading" : "Switch to right-to-left (manga direction)")

            Picker("", selection: $appState.readerMode) {
                ForEach(ReaderMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .tint(Color.appAccent)
            .frame(width: 180)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isQuickSettingsPresented.toggle()
                }
            } label: {
                Label("Quick Settings", systemImage: "gearshape")
                    .foregroundStyle(isQuickSettingsPresented ? Color.appAccent : .primary)
            }
            .help("Quick Settings Panel")
        }
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
            pipelineConfig: appState.readerPrefs.ocrPipelineConfig,
            responseTextScale: CGFloat(appState.readerPrefs.translationResponseScale)
        )
    }

    /// Mark this moment as the last interaction and ensure the controls
    /// are visible. Called from hover, page change, mode change.
    private func wakeControls() {
        lastInteractionAt = .now
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        }
    }

    /// Polls every 0.5 s — if no interaction has happened in the last
    /// `hideAfter` seconds, fade the controls out. Runs for the lifetime
    /// of the reader view.
    private func runIdleTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if controlsVisible,
               Date().timeIntervalSince(lastInteractionAt) > hideAfter {
                withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
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
                        
                        HStack {
                            Toggle("Right-to-Left (Manga)", isOn: $appState.rtlReading)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            Spacer()
                        }
                        
                        if appState.readerMode == .standard || appState.readerMode == .reversed {
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
                                                .foregroundStyle(selected ? Color.white : Color.primary)
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
        .glassCard(cornerRadius: 16)
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

    private var recentCovers: [String] {
        Array(appState.history.sorted { $0.updatedAt > $1.updatedAt }.prefix(12).map { $0.mangaCoverUrl })
    }

    var body: some View {
        ZStack {
            // ── Cinematic cover mosaic background ─────────────────────────
            ZStack {
                Color.appBackground

                if !recentCovers.isEmpty {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ],
                        spacing: 4
                    ) {
                        ForEach(recentCovers, id: \.self) { url in
                            AsyncImage(url: URL(string: url)) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().scaledToFill().frame(height: 180)
                                } else {
                                    Color.primary.opacity(0.04).frame(height: 180)
                                }
                            }
                            .clipped()
                        }
                    }
                    .blur(radius: 28)
                    .opacity(0.22)
                    .clipped()
                }

                // Vignette over mosaic — uses appBackground so it adapts to light/dark
                RadialGradient(
                    colors: [Color.appBackground.opacity(0.0), Color.appBackground.opacity(0.80)],
                    center: .center,
                    startRadius: 80,
                    endRadius: 700
                )
                LinearGradient(
                    stops: [
                        .init(color: Color.appBackground, location: 0.0),
                        .init(color: .clear, location: 0.20),
                        .init(color: .clear, location: 0.80),
                        .init(color: Color.appBackground, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()

            // ── Content ───────────────────────────────────────────────────
            VStack(spacing: 32) {
                hero
                quickActions
                recentSection
            }
            .frame(maxWidth: 700)
            .padding(40)
        }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            ZStack {
                // Outer aura — wide soft bloom behind the circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent.opacity(0.15), Color.appAccent.opacity(0.07), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 200, height: 200)
                    .blur(radius: 30)

                // Outer ambient glow
                RadialGradient(
                    colors: [Color.appAccent.opacity(0.3), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 100
                )
                .blur(radius: 12)
                .frame(width: 160, height: 160)

                // Gradient circle background
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent, Color.appAccent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 116, height: 116)
                    .shadow(color: Color.appAccent.opacity(0.5), radius: 32)

                Image(systemName: "book.pages.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white)
            }

            Text("Ready to Read")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .foregroundStyle(.primary)

            Text("Resume a recent chapter, browse sources, or open local files. The reader sidebar appears once a chapter is loaded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }

    private var quickActions: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if let latest = latestHistory {
                    Button {
                        Task { await appState.openHistoryEntry(latest) }
                    } label: {
                        ReaderActionCard(
                            title: "Continue",
                            subtitle: latest.mangaTitle,
                            systemImage: "play.fill",
                            isPrimary: true
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    appState.pendingNavigation = .explore
                } label: {
                    ReaderActionCard(
                        title: "Browse",
                        subtitle: "Find manga from sources",
                        systemImage: "safari",
                        isPrimary: latestHistory == nil
                    )
                }
                .buttonStyle(.plain)

                Button {
                    appState.pendingNavigation = .favourites
                } label: {
                    ReaderActionCard(
                        title: "Library",
                        subtitle: "\(appState.favourites.count) favourites",
                        systemImage: "heart.text.square",
                        isPrimary: false
                    )
                }
                .buttonStyle(.plain)

                Button {
                    appState.pendingNavigation = .local
                } label: {
                    ReaderActionCard(
                        title: "Local",
                        subtitle: "Open CBZ files",
                        systemImage: "folder",
                        isPrimary: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var recentSection: some View {
        if !recentHistory.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recently Read")
                        .font(.headline)
                    Spacer()
                    Button("View History") {
                        appState.pendingNavigation = .history
                    }
                    .buttonStyle(.link)
                }

                VStack(spacing: 8) {
                    ForEach(recentHistory) { row in
                        ReaderRecentRow(row: row) {
                            Task { await appState.openHistoryEntry(row) }
                        }
                    }
                }
            }
            .padding(16)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.06), Color.primary.opacity(0.02)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

@MainActor
private struct ReaderActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isPrimary: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(isPrimary ? .white : Color.appAccent)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(isPrimary ? .white : .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isPrimary ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 160, height: 112, alignment: .leading)
        .padding(16)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            Group {
                if isPrimary {
                    // AURORA FILL: base accent linear layered with a bright
                    // accent radial spot at .topLeading + dim spot bottomTrailing.
                    ZStack {
                        LinearGradient(
                            stops: [
                                .init(color: Color.appAccent.opacity(0.95), location: 0),
                                .init(color: Color.appAccent.opacity(0.72), location: 0.6),
                                .init(color: Color.appAccent.opacity(0.52), location: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        RadialGradient(
                            stops: [
                                .init(color: Color.appAccent.opacity(0.45), location: 0),
                                .init(color: Color.appAccent.opacity(0.18), location: 0.5),
                                .init(color: .clear, location: 1)
                            ],
                            center: .topLeading, startRadius: 0, endRadius: 170
                        )
                        RadialGradient(
                            stops: [
                                .init(color: Color.appAccent.opacity(0.20), location: 0),
                                .init(color: .clear, location: 1)
                            ],
                            center: .bottomTrailing, startRadius: 0, endRadius: 150
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .frame(height: 35)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                } else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.primary.opacity(0.20), Color.primary.opacity(0.06)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 0.7
                                )
                        )
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isPrimary ? Color.white.opacity(0.20) : Color.clear, lineWidth: isPrimary ? 1 : 0)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

@MainActor
private struct ReaderRecentRow: View {
    let row: HelperHistoryRow
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                // Cover 42x58 cornerRadius 6
                AsyncImage(url: URL(string: row.mangaCoverUrl)) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.tertiary.opacity(0.35))
                            .overlay(Image(systemName: "book.closed").foregroundStyle(.secondary))
                    }
                }
                .frame(width: 42, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 3) {
                    Text(row.mangaTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(row.chapterTitle.isEmpty ? "Chapter" : row.chapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 2)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.appAccent, Color.appAccent.opacity(0.55)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                            .scaleEffect(x: Double(row.percent), anchor: .leading)
                    }
                    .frame(maxWidth: .infinity)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

@MainActor
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selected: SettingsCategory = .appearance
    @State private var syncPassword: String = ""
    @State private var cacheUsageBytes: Int = 0
    @State private var dbSizeBytes: Int = 0

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
            ScrollView {
                detailPage(for: selected)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
            }
            .frame(minWidth: 440)
        }
        .task {
            cacheUsageBytes = URLCache.shared.currentDiskUsage
            dbSizeBytes = (try? FileManager.default.attributesOfItem(atPath: dbPath)[.size] as? Int) ?? 0
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { cat in
                    Button {
                        selected = cat
                    } label: {
                        Label(cat.title, systemImage: cat.systemImage)
                            .tint(selected == cat ? Color.appAccent : nil)
                            .foregroundStyle(selected == cat ? Color.appAccent : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(selected == cat ? Color.appAccent.opacity(0.16) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
        .scrollContentBackground(.hidden)
        .tint(Color.appAccent)
        .background(Color.appBackground)
    }

    @ViewBuilder
    private func detailPage(for cat: SettingsCategory) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(cat.title).font(.title2.bold())
            switch cat {
            case .appearance:    appearanceSection
            case .library:       librarySection
            case .reader:        readerSection
            case .sources:       sourcesSection
            case .translation:   translationSection
            case .network:       networkSection
            case .downloads:     downloadsSection
            case .tracker:       trackerSection
            case .sync:          supabaseSection
            case .backup:        backupSection
            case .notifications: notificationsSection
            case .privacy:       privacySection
            case .advanced:      advancedSection
            case .about:         aboutSection
            }
        }
    }

    // MARK: - Sub-pages

    private var appearanceSection: some View {
        VStack(spacing: 12) {
            settingGroup("Theme") {
                pickerRow("App theme", selection: $appState.readerPrefs.appAppearance) {
                    Text("Follow system").tag("auto"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
            }
            settingGroup("Accent color") {
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

    // MARK: - Accent color picker

    private var accentCustomBinding: Binding<Color> {
        Binding(
            get: { Color(hex: appState.readerPrefs.customAccentHex) ?? .red },
            set: { newColor in
                appState.readerPrefs.customAccentHex = newColor.hexString
                appState.readerPrefs.accentColor = "custom"
            }
        )
    }

    @ViewBuilder
    private var accentColorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Preset swatches
            HStack(spacing: 10) {
                ForEach(ReaderPrefs.accentPresets, id: \.name) { preset in
                    Button {
                        appState.readerPrefs.accentColor = preset.name
                    } label: {
                        Circle()
                            .fill(preset.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2)
                                    .padding(-3)
                                    .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                                    .opacity(appState.readerPrefs.accentColor == preset.name ? 1 : 0)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(preset.name.capitalized)
                }
                Spacer(minLength: 0)
            }

            Text("Tap a colour, pick from your wallpaper, or choose a custom shade.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().opacity(0.12)

            // From wallpaper
            HStack(spacing: 12) {
                Button {
                    if !appState.readerPrefs.pickAccentFromWallpaper() {
                        appState.statusMessage = "Couldn't read a colour from your wallpaper."
                    }
                } label: {
                    Label("Pick from Wallpaper", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)

                if appState.readerPrefs.accentColor == "wallpaper" {
                    Circle()
                        .fill(appState.readerPrefs.effectiveAccentColor)
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white, lineWidth: 2)
                                .padding(-3)
                                .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
                        )
                }
                Spacer(minLength: 0)
            }

            // Custom color
            HStack {
                ColorPicker(selection: accentCustomBinding, supportsOpacity: false) {
                    Text("Custom color")
                }
                if appState.readerPrefs.accentColor == "custom" {
                    Text("In use")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }

    private var librarySection: some View {
        VStack(spacing: 12) {
            settingGroup("History") {
                stepperRow("Retention",
                           value: $appState.readerPrefs.historyRetentionDays,
                           range: 0...365, step: 30,
                           label: appState.readerPrefs.historyRetentionDays == 0
                                ? "Forever" : "\(appState.readerPrefs.historyRetentionDays) days")
                toggleRow("Group by date", description: "Today / Yesterday / Earlier sections.", isOn: $appState.readerPrefs.historyGrouping)
                pickerRow("Sort order", selection: $appState.readerPrefs.historySortOrder) {
                    Text("Last read").tag("last_read")
                    Text("A → Z").tag("alpha")
                    Text("Recently added").tag("added")
                }
            }
            settingGroup("Search") {
                toggleRow("Hide NSFW results", description: "Adult-tagged manga skipped in searches.", isOn: $appState.readerPrefs.nsfwFilter)
            }
            settingGroup("Categories") {
                infoRow("Total", value: "\(appState.categories.count)")
                Text("Create, rename, and delete categories from a manga's details page.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
    }

    private var readerSection: some View {
        VStack(spacing: 12) {
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
                toggleRow("Tap zones", description: "Click left / right thirds of the page to flip.", isOn: $appState.readerPrefs.tapZonesEnabled)
                toggleRow("Tap zones LTR", description: "Left tap goes back regardless of reading direction.", isOn: $appState.readerPrefs.readerTapsLtr)
                toggleRow("Invert page direction", description: "Swap the meaning of left/right.", isOn: $appState.readerPrefs.invertNavigation)
                toggleRow("Auto-hide controls", description: "Page counter fades after 2.5 s of mouse idle.", isOn: $appState.readerPrefs.autoHideControls)
                toggleRow("Show page numbers overlay", description: "Page counter + seekbar at the bottom.", isOn: $appState.readerPrefs.showPageNumbers)
            }
            settingGroup("Performance") {
                toggleRow("Prefetch next chapter", description: "Warm the image cache while reading.", isOn: $appState.readerPrefs.prefetchNextPages)
            }
        }
    }

    private var sourcesSection: some View {
        VStack(spacing: 12) {
            settingGroup("Filters") {
                toggleRow("Hide NSFW sources", description: "Adult-flagged sources are removed from the catalog, sidebar, and global search.", isOn: $appState.hideNsfwSources)
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

    private var translationSection: some View {
        VStack(spacing: 12) {
            settingGroup("Pipeline") {
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
                    ForEach(TranslationSettings.supportedLanguages, id: \.self) { Text($0).tag($0) }
                }
                pickerRow("Target language",
                          selection: bind(\.translateSettings.targetLang)) {
                    ForEach(TranslationSettings.supportedLanguages.filter { $0 != "AUTO" }, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                Text("Vision OCR + Google Translate runs locally and needs no key. Apple Intelligence refines OCR output on-device — no provider configuration required.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.bottom, 10)
            }
            settingGroup("Speed & Quality") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Speed vs Quality", selection: $appState.readerPrefs.translationTier) {
                        Text("Fast").tag(OcrProvider.Tier.fast)
                        Text("Tuned (Recommended)").tag(OcrProvider.Tier.tuned)
                        Text("Balanced").tag(OcrProvider.Tier.balanced)
                        Text("Quality").tag(OcrProvider.Tier.quality)
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.appAccent)
                    .labelsHidden()
                    Text(appState.readerPrefs.translationTier.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                toggleRow("Apple Intelligence polish",
                          description: "After translation, rewrite each line on-device with the Foundation Models LLM for natural phrasing. Adds 1–3 s per page. Works on any pipeline tier.",
                          isOn: $appState.readerPrefs.applePolish)
            }
            settingGroup("Debug HUD") {
                toggleRow("Translation pipeline HUD",
                          description: "Floating chip strip in the reader showing Download → OCR → Translate → Refine timings.",
                          isOn: $appState.debugHUDEnabled)
            }
        }
    }

    private var networkSection: some View {
        VStack(spacing: 12) {
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
                infoRow("User-Agent", value: "Nyora/0.1.0 (macOS)")
            }
        }
    }

    private var downloadsSection: some View {
        VStack(spacing: 12) {
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

    private var trackerSection: some View {
        VStack(spacing: 12) {
            settingGroup("AniList") {
                toggleRow("Scrobble on chapter open", description: "Update progress automatically.", isOn: bind(\.tracker.anilistEnabled))
                secureFieldRow("Personal access token", text: bind(\.tracker.anilistToken), placeholder: "Generate at anilist.co/settings/developer")
                Text("Click New client → Token only. Stored in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            settingGroup("MyAnimeList") {
                infoRow("Status", value: "Coming soon")
            }
            settingGroup("Kitsu") {
                infoRow("Status", value: "Coming soon")
            }
            settingGroup("Shikimori") {
                infoRow("Status", value: "Coming soon")
            }
        }
    }

    private var supabaseSection: some View {
        VStack(spacing: 12) {
            if let status = appState.supabaseStatus {
                settingGroup("Account") {
                    if status.isAuthenticated {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status.userId)
                                .font(.headline)
                            Text("Authenticated via Google")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)

                        rowSeparator

                        buttonRow("Sign out", systemImage: "rectangle.portrait.and.arrow.right", tint: .red) {
                            Task { await appState.supabaseSignOut() }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not signed in")
                                .font(.headline)
                            Text("Sign in to sync your library across devices using Supabase.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(14)

                        rowSeparator

                        buttonRow("Sign in with Google", systemImage: "person.crop.circle.badge.plus") {
                            guard !appState.isSupabaseSigningIn else { return }
                            signInWithGoogle(status: status)
                        }
                        .opacity(appState.isSupabaseSigningIn ? 0.5 : 1.0)
                    }
                }

                if status.isAuthenticated {
                    settingGroup("Sync") {
                        buttonRow("Sync now", systemImage: "arrow.triangle.2.circlepath") {
                            guard !appState.isSupabaseSyncing else { return }
                            Task { await appState.supabaseSync() }
                        }
                        .opacity(appState.isSupabaseSyncing ? 0.5 : 1.0)

                        infoRow("Last synced", value: status.lastSyncTimestamp)
                    }
                }
            } else {
                ProgressView()
                    .padding()
                    .task {
                        await appState.refreshSupabaseStatus()
                    }
            }
        }
    }

    private func signInWithGoogle(status: SupabaseStatusResponse) {
        guard !appState.isSupabaseSigningIn else { return }
        Task {
            appState.isSupabaseSigningIn = true
            appState.statusMessage = "Opening Google sign-in..."
            defer { appState.isSupabaseSigningIn = false }

            switch await SupabaseGoogleAuthHelper.signIn(serverClientID: status.googleServerClientId) {
            case .success(let idToken):
                _ = await appState.supabaseSignIn(idToken: idToken)
            case .cancelled:
                appState.statusMessage = "Google sign-in canceled"
            case .failure(let message):
                appState.statusMessage = "Google sign-in failed: \(message)"
            }
        }
    }

    private var backupSection: some View {
        VStack(spacing: 12) {
            settingGroup("Manual backup") {
                buttonRow("Export library…", systemImage: "square.and.arrow.up") {
                    Task { @MainActor in await exportBackup() }
                }
                buttonRow("Import library…", systemImage: "square.and.arrow.down") {
                    Task { @MainActor in await importBackup() }
                }
                Text("Saves favourites, history, categories, and bookmarks to a single JSON file. Downloaded images are not included.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            settingGroup("Periodic backup") {
                infoRow("Status", value: "Manual only")
                Text("Periodic backups will land in a follow-up release.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
    }

    private var notificationsSection: some View {
        VStack(spacing: 12) {
            settingGroup("Banners") {
                Text("System banners are managed in macOS System Settings → Notifications → Nyora. The toggles here control which events Nyora emits.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 10)
            }
            settingGroup("Events") {
                toggleRow("New chapter notifications", description: "Banner when an updated manga has new chapters.", isOn: $appState.readerPrefs.isTrackerEnabled)
            }
        }
    }

    private var privacySection: some View {
        VStack(spacing: 12) {
            settingGroup("Browsing") {
                toggleRow("Incognito mode", description: "Don't record chapters in history while it's on.", isOn: $appState.readerPrefs.isIncognitoModeEnabled)
                toggleRow("Confirm before quitting", description: "Show a Cmd+Q confirmation prompt.", isOn: $appState.readerPrefs.exitConfirm)
            }
            settingGroup("Lock") {
                toggleRow("Require Touch ID / password on launch", description: "Locks the app until biometric or password authentication.", isOn: $appState.readerPrefs.isBiometricProtectionEnabled)
            }
        }
    }

    private var advancedSection: some View {
        VStack(spacing: 12) {
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
                HStack {
                    Text("State"); Spacer()
                    Text(appState.helperStatus.label).foregroundStyle(appState.helperStatus.color)
                }
                .padding(14)
                infoRow("Endpoint", value: appState.helperBaseUrl.isEmpty ? "—" : appState.helperBaseUrl)
                buttonRow("Restart service", systemImage: "arrow.triangle.2.circlepath") {
                    Task { @MainActor in await appState.restartHelper() }
                }
            }
            settingGroup("Danger zone") {
                buttonRow("Wipe database", systemImage: "trash.fill", tint: .red) {
                    Task { @MainActor in await appState.clearDatabase() }
                }
                Text("Permanently removes every manga, category, favourite, and history row. The 963 source registrations are reseeded on next launch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
    }

    private var aboutSection: some View {
        VStack(spacing: 12) {
            settingGroup("App") {
                infoRow("Version", value: "0.1.0")
                infoRow("Build", value: "Nyora for macOS")
                infoRow("Min macOS", value: "14.0")
            }
            settingGroup("Engine") {
                infoRow("OCR", value: "Apple Vision")
                infoRow("MT",  value: "Google Translate")
                infoRow("Refinement", value: "Apple Intelligence + BYOK LLM")
            }
            settingGroup("Credits") {
                Text("Built on top of the open-source nyora-parsers library for source connectivity. Reader UX inspired by Nyora Android.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(14)
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

    /// A flat settings group: a small uppercase section header above a column
    /// of rows over a SUBTLE vertical linear-gradient background. No bordered
    /// card, no shadow — rows are separated by hairline dividers (each row
    /// helper draws its own trailing separator).
    private func settingGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(0.8)
                .foregroundStyle(Color.appAccent)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.primary.opacity(0.05), Color.primary.opacity(0.015)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
        }
    }

    /// Hairline divider drawn at the bottom of each settings row so adjacent
    /// rows in a group are separated without any hard bordered box.
    private var rowSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    private func toggleRow(_ title: String, description: String, isOn: Binding<Bool>) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(.primary)
                    Text(description).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .tint(Color.appAccent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            rowSeparator
        }
    }

    private func pickerRow<V: Hashable, Content: View>(_ title: String, selection: Binding<V>, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Picker("", selection: selection) { content() }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .tint(.secondary)
            }
            .padding(14)

            rowSeparator
        }
    }

    private func stepperRow(_ title: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            step: Int,
                            label: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(14)

            rowSeparator
        }
    }

    private func textFieldRow(_ title: String,
                              text: Binding<String>,
                              placeholder: String) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body)
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)

            rowSeparator
        }
    }

    private func secureFieldRow(_ title: String,
                                text: Binding<String>,
                                placeholder: String) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.body)
                SecureField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)

            rowSeparator
        }
    }

    private func buttonRow(_ title: String,
                            systemImage: String,
                            tint: Color = .appAccent,
                            action: @escaping () -> Void) -> some View {
        SettingsButtonRow(title: title, systemImage: systemImage, tint: tint, action: action)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer()
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)

            rowSeparator
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

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, label: String) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title)
                    Spacer()
                    Text(label).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: value, in: range, step: step)
                    .tint(Color.appAccent)
            }
            .padding(14)

            rowSeparator
        }
    }
}

@MainActor
private struct SettingsButtonRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(isHovered ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovered ? 0.05 : 0))
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .onHover { isHovered = $0 }
    }
}

enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case appearance, library, reader, sources, translation, network, downloads
    case tracker, sync, backup, notifications, privacy, advanced, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance:    return "Appearance"
        case .library:       return "Library"
        case .reader:        return "Reader"
        case .sources:       return "Sources"
        case .translation:   return "Translation"
        case .network:       return "Network"
        case .downloads:     return "Downloads"
        case .tracker:       return "Tracker"
        case .sync:          return "Cloud sync"
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
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                // 2-spot layered radial: a bright accent center bloom over a
                // dimmer accent ring — single-hue depth instead of a flat wash.
                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Color.appAccent.opacity(0.05), location: 0),
                                .init(color: Color.appAccent.opacity(0.22), location: 0.78),
                                .init(color: Color.appAccent.opacity(0.04), location: 1)
                            ],
                            center: .center, startRadius: 0, endRadius: 40
                        )
                    )
                    .frame(width: 80, height: 80)
                    .overlay {
                        Circle()
                            .fill(
                                RadialGradient(
                                    stops: [
                                        .init(color: Color.appAccent.opacity(0.34), location: 0),
                                        .init(color: Color.appAccent.opacity(0.10), location: 0.5),
                                        .init(color: .clear, location: 1)
                                    ],
                                    center: .topLeading, startRadius: 0, endRadius: 64
                                )
                            )
                            .frame(width: 80, height: 80)
                    }
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appAccent)
            }
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

@MainActor
struct HistoryRowView: View {
    let row: HelperHistoryRow
    let accent: Color
    let secondaryAccent: Color
    @EnvironmentObject var appState: AppState
    @State private var isHovered = false

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

                // Metadata
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.mangaTitle)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(displayChapterTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(displayDate, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(row.sourceName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                Text("\(Int((row.percent * 100).rounded()))%")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [Color.primary.opacity(0.18), Color.primary.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        isHovered
                            ? AnyShapeStyle(LinearGradient(
                                stops: [
                                    .init(color: accent.opacity(0.12), location: 0),
                                    .init(color: accent.opacity(0.05), location: 0.5),
                                    .init(color: Color.clear, location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                              ))
                            : AnyShapeStyle(Color.clear)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
struct SuggestionCard: View {
    let manga: HelperSuggestedManga
    @State private var isHovered = false

    private var accentColor: Color {
        Color.appAccent
    }

    var body: some View {
        // Cover with title overlaid at bottom
        ZStack(alignment: .bottom) {
            AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                if case let .success(image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    CoverPlaceholder(title: manga.title, accent: accentColor)
                }
            }
            .aspectRatio(2/3, contentMode: .fill)
            .frame(maxWidth: .infinity)

            // Bottom vignette + title overlay
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(0.50), location: 0.72),
                    .init(color: .black.opacity(0.85), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Text(manga.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(isHovered ? 0.12 : 0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, y: 5)
        .shadow(color: isHovered ? accentColor.opacity(0.30) : .clear, radius: 16, y: 6)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.38, dampingFraction: 0.65), value: isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
