import Foundation
import WebKit
import AppKit

/// Solves Cloudflare challenges for the headless JVM helper.
///
/// The helper fetches sites with plain OkHttp and can't run challenge JS, so a
/// protected source returns `Cloudflare challenge: <host>`. This loads the site in a
/// WKWebView (which DOES run the challenge), waits for the `cf_clearance` cookie, and
/// returns it as a `Cookie:` header string. The bridge then POSTs it to the helper's
/// `/cloudflare/clearance` endpoint and retries the request.
///
/// Two-phase solve:
///   1. **Passive** — a hidden, off-screen WebView. Cloudflare's plain JS challenge
///      ("Just a moment…") clears itself within a few seconds with no user action.
///   2. **Interactive** — if the passive phase doesn't clear, the challenge is a
///      Turnstile checkbox or a "managed challenge" that REQUIRES a human click. We
///      surface the same WebView in a real, focused window so the user can complete
///      it, then capture the resulting `cf_clearance`. Previously this case timed out
///      and the request was rejected.
///
/// Critical: the WebView must use the SAME User-Agent the helper sends (Chrome 115,
/// `NYORA_BROWSER_UA` on the Kotlin side), because `cf_clearance` is bound to the UA
/// (and IP) that solved it.
@MainActor
final class MacCloudflareSolver: NSObject, NSWindowDelegate {
    static let shared = MacCloudflareSolver()

    /// Must match `NYORA_BROWSER_UA` (Kotlin) byte-for-byte.
    private static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36"

    private var webView: WKWebView?
    private var hiddenWindow: NSWindow?
    private var interactiveWindow: NSWindow?
    private var inFlight: Set<String> = []
    private var userCancelled = false

    /// How long to wait for a hands-free clear before showing the window to the user.
    private let passiveTimeout: TimeInterval = 8
    /// How long to give the user to complete an interactive challenge.
    private let interactiveTimeout: TimeInterval = 180
    private let pollInterval: UInt64 = 500_000_000  // 0.5s

    /// Loads `https://host/` in a WebView and returns a `name=value; …` cookie header
    /// once `cf_clearance` is present. Auto-solves passive challenges silently; for
    /// interactive challenges it presents a focused window and waits for the user.
    /// Returns nil only if the user cancels or the interactive window times out.
    func solve(host: String) async -> String? {
        guard !inFlight.contains(host), let url = URL(string: "https://\(host)/") else { return nil }
        inFlight.insert(host)
        userCancelled = false
        defer {
            inFlight.remove(host)
            dismissInteractiveWindow()
        }

        let wv = ensureWebView()
        wv.customUserAgent = Self.userAgent
        wv.load(URLRequest(url: url))

        // Phase 1 — passive: most "Just a moment…" challenges clear on their own.
        if let header = await poll(host: host, timeout: passiveTimeout) {
            return header
        }

        // Phase 2 — interactive: still challenged, so a human must act. Show the WebView.
        presentInteractiveWindow(host: host, webView: wv)
        if let header = await poll(host: host, timeout: interactiveTimeout) {
            return header
        }
        return await clearanceHeader(for: host)
    }

    /// Polls the cookie store until `cf_clearance` appears, the user cancels, or the
    /// timeout elapses.
    private func poll(host: String, timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if userCancelled { return nil }
            try? await Task.sleep(nanoseconds: pollInterval)
            if let header = await clearanceHeader(for: host) { return header }
        }
        return nil
    }

    private func ensureWebView() -> WKWebView {
        if let wv = webView { return wv }
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // persistent — reuse clearance across solves
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 600), configuration: cfg)
        wv.customUserAgent = Self.userAgent
        // A WKWebView must live in a window for the challenge's JS timers/rendering to
        // run. During the passive phase it sits in an off-screen, never-shown window.
        let win = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 480, height: 600),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = wv
        win.orderOut(nil)
        hiddenWindow = win
        webView = wv
        return wv
    }

    /// Reparents the live WebView into a visible, focused window with a short
    /// instruction banner so the user can complete the challenge.
    private func presentInteractiveWindow(host: String, webView wv: WKWebView) {
        guard interactiveWindow == nil else { return }

        let width: CGFloat = 480, height: CGFloat = 640, bannerH: CGFloat = 44
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let banner = NSTextField(labelWithString:
            "Complete the verification for \(host) to continue. This window closes automatically once you pass.")
        banner.frame = NSRect(x: 12, y: height - bannerH + 6, width: width - 24, height: bannerH - 12)
        banner.font = .systemFont(ofSize: 12)
        banner.textColor = .secondaryLabelColor
        banner.lineBreakMode = .byWordWrapping
        banner.maximumNumberOfLines = 2
        banner.autoresizingMask = [.width, .minYMargin]

        wv.removeFromSuperview()
        wv.frame = NSRect(x: 0, y: 0, width: width, height: height - bannerH)
        wv.autoresizingMask = [.width, .height]

        container.addSubview(wv)
        container.addSubview(banner)

        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Verify you're human — \(host)"
        win.isReleasedWhenClosed = false
        win.contentView = container
        win.delegate = self
        win.level = .floating
        win.center()

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        interactiveWindow = win
    }

    /// Tears down the interactive window and parks the WebView back off-screen so the
    /// next solve can reuse it (and its persistent cookie store).
    private func dismissInteractiveWindow() {
        guard let win = interactiveWindow else { return }
        if let wv = webView {
            wv.removeFromSuperview()
            wv.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
            wv.autoresizingMask = []
            hiddenWindow?.contentView = wv
            hiddenWindow?.orderOut(nil)
        }
        win.delegate = nil
        win.orderOut(nil)
        interactiveWindow = nil
    }

    private func clearanceHeader(for host: String) async -> String? {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return nil }
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let relevant = cookies.filter { matches(host: host, cookieDomain: $0.domain) }
        guard relevant.contains(where: { $0.name == "cf_clearance" }) else { return nil }
        return relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func matches(host: String, cookieDomain: String) -> Bool {
        let d = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == d || host.hasSuffix("." + d) || d.hasSuffix(host)
    }

    // MARK: NSWindowDelegate

    /// User closed the verification window without passing → cancel the solve so the
    /// awaiting request fails fast instead of hanging until the interactive timeout.
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === interactiveWindow {
            userCancelled = true
        }
    }
}
