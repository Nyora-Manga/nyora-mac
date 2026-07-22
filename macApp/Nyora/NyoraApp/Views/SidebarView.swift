import SwiftUI

enum NavDestination: String, CaseIterable, Identifiable, Hashable {
    case history
    case favourites
    case explore
    case feed
    case browser
    case local
    case bookmarks
    case downloads
    case updates
    case reader
    case stats
    case universalSearch
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history:     return "History"
        case .favourites:  return "Favourites"
        case .explore:     return "Explore"
        case .feed:        return "Feed"
        case .browser:     return "Browser"
        case .local:       return "Local"
        case .bookmarks:   return "Bookmarks"
        case .downloads:   return "Downloads"
        case .updates:     return "Updates"
        case .reader:      return "Reader"
        case .stats:       return "Stats"
        case .universalSearch: return "Search"
        case .settings:    return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .history:     return "clock.arrow.circlepath"
        case .favourites:  return "heart.text.square"
        case .explore:     return "safari"
        case .feed:        return "newspaper"
        case .browser:     return "globe"
        case .local:       return "folder"
        case .bookmarks:   return "bookmark"
        case .downloads:   return "arrow.down.circle"
        case .updates:     return "arrow.triangle.2.circlepath"
        case .reader:      return "book.pages"
        case .stats:       return "chart.bar.xaxis"
        case .universalSearch: return "magnifyingglass"
        case .settings:    return "gearshape"
        }
    }
}
// MARK: - Anime Sidebar Row

@MainActor
private struct AnimeSidebarRow: View {
    let destination: NavDestination
    let isSelected: Bool
    /// Passed in (not read from the static `Color.appAccent`) so a scheme change is an
    /// actual input change — otherwise SwiftUI skips re-running this row's body when only
    /// the accent changes and the selected pill keeps the old colour until the next event.
    let accent: Color
    var badgeCount: Int? = nil
    var badgeIsRed: Bool = false
    var showLive: Bool = false

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            // Left-edge indicator — always-visible bar, opacity-driven
            ZStack(alignment: .leading) {
                // Hover left-edge subtle accent line
                LinearGradient(
                    colors: [Color.appAccent.opacity(0.4), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: 1.5, height: 10)
                .opacity(isHovered && !isSelected ? 1 : 0)
                .animation(.hoverSpring, value: isHovered)

                // Selected 3pt gradient bar. The selected row's background is an
                // accent-tinted glass (RowSelectionGlass), so this sits *on* the accent
                // and must be drawn in the contrasting colour — an accent bar on an
                // accent fill is invisible, as was the accent glow around it.
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.onAccent,
                                Color.onAccent.opacity(0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 3, height: 20)
                    .opacity(isSelected ? 1 : 0)
                    .animation(.hoverSpring, value: isSelected)
            }
            .frame(width: 3)

            // SF Symbol icon — on the accent-tinted selected row it must be the
            // contrasting colour, not the accent itself, or it disappears.
            Image(systemName: destination.systemImage)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.onAccent : Color.secondary)
                .frame(width: 18, height: 18)
                .animation(.hoverSpring, value: isSelected)

            // Title. `.primary` only happened to read here because the accent is dark;
            // a light accent (Yuki) would have put white text on a near-white fill.
            Text(destination.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? Color.onAccent : Color.secondary)
                .animation(.hoverSpring, value: isSelected)

            Spacer()

            // Trailing badge area
            trailingBadge
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .modifier(RowSelectionGlass(isSelected: isSelected, isHovered: isHovered, accent: accent))
        .scaleEffect(isSelected ? 1.0 : (isHovered ? 1.01 : 1.0))
        .animation(.hoverSpring, value: isSelected)
        .animation(.hoverSpring, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: Trailing badge

    @ViewBuilder
    private var trailingBadge: some View {
        if showLive {
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .shadow(color: Color.green.opacity(0.8), radius: 4)
        } else if let count = badgeCount, count > 0 {
            if badgeIsRed {
                Text("\(count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        LinearGradient(
                            colors: [Color.red.opacity(0.95), Color.red.opacity(0.70)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
            } else {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        LinearGradient(
                            colors: [Color.primary.opacity(0.12), Color.primary.opacity(0.07)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
            }
        }
    }

}

// MARK: - Row selection glass

/// Selected rows become an accent-tinted floating glass pill; hovered rows get a
/// subtle fill. Routed through `adaptiveGlass` so reduce-transparency is honoured.
@MainActor
private struct RowSelectionGlass: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let accent: Color

    func body(content: Content) -> some View {
        if isSelected {
            // Explicit accent fill (passed in, not the static Color.appAccent) — the
            // `.interactive()` glass highlight used to pick up the SYSTEM accent, and a
            // static read wouldn't re-render on a scheme change. This guarantees the
            // selection is the user's live scheme colour.
            content
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent)
                )
        } else if isHovered {
            content
                .background(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.08),
                            Color.primary.opacity(0.03)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        } else {
            content
        }
    }
}

// MARK: - Section Header

@MainActor
private struct AnimeSectionHeader: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            // Left accent bar: tri-stop gradient with soft fade tail
            LinearGradient(
                colors: [
                    Color.appAccent.opacity(0.9),
                    Color.appAccent.opacity(0.3),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 1.5, height: 16)

            Text(title.uppercased())
                .font(.caption2.bold())
                .tracking(1.8)
                .foregroundStyle(Color.secondary.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}
// MARK: - Gradient Section Divider

@MainActor
private struct SectionDivider: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, Color.primary.opacity(0.12), .clear],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(height: 0.5)
        .padding(.vertical, 4)
    }
}
// MARK: - Sidebar View

@MainActor
struct SidebarView: View {
    @Binding var selection: NavDestination
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // NYORA branding header
            HStack {
                Text("NYORA")
                    .font(.caption.bold().monospaced())
                    .tracking(4)
                    .foregroundStyle(Color.secondary)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Thin gradient divider below brand
            LinearGradient(
                colors: [.clear, Color.primary.opacity(0.12), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.5)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 2) {
                    // LIBRARY section
                    if hasLibraryItems {
                        AnimeSectionHeader(title: "Library")
                        if isEnabled(.history)    { row(.history) }
                        if isEnabled(.favourites) { row(.favourites) }
                        if isEnabled(.local)      { row(.local) }
                        if isEnabled(.bookmarks)  { row(.bookmarks) }
                        if isEnabled(.downloads)  { row(.downloads) }
                    }

                    // Divider between LIBRARY and DISCOVER
                    if hasLibraryItems && hasDiscoverItems {
                        SectionDivider()
                    }

                    // DISCOVER section
                    if hasDiscoverItems {
                        AnimeSectionHeader(title: "Discover")
                        if isEnabled(.explore)     { row(.explore) }
                        if isEnabled(.feed)        { row(.feed) }
                        if isEnabled(.updates)     { row(.updates) }
                        if isEnabled(.browser)     { row(.browser) }
                    }

                    // Divider between DISCOVER and READING
                    if hasDiscoverItems && hasReadingItems {
                        SectionDivider()
                    }

                    // READING section
                    if hasReadingItems {
                        AnimeSectionHeader(title: "Reading")
                        if isEnabled(.reader) { row(.reader) }
                        if isEnabled(.stats)  { row(.stats) }
                        if isEnabled(.universalSearch) { row(.universalSearch) }
                    }

                    // Divider before APP
                    if hasReadingItems {
                        SectionDivider()
                    }

                    // APP section
                    AnimeSectionHeader(title: "App")
                    row(.settings)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        // Sidebar column adopts Liquid Glass automatically in NavigationSplitView
        // on macOS 26 — leave it material-free and DON'T add backgroundExtensionEffect
        // (that mirrored the edges and made the sidebar look like a bordered card).
    }

    // MARK: - Logic

    private var hasLibraryItems: Bool {
        isEnabled(.history) || isEnabled(.favourites) || isEnabled(.local) || isEnabled(.bookmarks) || isEnabled(.downloads)
    }

    private var hasDiscoverItems: Bool {
        isEnabled(.explore) || isEnabled(.feed) || isEnabled(.updates) || isEnabled(.browser)
    }

    private var hasReadingItems: Bool {
        isEnabled(.reader) || isEnabled(.stats) || isEnabled(.universalSearch)
    }

    private func isEnabled(_ dest: NavDestination) -> Bool {
        appState.readerPrefs.enabledNavItems.contains(dest.rawValue)
    }

    private func row(_ destination: NavDestination) -> some View {
        // A tap gesture, NOT a Button: a Button inside the sidebar ScrollView joins AppKit's
        // responder chain, so on every selection change AppKit auto-scrolled the ScrollView to
        // reveal the focused control — which yanked the whole sidebar up (the selected row
        // jumped under the titlebar) and left scrolling stuck. A plain tappable row has no
        // scroll-to-visible behaviour, so the sidebar stays put.
        AnimeSidebarRow(
            destination: destination,
            isSelected: selection == destination,
            accent: appState.readerPrefs.effectiveAccentColor,
            badgeCount: badgeCount(for: destination),
            badgeIsRed: destination == .updates,
            showLive: destination == .reader && appState.activeChapter != nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selection = destination
        }
    }

    private func badgeCount(for destination: NavDestination) -> Int? {
        switch destination {
        case .updates:
            let count = appState.updates.count
            return count > 0 ? count : nil
        case .bookmarks:
            let count = appState.bookmarks.count
            return count > 0 ? count : nil
        default:
            return nil
        }
    }
}
