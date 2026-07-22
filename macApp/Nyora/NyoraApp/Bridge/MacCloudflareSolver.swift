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

    /// A REAL Safari-on-macOS UA — critically, one consistent with WKWebView's actual
    /// engine. A spoofed Chrome UA makes Cloudflare expect `sec-ch-ua` client hints that
    /// WebKit never sends, so a `fetch()` to a WAF-guarded endpoint (admin-ajax.php) is
    /// scored as a bot and re-challenged even with a valid clearance. A genuine Safari
    /// identity has no such inconsistency. The relay fetches run inside this same WebView,
    /// so its UA is what Cloudflare sees end-to-end.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4.1 Safari/605.1.15"

    private var webView: WKWebView?
    private var hiddenWindow: NSWindow?
    private var interactiveWindow: NSWindow?
    private var pending: [String: Task<String?, Never>] = [:]
    private var userCancelled = false

    /// How long to wait for a hands-free clear before showing the window to the user.
    private let passiveTimeout: TimeInterval = 8
    /// How long to give the user to complete an interactive challenge.
    private let interactiveTimeout: TimeInterval = 180
    private let pollInterval: UInt64 = 500_000_000  // 0.5s

    /// Loads `https://host/` in a WebView and returns a `name=value; …` cookie header
    /// once `cf_clearance` is present. Auto-solves passive challenges silently; for
    /// interactive challenges it presents a focused window and waits for the user.
    ///
    /// Concurrent solves for the same host are COALESCED: browse often fires several
    /// requests to a source at once, and each 403 asks to solve. Without coalescing the
    /// first took the slot and every other caller got an immediate nil — surfacing a
    /// "Browse failed" toast while a solve was still running. Now they all await the one
    /// solve and share its clearance.
    func solve(host: String) async -> String? {
        if let existing = pending[host] {
            return await existing.value
        }
        let task = Task<String?, Never> { [weak self] in
            await self?.performSolve(host: host) ?? nil
        }
        pending[host] = task
        let result = await task.value
        pending[host] = nil
        return result
    }

    private func performSolve(host: String) async -> String? {
        Self.diag("performSolve start host=\(host)")
        guard let url = URL(string: "https://\(host)/") else { Self.diag("bad url \(host)"); return nil }
        userCancelled = false
        defer { dismissInteractiveWindow() }

        let wv = ensureWebView()
        wv.customUserAgent = Self.userAgent
        // Clear any existing clearance/challenge cookies for this host FIRST. The data
        // store is persistent, so without this the passive poll instantly finds a stale
        // cf_clearance from a previous solve (possibly expired) and returns it without ever
        // re-running the challenge — which is then rejected on retry. Forcing a clean slate
        // makes the WebView actually solve fresh.
        await clearChallengeCookies(for: host)
        wv.load(URLRequest(url: url))
        Self.diag("cleared cookies + loaded \(url), starting passive poll")

        // Phase 1 — detect INSTANTLY whether this needs a human, android-style. A CF
        // challenge page is titled "Just a moment…"; the moment we see that title we stop
        // waiting and show the window (no fixed 8s stall). A simple JS challenge instead
        // navigates to the real page — its title changes and cf_clearance appears — so we
        // return silently without ever showing a window.
        if let header = await waitForAutoSolveOrChallenge(host: host) {
            Self.diag("AUTO-solved host=\(host) ua=\(Self.userAgent)")
            return header
        }
        Self.diag("challenge needs interaction host=\(host), presenting window immediately")

        // Phase 2 — interactive: still challenged, so a human must act. Show the WebView and
        // WAIT for the USER to close the window. A managed challenge can set an interim
        // cf_clearance mid-verification; auto-closing on the first cookie captured that
        // half-baked clearance (which Cloudflare then rejected). Letting the user finish the
        // whole challenge and close the window themselves means we capture the FINAL cookies.
        presentInteractiveWindow(host: host, webView: wv)
        Self.diag("interactive window presented=\(interactiveWindow != nil) host=\(host) — waiting for manual close")
        await waitForWindowClose(timeout: interactiveTimeout)
        let header = await clearanceHeader(for: host)
        Self.diag("solve after close host=\(host) result=\(header != nil ? "clearance" : "nil")")
        if let header { Self.diag("FULLCOOKIE \(host) :: \(header)") }
        return header
    }

    private var closeContinuation: CheckedContinuation<Void, Never>?

    /// Suspends until the user closes the interactive window (windowWillClose) or the safety
    /// timeout elapses. This is what makes cookie capture happen on manual close, not on the
    /// first interim clearance.
    private func waitForWindowClose(timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            closeContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resumeClose()
            }
        }
    }

    private func resumeClose() {
        closeContinuation?.resume()
        closeContinuation = nil
    }

    /// Append-only diagnostic log so the CF solve flow can be observed in a packaged
    /// build (stdout is not visible when launched via `open`). Read /tmp/nyora-cf.log.
    nonisolated static func diag(_ message: String) {
        let line = "[cf] \(message)\n"
        let path = "/tmp/nyora-cf.log"
        if let data = line.data(using: .utf8) {
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Returns instantly once we can tell whether this challenge needs a human:
    /// - returns a clearance header if a simple JS challenge auto-cleared (no window needed);
    /// - returns nil the moment the CF challenge page ("Just a moment…"/Turnstile) is up, so
    ///   the caller shows the interactive window immediately instead of stalling.
    /// A short cap bounds the wait if the page is slow to render either outcome.
    private func waitForAutoSolveOrChallenge(host: String) async -> String? {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            let title = (webView?.title ?? "").lowercased()
            // Challenge page detected → needs interaction, show the window now.
            if title.contains("just a moment") || title.contains("attention required") ||
                title.contains("verifying") || title.contains("verify you are human") {
                return nil
            }
            // Real page title present AND clearance set → auto-solved silently.
            if !title.isEmpty, let header = await clearanceHeader(for: host) {
                return header
            }
        }
        return nil
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
        // Ephemeral (in-memory) store: the persistent default store survived across solves
        // AND app restarts, so it kept handing back a long-expired cf_clearance instead of
        // ever re-solving. Ephemeral starts clean each launch; combined with the pre-solve
        // data nuke below, every solve runs the challenge fresh.
        cfg.websiteDataStore = .nonPersistent()
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
            "Complete the verification for \(host), then CLOSE this window to continue.")
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

    /// Nuke ALL site data (cookies AND the HTTP cache) before a solve so the challenge
    /// re-runs from a clean slate. Clearing only cookies was not enough — WKWebView served
    /// a cached challenge-passed page, returning the same stale cf_clearance every time.
    private func clearChallengeCookies(for host: String) async {
        guard let store = webView?.configuration.websiteDataStore else { return }
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    private func clearanceHeader(for host: String) async -> String? {
        guard let store = webView?.configuration.websiteDataStore.httpCookieStore else { return nil }
        let cookies: [HTTPCookie] = await withCheckedContinuation { cont in
            store.getAllCookies { cont.resume(returning: $0) }
        }
        let relevant = cookies.filter { matches(host: host, cookieDomain: $0.domain) }
        guard relevant.contains(where: { $0.name == "cf_clearance" }) else { return nil }
        // Send only the persistent clearance/bot-management cookies. cf_chl_* are
        // transient challenge-in-progress cookies — a real browser drops them once
        // cleared, and echoing them back makes Cloudflare restart the challenge.
        let keep = relevant.filter { !$0.name.hasPrefix("cf_chl") }
        return keep.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// Fetch a URL THROUGH the WebView session that solved the challenge. cf_clearance is
    /// bound to that browser session (verified: no external client — OkHttp or even
    /// curl-impersonate with any JA3 — can replay it), so the only way to use it is to let
    /// the browser itself make the request. Same-origin `fetch()` on the solved page carries
    /// the clearance + WebKit TLS that Cloudflare accepts. This is the macOS equivalent of
    /// android routing its WebView requests through the shared network client.
    /// Returns (status, headers, body) or nil on failure.
    func fetchViaWebView(url: String, method: String, headers: [String: String], bodyBase64: String?) async -> (Int, [String: String], Data)? {
        guard let wv = webView else { return nil }
        let hdrsJSON: String = (try? String(data: JSONSerialization.data(withJSONObject: headers), encoding: .utf8)) ?? "{}"
        // callAsyncJavaScript awaits the promise (evaluateJavaScript would return the
        // unresolved promise object). Read the body as bytes → base64 so binary (images)
        // survives the JS→Swift string boundary. A request body (POST admin-ajax) is passed
        // in as base64 and decoded to a Uint8Array — GET must not carry a body.
        let body = """
        const opts = { method: method, headers: JSON.parse(hdrs), credentials: 'include', redirect: 'follow' };
        if (reqBody && method !== 'GET' && method !== 'HEAD') {
            opts.body = Uint8Array.from(atob(reqBody), c => c.charCodeAt(0));
        }
        const r = await fetch(url, opts);
        const buf = new Uint8Array(await r.arrayBuffer());
        let bin = '';
        const chunk = 0x8000;
        for (let i = 0; i < buf.length; i += chunk) { bin += String.fromCharCode.apply(null, buf.subarray(i, i + chunk)); }
        const h = {}; r.headers.forEach((v, k) => { h[k] = v; });
        return JSON.stringify({ status: r.status, headers: h, body: btoa(bin) });
        """
        let raw: Any?
        do {
            raw = try await wv.callAsyncJavaScript(
                body,
                arguments: ["url": url, "method": method, "hdrs": hdrsJSON, "reqBody": bodyBase64 ?? ""],
                contentWorld: .page,
            )
        } catch {
            Self.diag("relay fetch JS error url=\(url): \(error)")
            return nil
        }
        guard let json = raw as? String,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? Int,
              let b64 = obj["body"] as? String,
              let bodyData = Data(base64Encoded: b64) else {
            Self.diag("relay fetch bad response url=\(url)")
            return nil
        }
        let respHeaders = (obj["headers"] as? [String: String]) ?? [:]
        return (status, respHeaders, bodyData)
    }

    private func matches(host: String, cookieDomain: String) -> Bool {
        let d = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == d || host.hasSuffix("." + d) || d.hasSuffix(host)
    }

    // MARK: NSWindowDelegate

    /// The user closed the verification window — they're done, so capture the final cookies
    /// now. This is the intended completion path (see performSolve phase 2).
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === interactiveWindow {
            resumeClose()
        }
    }
}
