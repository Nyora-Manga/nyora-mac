import Foundation
import SwiftUI
import Security

/// Tracker integration settings backed by Keychain (token) + UserDefaults
/// (enabled flag, last linked media ids). Keychain storage means the token
/// survives app reinstalls and is never written to backup JSON.
///
/// Right now only AniList is wired. MAL/Kitsu/Shikimori can be added in the
/// same shape — each backend gets a separate keychain account + endpoint.
@MainActor
final class TrackerSettings: ObservableObject {
    @Published var anilistEnabled: Bool {
        didSet { Self.ud.set(anilistEnabled, forKey: Keys.anilistEnabled) }
    }
    @Published var anilistToken: String {
        didSet {
            if anilistToken.isEmpty {
                Self.keychainDelete(account: Keys.anilistAccount)
            } else {
                Self.keychainSet(account: Keys.anilistAccount, value: anilistToken)
            }
        }
    }
    /// `mangaId -> anilist media id`. Lets the reader scrobble without
    /// re-searching every time.
    @Published var anilistLinks: [String: Int] {
        didSet {
            if let data = try? JSONEncoder().encode(anilistLinks) {
                Self.ud.set(data, forKey: Keys.anilistLinks)
            }
        }
    }

    init() {
        anilistEnabled = Self.ud.bool(forKey: Keys.anilistEnabled)
        anilistToken = Self.keychainGet(account: Keys.anilistAccount) ?? ""
        if let data = Self.ud.data(forKey: Keys.anilistLinks),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            anilistLinks = dict
        } else {
            anilistLinks = [:]
        }
    }

    var isConfigured: Bool {
        anilistEnabled && !anilistToken.isEmpty
    }

    // MARK: - Keychain helpers

    private static func keychainSet(account: String, value: String) {
        let data = Data(value.utf8)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.nyora.tracker",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func keychainGet(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.nyora.tracker",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8)
        else { return nil }
        return str
    }

    private static func keychainDelete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.nyora.tracker",
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }

    private static let ud = UserDefaults.standard
    private enum Keys {
        static let anilistEnabled = "nyora.tracker.anilist.enabled"
        static let anilistAccount = "anilist.personal.token"
        static let anilistLinks = "nyora.tracker.anilist.links"
    }
}
