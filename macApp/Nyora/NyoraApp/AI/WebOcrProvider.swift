import Foundation
import WebKit
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// OCR backed by nyora-web's PROVEN pipeline, run verbatim inside a hidden WKWebView.
///
/// The web app OCRs manga with ONNX models (a shared bubble YOLO detector + manga-ocr for
/// Japanese and PaddleOCR for zh/en/ko) in a module Worker (`tl-worker.js`). We ship that exact
/// worker unchanged and drive it from Swift, so the Mac gets byte-for-byte the same detection +
/// recognition as the web — replacing the Apple Vision OCR. Google Translate + the Apple
/// Intelligence refine step downstream are unchanged (they aren't Vision).
///
/// Models + the onnxruntime-web runtime download from public CDNs on first use and are cached in
/// the WebView's data store (first Japanese page ≈ 123 MB, then instant).
@MainActor
final class WebOcrProvider: NSObject, ObservableObject {
    static let shared = WebOcrProvider()

    /// The OCR languages the app offers to pre-download (worker keys). `en` shares the `zh` model.
    static let downloadableLangs: [(key: String, title: String, approxMB: Int)] = [
        ("ja", "Japanese", 123),
        ("zh", "Chinese / English", 32),
        ("ko", "Korean", 24),
    ]

    // Live download progress for the Settings "Translation models" UI.
    @Published var downloadingLang: String? = nil
    @Published var downloadProgress: Double = 0   // 0…1 (–1 while an indeterminate step runs)
    @Published var downloadLabel: String = ""
    /// Languages whose models have been downloaded at least once (cached in the WebView store).
    /// Persisted heuristically — the real cache lives in WebKit; cleared data would make this stale.
    @Published private(set) var installedLangs: Set<String>

    private static let installedKey = "nyora.ocr.models.installed"

    /// One detected+recognized text region: pixel bbox (top-left origin, source-image space),
    /// the OCR'd text, and the balloon background colour as a CSS `rgb(...)` string.
    struct Block: Sendable {
        let text: String
        let box: CGRect
        let bg: String
    }

    enum OcrError: LocalizedError {
        case serverFailed
        case encodeFailed
        case worker(String)
        case timeout
        var errorDescription: String? {
            switch self {
            case .serverFailed: return "OCR asset server failed to start"
            case .encodeFailed: return "Failed to encode page image for OCR"
            case let .worker(m): return "OCR engine error: \(m)"
            case .timeout: return "OCR timed out"
            }
        }
    }

    private var server: OcrAssetServer?
    private var webView: WKWebView?
    private var hostWindow: NSWindow?

    private var isReady = false
    private var bootError: Error?
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    private var pageWaiters: [String: CheckedContinuation<[Block], Error>] = [:]
    private var counter = 0

    private override init() {
        let saved = UserDefaults.standard.array(forKey: Self.installedKey) as? [String] ?? []
        installedLangs = Set(saved)
        super.init()
    }

    /// True once the worker has loaded its runtime + detector and is ready to OCR.
    var ready: Bool { isReady }

    // MARK: - Model pre-download (Settings)

    /// Download a language's OCR model ahead of time so the first real translation is instant.
    /// Runs OCR on a tiny blank image, which makes the worker `ensureEngine(lang)` (i.e. fetch +
    /// cache the model). Progress is published for the Settings UI.
    func preload(lang: String) async throws {
        guard downloadingLang == nil else { return }
        downloadingLang = lang
        downloadProgress = 0
        downloadLabel = "Preparing…"
        defer {
            downloadingLang = nil
            downloadProgress = 0
            downloadLabel = ""
        }
        do {
            _ = try await ocr(cgImage: Self.blankImage(), lang: lang)
            markInstalled(lang)
        } catch {
            throw error
        }
    }

    private func markInstalled(_ lang: String) {
        installedLangs.insert(lang)
        UserDefaults.standard.set(Array(installedLangs), forKey: Self.installedKey)
    }

    private static func blankImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    // MARK: - Bootstrap

    /// Boot the localhost asset server + hidden WebView once and wait for the worker's `ready`.
    /// Idempotent; safe to call before every page.
    func ensureReady() async throws {
        if isReady { return }
        if let bootError { throw bootError }
        if webView == nil { try bootstrap() }
        if isReady { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            readyWaiters.append(c)
            // Fail the wait if the runtime + detector don't load within 60s.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !self.isReady, !self.readyWaiters.isEmpty else { return }
                let waiters = self.readyWaiters
                self.readyWaiters = []
                waiters.forEach { $0.resume(throwing: OcrError.timeout) }
            }
        }
    }

    private func bootstrap() throws {
        let server = OcrAssetServer()
        guard let port = server.start() else {
            let e = OcrError.serverFailed
            bootError = e
            throw e
        }
        self.server = server

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "ocr")
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 2, height: 2), configuration: config)
        wv.navigationDelegate = self
        self.webView = wv

        // Host in a tiny off-screen window so WebKit keeps the page active (an unparented
        // WKWebView gets its timers/JS throttled, which would stall the OCR worker).
        let win = NSWindow(
            contentRect: NSRect(x: -400, y: -400, width: 2, height: 2),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        win.isReleasedWhenClosed = false
        win.contentView?.addSubview(wv)
        win.orderOut(nil)
        self.hostWindow = win

        let url = URL(string: "http://127.0.0.1:\(port)/harness.html")!
        wv.load(URLRequest(url: url))
    }

    // MARK: - OCR

    /// OCR one page image. `lang` is the source language: `ja`, `zh`, `en`, or `ko`.
    func ocr(cgImage: CGImage, lang: String) async throws -> [Block] {
        try await ensureReady()
        guard let base64 = Self.pngBase64(cgImage) else { throw OcrError.encodeFailed }
        counter += 1
        let id = "p\(counter)"
        let js = "window.__ocrPage(\(Self.jsArg(id)), \(Self.jsArg(base64)), \(Self.jsArg(lang)))"
        // Generous: the FIRST page for a language downloads its model (ja ≈ 123 MB); later pages
        // are fast. The worker posts `page-error` on failure, resolving early.
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Block], Error>) in
            pageWaiters[id] = c
            webView?.evaluateJavaScript(js) { [weak self] _, err in
                guard let err else { return }
                Task { @MainActor in self?.pageWaiters.removeValue(forKey: id)?.resume(throwing: err) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
                self.pageWaiters.removeValue(forKey: id)?.resume(throwing: OcrError.timeout)
            }
        }
    }

    // MARK: - Bridge callbacks (main actor)

    private func handleReady() {
        isReady = true
        let waiters = readyWaiters; readyWaiters = []
        waiters.forEach { $0.resume() }
    }

    private func handleInitError(_ message: String) {
        let e = OcrError.worker(message)
        bootError = e
        let waiters = readyWaiters; readyWaiters = []
        waiters.forEach { $0.resume(throwing: e) }
    }

    private func handlePageResult(id: String, blocks: [Block]) {
        pageWaiters.removeValue(forKey: id)?.resume(returning: blocks)
    }

    private func handlePageError(id: String, message: String) {
        pageWaiters.removeValue(forKey: id)?.resume(throwing: OcrError.worker(message))
    }

    private func handleProgress(label: String, pct: Double) {
        // Only surfaced while a Settings-initiated pre-download is running.
        guard downloadingLang != nil else { return }
        if !label.isEmpty { downloadLabel = label }
        downloadProgress = max(0, min(1, pct / 100.0))
    }

    // MARK: - Helpers

    nonisolated private static func pngBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data).base64EncodedString()
    }

    /// JSON-encode a string into a safe JS literal (handles quotes/newlines/unicode).
    nonisolated private static func jsArg(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let arr = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast()) // strip the [ ] around the single element
    }

    nonisolated private static func parseBlock(_ d: [String: Any]) -> Block? {
        func num(_ k: String) -> CGFloat? { (d[k] as? NSNumber).map { CGFloat(truncating: $0) } }
        guard let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") else { return nil }
        return Block(
            text: d["text"] as? String ?? "",
            box: CGRect(x: x, y: y, width: w, height: h),
            bg: d["bg"] as? String ?? "rgb(255,255,255)"
        )
    }
}

// MARK: - WKScriptMessageHandler

extension WebOcrProvider: WKScriptMessageHandler {
    // WebKit invokes this on the main thread, so it's safe to touch main-actor state directly.
    nonisolated func userContentController(_ userContentController: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                handleReady()
            case "init-error":
                handleInitError(body["error"] as? String ?? "init failed")
            case "page-result":
                guard let id = body["id"] as? String else { return }
                let blocks = (body["blocks"] as? [[String: Any]] ?? []).compactMap(Self.parseBlock)
                handlePageResult(id: id, blocks: blocks)
            case "page-error":
                guard let id = body["id"] as? String else { return }
                handlePageError(id: id, message: body["error"] as? String ?? "ocr failed")
            case "progress":
                handleProgress(label: body["label"] as? String ?? "",
                               pct: (body["pct"] as? NSNumber)?.doubleValue ?? 0)
            default:
                break
            }
        }
    }
}

// MARK: - WKNavigationDelegate

extension WebOcrProvider: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { handleInitError(error.localizedDescription) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { handleInitError(error.localizedDescription) }
    }
}
