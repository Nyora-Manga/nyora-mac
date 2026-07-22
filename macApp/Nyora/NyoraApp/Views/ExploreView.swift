import SwiftUI
import AppKit

@MainActor
struct ExploreView: View {
    @EnvironmentObject var appState: AppState

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
    // Source-grid landing (nyora-web wireframe): search-all-sources text + language filter.
    @State private var sourceSearch: String = ""
    @State private var languageFilter: String? = nil

    // Cached derived state — avoids recomputing on every render cycle
    @State private var cachedFilteredBrowseMangas: [MangaSummary] = []
    @State private var cachedUniqueGenres: [String] = []

    var body: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let detailsVisible = appState.activeMangaDetails != nil || appState.isDetailLoading
            // A proper full overview page (thin dismiss margin on the left), not a
            // cramped 480px slide-over. The detail view itself lays out as two
            // columns (cover/info + chapters) when it has the room.
            let panelWidth: CGFloat = min(totalWidth - 28, max(760, totalWidth))
            // Two states, nyora-web style: with no source chosen we show the "Manga sources"
            // grid (language-divided, searchable); once a source is picked we show its browse
            // area. The old always-on 468-source rail is gone.
            Group {
                if appState.selectedSourceId == nil {
                    SourcesGridLanding(
                        search: $sourceSearch,
                        languageFilter: $languageFilter,
                        onOpen: { selectSource($0.id) }
                    )
                } else {
                    browseArea
                }
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // The source's engine/language line lives in the real toolbar subtitle
            // now, instead of a hand-drawn header that duplicated the pane title.
            .navigationSubtitle(
                activeSource.map { "\($0.engine) · \($0.lang.uppercased())" } ?? ""
            )
            .toolbar {
                // When browsing a source, a "Sources" back button returns to the grid landing,
                // and the quick-switch popover lets you jump to another source without going back.
                // On the grid itself there's nothing here — the grid IS the source picker.
                if appState.selectedSourceId != nil {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            deselectSource()
                        } label: {
                            Label("Sources", systemImage: "chevron.left")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Back to all sources")
                    }
                    ToolbarItem(placement: .navigation) {
                        SourcePickerButton()
                    }
                }
                // Finder puts its view-mode segmented control in the toolbar; so do we.
                if let s = activeSource, s.isInstalled {
                    ToolbarItem {
                        Picker("Mode", selection: $browseMode) {
                            ForEach(BrowseMode.allCases) { mode in
                                Label(mode.rawValue, systemImage: mode.systemImage).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .help("Browse mode")
                    }
                }

                ToolbarItemGroup {
                    // Manual Cloudflare solve for the selected source — opens the WebView
                    // verification window on demand, for when a source is CF-blocked but the
                    // error doesn't auto-trigger the solver (e.g. "Authorization required").
                    if let s = activeSource, s.isInstalled {
                        Button {
                            Task { await appState.solveCloudflare(for: s.id) }
                        } label: {
                            Label("Solve Cloudflare", systemImage: "checkmark.shield")
                        }
                        .disabled(appState.isSolvingCloudflare)
                        .help("Open the Cloudflare verification for \(s.name)")
                    }

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
            .onChange(of: appState.selectedSourceId) { _, _ in
                // Reset to Popular when switching sources so the grid always shows content.
                browseMode = .popular
            }
            .onChange(of: browseMode) { _, newMode in
                selectedGenreFilter = nil
                updateFilteredMangas()
                guard let sid = appState.selectedSourceId else { return }
                if newMode != .search {
                    Task { await loadCurrentMode(sid: sid) }
                }
            }
        }
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
                    .font(.headline)
                Spacer()
                Text("\(installedSourceCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 8)

            // A real AppKit NSSearchField — already the native control, kept as-is.
            SourceFilterSearchField(text: $sourceFilter, placeholder: "Filter sources")
                .frame(height: 28)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            if appState.isLoading || appState.isBrowseLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(appState.isBrowseLoading ? "Loading results" : "Refreshing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            Divider()

            sourceList
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The rail is a real `List` with system selection, so macOS draws the
    /// selected row (and its correct on-accent text colour) instead of a
    /// hand-rolled accent-on-accent fill.
    private var sourceList: some View {
        List(selection: railSelection) {
            if !pinnedSources.isEmpty {
                Section("Pinned") {
                    ForEach(pinnedSources) { source in
                        SourceListRow(source: source)
                            .tag(source.id)
                            .contextMenu { sourceRowMenu(source) }
                    }
                }
            }
            if !installedSources.isEmpty {
                Section("Installed") {
                    ForEach(installedSources) { source in
                        SourceListRow(source: source)
                            .tag(source.id)
                            .contextMenu { sourceRowMenu(source) }
                    }
                }
            }
            if !availableSources.isEmpty {
                Section("Available") {
                    ForEach(availableSources) { source in
                        SourceListRow(source: source)
                            .tag(source.id)
                            .contextMenu { sourceRowMenu(source) }
                    }
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
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private var railSelection: Binding<String?> {
        Binding(
            get: { appState.selectedSourceId },
            set: { newValue in
                guard let id = newValue else { return }
                selectSource(id)
            }
        )
    }

    private func selectSource(_ id: String) {
        selectedGenreFilter = nil
        appState.selectedSourceId = id
        appState.selectedBrowseMangaId = nil
        appState.activeMangaDetails = nil
        appState.detailsIsFavourited = false
        appState.browseMangas = []
        appState.isBrowseLoading = false
        appState.isDetailLoading = false
        if appState.sources.first(where: { $0.id == id })?.isInstalled == true {
            Task { await loadCurrentMode(sid: id) }
        }
    }

    /// Return to the source-grid landing: clear the active source and any open detail/browse
    /// state so the grid shows cleanly.
    private func deselectSource() {
        appState.selectedSourceId = nil
        appState.selectedBrowseMangaId = nil
        appState.activeMangaDetails = nil
        appState.detailsIsFavourited = false
        appState.browseMangas = []
        appState.isBrowseLoading = false
        appState.isDetailLoading = false
        selectedGenreFilter = nil
        query = ""
    }

    // MARK: - Browse pane

    private var activeSource: SourceSummary? {
        guard let sid = appState.selectedSourceId else { return nil }
        return appState.sources.first(where: { $0.id == sid })
    }

    private var browseArea: some View {
        VStack(spacing: 0) {
            // The title/subtitle block moved to the real navigation title + subtitle,
            // and the mode picker to the toolbar; only the search field is left.
            if let s = activeSource, s.isInstalled, browseMode == .search {
                SourceFilterSearchField(
                    text: $query,
                    placeholder: "Search this source",
                    onSubmit: { Task { await appState.searchActiveSource(query: query) } }
                )
                .frame(height: 28)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
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

    // Stock bordered toggles. `.toggleStyle(.button)` is the system's own filter
    // chip: it fills with the accent when on and picks the readable foreground
    // itself, so no gradient capsule and no hardcoded white-on-accent.
    private var quickFilterChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Top Categories")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Toggle(
                        "All",
                        isOn: Binding(
                            get: { selectedGenreFilter == nil },
                            set: { if $0 { selectedGenreFilter = nil } }
                        )
                    )
                    .toggleStyle(.button)

                    ForEach(uniqueGenres, id: \.self) { genre in
                        Toggle(
                            genre,
                            isOn: Binding(
                                get: { selectedGenreFilter == genre },
                                set: { selectedGenreFilter = $0 ? genre : nil }
                            )
                        )
                        .toggleStyle(.button)
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
                    Label("Close", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
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
        // Opaque system panel instead of a glass slab.
        .background(Color.appBackground)
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
    /// Fired when the user presses Return. Nil for filter-as-you-type fields.
    var onSubmit: (() -> Void)? = nil

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
        context.coordinator.onSubmit = onSubmit
        // Do not push SwiftUI's value back into AppKit while the field editor
        // is active. During live typing, SwiftUI can re-render from unrelated
        // state changes before the binding catches up, which resets each key.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding private var text: String
        var onSubmit: (() -> Void)?

        init(text: Binding<String>, onSubmit: (() -> Void)?) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }

        // Return submits. The field's own clear button just empties the text —
        // it does not fire a search, matching the old hand-built clear button.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let onSubmit
            else { return false }
            text = control.stringValue
            onSubmit()
            return true
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

    var body: some View {
        // No `isSelected` styling: the List draws selection, which also picks the
        // correct on-accent text colour for whichever of the 12 themes is active.
        HStack(spacing: 10) {
            // Matches CatalogSheet's source rows — the two source lists now agree.
            Image(systemName: "puzzlepiece.extension")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(source.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if source.isNsfw {
                        Text("18+")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Adult content, 18 plus")
                    }
                }
                Text("\(source.engine) · \(source.lang.uppercased())\(source.isNsfw ? " · NSFW" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: source.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(source.isInstalled ? Color.green : Color.secondary)
                .imageScale(.small)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Cover card

@MainActor
// MARK: - Sources grid landing (nyora-web wireframe)

/// The Explore landing shown when no source is selected: a "Manga sources" grid divided by
/// language, with a search-all-sources field and a language dropdown filter (with counts) —
/// mirroring nyora-web. Each card shows the source icon (or a language badge), name, and
/// language; pinned sources are highlighted. Tapping a card opens that source's browse view.
private struct SourcesGridLanding: View {
    @EnvironmentObject var appState: AppState
    @Binding var search: String
    @Binding var languageFilter: String?
    let onOpen: (SourceSummary) -> Void
    @State private var warmedIcons = false

    /// Browseable sources = installed, NSFW-filtered. These are what the grid divides by language.
    private var installed: [SourceSummary] {
        appState.visibleSources.filter(\.isInstalled)
    }

    private var languageOptions: [LanguageOption] {
        LanguageOption.options(from: installed)
    }

    /// Sources after the language + search filters, pinned first then alphabetical.
    private var filtered: [SourceSummary] {
        var list = installed
        if let lang = languageFilter {
            list = list.filter { $0.languageCode == lang }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.name.lowercased().contains(q)
                    || $0.languageName.lowercased().contains(q)
                    || $0.languageCode.contains(q)
            }
        }
        return list.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var currentLanguageLabel: String {
        guard let code = languageFilter,
              let opt = languageOptions.first(where: { $0.code == code })
        else { return "All languages (\(installed.count))" }
        return "\(opt.label) (\(opt.count))"
    }

    /// Binding that maps the "" sentinel (used for the "All languages" row) to `nil`.
    private var languageSelection: Binding<String> {
        Binding(
            get: { languageFilter ?? "" },
            set: { languageFilter = $0.isEmpty ? nil : $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().opacity(0.5)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // The engine resolves source favicons in the background; if none have arrived
            // yet, re-fetch a few times so the warmed icons replace the language badges.
            guard !warmedIcons else { return }
            warmedIcons = true
            for _ in 0..<4 {
                if !installed.isEmpty && !installed.allSatisfy({ $0.iconUrl.isEmpty }) { break }
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                await appState.refreshSources()
            }
        }
    }

    // Full-width "Search all sources…" field, like the web's top bar.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search all sources…", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .adaptiveGlass(.capsule)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if installed.isEmpty {
            ContentUnavailableView {
                Label("No sources yet", systemImage: "puzzlepiece.extension")
            } description: {
                Text("Add sources from the catalogue to start browsing.")
            } actions: {
                Button("Add Sources") { Task { await appState.openCatalog() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.appAccent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: search)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerRow
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 116, maximum: 150), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 16
                    ) {
                        ForEach(filtered) { source in
                            SourceGridCard(
                                source: source,
                                onTap: { onOpen(source) },
                                onTogglePin: { Task { await appState.togglePinSource(source.id) } }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
            }
        }
    }

    // "Manga sources" heading + the language dropdown + Catalog, matching the web's section head.
    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Manga sources")
                .font(.title3.weight(.semibold))
            Text("\(filtered.count)")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()

            Menu {
                Picker("Language", selection: languageSelection) {
                    Text("All languages (\(installed.count))").tag("")
                    ForEach(languageOptions) { opt in
                        Text("\(opt.label) (\(opt.count))").tag(opt.code)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.callout)
                    Text(currentLanguageLabel).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .adaptiveGlass(.capsule, interactive: true)
            .help("Filter sources by language")

            Button {
                Task { await appState.openCatalog() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.2x2").font(.callout)
                    Text("Catalog")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .adaptiveGlass(.capsule, interactive: true)
            .help("Add or manage sources")
        }
    }
}

/// One source card in the grid: icon (or language badge), name, language, pin state.
private struct SourceGridCard: View {
    let source: SourceSummary
    let onTap: () -> Void
    let onTogglePin: () -> Void
    @State private var isHovered = false
    @State private var iconFailed = false

    private var langBadgeText: String {
        let code = source.languageCode
        return code.isEmpty ? "?" : String(code.prefix(2)).uppercased()
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 9) {
                icon
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .overlay(alignment: .topTrailing) {
                        if source.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.onAccent)
                                .padding(4)
                                .background(Circle().fill(Color.appAccent))
                                .offset(x: 6, y: -6)
                        }
                    }

                VStack(spacing: 2) {
                    Text(source.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    Text(source.languageName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .adaptiveGlass(.rect(cornerRadius: 16), interactive: true)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(source.isPinned ? Color.appAccent.opacity(0.6) : Color.clear,
                              lineWidth: source.isPinned ? 1.5 : 0)
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0.0), radius: isHovered ? 10 : 0, y: isHovered ? 5 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(source.isPinned ? "Unpin" : "Pin",
                   systemImage: source.isPinned ? "pin.slash" : "pin",
                   action: onTogglePin)
        }
        .help(source.name)
    }

    // Real source icon when available; otherwise a neutral language badge (like the web).
    @ViewBuilder
    private var icon: some View {
        if !source.iconUrl.isEmpty, !iconFailed,
           let url = URL(string: source.iconUrl) {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    // Favicon fitted on a neutral tile so small/transparent icons read like
                    // an app icon rather than being cropped edge-to-edge.
                    ZStack {
                        Color.primary.opacity(0.06)
                        image.resizable().scaledToFit().padding(11)
                    }
                case .failure:
                    languageBadge.onAppear { iconFailed = true }
                case .empty:
                    ZStack { languageBadge; ProgressView().controlSize(.small) }
                @unknown default:
                    languageBadge
                }
            }
        } else {
            languageBadge
        }
    }

    private var languageBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.09))
            Text(langBadgeText)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Source picker (toolbar popover, replaces the 468-source rail)

private struct SourcePickerButton: View {
    @EnvironmentObject var appState: AppState
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.callout)
                Text(appState.activeSourceSummary?.name ?? "Choose Source")
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Switch source")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SourcePickerPopover { isPresented = false }
                .environmentObject(appState)
                .frame(width: 320, height: 440)
        }
    }
}

private struct SourcePickerPopover: View {
    @EnvironmentObject var appState: AppState
    @State private var filter = ""
    let dismiss: () -> Void

    private var installed: [SourceSummary] {
        appState.visibleSources.filter(\.isInstalled)
    }
    private var filtered: [SourceSummary] {
        guard !filter.isEmpty else { return installed }
        let q = filter.lowercased()
        return installed.filter { $0.name.lowercased().contains(q) || $0.lang.lowercased().contains(q) }
    }
    private var pinned: [SourceSummary] {
        filtered.filter(\.isPinned).sorted { $0.name < $1.name }
    }
    private var recents: [SourceSummary] {
        appState.recentSourceIds.compactMap { id in
            filtered.first { $0.id == id && !$0.isPinned }
        }
    }
    private var byLanguage: [(String, [SourceSummary])] {
        let recentIds = Set(recents.map(\.id))
        let rest = filtered.filter { !$0.isPinned && !recentIds.contains($0.id) }
        return Dictionary(grouping: rest, by: { $0.lang.uppercased() })
            .map { ($0.key, $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.0 < $1.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search sources", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            Divider()
            List {
                if !pinned.isEmpty {
                    Section("Pinned") { ForEach(pinned) { row($0) } }
                }
                if !recents.isEmpty {
                    Section("Recent") { ForEach(recents) { row($0) } }
                }
                ForEach(byLanguage, id: \.0) { lang, list in
                    Section(lang) { ForEach(list) { row($0) } }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            Button {
                dismiss()
                Task { await appState.openCatalog() }
            } label: {
                Label("Manage Sources…", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
    }

    @ViewBuilder
    private func row(_ s: SourceSummary) -> some View {
        Button {
            dismiss()
            Task { await appState.loadPopular(sourceId: s.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.name).lineLimit(1)
                    Text("\(s.engine) · \(s.lang.uppercased())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if s.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
                if s.id == appState.selectedSourceId {
                    Image(systemName: "checkmark").foregroundStyle(Color.appAccent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(s.isPinned ? "Unpin" : "Pin", systemImage: s.isPinned ? "pin.slash" : "pin") {
                Task { await appState.togglePinSource(s.id) }
            }
        }
    }
}

private struct MangaCoverCard: View {
    let manga: MangaSummary
    let isSelected: Bool
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // Artwork-forward cover — edge-to-edge with rounded corners and a soft depth
                // shadow, the way App Store / TV / Music show catalogue art. No boxy card
                // chrome around it. Fixed 2:3 so every cover is uniform regardless of source
                // image dimensions.
                ZStack {
                    Color.primary.opacity(0.06)
                    coverImage
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.appAccent : Color.white.opacity(0.08),
                            lineWidth: isSelected ? 2.5 : 0.5
                        )
                )
                .overlay(alignment: .topTrailing) {
                    if manga.unread > 0 {
                        Text("\(manga.unread)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.appAccent))
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if manga.progress > 0 {
                        ProgressView(value: Double(min(manga.progress, 1.0)))
                            .progressViewStyle(.linear)
                            .tint(Color.appAccent)
                            .scaleEffect(y: 0.5)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 6)
                            .allowsHitTesting(false)
                    }
                }
                .shadow(color: .black.opacity(isHovered ? 0.35 : 0.22), radius: isHovered ? 12 : 6, y: isHovered ? 6 : 3)

                // Reserve two lines so 1-line and 2-line titles yield equal-height cards,
                // which keeps the grid rows aligned (no title bleeding into the row below).
                Text(manga.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Subtle App-Store-style hover lift.
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

// MARK: - Chapter row

@MainActor
private struct ChapterRow: View {
    let chapter: HelperChapter
    var downloaded: Bool = false
    let onTap: () -> Void

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

    /// Secondary line: relative date · scanlator · volume (whichever are present).
    private var metaString: String {
        var parts: [String] = []
        if !uploadDateString.isEmpty { parts.append(uploadDateString) }
        if let s = chapter.scanlator, !s.isEmpty { parts.append(s) }
        if chapter.volume > 0 { parts.append("Vol. \(chapter.volume)") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button { onTap() } label: {
            HStack(spacing: 12) {
                // Plain monospaced number — no accent-filled tile, no hover swap.
                Text(chapterNumberText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)

                // Title + ONE secondary line.
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !metaString.isEmpty {
                        Text(metaString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if downloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Downloaded")
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @State private var showDownloadSheet: Bool = false
    @State private var chaptersNewestFirst: Bool = false
    // Chapter overview filters (web-style).
    @State private var chapterSearch: String = ""
    @State private var chapterFilter: ChapterFilter = .all
    @State private var scanlatorFilter: String? = nil

    enum ChapterFilter: String, CaseIterable, Identifiable {
        case all = "All", downloaded = "Downloaded", notDownloaded = "Not downloaded"
        var id: String { rawValue }
    }

    /// Chapter URLs already fully downloaded (for the badge + Downloaded filter).
    private var downloadedChapterUrls: Set<String> {
        Set(appState.downloads.filter { $0.status == "COMPLETED" }.map(\.chapterUrl))
    }
    /// Distinct scanlators present, for the scanlator filter menu.
    private var scanlators: [String] {
        Array(Set(details.chapters.compactMap { s in s.scanlator.flatMap { $0.isEmpty ? nil : $0 } })).sorted()
    }
    /// The chapters after sort + search + downloaded + scanlator filters.
    private var visibleChapters: [HelperChapter] {
        let ordered = chaptersNewestFirst ? Array(details.chapters.reversed()) : details.chapters
        let q = chapterSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let dl = downloadedChapterUrls
        return ordered.filter { ch in
            switch chapterFilter {
            case .all: break
            case .downloaded: if !dl.contains(ch.url) { return false }
            case .notDownloaded: if dl.contains(ch.url) { return false }
            }
            if let sc = scanlatorFilter, (ch.scanlator ?? "") != sc { return false }
            guard !q.isEmpty else { return true }
            return ch.title.lowercased().contains(q)
                || String(format: "%g", ch.number).contains(q)
        }
    }

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
        GeometryReader { geo in
            if geo.size.width >= 780 {
                // Wide: proper two-column overview — cover/info on the left, the
                // chapter overview filling the rest (like the web detail page).
                HStack(alignment: .top, spacing: 0) {
                    ScrollView { infoColumn.padding(20) }
                        .frame(width: 340)
                    Divider()
                    ScrollView { chaptersSection.padding(20) }
                        .frame(maxWidth: .infinity)
                }
            } else {
                // Narrow: single stacked column.
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        hero
                        if !details.manga.tags.isEmpty { tagsRow }
                        descriptionBlock
                        Divider().padding(.vertical, 4)
                        chaptersSection
                    }
                    .padding(20)
                }
            }
        }
    }

    /// Vertical hero for the wide layout: big cover, then title / meta / library
    /// button / tags / description in one scrolling column.
    @ViewBuilder
    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            cover
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(details.manga.title).font(.title3.bold()).lineLimit(4)
                if let webURL {
                    Button { appState.openInApp(webURL) } label: {
                        Image(systemName: "globe").font(.subheadline.weight(.semibold)).foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain).help("Open website")
                }
            }
            if !details.manga.authors.isEmpty {
                Label(details.manga.authors.joined(separator: ", "), systemImage: "person")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !details.manga.altTitles.isEmpty {
                Text(details.manga.altTitles.prefix(2).joined(separator: " • "))
                    .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            HStack(spacing: 10) {
                let rating = details.manga.rating
                if rating > 0 {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill").font(.caption).foregroundStyle(.secondary)
                }
                Label("\(details.chapters.count) Chs", systemImage: "doc.text").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if details.manga.isNsfw {
                    Text("18+").font(.caption.weight(.semibold)).foregroundStyle(.red)
                }
            }
            .padding(.top, 2)

            Button { Task { await appState.toggleDetailsFavourite() } } label: {
                Label(
                    appState.detailsIsFavourited ? "In Library" : "Add to Library",
                    systemImage: appState.detailsIsFavourited ? "heart.fill" : "heart"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.detailsIsFavourited ? Color.pink : Color.appAccent)
            .padding(.top, 2)

            if !details.manga.tags.isEmpty { tagsRow }
            descriptionBlock
        }
    }

    @ViewBuilder
    private var descriptionBlock: some View {
        if !details.manga.description.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                // HTMLText renders/strips the source's HTML (raw descriptions carry
                // <p style=…>/<br>/<i> that plain Text would show verbatim).
                HTMLText(html: details.manga.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(appState.readerPrefs.descriptionCollapse && !isExpanded ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.readerPrefs.descriptionCollapse {
                    Button { withAnimation { isExpanded.toggle() } } label: {
                        Text(isExpanded ? "Read less" : "Read more...")
                            .font(.subheadline.bold())
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.readerPrefs.pagesTab {
                Picker("", selection: $selectedTab) {
                    Text("Chapters").tag(0)
                    Text("Pages").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .tint(Color.appAccent)
            }
            if !appState.readerPrefs.pagesTab || selectedTab == 0 {
                chaptersHeader
                chaptersList
            } else {
                pagesView
            }
        }
    }

    @ViewBuilder
    private var hero: some View {
        HStack(alignment: .top, spacing: 16) {
            // Cover — prominent thumbnail
            cover
                .frame(minWidth: 104, idealWidth: 130, maxWidth: 160)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

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

                // Rating, chapter count and the NSFW marker survive as plain
                // secondary text instead of three gradient badges.
                HStack(spacing: 10) {
                    let rating = details.manga.rating
                    if rating > 0 {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Label("\(details.chapters.count) Chs", systemImage: "doc.text")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    if details.manga.isNsfw {
                        Text("18+")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .accessibilityLabel("Adult content, 18 plus")
                    }
                }
                .padding(.top, 2)

                Spacer(minLength: 4)

                // Stock prominent button: the tint is the only accent, and the
                // system picks the readable label colour for it.
                Button {
                    Task { await appState.toggleDetailsFavourite() }
                } label: {
                    Label(
                        appState.detailsIsFavourited ? "In Library" : "Add to Library",
                        systemImage: appState.detailsIsFavourited ? "heart.fill" : "heart"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.detailsIsFavourited ? Color.pink : Color.appAccent)
            }
            Spacer(minLength: 0)
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
                // Flat tag tokens — no gradient fill, no stroke.
                ForEach(visibleTags, id: \.key) { tag in
                    Text(tag.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }

                if isTruncated {
                    Button("Show all") { showAllTags = true }
                        .buttonStyle(.link)
                        .font(.caption)
                } else if showAllTags && allTags.count > tagLimit {
                    Button("Show less") { showAllTags = false }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var chaptersHeader: some View {
        VStack(spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Chapters")
                .font(.headline)

            Text("\(details.chapters.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            if details.chapters.count > 1 {
                Button {
                    chaptersNewestFirst.toggle()
                } label: {
                    Label(
                        chaptersNewestFirst ? "Newest" : "Oldest",
                        systemImage: chaptersNewestFirst ? "arrow.down" : "arrow.up"
                    )
                }
                .buttonStyle(.borderless)
                .help("Sort chapters newest- or oldest-first")
            }

            if !details.chapters.isEmpty {
                Button {
                    showDownloadSheet = true
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("Download chapters — pick a range or select individually")
            }
        }
        chaptersFilterBar
        }
        .padding(.bottom, 2)
        .task { await appState.reloadDownloads() }
        .sheet(isPresented: $showDownloadSheet) {
            DownloadChaptersSheet(details: details, sourceId: appState.selectedSourceId ?? "")
                .environmentObject(appState)
        }
    }

    /// Web-style filter row: search, downloaded filter, scanlator filter, count.
    private var chaptersFilterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Filter chapters…", text: $chapterSearch).textFieldStyle(.plain)
                if !chapterSearch.isEmpty {
                    Button { chapterSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .frame(maxWidth: 260)

            Picker("", selection: $chapterFilter) {
                ForEach(ChapterFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()

            if scanlators.count > 1 {
                Menu {
                    Button("All scanlators") { scanlatorFilter = nil }
                    Divider()
                    ForEach(scanlators, id: \.self) { s in Button(s) { scanlatorFilter = s } }
                } label: {
                    Label(scanlatorFilter ?? "Scanlator", systemImage: "person.2")
                        .labelStyle(.titleAndIcon)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

            Spacer()
            Text("\(visibleChapters.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chaptersList: some View {
        let dl = downloadedChapterUrls
        LazyVStack(spacing: 5) {
            if visibleChapters.isEmpty {
                Text(chapterSearch.isEmpty ? "No chapters match this filter." : "No chapters match “\(chapterSearch)”.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(visibleChapters) { chapter in
                    ChapterRow(chapter: chapter, downloaded: dl.contains(chapter.url)) { onChapter(chapter) }
                }
            }
        }
    }

    @ViewBuilder
    private var pagesView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header row
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Page Thumbnails")
                    .font(.headline)

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
                                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                    )

                                    Text("\(index + 1)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
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
    @State private var searchText = ""
    @State private var hideDownloaded = false

    private var chapters: [HelperChapter] { details.chapters }

    /// Chapter URLs already fully downloaded vs still queued / in-progress.
    private var downloadedUrls: Set<String> {
        Set(appState.downloads.filter { $0.status == "COMPLETED" }.map(\.chapterUrl))
    }
    private var queuedUrls: Set<String> {
        Set(appState.downloads
            .filter { $0.status != "COMPLETED" && $0.status != "FAILED" && $0.status != "CANCELLED" }
            .map(\.chapterUrl))
    }
    /// Chapters after the search filter + optional "hide downloaded".
    private var visibleChapters: [HelperChapter] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return chapters.filter { ch in
            if hideDownloaded && downloadedUrls.contains(ch.url) { return false }
            guard !q.isEmpty else { return true }
            return ch.title.lowercased().contains(q)
                || String(format: "%g", ch.number).contains(q)
                || (ch.scanlator?.lowercased().contains(q) ?? false)
        }
    }
    /// Visible chapters that can still be selected (i.e. not already downloaded).
    private var selectableVisible: [HelperChapter] {
        visibleChapters.filter { !downloadedUrls.contains($0.url) }
    }
    private func shortLabel(_ ch: HelperChapter) -> String {
        ch.number > 0 ? "Ch \(String(format: "%g", ch.number))" : ch.title
    }

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
                    // Search / filter — makes picking chapters in a long list easy.
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                        TextField("Filter by title, number or scanlator…", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                    // Range select — operates on what's currently visible.
                    HStack(spacing: 8) {
                        Text("Range").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Picker("", selection: $fromIdx) {
                            ForEach(visibleChapters.indices, id: \.self) { Text(shortLabel(visibleChapters[$0])).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Picker("", selection: $toIdx) {
                            ForEach(visibleChapters.indices, id: \.self) { Text(shortLabel(visibleChapters[$0])).tag($0) }
                        }
                        .labelsHidden().frame(maxWidth: .infinity)
                        Button("Select") { selectRange() }.buttonStyle(.bordered)
                    }
                    HStack(spacing: 8) {
                        chip("All") { selected.formUnion(selectableVisible.map(\.id)) }
                        chip("None") { selected.removeAll() }
                        chip("Invert") {
                            let ids = Set(selectableVisible.map(\.id))
                            selected = ids.symmetricDifference(selected).intersection(ids)
                        }
                        Toggle("Hide downloaded", isOn: $hideDownloaded)
                            .toggleStyle(.checkbox).controlSize(.small)
                        Spacer()
                        Text("\(selected.count) selected")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider()

                if visibleChapters.isEmpty {
                    Spacer()
                    Text(searchText.isEmpty ? "No chapters" : "No chapters match “\(searchText)”")
                        .foregroundStyle(.secondary).font(.callout)
                    Spacer()
                } else {
                    List {
                        ForEach(visibleChapters) { ch in
                            let done = downloadedUrls.contains(ch.url)
                            let queued = queuedUrls.contains(ch.url)
                            let picked = selected.contains(ch.id)
                            Button { if !done { toggle(ch.id) } } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: (done || picked) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(done ? Color.green : (picked ? Color.appAccent : .secondary))
                                    Text(ch.title).lineLimit(1)
                                        .foregroundStyle(done ? .secondary : .primary)
                                    Spacer(minLength: 0)
                                    if done {
                                        Text("Downloaded").font(.caption2).foregroundStyle(.green)
                                    } else if queued {
                                        Text("Queued").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(done)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
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
        // Populate the downloaded/queued badges (best-effort).
        .task { await appState.reloadDownloads() }
        // Keep the range pickers valid as the filter changes the visible set.
        .onChange(of: searchText) { _, _ in
            fromIdx = 0
            toIdx = max(0, visibleChapters.count - 1)
        }
    }

    private func chip(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func selectRange() {
        let vis = visibleChapters
        guard !vis.isEmpty else { return }
        let n = vis.count - 1
        let lo = max(0, min(min(fromIdx, toIdx), n))
        let hi = max(0, min(max(fromIdx, toIdx), n))
        // Add the range (skipping already-downloaded chapters) to the selection.
        selected.formUnion(vis[lo...hi].filter { !downloadedUrls.contains($0.url) }.map(\.id))
    }

    private func submit() async {
        submitting = true
        let chosen = chapters.filter { selected.contains($0.id) }
        await appState.downloadChapters(sourceId: sourceId, manga: details.manga, chapters: chosen)
        submitting = false
        dismiss()
    }
}
