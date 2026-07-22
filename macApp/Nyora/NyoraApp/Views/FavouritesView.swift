import SwiftUI
// MARK: - FavouritesView

@MainActor
struct FavouritesView: View {
    @EnvironmentObject var appState: AppState

    private var filtered: [HelperManga] {
        let q = appState.libraryQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return appState.favourites }
        return appState.favourites.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                EmptyStateView(
                    icon: "heart",
                    title: appState.libraryQuery.isEmpty ? "No favourites yet" : "No results",
                    message: appState.libraryQuery.isEmpty
                        ? "Tap the heart on any manga's details to add it here."
                        : "Try a different search term."
                )
            } else {
                listContent
            }
        }
        .searchable(text: $appState.libraryQuery, prompt: "Search favourites")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await appState.reloadFavourites() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    // MARK: List

    private var listContent: some View {
        List {
            ForEach(filtered, id: \.id) { manga in
                FavouriteRow(manga: manga)
                    .contentShape(Rectangle())
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
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        // Let the window glass/vibrancy show through in glass mode (parity with the
        // other panes); harmless in flat mode where the window is opaque.
        .scrollContentBackground(.hidden)
    }
}

// MARK: - FavouriteRow

@MainActor
/// A favourite as a full-width list row — small 2:3 cover thumbnail, title,
/// author, and reading progress. Mirrors the History / Bookmarks list feel.
struct FavouriteRow: View {
    let manga: HelperManga
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: manga.coverUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    CoverPlaceholder(title: manga.title, accent: .appAccent)
                }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fill)
            .frame(width: 46, height: 69)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(manga.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                if !manga.authors.isEmpty {
                    Text(manga.authors[0])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if manga.progress > 0 {
                    ProgressView(value: Double(manga.progress))
                        .progressViewStyle(.linear)
                        .tint(.appAccent)
                        .frame(maxWidth: 200)
                        .scaleEffect(y: 0.6)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.06 : 0))
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - FavouriteCard

@MainActor
/// A favourite as a stock grid cell — cover, title, author. The card carries no
/// surface of its own: no hover gradient, conic border, drop shadow, glow or
/// scale. The cover art is the content; the system supplies everything else.
struct FavouriteCard: View {
    let manga: HelperManga

    private var accentColor: Color {
        Color.appAccent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            coverStack
            metaStack
        }
        .contentShape(Rectangle())
    }

    // MARK: Cover

    private var coverStack: some View {
        ZStack(alignment: .bottom) {
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
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // Reading progress at the bottom of the cover — the accent stays,
            // but only as a tint on a stock ProgressView.
            if manga.progress > 0 {
                ProgressView(value: Double(manga.progress))
                    .progressViewStyle(.linear)
                    .tint(accentColor)
                    .scaleEffect(y: 0.5)
            }
        }
    }

    // MARK: Meta

    private var metaStack: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(manga.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)

            if !manga.authors.isEmpty {
                Text(manga.authors[0])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - CoverPlaceholder

@MainActor
/// Neutral, system-material artwork placeholder — the way Apple's own apps (Music, Books,
/// TV) show missing cover art: a quaternary fill with a single tertiary SF Symbol, no
/// colour, no text (the title is already shown beneath the cover). `accent`/`title` are
/// kept for call-site compatibility but intentionally unused.
struct CoverPlaceholder: View {
    let title: String
    let accent: Color
    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: "book.closed")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tertiary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
