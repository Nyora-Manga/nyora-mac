import SwiftUI
// MARK: - FavouritesView

@MainActor
struct FavouritesView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var filtered: [HelperManga] {
        let q = appState.libraryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return appState.favourites }
        return appState.favourites.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            // Dynamic background
            ZStack {
                Color.appBackground
                if colorScheme == .dark {
                    RadialGradient(
                        colors: [appState.activeCoverAccentPrimary.opacity(0.20), .clear],
                        center: .topTrailing,
                        startRadius: 0,
                        endRadius: 420
                    )
                    RadialGradient(
                        colors: [appState.activeCoverAccentSecondary.opacity(0.12), .clear],
                        center: .bottomLeading,
                        startRadius: 0,
                        endRadius: 360
                    )
                }
            }
            .animation(.easeInOut(duration: 0.6), value: appState.activeCoverAccentPrimary)
            .ignoresSafeArea()

            // Bottom-center purple radial — dark mode only
            if colorScheme == .dark {
                VStack {
                    Spacer()
                    RadialGradient(
                        colors: [Color.appAccent.opacity(0.08), .clear],
                        center: .bottom,
                        startRadius: 0,
                        endRadius: 280
                    )
                    .frame(height: 280)
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
            }

            if filtered.isEmpty {
                EmptyStateView(
                    icon: "heart",
                    title: appState.libraryQuery.isEmpty ? "No favourites yet" : "No results",
                    message: appState.libraryQuery.isEmpty
                        ? "Tap the heart on any manga's details to add it here."
                        : "Try a different search term."
                )
            } else {
                gridContent
            }
        }
        .toolbar {
            ToolbarItem {
                DarkGlassSearchField(
                    text: $appState.libraryQuery,
                    placeholder: "Search favourites"
                )
            }
            ToolbarItem {
                Button {
                    Task { await appState.reloadFavourites() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: Grid

    private var gridContent: some View {
        let cols = [GridItem(.adaptive(minimum: CGFloat(appState.readerPrefs.gridSize)), spacing: 10)]
        return ScrollView {
            VStack(spacing: 14) {
                if let top = filtered.first {
                    FavouriteSpotlightHero(manga: top)
                        .environmentObject(appState)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                }
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(filtered, id: \.id) { manga in
                        FavouriteCard(manga: manga)
                            .onTapGesture {
                                Task { await appState.openFavouriteManga(manga) }
                            }
                            .contextMenu {
                                Button {
                                    Task { await appState.openFavouriteManga(manga) }
                                } label: {
                                    Label("Open Details", systemImage: "book.fill")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    Task { await appState.removeFavourite(mangaId: manga.id) }
                                } label: {
                                    Label("Remove from Library", systemImage: "heart.slash")
                                }
                            }
                    }
                }
                .padding(14)
            }
        }
    }
}

// MARK: - FavouriteSpotlightHero

@MainActor
private struct FavouriteSpotlightHero: View {
    let manga: HelperManga
    @EnvironmentObject var appState: AppState
    private var accent: Color {
        Color.appAccent
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Full-bleed cover
            AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                } else {
                    // Aurora fill — layered accent radials over a dim base
                    ZStack {
                        accent.opacity(0.22)
                        RadialGradient(
                            stops: [
                                .init(color: accent.opacity(0.85), location: 0.0),
                                .init(color: accent.opacity(0.55), location: 0.35),
                                .init(color: accent.opacity(0.18), location: 0.7),
                                .init(color: .clear,                location: 1.0),
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: 360
                        )
                        RadialGradient(
                            stops: [
                                .init(color: accent.opacity(0.40), location: 0.0),
                                .init(color: accent.opacity(0.20), location: 0.45),
                                .init(color: .clear,                location: 1.0),
                            ],
                            center: .bottomTrailing,
                            startRadius: 0,
                            endRadius: 300
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipped()

            // 6-stop vignette
            LinearGradient(
                stops: [
                    .init(color: .clear,                  location: 0.00),
                    .init(color: .clear,                  location: 0.25),
                    .init(color: .black.opacity(0.08),    location: 0.45),
                    .init(color: .black.opacity(0.55),    location: 0.65),
                    .init(color: .black.opacity(0.82),    location: 0.85),
                    .init(color: .black.opacity(0.97),    location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Bottom-left content
            VStack(alignment: .leading, spacing: 6) {
                // Gradient "MY TOP PICK" badge
                Text("MY TOP PICK")
                    .font(.caption2.bold())
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule()
                            .fill(accent.opacity(0.92))
                            .overlay(
                                // Top highlight — lifts the accent fill
                                Capsule()
                                    .fill(
                                        RadialGradient(
                                            colors: [Color.white.opacity(0.32), .clear],
                                            center: .top,
                                            startRadius: 0,
                                            endRadius: 22
                                        )
                                    )
                            )
                    )

                Text(manga.title)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: accent.opacity(0.4), radius: 8)
                    .lineLimit(2)

                if !manga.authors.isEmpty {
                    Text(manga.authors.joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                if manga.progress > 0 {
                    let progressFraction = min(1, max(0, CGFloat(manga.progress)))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.15))
                                .frame(width: geo.size.width, height: 3)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [accent, accent.opacity(0.55)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: geo.size.width * progressFraction, height: 3)
                        }
                    }
                    .frame(maxWidth: 360)
                    .frame(height: 3)
                }
            }
            .padding(20)

            // Top-right heart badge
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "heart.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.pink.opacity(0.95), Color.pink.opacity(0.70)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .shadow(color: Color.pink.opacity(0.55), radius: 6)
                        )
                        .padding(12)
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            // Conic accent sweep — rotating-light edge
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(
                    AngularGradient(
                        stops: [
                            .init(color: accent.opacity(0.45), location: 0.0),
                            .init(color: accent.opacity(0.10), location: 0.25),
                            .init(color: accent.opacity(0.38), location: 0.5),
                            .init(color: accent.opacity(0.08), location: 0.75),
                            .init(color: accent.opacity(0.45), location: 1.0),
                        ],
                        center: .center
                    ),
                    lineWidth: 1.0
                )
        )
        .shadow(color: .black.opacity(0.25), radius: 14, y: 7)
        .onTapGesture {
            Task { await appState.openFavouriteManga(manga) }
        }
        .contextMenu {
            Button {
                Task { await appState.openFavouriteManga(manga) }
            } label: {
                Label("Open Details", systemImage: "book.fill")
            }
            Divider()
            Button(role: .destructive) {
                Task { await appState.removeFavourite(mangaId: manga.id) }
            } label: {
                Label("Remove from Library", systemImage: "heart.slash")
            }
        }
    }
}
// MARK: - Dark Glass Search Field

@MainActor
struct DarkGlassSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary.opacity(isFocused ? 0.85 : 0.45))
                .animation(.easeOut(duration: 0.18), value: isFocused)

            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.primary.opacity(0.88))
                .focused($isFocused)
                .tint(Color.appAccent.opacity(0.9))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary.opacity(0.35))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(minWidth: 140, idealWidth: 210, maxWidth: 320)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            isFocused ? Color.primary.opacity(0.22) : Color.primary.opacity(0.08),
                            lineWidth: isFocused ? 1.0 : 0.7
                        )
                )
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

// MARK: - FavouriteCard

@MainActor
struct FavouriteCard: View {
    let manga: HelperManga

    @State private var isHovered = false
    private var accentColor: Color {
        Color.appAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            coverStack
            metaStack
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isHovered
                    ? AnyShapeStyle(LinearGradient(
                        colors: [Color.primary.opacity(0.13), Color.primary.opacity(0.07), Color.primary.opacity(0.02)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                      ))
                    : AnyShapeStyle(LinearGradient(
                        colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.05), Color.primary.opacity(0.01)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                      ))
                )
                .overlay(
                    // Faint topLeading accent spot on hover — subtle warmth
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [accentColor.opacity(isHovered ? 0.16 : 0), .clear],
                                center: .topLeading,
                                startRadius: 0,
                                endRadius: 140
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isHovered
                        ? AnyShapeStyle(AngularGradient(
                            stops: [
                                .init(color: accentColor.opacity(0.50), location: 0.0),
                                .init(color: accentColor.opacity(0.12), location: 0.25),
                                .init(color: accentColor.opacity(0.42), location: 0.5),
                                .init(color: accentColor.opacity(0.10), location: 0.75),
                                .init(color: accentColor.opacity(0.50), location: 1.0),
                            ],
                            center: .center
                          ))
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                          )),
                    lineWidth: isHovered ? 1.0 : 0.7
                )
        )
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .shadow(color: accentColor.opacity(isHovered ? 0.35 : 0), radius: 22, y: 8)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: Cover

    private var coverStack: some View {
        ZStack(alignment: .topTrailing) {
            // Base image 2:3 ratio
            AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    CoverPlaceholder(title: manga.title, accent: accentColor)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fill)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            // 5-stop richer bottom vignette
            LinearGradient(
                stops: [
                    .init(color: .clear,                  location: 0.00),
                    .init(color: .clear,                  location: 0.30),
                    .init(color: .black.opacity(0.18),    location: 0.52),
                    .init(color: .black.opacity(0.68),    location: 0.76),
                    .init(color: .black.opacity(0.94),    location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .allowsHitTesting(false)

            // Inner top highlight overlay
            VStack {
                LinearGradient(
                    colors: [Color.white.opacity(0.08), .clear],
                    startPoint: .top,
                    endPoint: .center
                )
                .frame(height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Spacer()
            }
            .allowsHitTesting(false)

            // Heart badge top-right — gradient fill
            Image(systemName: "heart.fill")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .padding(6)
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.pink.opacity(0.95), Color.pink.opacity(0.70)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color.pink.opacity(0.55), radius: 6)
                )
                .padding(8)

            // Reading progress at very bottom of cover area
            if manga.progress > 0 {
                VStack {
                    Spacer()
                    ProgressView(value: Double(manga.progress))
                        .progressViewStyle(.linear)
                        .tint(accentColor)
                        .scaleEffect(y: 0.5)
                        .padding(.horizontal, 0)
                }
            }
        }
    }

    // MARK: Meta

    private var metaStack: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(manga.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if !manga.authors.isEmpty {
                Text(manga.authors[0])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .padding(.top, 6)
    }
}

// MARK: - CoverPlaceholder

@MainActor
struct CoverPlaceholder: View {
    let title: String
    let accent: Color
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Dim base
            accent.opacity(0.28)

            // Aurora — bright accent corner falling off into the dim base
            RadialGradient(
                stops: [
                    .init(color: accent.opacity(0.90), location: 0.0),
                    .init(color: accent.opacity(0.62), location: 0.35),
                    .init(color: accent.opacity(0.30), location: 0.7),
                    .init(color: .clear,               location: 1.0),
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 180
            )

            // Secondary dim accent spot for depth
            RadialGradient(
                stops: [
                    .init(color: accent.opacity(0.34), location: 0.0),
                    .init(color: .clear,               location: 1.0),
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 140
            )

            // Inner glow overlay — radial from center
            RadialGradient(
                colors: [Color.white.opacity(0.12), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 80
            )

            Text(title)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.white.opacity(0.93))
                .padding(10)
                .lineLimit(3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
