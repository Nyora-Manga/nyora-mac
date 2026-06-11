import Foundation
import GoogleSignIn
import AppKit

enum SupabaseGoogleAuthHelper {

    static let appClientID = "181067068545-9jkcbv6cb552jvmn6o3rdk87m2195g7n.apps.googleusercontent.com"
    static let defaultServerClientID = "181067068545-4jkfesn716ucqbuhcbtvdtlqfg3ar38u.apps.googleusercontent.com"
    @MainActor private static var isSignInInFlight = false

    enum SignInResult {
        case success(String)
        case cancelled
        case failure(String)
    }

    @MainActor
    static func signIn(serverClientID: String) async -> SignInResult {
        guard !isSignInInFlight else {
            return .failure("Google sign-in is already in progress.")
        }

        guard let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            return .failure("No active Nyora window for Google sign-in.")
        }

        isSignInInFlight = true
        defer { isSignInInFlight = false }

        let clientID = (Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? appClientID
        let serverClientID = serverClientID.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? defaultServerClientID
        let config = GIDConfiguration(clientID: clientID, serverClientID: serverClientID)
        GIDSignIn.sharedInstance.configuration = config

        NSApplication.shared.activate(ignoringOtherApps: true)

        return await withCheckedContinuation { continuation in
            let box = GoogleSignInContinuationBox(continuation)
            box.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                box.resume(.failure("Google sign-in timed out before Google returned a token."))
            }

            GIDSignIn.sharedInstance.signIn(withPresenting: window) { result, error in
                box.timeoutTask?.cancel()
                if let error = error {
                    let nsError = error as NSError
                    if nsError.code == -5 {
                        Task { @MainActor in box.resume(.cancelled) }
                    } else {
                        let message = "\(error.localizedDescription) (Code: \(nsError.code))"
                        print("Google Sign-In error: \(message)")
                        Task { @MainActor in box.resume(.failure(message)) }
                    }
                    return
                }

                guard let idToken = result?.user.idToken?.tokenString, !idToken.isEmpty else {
                    Task { @MainActor in box.resume(.failure("Google returned no ID token.")) }
                    return
                }
                Task { @MainActor in box.resume(.success(idToken)) }
            }
        }
    }

    @MainActor
    static func signIn(clientID: String = appClientID, serverClientID: String) async -> String? {
        let result = await signIn(serverClientID: serverClientID)
        if case let .success(idToken) = result {
            return idToken
        }
        return nil
    }
}

@MainActor
private final class GoogleSignInContinuationBox {
    private var continuation: CheckedContinuation<SupabaseGoogleAuthHelper.SignInResult, Never>?
    var timeoutTask: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<SupabaseGoogleAuthHelper.SignInResult, Never>) {
        self.continuation = continuation
    }

    func resume(_ result: SupabaseGoogleAuthHelper.SignInResult) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        continuation.resume(returning: result)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
