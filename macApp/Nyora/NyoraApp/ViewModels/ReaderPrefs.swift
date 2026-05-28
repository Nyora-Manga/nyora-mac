import Foundation
import SwiftUI

@MainActor
final class ReaderPrefs: ObservableObject {
    @Published var defaultReaderMode: String = UserDefaults.standard.string(forKey: Keys.defaultMode) ?? "paged" {
        didSet { UserDefaults.standard.set(defaultReaderMode, forKey: Keys.defaultMode) }
    }

    @Published var historyRetentionDays: Int = (UserDefaults.standard.object(forKey: Keys.retentionDays) as? Int) ?? 90 {
        didSet { UserDefaults.standard.set(historyRetentionDays, forKey: Keys.retentionDays) }
    }

    @Published var prefetchNextPages: Bool = (UserDefaults.standard.object(forKey: Keys.prefetchNext) as? Bool) ?? true {
        didSet { UserDefaults.standard.set(prefetchNextPages, forKey: Keys.prefetchNext) }
    }

    @Published var nsfwFilter: Bool = UserDefaults.standard.bool(forKey: Keys.nsfwFilter) {
        didSet { UserDefaults.standard.set(nsfwFilter, forKey: Keys.nsfwFilter) }
    }

    private enum Keys {
        static let defaultMode = "nyora.reader.defaultMode"
        static let retentionDays = "nyora.history.retentionDays"
        static let prefetchNext = "nyora.reader.prefetchNext"
        static let nsfwFilter = "nyora.library.nsfwFilter"
    }
}
