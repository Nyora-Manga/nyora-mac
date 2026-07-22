import SwiftUI

// Full-page universal search across every installed source. Reuses AppState's
// global-search API (globalSearchQuery / runGlobalSearch / globalSearchResults /
// isGlobalSearching) and the grouped result layout from GlobalSearchSheet.
//
// The search control is the system `.searchable` field — the same one
// GlobalSearchSheet uses — so the two search surfaces agree with each other and
// with Finder instead of each rolling their own pill.
@MainActor
struct UniversalSearchView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var searchFocused: Bool

    // Local field state; committed into appState.globalSearchQuery on submit.
    @State private var query: String = ""
    @State private var hasSearched = false

    var body: some View {
        content
            .searchable(
                text: $query,
                placement: .toolbar,
                prompt: "Search every source…"
            )
            .searchFocused($searchFocused)
            .onSubmit(of: .search, runSearch)
            .onChange(of: query) { _, q in
                if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    hasSearched = false
                    // The field's native clear button lands here — keep AppState in
                    // step, as the old hand-built clear button did.
                    appState.globalSearchQuery = ""
                }
            }
            .toolbar {
                if appState.isGlobalSearching {
                    ToolbarItem {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .onAppear {
                query = appState.globalSearchQuery
                hasSearched = !appState.globalSearchResults.isEmpty
                searchFocused = true
            }
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appState.globalSearchQuery = query
        hasSearched = true
        Task { await appState.runGlobalSearch() }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !hasSearched && appState.globalSearchResults.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Search",
                message: "Searches every installed source at the same time. Press Return to run."
            )
        } else if hasSearched
            && visibleResults.isEmpty
            && !appState.isGlobalSearching {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No Matches",
                message: "Try a different title or check that sources are installed."
            )
        } else {
            resultsScrollView
        }
    }

    // MARK: - Results

    private var resultsScrollView: some View {
        ScrollView(.vertical) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                ForEach(visibleResults, id: \.id) { group in
                    Section {
                        if group.entries.isEmpty && group.error == nil {
                            Text("No matches in this source")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(group.entries, id: \.id) { manga in
                                UniversalSearchCard(manga: manga) {
                                    Task { await appState.openGlobalSearchResult(group: group, manga: manga) }
                                }
                            }
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // A plain section header — the system draws the metrics. The old uppercase
    // caption, accent gradient rule and gradient count capsule are gone; the count
    // and the per-source error both survive as plain text.
    private func groupHeader(_ group: HelperGlobalSearchGroup) -> some View {
        HStack(spacing: 6) {
            Text(group.sourceName)
                .font(.headline)

            if !group.entries.isEmpty {
                Text("\(group.entries.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let err = group.error, !err.isEmpty {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(err)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var visibleResults: [HelperGlobalSearchGroup] {
        guard appState.hideNsfwSources else { return appState.globalSearchResults }
        let nsfwIds = Set(appState.visibleSources.filter { $0.isNsfw }.map { $0.id })
        return appState.globalSearchResults.filter { !nsfwIds.contains($0.sourceId) }
    }
}

// MARK: - Result card

@MainActor
private struct UniversalSearchCard: View {
    let manga: HelperManga
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                            .shimmer()
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                )

                // Label below the thumbnail, the way Finder's icon view does it —
                // replaces the vignette gradient plus shadowed white overlay text.
                Text(manga.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
