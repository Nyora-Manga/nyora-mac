import SwiftUI
import AppKit

@MainActor
struct ExploreView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    enum BrowseMode: String, CaseIterable, Identifiable {
        case popular = "Popular"
        case latest = "Latest"
        case search = "Search"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .popular: return "flame"
            case .latest: return "clock"
            case .search: return "magnifyingglass"
            }
        }
    }

    @State private var sourceFilter: String = ""
    @State private var browseMode: BrowseMode = .popular
    @State private var query: String = ""
    @State private var selectedGenreFilter: String? = nil
    @FocusState private var isSearchQueryFocused: Bool

    // Cached derived state — avoids recomputing on every render cycle
    @State private var cachedFilteredBrowseMangas: [MangaSummary] = []
    @State private var cachedUniqueGenres: [String] = []

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let railWidth: CGFloat = min(230, max(190, totalWidth * 0.21))
            let detailsVisible = appState.activeMangaDetails != nil || appState.isDetailLoading
            let panelWidth: CGFloat = min(480, max(320, totalWidth * 0.46))
            HStack(spacing: 0) {
                sourceRail
                    .frame(width: railWidth)
                Divider().opacity(0.5)
                browseArea
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(exploreBackdrop)
            .overlay(alignment: .trailing) {
                if detailsVisible {
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.28)
                            .ignoresSafeArea()
                            .onTapGesture { closeDetails() }
                            .transition(.opacity)
                        detailSlideOver
                            .frame(width: panelWidth)
                            .transition(.move(edge: .trailing))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: detailsVisible)
            .onAppear {
                updateFilteredMangas()
                updateUniqueGenres()
            }
            .onChange(of: appState.browseMangas) { _, _ in
                updateFilteredMangas()
                updateUniqueGenres()
            }
            .onChange(of: selectedGenreFilter) { _, _ in
                updateFilteredMangas()
            }
            .onChange(of: appState.readerPrefs.nsfwFilter) { _, _ in
                updateFilteredMangas()
            }
            .onChange(of: appState.readerPrefs.quickFilter) { _, newValue in
                // Clear the stale genre selection when Quick Filter is turned off so
                // it doesn't silently re-apply the old filter if the user turns it on again.
                if !newValue {
                    selectedGenreFilter = nil
                }
                updateFilteredMangas()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                updateFilteredMangas()
            }
            .navigationTitle(activeSource?.name ?? "Explore")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        Task { await appState.openCatalog() }
                    } label: {
                        Label("Add Sources", systemImage: "plus.circle")
                    }

                    Button {
                        Task { await appState.reloadCatalog() }
                    } label: {
                        Label("Refresh Catalog", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var exploreBackdrop: some View {
        Color(.windowBackgroundColor).ignoresSafeArea()
    }

    private func closeDetails() {
        appState.activeMangaDetails = nil
        appState.selectedBrowseMangaId = nil
        appState.detailsIsFavourited = false
        appState.isDetailLoading = false
    }

    // MARK: - Sidebar

    private var filteredSources: [SourceSummary] {
        let base = appState.visibleSources
        let q = sourceFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return base }
        return base.filter {
            $0.name.lowercased().contains(q) || $0.lang.lowercased().contains(q)
        }
    }

    private var pinnedSources: [SourceSummary] {
        filteredSources.filter { $0.isPinned }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var installedSources: [SourceSummary] {
        filteredSources.filter { $0.isInstalled && !$0.isPinned }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var availableSources: [SourceSummary] {
        filteredSources.filter { !$0.isInstalled && !$0.isPinned }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // uniqueGenres and filteredBrowseMangas are cached in @State and updated via onChange.
    // Use the cached values everywhere instead of recomputing on each render.
    private var uniqueGenres: [String] { cachedUniqueGenres }
    private var filteredBrowseMangas: [MangaSummary] { cachedFilteredBrowseMangas }

    private func updateUniqueGenres() {
        let allTags = appState.browseMangas.flatMap { $0.tags }
        var counts: [String: Int] = [:]
        for tag in allTags {
            let normalized = tag.capitalized
            counts[normalized, default: 0] += 1
        }
        cachedUniqueGenres = counts.keys.sorted()
    }

    private func updateFilteredMangas() {
        var base = appState.browseMangas

        if appState.readerPrefs.nsfwFilter {
            base = base.filter { manga in
                let lowerTags = manga.tags.map { $0.lowercased() }
                return !lowerTags.contains { tag in
                    tag.contains("nsfw") || tag.contains("18+") || tag.contains("adult") || tag.contains("hentai") || tag.contains("erotica") || tag.contains("mature") || tag.contains("ecchi")
                }
            }
        }

        if appState.readerPrefs.quickFilter, let genre = selectedGenreFilter {
            base = base.filter { manga in
                manga.tags.map { $0.capitalized }.contains(genre)
            }
        }

        cachedFilteredBrowseMangas = base
    }

    private var featuredManga: MangaSummary? {
        filteredBrowseMangas.first ?? appState.browseMangas.first
    }

    private var installedSourceCount: Int {
        appState.visibleSources.filter(\.isInstalled).count
    }

    private var discoverableSourceCount: Int {
        availableSources.count
    }

    private var sourceRail: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Sources")
                    .font(.title3.weight(.bold))
                Spacer()
                Text("\(installedSourceCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            SourceFilterSearchField(text: $sourceFilter, placeholder: "Filter sources")
                .frame(height: 28)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if appState.isLoading || appState.isBrowseLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(appState.isBrowseLoading ? "Loading results" : "Refreshing")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            Divider().opacity(0.4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    customSourceSections
                }
                .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.025))
    }

    // MARK: - Browse pane

    private var activeSource: SourceSummary? {
        guard let sid = appState.selectedSourceId else { return nil }
        return appState.sources.first(where: { $0.id == sid })
    }

    private var browseArea: some View {
        VStack(spacing: 0) {
            if let s = activeSource, s.isInstalled {
                browseHeader
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)
                Divider().opacity(0.4)
            }
            browseContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var browseContent: some View {
        if let source = activeSource, !source.isInstalled {
            ContentUnavailableView {
                Label("\(source.name) not installed", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Install this source to browse its catalogue.")
            } actions: {
                Button("Install \(source.name)") {
                    Task { await appState.install(source) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.appAccent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if activeSource == nil {
            ContentUnavailableView(
                "Pick a source",
                systemImage: "sidebar.left",
                description: Text("Choose a source from the rail to browse its catalogue.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.isBrowseLoading && appState.browseMangas.isEmpty {
            VStack {
                ProgressView()
                Text("Loading…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.browseMangas.isEmpty {
            ContentUnavailableView(
                browseMode == .search ? "No matches" : "Nothing to show",
                systemImage: browseMode.systemImage,
                description: Text(browseMode == .search
                    ? "Try different search terms."
                    : "This source returned an empty result.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if appState.readerPrefs.quickFilter {
                        quickFilterChips
                    }
                    if filteredBrowseMangas.isEmpty {
                        ContentUnavailableView(
                            "No matches",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("Try clearing the active filter or the NSFW filter in Settings.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        browseGrid
                    }
                }
                .padding(20)
            }
        }
    }

    private var quickFilterChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Categories")
                .font(.caption2.weight(.bold))
                .textCase(.uppercase)
                .kerning(1.2)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                            selectedGenreFilter = nil
                        }
                    } label: {
                        Text("All")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(
                                selectedGenreFilter == nil
                                    ? AnyShapeStyle(LinearGradient(
                                        colors: [Color.appAccent.opacity(0.97), Color.appAccent.opacity(0.65)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                      ))
                                    : AnyShapeStyle(LinearGradient(
                                        colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                      )),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        selectedGenreFilter == nil
                                            ? Color.clear
                                            : Color.primary.opacity(0.10),
                                        lineWidth: 0.6
                                    )
                            )
                            .overlay(alignment: .top) {
                                if selectedGenreFilter == nil {
                                    // RadialGradient highlight spot for selected depth
                                    RadialGradient(
                                        colors: [Color.white.opacity(0.32), Color.clear],
                                        center: .top,
                                        startRadius: 0,
                                        endRadius: 30
                                    )
                                    .clipShape(Capsule())
                                    .allowsHitTesting(false)
                                }
                            }
                            .foregroundStyle(selectedGenreFilter == nil ? .white : .primary)
                            .shadow(
                                color: selectedGenreFilter == nil ? Color.appAccent.opacity(0.40) : .clear,
                                radius: 8
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: selectedGenreFilter)

                    ForEach(uniqueGenres, id: \.self) { genre in
                        let isActive = selectedGenreFilter == genre
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                                selectedGenreFilter = isActive ? nil : genre
                            }
                        } label: {
                            Text(genre)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    isActive
                                        ? AnyShapeStyle(LinearGradient(
                                            colors: [Color.appAccent.opacity(0.97), Color.appAccent.opacity(0.65)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                          ))
                                        : AnyShapeStyle(LinearGradient(
                                            colors: [Color.primary.opacity(0.08), Color.primary.opacity(0.04)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                          )),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule()
                                        .strokeBorder(
                                            isActive
                                                ? Color.clear
                                                : Color.primary.opacity(0.10),
                                            lineWidth: 0.6
                                        )
                                )
                                .overlay(alignment: .top) {
                                    if isActive {
                                        // RadialGradient highlight spot for selected depth
                                        RadialGradient(
                                            colors: [Color.white.opacity(0.32), Color.clear],
                                            center: .top,
                                            startRadius: 0,
                                            endRadius: 30
                                        )
                                        .clipShape(Capsule())
                                        .allowsHitTesting(false)
                                    }
                                }
                                .foregroundStyle(isActive ? .white : .primary)
                                .shadow(
                                    color: isActive ? Color.appAccent.opacity(0.40) : .clear,
                                    radius: 8
                                )
                        }
                        .buttonStyle(.plain)
                        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: selectedGenreFilter)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private var browseGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(filteredBrowseMangas.count) titles")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: CGFloat(appState.readerPrefs.gridSize), maximum: CGFloat(appState.readerPrefs.gridSize) * 1.35), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(filteredBrowseMangas) { manga in
                    MangaCoverCard(
                        manga: manga,
                        isSelected: appState.selectedBrowseMangaId == manga.id
                    ) {
                        Task { await appState.openDetails(manga) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var browseHeader: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeSource?.name ?? "Explore")
                        .font(.title2.weight(.bold))
                    Text(activeSource.map { "\($0.engine) · \($0.lang.uppercased())" } ?? "Pick a source")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Mode", selection: $browseMode) {
                    ForEach(BrowseMode.allCases) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .tint(Color.appAccent)
                .onChange(of: browseMode) { _, newMode in
                    selectedGenreFilter = nil
                    updateFilteredMangas()
                    guard let sid = appState.selectedSourceId else { return }
                    if newMode != .search {
                        Task { await loadCurrentMode(sid: sid) }
                    }
                }
            }

            if browseMode == .search {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    TextField("Search this source", text: $query)
                        .textFieldStyle(.plain)
                        .focused($isSearchQueryFocused)
                        .onSubmit {
                            Task { await appState.searchActiveSource(query: query) }
                        }
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                }
                .onTapGesture {
                    isSearchQueryFocused = true
                }
            }
        }
    }

    private func loadCurrentMode(sid: String) async {
        switch browseMode {
        case .popular: await appState.loadPopular(sourceId: sid)
        case .latest:  await appState.loadLatest(sourceId: sid)
        case .search:  break  // search is user-triggered
        }
    }

    // wallpaperPalette replaced by AppState.activeCoverAccentPrimary/Secondary

    // MARK: - Detail pane

    private var detailSlideOver: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(appState.activeMangaDetails?.manga.title ?? "Details")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button { closeDetails() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let details = appState.activeMangaDetails {
                MangaDetailView(details: details) { chapter in
                    Task { await appState.openChapter(chapter) }
                }
            } else if appState.isDetailLoading {
                VStack {
                    ProgressView()
                    Text("Loading details…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: .black.opacity(0.25), radius: 18, x: -6)
    }

    @ViewBuilder
    private var customSourceSections: some View {
        if !pinnedSources.isEmpty {
            customSectionHeader("Pinned")
            ForEach(pinnedSources) { source in
                customSourceRow(source)
            }
        }
        if !installedSources.isEmpty {
            customSectionHeader("Installed")
            ForEach(installedSources) { source in
                customSourceRow(source)
            }
        }
        if !availableSources.isEmpty {
            customSectionHeader("Available")
            ForEach(availableSources) { source in
                customSourceRow(source)
            }
        }
        if filteredSources.isEmpty {
            EmptyStateView(
                icon: "puzzlepiece.extension",
                title: appState.sources.isEmpty ? "No sources yet" : "No matches",
                message: appState.sources.isEmpty
                    ? "Use Refresh Catalog to pull from configured repositories."
                    : "Try a different filter or clear the NSFW toggle in Settings."
            )
            .padding(.top, 40)
        }
    }

    private func customSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            .tracking(1.0)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 6)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func customSourceRow(_ source: SourceSummary) -> some View {
        let isSelected = appState.selectedSourceId == source.id
        Button {
            selectedGenreFilter = nil
            appState.selectedSourceId = source.id
            appState.selectedBrowseMangaId = nil
            appState.activeMangaDetails = nil
            appState.detailsIsFavourited = false
            appState.browseMangas = []
            appState.isBrowseLoading = false
            appState.isDetailLoading = false
            if source.isInstalled {
                Task { await loadCurrentMode(sid: source.id) }
            }
        } label: {
            SourceListRow(source: source, isSelected: isSelected)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.appAccent.opacity(0.16) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { sourceRowMenu(source) }
    }

    @ViewBuilder
    private func sourceRowMenu(_ source: SourceSummary) -> some View {
        if source.isInstalled {
            Button("Uninstall", role: .destructive) {
                Task { await appState.uninstall(source) }
            }
        } else {
            Button("Install") {
                Task { await appState.install(source) }
            }
        }
    }
}

// MARK: - Native source filter

@MainActor
private struct SourceFilterSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        // Do not push SwiftUI's value back into AppKit while the field editor
        // is active. During live typing, SwiftUI can re-render from unrelated
        // state changes before the binding catches up, which resets each key.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }

        func searchFieldDidStartSearching(_ sender: NSSearchField) {
            text = sender.stringValue
        }

        func searchFieldDidEndSearching(_ sender: NSSearchField) {
            text = sender.stringValue
        }
    }
}

// MARK: - Sidebar row

@MainActor
private struct SourceListRow: View {
    let source: SourceSummary
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 9) {
            Text(source.lang.uppercased().prefix(2))
                .font(.caption2.weight(.bold))
                .foregroundStyle(isSelected ? Color.appAccent : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected ? Color.appAccent.opacity(0.20) : Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(source.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    if source.isNsfw {
                        Text("18+")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.9)))
                            .accessibilityLabel("Adult content, 18 plus")
                    }
                }
                Text("\(source.engine) · \(source.lang.uppercased())\(source.isNsfw ? " · NSFW" : "")")
                    .font(.caption2)
                    .foregroundStyle(source.isNsfw ? Color.red.opacity(0.85) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: source.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(source.isInstalled ? Color.green.opacity(0.85) : Color.secondary)
                .imageScale(.small)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Cover card

@MainActor
private struct MangaCoverCard: View {
    let manga: MangaSummary
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    private var accentColor: Color { manga.accent }

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    coverImage
                        .aspectRatio(2.0/3.0, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    isSelected ? Color.appAccent : Color.primary.opacity(0.12),
                                    lineWidth: isSelected ? 2 : 0.75
                                )
                        )

                    if manga.unread > 0 {
                        Text("\(manga.unread)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.appAccent))
                            .padding(6)
                    }

                    if manga.progress > 0 {
                        ProgressView(value: Double(min(manga.progress, 1.0)))
                            .progressViewStyle(.linear)
                            .tint(Color.appAccent)
                            .scaleEffect(y: 0.5)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: isHovered ? 10 : 5, y: isHovered ? 5 : 3)

                Text(manga.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var coverImage: some View {
        if let url = URL(string: manga.coverUrl), !manga.coverUrl.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    shimmerPlaceholder
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    placeholder
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    // Loading shimmer placeholder
    private var shimmerPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.primary.opacity(0.06))
            .shimmer()
    }

    private var placeholder: some View {
        CoverPlaceholder(title: manga.title, accent: manga.accent)
    }
}

/// Cover-card border: a conic accent sweep while hovered (modern rotating-light
/// edge), falling back to the resting straight gradient stroke otherwise.
@MainActor
private struct MangaCoverBorder: ViewModifier {
    let isHovered: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isHovered {
            content.conicBorder(cornerRadius: 16, accent: accent)
        } else {
            content.overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.7
                    )
            )
        }
    }
}

// MARK: - Hero card

@MainActor
private struct ExploreHeroCard: View {
    let manga: MangaSummary
    let sourceName: String
    let mode: ExploreView.BrowseMode
    let onOpen: () -> Void

    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background: AsyncImage scaledToFill, fallback to accent gradient
            heroArtwork
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // 6-stop cinematic vignette overlay
            LinearGradient(
                stops: [
                    .init(color: .clear,                   location: 0.00),
                    .init(color: .clear,                   location: 0.20),
                    .init(color: .black.opacity(0.04),     location: 0.38),
                    .init(color: .black.opacity(0.45),     location: 0.62),
                    .init(color: .black.opacity(0.82),     location: 0.84),
                    .init(color: .black.opacity(0.96),     location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)

            // Top-right metric boxes
            VStack(alignment: .trailing, spacing: 8) {
                heroMetricBox(value: "\(manga.unread)", label: "Unread")
                heroMetricBox(value: "\(manga.tags.count)", label: "Tags")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(14)

            // Bottom-left content
            VStack(alignment: .leading, spacing: 10) {
                // Mode badge
                Text(mode.rawValue.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        LinearGradient(
                            colors: [Color.appAccent.opacity(0.90), Color.appAccent.opacity(0.55)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )

                // Title
                Text(manga.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                // Genre tags — first 3
                let genreTags = Array(manga.tags.prefix(3))
                if !genreTags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(genreTags.enumerated()), id: \.offset) { _, tag in
                            Text(tag.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.75))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                    }
                }

                // CTA row: Read Now button + source name
                HStack(alignment: .center, spacing: 12) {
                    Button("Read Now") {
                        onOpen()
                    }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.appAccent)
                        .font(.subheadline.bold())
                        .overlay(
                            ZStack {
                                LinearGradient(
                                    colors: [Color.white.opacity(0.15), Color.clear],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .allowsHitTesting(false)
                        )

                    Text(sourceName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        // Top-left shimmer inner highlight
        .overlay(
            LinearGradient(
                colors: [Color.white.opacity(0.08), Color.clear],
                startPoint: .topLeading,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .allowsHitTesting(false)
        )
        // Card border: conic accent sweep (modern rotating-light edge)
        .conicBorder(cornerRadius: 26, accent: Color.appAccent)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 7)
        .shadow(color: Color.appAccent.opacity(0.10), radius: 30, y: 5)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func heroMetricBox(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.headline.bold())
                .foregroundStyle(.white)
            Text(label)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.12), Color.white.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var heroArtwork: some View {
        if let url = URL(string: manga.coverUrl), !manga.coverUrl.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    heroFallback
                }
            }
        } else {
            heroFallback
        }
    }

    private var heroFallback: some View {
        AuroraFill(accent: manga.accent, cornerRadius: 26)
    }
}

// MARK: - Tag colour palette (keyed by tag.key hash)

private extension Color {
    static let tagPalette: [Color] = [
        Color(red: 0.82, green: 0.22, blue: 0.42),   // rose
        Color(red: 0.24, green: 0.50, blue: 0.95),   // indigo
        Color(red: 0.18, green: 0.72, blue: 0.56),   // teal
        Color(red: 0.88, green: 0.52, blue: 0.12),   // amber
        Color(red: 0.58, green: 0.24, blue: 0.90),   // violet
        Color(red: 0.18, green: 0.64, blue: 0.30),   // green
        Color(red: 0.92, green: 0.32, blue: 0.22),   // coral
        Color(red: 0.22, green: 0.72, blue: 0.88),   // cyan
    ]

    static func tagColor(for key: String) -> Color {
        let idx = abs(key.hashValue) % tagPalette.count
        return tagPalette[idx]
    }
}

// MARK: - Chapter row (extracted for hover state)

@MainActor
private struct ChapterRow: View {
    let chapter: HelperChapter
    let onTap: () -> Void

    @State private var isHovered = false

    private var uploadDateString: String {
        guard chapter.uploadDate > 0 else { return "" }
        // Some parsers store uploadDate in milliseconds, others in seconds.
        // Values > 1e12 are clearly milliseconds (year ~2001+); smaller values
        // are already in seconds and must not be divided by 1000 (which would
        // produce a date in 1970 and yield "over 50 years ago").
        let seconds: TimeInterval = chapter.uploadDate > 1_000_000_000_000
            ? TimeInterval(chapter.uploadDate) / 1000.0
            : TimeInterval(chapter.uploadDate)
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var chapterNumberText: String {
        let n = chapter.number
        return n.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", n)
            : String(format: "%.1f", n)
    }

    var body: some View {
        Button { onTap() } label: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Chapter number badge
                    Text(chapterNumberText)
                        .font(.caption.bold())
                        .foregroundStyle(Color.appAccent)
                        .frame(width: 36, height: 24)
                        .background(
                            LinearGradient(
                                colors: [Color.appAccent.opacity(0.18), Color.appAccent.opacity(0.07)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )

                    // Middle: title + upload date
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !uploadDateString.isEmpty {
                            Text(uploadDateString)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    // Right: chevron, accentColor on hover
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isHovered ? Color.appAccent : Color.secondary.opacity(0.45))
                        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
                .contentShape(Rectangle())

                // Subtle divider below each row
                Divider().opacity(0.10)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - MangaDetailView

@MainActor
private struct MangaDetailView: View {
    let details: HelperDetailsResponse
    let onChapter: (HelperChapter) -> Void
    @EnvironmentObject var appState: AppState

    @State private var isExpanded: Bool = false
    @State private var showAllTags: Bool = false
    @State private var selectedTab: Int = 0
    @State private var selectedChapterForPages: HelperChapter? = nil
    @State private var isLibraryHovered: Bool = false
    @State private var libraryRingScale: CGFloat = 1.0
    @State private var showDownloadSheet: Bool = false

    /// The source's web page. Prefers `publicUrl`, falls back to `url`. Only a
    /// valid absolute (http/https) URL is returned so the button stays hidden
    /// when the DTO only carries a relative path.
    private var webURL: URL? {
        for candidate in [details.manga.publicUrl, details.manga.url] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { continue }
            return url
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                hero
                if !details.manga.tags.isEmpty {
                    tagsRow
                }
                if !details.manga.description.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.manga.description)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(appState.readerPrefs.descriptionCollapse && !isExpanded ? 3 : nil)
                            .fixedSize(horizontal: false, vertical: true)

                        if appState.readerPrefs.descriptionCollapse {
                            Button {
                                withAnimation {
                                    isExpanded.toggle()
                                }
                            } label: {
                                Text(isExpanded ? "Read less" : "Read more...")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(Color.appAccent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider().padding(.vertical, 4)

                if appState.readerPrefs.pagesTab {
                    Picker("Details Tab", selection: $selectedTab) {
                        Text("Chapters").tag(0)
                        Text("Pages").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .tint(Color.appAccent)
                    .padding(.vertical, 4)
                }

                if !appState.readerPrefs.pagesTab || selectedTab == 0 {
                    chaptersHeader
                    chaptersList
                } else {
                    pagesView
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            // Cover — prominent thumbnail
            cover
                .frame(minWidth: 104, idealWidth: 130, maxWidth: 160)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.35), radius: 14, y: 7)
                .shadow(color: Color.appAccent.opacity(0.25), radius: 12)
                .shadow(color: Color.appAccent.opacity(0.30), radius: 18)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(details.manga.title)
                        .font(.title3.bold())
                        .lineLimit(4)

                    // Open the source's web page inside the app (not Safari).
                    if let webURL {
                        Button {
                            appState.openInApp(webURL)
                        } label: {
                            Image(systemName: "globe")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.appAccent)
                        }
                        .buttonStyle(.plain)
                        .help("Open website")
                    }
                }

                if !details.manga.authors.isEmpty {
                    Label(details.manga.authors.joined(separator: ", "), systemImage: "person")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !details.manga.altTitles.isEmpty {
                    Text(details.manga.altTitles.prefix(2).joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                HStack(spacing: 7) {
                    // Rating badge — star with yellow glow
                    let rating = details.manga.rating
                    if rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.yellow)
                                .shadow(color: .yellow.opacity(0.75), radius: 4)
                            Text(String(format: "%.1f", rating))
                                .font(.caption.bold())
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            LinearGradient(
                                colors: [Color.yellow.opacity(0.20), Color.yellow.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.yellow.opacity(0.25), lineWidth: 0.5)
                        )
                    }

                    // Chapters count — accent badge (matches chaptersHeader)
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text.fill")
                            .font(.caption2)
                        Text("\(details.chapters.count) Chs")
                            .font(.caption.bold().monospacedDigit())
                    }
                    .foregroundStyle(Color.appAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        LinearGradient(
                            colors: [Color.appAccent.opacity(0.22), Color.appAccent.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )

                    // NSFW badge
                    if details.manga.isNsfw {
                        Text("18+")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.red.opacity(0.28), lineWidth: 0.5)
                            )
                    }
                }
                .padding(.top, 2)

                Spacer(minLength: 4)

                // Add-to-library button with gradient + spring scale hover
                Button {
                    Task { await appState.toggleDetailsFavourite() }
                } label: {
                    Label(
                        appState.detailsIsFavourited ? "In Library" : "Add to Library",
                        systemImage: appState.detailsIsFavourited ? "heart.fill" : "heart"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.detailsIsFavourited ? Color.pink : Color.appAccent)
                .shadow(
                    color: appState.detailsIsFavourited
                        ? Color.pink.opacity(0.45)
                        : Color.appAccent.opacity(isLibraryHovered ? 0.45 : 0.18),
                    radius: 8, y: 3
                )
                .scaleEffect(isLibraryHovered ? 1.04 : 1.0)
                .animation(.animeSpring, value: isLibraryHovered)
                .animation(.animeSpring, value: appState.detailsIsFavourited)
                .onHover { isLibraryHovered = $0 }
                .overlay {
                    if appState.detailsIsFavourited {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.pink.opacity(0.55), lineWidth: 2)
                            .scaleEffect(libraryRingScale)
                            .opacity(libraryRingScale > 1.0 ? (2.05 - libraryRingScale) : 0)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if appState.detailsIsFavourited {
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .allowsHitTesting(false)
                    }
                }
                .onChange(of: appState.detailsIsFavourited) { _, newValue in
                    guard newValue else { return }
                    libraryRingScale = 1.0
                    withAnimation(.easeOut(duration: 0.45)) {
                        libraryRingScale = 1.55
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .background {
            AsyncImage(url: URL(string: details.manga.coverUrl)) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                        .blur(radius: 40).opacity(0.15).clipped()
                }
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        // HelperDetailsResponse's manga has a coverUrl too — use it if non-empty.
        if let url = URL(string: details.manga.coverUrl), !details.manga.coverUrl.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    CoverPlaceholder(title: details.manga.title, accent: .appAccent)
                }
            }
        } else {
            CoverPlaceholder(title: details.manga.title, accent: .appAccent)
        }
    }

    @ViewBuilder
    private var tagsRow: some View {
        let allTags = details.manga.tags
        let tagLimit = 20
        let isTruncated = !showAllTags && allTags.count > tagLimit
        let visibleTags = showAllTags ? allTags : Array(allTags.prefix(tagLimit))
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleTags, id: \.key) { tag in
                    Text(tag.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            LinearGradient(
                                colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.05)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                        )
                }

                if isTruncated {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            showAllTags = true
                        }
                    } label: {
                        Text("Show all")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.appAccent.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else if showAllTags && allTags.count > tagLimit {
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            showAllTags = false
                        }
                    } label: {
                        Text("Show less")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.appAccent)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.appAccent.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var chaptersHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("CHAPTERS")
                .font(.caption.weight(.heavy))
                .kerning(1.2)
                .foregroundStyle(.secondary)

            Spacer()

            if !details.chapters.isEmpty {
                Button {
                    showDownloadSheet = true
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Color.appAccent.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .help("Download chapters — pick a range or select individually")
            }

            Text("\(details.chapters.count)")
                .font(.caption.bold().monospacedDigit())
                .foregroundStyle(Color.appAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.appAccent.opacity(0.12), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.appAccent.opacity(0.25), lineWidth: 0.5))
        }
        .padding(.bottom, 2)
        .sheet(isPresented: $showDownloadSheet) {
            DownloadChaptersSheet(details: details, sourceId: appState.selectedSourceId ?? "")
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var chaptersList: some View {
        LazyVStack(spacing: 0) {
            ForEach(details.chapters) { chapter in
                ChapterRow(chapter: chapter) { onChapter(chapter) }
            }
        }
    }

    @ViewBuilder
    private var pagesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header row
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("PAGE THUMBNAILS")
                    .font(.caption.weight(.heavy))
                    .kerning(1.2)
                    .foregroundStyle(.secondary)

                Spacer()

                let chaptersForPages = details.chapters
                if !chaptersForPages.isEmpty {
                    Picker("", selection: Binding(
                        get: { selectedChapterForPages ?? chaptersForPages.first! },
                        set: { selectedChapterForPages = $0 }
                    )) {
                        ForEach(chaptersForPages) { ch in
                            Text(ch.title).tag(ch)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 200)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    )
                }
            }
            .padding(.bottom, 2)

            if let activeChapter = selectedChapterForPages ?? details.chapters.first {
                if activeChapter.pages.isEmpty {
                    Text("No pages in this chapter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 84), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(Array(activeChapter.pages.enumerated()), id: \.offset) { index, page in
                            Button { onChapter(activeChapter) } label: {
                                VStack(spacing: 5) {
                                    AsyncImage(url: URL(string: page.url)) { phase in
                                        if case .success(let image) = phase {
                                            image.resizable().scaledToFill()
                                        } else {
                                            Rectangle()
                                                .fill(Color.primary.opacity(0.05))
                                                .overlay(
                                                    Image(systemName: "photo")
                                                        .foregroundStyle(.tertiary)
                                                )
                                                .shimmer()
                                        }
                                    }
                                    .frame(height: 114)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                                    )
                                    .overlay(alignment: .bottom) {
                                        LinearGradient(
                                            colors: [Color.clear, Color.black.opacity(0.55)],
                                            startPoint: .center,
                                            endPoint: .bottom
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .shadow(color: .black.opacity(0.30), radius: 8, y: 4)

                                    Text("\(index + 1)")
                                        .font(.caption2.monospacedDigit().weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .animeEntrance(delay: Double(index) * 0.04)
                        }
                    }
                }
            } else {
                Text("No chapters available.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
    }
}

// MARK: - Download chapters picker (range / multi-select)

@MainActor
private struct DownloadChaptersSheet: View {
    let details: HelperDetailsResponse
    let sourceId: String
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selected: Set<String> = []
    @State private var fromIdx: Int = 0
    @State private var toIdx: Int = 0
    @State private var submitting = false

    private var chapters: [HelperChapter] { details.chapters }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Download Chapters").font(.headline)
                    Text(details.manga.title)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.large).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            Divider()

            if chapters.isEmpty {
                Spacer()
                Text("No chapters available").foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Range").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("", selection: $fromIdx) {
                            ForEach(chapters.indices, id: \.self) { Text(chapters[$0].title).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Picker("", selection: $toIdx) {
                            ForEach(chapters.indices, id: \.self) { Text(chapters[$0].title).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Button("Select") { selectRange() }.buttonStyle(.bordered)
                    }
                    HStack(spacing: 8) {
                        chip("All") { selected = Set(chapters.map(\.id)) }
                        chip("None") { selected.removeAll() }
                        chip("Invert") { selected = Set(chapters.map(\.id)).subtracting(selected) }
                        Spacer()
                        Text("\(selected.count) selected")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chapters) { ch in
                            Button { toggle(ch.id) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selected.contains(ch.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(ch.id) ? Color.appAccent : .secondary)
                                    Text(ch.title).font(.subheadline).lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().opacity(0.25).padding(.leading, 42)
                        }
                    }
                }

                Divider()
                HStack {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button {
                        Task { await submit() }
                    } label: {
                        if submitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Download \(selected.count) chapter\(selected.count == 1 ? "" : "s")")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || submitting || sourceId.isEmpty)
                }
                .padding(16)
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 460, idealHeight: 560)
        .onAppear {
            fromIdx = 0
            toIdx = max(0, chapters.count - 1)
        }
    }

    private func chip(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Color.primary.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func selectRange() {
        guard !chapters.isEmpty else { return }
        let lo = min(fromIdx, toIdx), hi = max(fromIdx, toIdx)
        selected = Set(chapters[lo...hi].map(\.id))
    }

    private func submit() async {
        submitting = true
        let chosen = chapters.filter { selected.contains($0.id) }
        await appState.downloadChapters(sourceId: sourceId, manga: details.manga, chapters: chosen)
        submitting = false
        dismiss()
    }
}

@MainActor
private struct InstallButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Button("Get") {
                action()
            }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(Color.appAccent)

            LinearGradient(
                colors: [Color.appAccent.opacity(0.15), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .clipShape(Capsule())
            .allowsHitTesting(false)
        }
        .fixedSize()
        .scaleEffect(isHovered ? 1.06 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.70), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

@MainActor
private struct ShimmerRow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .shimmer()
            .frame(height: 64)
    }
}
