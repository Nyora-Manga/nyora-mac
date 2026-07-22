import SwiftUI

@MainActor
struct GlobalSearchSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            // No immersive near-black wash and no radial accent glow — the sheet
            // takes the system background, like every stock macOS sheet.
            content
                .searchable(
                    text: $appState.globalSearchQuery,
                    placement: .toolbar,
                    prompt: "Search every source…"
                )
                .searchFocused($searchFocused)
                .onSubmit(of: .search) {
                    hasSearched = true
                    Task { await appState.runGlobalSearch() }
                }
                .onChange(of: appState.globalSearchQuery) { _, q in
                    if q.isEmpty { hasSearched = false }
                }
                .toolbar {
                    if appState.isGlobalSearching {
                        ToolbarItem {
                            ProgressView().controlSize(.small)
                        }
                    }
                    ToolbarItem {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                }
        }
        .frame(
            minWidth: 580, idealWidth: 840, maxWidth: 1100,
            minHeight: 480, idealHeight: 640
        )
        .onAppear { searchFocused = true }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.globalSearchQuery.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "Global Search",
                message: "Searches every installed source at the same time. Press Return to run."
            )
        } else if hasSearched && appState.globalSearchResults.isEmpty && !appState.isGlobalSearching {
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
                columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(visibleResults, id: \.id) { group in
                    Section {
                        if group.entries.isEmpty && group.error == nil {
                            Text("No matches in this source")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(group.entries, id: \.id) { manga in
                                GlobalSearchCard(manga: manga) {
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

    // Plain section header — the accent gradient rule and the gradient count chip
    // are gone; the count and the per-source error survive as plain text.
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

// MARK: - GlobalSearchCard

@MainActor
private struct GlobalSearchCard: View {
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

                // Label below the thumbnail, Finder icon-view style — replaces the
                // vignette gradient plus shadowed white overlay text.
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
