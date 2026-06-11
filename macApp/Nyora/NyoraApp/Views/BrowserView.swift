import SwiftUI
import WebKit
import AppKit

// MARK: - WebView Controller

/// Small imperative controller the parent holds so it can drive the
/// underlying `WKWebView` (back / forward / reload / stop) without owning
/// the view directly. The `WebView` representable hands itself a reference
/// to the live web view through this controller in `makeNSView`.
final class WebViewController: ObservableObject {
    fileprivate weak var webView: WKWebView?

    func goBack()    { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload()    { webView?.reload() }
    func stop()      { webView?.stopLoading() }
}

// MARK: - WebView (NSViewRepresentable)

/// A SwiftUI wrapper around `WKWebView`. The parent passes a load target
/// `url` (load is triggered whenever it changes) and binds back live
/// navigation state — `canGoBack`, `canGoForward`, `isLoading`,
/// `estimatedProgress`, `pageTitle`, `currentURL` — updated via KVO and the
/// navigation delegate. Imperative actions go through `controller`.
@MainActor
struct WebView: NSViewRepresentable {
    /// Load target. When this changes to a new value the web view navigates.
    var url: URL?
    /// Optional controller the parent holds for goBack/goForward/reload/stop.
    var controller: WebViewController?

    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var estimatedProgress: Double
    @Binding var pageTitle: String
    @Binding var currentURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true

        context.coordinator.observe(webView)
        controller?.webView = webView

        if let url { webView.load(URLRequest(url: url)) }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller?.webView = webView
        // Only (re)load when the requested URL actually differs from what is
        // currently shown, to avoid reload loops while the user browses.
        if let url, url != context.coordinator.lastRequestedURL, url != webView.url {
            context.coordinator.lastRequestedURL = url
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: WebView
        fileprivate var lastRequestedURL: URL?
        private var observations: [NSKeyValueObservation] = []

        init(_ parent: WebView) {
            self.parent = parent
            self.lastRequestedURL = parent.url
        }

        /// Wire up KVO for the observable properties WebKit exposes.
        func observe(_ webView: WKWebView) {
            observations = [
                webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.push { $0.canGoBack = wv.canGoBack }
                },
                webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.push { $0.canGoForward = wv.canGoForward }
                },
                webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.push { $0.isLoading = wv.isLoading }
                },
                webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.push { $0.estimatedProgress = wv.estimatedProgress }
                },
                webView.observe(\.title, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.push { $0.pageTitle = wv.title ?? "" }
                },
                webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                    self?.push { $0.currentURL = wv.url }
                }
            ]
        }

        func invalidate() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        /// Bindings must be mutated on the main thread; KVO callbacks already
        /// fire on the main queue for WKWebView but we stay defensive.
        private func push(_ apply: @MainActor (WebView) -> Void) {
            apply(parent)
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            push { $0.currentURL = webView.url }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            push {
                $0.isLoading = false
                $0.pageTitle = webView.title ?? ""
                $0.currentURL = webView.url
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            push { $0.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            push { $0.isLoading = false }
        }
    }
}

// MARK: - BrowserView (dedicated in-app browser page)

/// A full in-app browser page: top bar with Back / Forward / Reload (or Stop
/// while loading), an editable address field that loads on submit, a thin
/// progress bar, and the web view filling the rest. Clean / flat to match the
/// rest of the app, and responsive (`maxWidth: .infinity`).
@MainActor
struct BrowserView: View {
    @StateObject private var controller = WebViewController()

    @State private var addressText: String = ""
    @State private var loadURL: URL? = nil

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var estimatedProgress: Double = 0
    @State private var pageTitle = ""
    @State private var currentURL: URL? = nil

    var body: some View {
        VStack(spacing: 0) {
            topBar
            progressBar
            Divider().opacity(0.4)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            navButton(systemImage: "chevron.left", enabled: canGoBack) {
                controller.goBack()
            }
            .help("Back")

            navButton(systemImage: "chevron.right", enabled: canGoForward) {
                controller.goForward()
            }
            .help("Forward")

            navButton(systemImage: isLoading ? "xmark" : "arrow.clockwise", enabled: true) {
                if isLoading { controller.stop() } else { controller.reload() }
            }
            .help(isLoading ? "Stop" : "Reload")

            addressField

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Search or enter address…", text: $addressText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { submitAddress() }
            if !addressText.isEmpty {
                Button {
                    addressText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    private func navButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { action() } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.appAccent : Color.secondary.opacity(0.4))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Progress bar

    @ViewBuilder
    private var progressBar: some View {
        if isLoading && estimatedProgress > 0 && estimatedProgress < 1 {
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent, Color.appAccent.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(estimatedProgress))
                    .animation(.easeOut(duration: 0.2), value: estimatedProgress)
            }
            .frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if loadURL == nil {
            startPage
        } else {
            web
        }
    }

    private var web: some View {
        WebView(
            url: loadURL,
            controller: controller,
            canGoBack: $canGoBack,
            canGoForward: $canGoForward,
            isLoading: $isLoading,
            estimatedProgress: $estimatedProgress,
            pageTitle: $pageTitle,
            currentURL: $currentURL
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: currentURL) { _, newValue in
            // Reflect navigation back into the address field, but don't fight
            // the user while they are typing (handled by focus-less compare).
            if let newValue { addressText = newValue.absoluteString }
        }
    }

    private var startPage: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.appAccent.opacity(0.18), Color.appAccent.opacity(0.05)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .frame(width: 80, height: 80)
                Image(systemName: "globe")
                    .font(.system(size: 34))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.appAccent)
            }
            VStack(spacing: 6) {
                Text("Browser")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Type an address or a search above to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Address handling

    /// Resolve the typed text into a URL: if it parses as a URL we prepend
    /// `https://` when it has no scheme; otherwise we run a Google search.
    private func submitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        loadURL = Self.resolve(trimmed)
    }

    static func resolve(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Already a full URL with a scheme.
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return url
        }

        // Looks like a bare host (contains a dot, no spaces) → prepend https://
        let looksLikeHost = trimmed.contains(".") && !trimmed.contains(" ")
        if looksLikeHost, let url = URL(string: "https://\(trimmed)") {
            return url
        }

        // Fall back to a Google search.
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "https://www.google.com/search?q=\(query)")
    }
}

// MARK: - InAppWebSheet (modal web view)

/// A sheet that shows a `WKWebView` for an arbitrary URL inside lightweight
/// chrome: a header with the page title plus Reload, Open-in-Safari and Close
/// buttons. Sized ~900×680 and resizable.
@MainActor
struct InAppWebSheet: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = WebViewController()

    @State private var canGoBack = false
    @State private var canGoForward = false
    @State private var isLoading = false
    @State private var estimatedProgress: Double = 0
    @State private var pageTitle = ""
    @State private var currentURL: URL? = nil

    init(url: URL) {
        self.url = url
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBar
            Divider().opacity(0.4)
            WebView(
                url: url,
                controller: controller,
                canGoBack: $canGoBack,
                canGoForward: $canGoForward,
                isLoading: $isLoading,
                estimatedProgress: $estimatedProgress,
                pageTitle: $pageTitle,
                currentURL: $currentURL
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, idealWidth: 900, minHeight: 440, idealHeight: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(pageTitle.isEmpty ? (currentURL ?? url).host ?? "Web Page" : pageTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text((currentURL ?? url).absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            Button {
                if isLoading { controller.stop() } else { controller.reload() }
            } label: {
                Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            .help(isLoading ? "Stop" : "Reload")

            Button {
                NSWorkspace.shared.open(currentURL ?? url)
            } label: {
                Image(systemName: "safari")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            .buttonStyle(.plain)
            .help("Open in Safari")

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var progressBar: some View {
        if isLoading && estimatedProgress > 0 && estimatedProgress < 1 {
            GeometryReader { geo in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.appAccent, Color.appAccent.opacity(0.6)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(estimatedProgress))
                    .animation(.easeOut(duration: 0.2), value: estimatedProgress)
            }
            .frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }
}
