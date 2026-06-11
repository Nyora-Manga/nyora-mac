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

                // Selected 3pt tri-color gradient bar
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.appAccent,
                                Color.appAccent.opacity(0.55)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(
                        color: Color.appAccent.opacity(isSelected ? 0.80 : 0.0),
                        radius: isSelected ? 9 : 0
                    )
                    .frame(width: 3, height: 20)
                    .opacity(isSelected ? 1 : 0)
                    .animation(.hoverSpring, value: isSelected)
            }
            .frame(width: 3)

            // SF Symbol icon
            Image(systemName: destination.systemImage)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(isSelected ? Color.appAccent : Color.secondary)
                .shadow(
                    color: isSelected ? Color.appAccent.opacity(0.80) : .clear,
                    radius: isSelected ? 9 : 0
                )
                .frame(width: 18, height: 18)
                .animation(.hoverSpring, value: isSelected)

            // Title
            Text(destination.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular, design: .rounded))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .animation(.hoverSpring, value: isSelected)

            Spacer()

            // Trailing badge area
            trailingBadge
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        // 2-layer selected shadow: near (accent) + far (purple haze)
        .shadow(
            color: isSelected ? Color.appAccent.opacity(0.20) : .clear,
            radius: isSelected ? 10 : 0,
            y: isSelected ? 4 : 0
        )
        .shadow(
            color: isSelected ? Color.appAccent.opacity(0.10) : .clear,
            radius: isSelected ? 18 : 0,
            y: isSelected ? 6 : 0
        )
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

    // MARK: Row background

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            ZStack {
                // Base accent sweep leading -> trailing
                LinearGradient(
                    colors: [
                        Color.appAccent.opacity(0.28),
                        Color.appAccent.opacity(0.12),
                        Color.clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                // Aurora glow spot anchored at the leading edge for organic depth
                RadialGradient(
                    colors: [
                        Color.appAccent.opacity(0.30),
                        Color.appAccent.opacity(0.10),
                        .clear
                    ],
                    center: .leading,
                    startRadius: 0,
                    endRadius: 80
                )
            }
        } else if isHovered {
            LinearGradient(
                colors: [
                    Color.primary.opacity(0.08),
                    Color.primary.opacity(0.03)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.clear
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
    @Environment(\.colorScheme) private var colorScheme

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
        .background(
            ZStack {
                Color(.windowBackgroundColor)
                if colorScheme == .dark {
                    // Aurora spot 1 — bright accent anchored topLeading, eased falloff
                    RadialGradient(
                        colors: [
                            appState.activeCoverAccentPrimary.opacity(0.14),
                            appState.activeCoverAccentPrimary.opacity(0.07),
                            Color.appAccent.opacity(0.03),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 320
                    )
                    // Aurora spot 2 — dimmer accent pool anchored bottomTrailing
                    RadialGradient(
                        colors: [
                            Color.appAccent.opacity(0.07),
                            Color.appAccent.opacity(0.03),
                            .clear
                        ],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: 240
                    )
                }
            }
            .animation(.easeInOut(duration: 0.8), value: appState.activeCoverAccentPrimary)
            .ignoresSafeArea()
        )
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
        Button {
            selection = destination
        } label: {
            AnimeSidebarRow(
                destination: destination,
                isSelected: selection == destination,
                badgeCount: badgeCount(for: destination),
                badgeIsRed: destination == .updates,
                showLive: destination == .reader && appState.activeChapter != nil
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
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
