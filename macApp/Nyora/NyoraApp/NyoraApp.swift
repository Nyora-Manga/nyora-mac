import SwiftUI
import AppKit
import CoreSpotlight

@main
@MainActor
struct NyoraApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(NyoraAppDelegate.self) private var appDelegate

    init() {
        // Size the shared URL cache up-front. macOS's default `URLCache.shared`
        // is small (a few MB), so large reader page images get evicted almost
        // immediately — defeating the reader's page prefetch (see
        // AppState.prefetchReaderPages / prefetchNextChapter) and forcing
        // re-downloads when revisiting a page. Page/cover fetches all go through
        // URLSession.shared, which reads this cache. Conservative sizing:
        // 256 MB in memory, 1 GB on disk. Set once at launch, before any fetch.
        // (Settings cache-usage UI in PlaceholderViews reads URLCache.shared and
        // will reflect these limits.)
        URLCache.shared = URLCache(
            memoryCapacity: 256 * 1024 * 1024,
            diskCapacity: 1024 * 1024 * 1024,
            diskPath: nil
        )

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
        // The system title is hidden so RootView can draw its own accent-coloured pane
        // title in the toolbar (macOS gives no way to recolour the built-in title text).
        .windowToolbarStyle(.unified(showsTitle: false))
        // .contentMinSize (not .contentSize): the window must be free to grow to
        // fill the display in macOS full-screen / zoom. .contentSize pins it to the
        // ideal content size, which is what made full-screen misbehave.
        .windowResizability(.contentMinSize)
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
