import SwiftUI
import AppKit
import CoreSpotlight
import GoogleSignIn

@main
@MainActor
struct NyoraApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(NyoraAppDelegate.self) private var appDelegate

    init() {
        // Wire the delegate to the appState so it can shut down the helper on quit.
        // (The adaptor instance and our @StateObject are separate; we lift the
        // reference through a static so termination has access without ordering issues.)
        NyoraAppDelegate.shutdownHook = nil // reset between hot reloads
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .frame(minWidth: 820, minHeight: 560)
                .task {
                    NyoraAppDelegate.shutdownHook = { [appState] in
                        await appState.shutdownHelper()
                    }
                    await appState.bootstrap()
                    // Initial Spotlight index once library data is loaded.
                    appState.reindexSpotlight()
                }
                .onOpenURL { url in
                    if GIDSignIn.sharedInstance.handle(url) {
                        return
                    }
                    appState.handleDeepLink(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String {
                        Task {
                            await appState.openMangaById(id.replacingOccurrences(of: "nyora.manga.", with: ""))
                        }
                    }
                }
                .sheet(isPresented: Binding(
                    get: { appState.inAppBrowserURL != nil },
                    set: { if !$0 { appState.inAppBrowserURL = nil } })) {
                    if let u = appState.inAppBrowserURL { InAppWebSheet(url: u) }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentSize)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Sources") {
                    Task { await appState.refreshSources() }
                }
                .keyboardShortcut("r")

                Divider()

                Button("Global Search…") {
                    appState.isGlobalSearchPresented = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

@MainActor
final class NyoraAppDelegate: NSObject, NSApplicationDelegate {
    static var shutdownHook: (() async -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if UserDefaults.standard.bool(forKey: "nyora.app.exitConfirm") {
            let alert = NSAlert()
            alert.messageText = "Quit Nyora?"
            alert.informativeText = "Are you sure you want to exit?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }
        
        guard let hook = NyoraAppDelegate.shutdownHook else { return .terminateNow }
        NyoraAppDelegate.shutdownHook = nil
        Task { @MainActor in
            await hook()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
