import SwiftUI

struct DetailContainerView: View {
    let destination: NavDestination

    var body: some View {
        // Every pane is wrapped in a GeometryReader — the same stabilizer ExploreView uses.
        // It pins the detail content to a fixed, full-size frame so selecting a pane can't make
        // the window auto-scroll the sidebar up (which happened on Local/Downloads/Updates and
        // any pane whose content didn't itself fill the space like Explore's does).
        GeometryReader { _ in
            Group {
                switch destination {
                case .history: HistoryView()
                case .favourites: FavouritesView()
                case .explore: ExploreView()
                case .browser: BrowserView()
                case .feed: FeedView()
                case .local: LocalView()
                case .bookmarks: BookmarksView()
                case .downloads: DownloadsView()
                case .updates: UpdatesView()
                case .reader: ReaderView()
                case .universalSearch: UniversalSearchView()
                case .stats: StatsView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
