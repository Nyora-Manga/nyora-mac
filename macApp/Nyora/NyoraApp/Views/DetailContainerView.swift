import SwiftUI

struct DetailContainerView: View {
    let destination: NavDestination

    var body: some View {
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
