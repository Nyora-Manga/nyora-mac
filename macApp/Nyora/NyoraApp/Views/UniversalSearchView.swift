import SwiftUI

// Full-page universal search across every installed source. Reuses AppState's
// global-search API (globalSearchQuery / runGlobalSearch / globalSearchResults /
// isGlobalSearching) and the grouped result layout from GlobalSearchSheet, but
// presented inline as a clean, flat, responsive page.
@MainActor
struct UniversalSearchView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var searchFocused: Bool

    // Local field state; committed into appState.globalSearchQuery on submit.
    @State private var query: String = ""
    @State private var hasSearched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
                .padding(.horizontal, 24)

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            query = appState.globalSearchQuery
            hasSearched = !appState.globalSearchResults.isEmpty
            searchFocused = true
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(Color.primary.opacity(0.5))

            TextField("Search every source…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .foregroundStyle(.primary)
                .focused($searchFocused)
                .onSubmit(runSearch)
                .onChange(of: query) { _, q in
                    if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        hasSearched = false
                    }
                }
                .tint(Color.appAccent)

            if appState.isGlobalSearching {
                ProgressView()
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .scale))
            } else if !query.isEmpty {
                Button {
                    query = ""
                    appState.globalSearchQuery = ""
                    hasSearched = false
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .background(
                    LinearGradient(
                        colors: [Color.appAccent.opacity(0.07), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.appAccent.opacity(0.22), Color.primary.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.6
                        )
                )
        )
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
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
            placeholderView
        } else if hasSearched
            && visibleResults.isEmpty
            && !appState.isGlobalSearching {
            noResultsView
        } else {
            resultsScrollView
        }
    }

    // MARK: - Placeholder

    private var placeholderView: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.appAccent.opacity(0.26), Color.appAccent.opacity(0.10), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 90, height: 90)
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appAccent)
            }
            .animeEntrance(delay: 0.0)

            Spacer().frame(height: 24)

            Text("Search")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .animeEntrance(delay: 0.08)

            Spacer().frame(height: 10)

            Text("Searches every installed source at the same time.\nPress Return to run.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .animeEntrance(delay: 0.14)

            Spacer().frame(height: 20)

            Text("⏎ Return to search")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .animeEntrance(delay: 0.20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No results

    private var noResultsView: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.appAccent.opacity(0.26), Color.appAccent.opacity(0.10), .clear],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 80
                        )
                    )
                    .frame(width: 90, height: 90)
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 64))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appAccent)
            }
            .animeEntrance(delay: 0.0)

            Spacer().frame(height: 24)

            Text("No Matches")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .animeEntrance(delay: 0.07)

            Spacer().frame(height: 8)

            Text("Try a different title or check that sources are installed.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
                .animeEntrance(delay: 0.13)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Results

    private var resultsScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(visibleResults.enumerated()), id: \.element.id) { idx, group in
                    groupSection(group)
                        .animeEntrance(delay: Double(idx) * 0.05)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private func groupSection(_ group: HelperGlobalSearchGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent.opacity(0.95), Color.appAccent.opacity(0.45), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 18)

                Text(group.sourceName.uppercased())
                    .font(.caption.bold())
                    .tracking(0.6)
                    .foregroundStyle(.secondary)

                if !group.entries.isEmpty {
                    Text("\(group.entries.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(Color.appAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.appAccent.opacity(0.20), Color.appAccent.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
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

            if group.entries.isEmpty && group.error == nil {
                Text("No matches in this source")
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.28))
                    .padding(.vertical, 6)
                    .padding(.leading, 14)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(group.entries, id: \.id) { manga in
                        UniversalSearchCard(manga: manga) {
                            Task { await appState.openGlobalSearchResult(group: group, manga: manga) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                        switch phase {
                        case let .success(image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                                .shimmer()
                        }
                    }
                    .aspectRatio(2.0 / 3.0, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    LinearGradient(
                        colors: [.clear, .clear, .black.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    Text(manga.title)
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isHovered ? Color.appAccent.opacity(0.45) : Color.clear,
                            lineWidth: 1
                        )
                )
            }
        }
        .buttonStyle(.plain)
        .shadow(
            color: isHovered ? Color.appAccent.opacity(0.30) : .black.opacity(0.18),
            radius: isHovered ? 12 : 6,
            x: 0,
            y: isHovered ? 5 : 3
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.38, dampingFraction: 0.65), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
