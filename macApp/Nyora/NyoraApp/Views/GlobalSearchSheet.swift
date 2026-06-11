import SwiftUI

@MainActor
struct GlobalSearchSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var searchFocused: Bool
    @State private var hasSearched = false

    var body: some View {
        ZStack {
            // Near-black immersive base in dark mode; adaptive in light mode
            (colorScheme == .dark ? Color.black.opacity(0.96) : Color(.windowBackgroundColor).opacity(0.98))
                .ignoresSafeArea()

            // Glassy ultraThinMaterial overlay at low opacity
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.15)
                .ignoresSafeArea()

            // Dark-mode radial accent glow in top-leading corner
            if colorScheme == .dark {
                GeometryReader { geo in
                    RadialGradient(
                        colors: [Color.appAccent.opacity(0.06), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 350
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                header

                // Thin separator — no system Divider, just spacing + a hairline
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 0.5)
                    .padding(.horizontal, 16)

                content
            }
        }
        .frame(
            minWidth: 580, idealWidth: 840, maxWidth: 1100,
            minHeight: 480, idealHeight: 640
        )
        .onAppear { searchFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            // Magnifying glass icon
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .foregroundStyle(Color.primary.opacity(0.5))

            // Search input
            TextField("Search every source…", text: $appState.globalSearchQuery)
                .textFieldStyle(.plain)
                .font(.title3)
                .foregroundStyle(.primary)
                .focused($searchFocused)
                .onSubmit {
                    hasSearched = true
                    Task { await appState.runGlobalSearch() }
                }
                .onChange(of: appState.globalSearchQuery) { _, q in
                    if q.isEmpty { hasSearched = false }
                }
                .tint(Color.appAccent)

            // Spinner while searching
            if appState.isGlobalSearching {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
                    .transition(.opacity.combined(with: .scale))
            }

            // Dismiss button
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
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
                // Faint topLeading accent glow spot for pill depth
                .background(
                    RadialGradient(
                        colors: [Color.appAccent.opacity(0.10), Color.appAccent.opacity(0.03), .clear],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 220
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
        .padding(16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appState.globalSearchQuery.isEmpty {
            placeholderView
        } else if hasSearched && appState.globalSearchResults.isEmpty && !appState.isGlobalSearching {
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
                // 2-spot layered aurora: bright accent topLeading + dim
                // accent bottomTrailing for organic depth
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
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.appAccent.opacity(0.14), .clear],
                            center: .bottomTrailing,
                            startRadius: 0,
                            endRadius: 70
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

            Text("Global Search")
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

            // Keyboard hint chip
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

    // MARK: - No Results

    private var noResultsView: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                // 2-spot layered aurora: bright accent topLeading + dim
                // accent bottomTrailing for organic depth
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
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.appAccent.opacity(0.14), .clear],
                            center: .bottomTrailing,
                            startRadius: 0,
                            endRadius: 70
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

    // MARK: - Results Scroll

    private var resultsScrollView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(Array(visibleResults.enumerated()), id: \.element.id) { idx, group in
                    groupSection(group)
                        .animeEntrance(delay: Double(idx) * 0.05)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Group Section

    private func groupSection(_ group: HelperGlobalSearchGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack(spacing: 8) {
                // Left accent capsule
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent.opacity(0.95), Color.appAccent.opacity(0.45), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 1.5, height: 18)

                Text(group.sourceName)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)

                // Count chip
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
                    columns: [.init(.adaptive(minimum: 130), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(group.entries, id: \.id) { manga in
                        AnimeSearchCard(manga: manga) {
                            Task { await appState.openGlobalSearchResult(group: group, manga: manga) }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var visibleResults: [HelperGlobalSearchGroup] {
        guard appState.hideNsfwSources else { return appState.globalSearchResults }
        let nsfwIds = Set(appState.visibleSources.filter { $0.isNsfw }.map { $0.id })
        return appState.globalSearchResults.filter { !nsfwIds.contains($0.sourceId) }
    }
}

// MARK: - AnimeSearchCard

@MainActor
private struct AnimeSearchCard: View {
    let manga: HelperManga
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button { action() } label: {
            ZStack(alignment: .bottomLeading) {
                // Cover — 2:3 ratio
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

                // Bottom vignette
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // Title overlaid at bottom of cover
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
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: isHovered
                                        ? [Color.appAccent.opacity(0.30), Color.primary.opacity(0.08)]
                                        : [Color.clear, Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.6
                            )
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .drawingGroup()
        }
        .buttonStyle(.plain)
        .shadow(
            color: isHovered ? Color.appAccent.opacity(0.35) : .black.opacity(0.22),
            radius: isHovered ? 14 : 8,
            x: 0,
            y: isHovered ? 6 : 4
        )
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.38, dampingFraction: 0.65), value: isHovered)
        .onHover { isHovered = $0 }
    }
}
