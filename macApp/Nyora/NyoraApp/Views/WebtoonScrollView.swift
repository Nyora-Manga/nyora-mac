import SwiftUI
import AppKit

/// Hosts SwiftUI content inside an NSScrollView so we can drive scroll
/// position smoothly with a per-frame timer. SwiftUI's
/// `ScrollViewReader.scrollTo` is a snap on macOS, so it can't drive
/// continuous auto-scroll.
///
/// Reports the currently-most-visible page index back through `currentPage`
/// so we can persist reading position. Set `pixelsPerSecond` > 0 to engage
/// auto-scroll, 0 to pause. User trackpad/scroll-wheel input is handled by
/// AppKit natively while auto-scroll is paused; while it's running we don't
/// fight the user — any user-initiated scroll cancels auto-scroll via
/// `scrollWheelObserver`.
struct WebtoonScrollView<Content: View>: NSViewRepresentable {
    @Binding var currentPage: Int
    @Binding var pixelsPerSecond: Double
    /// When the parent sets this to a non-nil page index (e.g. via the
    /// page-counter slider), the coordinator scrolls there and clears it.
    @Binding var scrollRequest: Int?
    let pageCount: Int
    let initialPage: Int
    /// The available width for the hosted content. Used to decide when to
    /// re-render the SwiftUI root — `sv.bounds.width` isn't always synced when
    /// SwiftUI fires `updateNSView`, so we rely on the SwiftUI-supplied value.
    let containerWidth: CGFloat
    let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.scrollerStyle = .overlay
        sv.autohidesScrollers = false
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.verticalScrollElasticity = .none
        sv.horizontalScrollElasticity = .none
        // Native pinch-to-zoom + pan-when-zoomed. The scroller's clip view
        // handles all of this for us; we don't need to wire gestures by hand.
        sv.allowsMagnification = true
        sv.minMagnification = 1.0
        sv.maxMagnification = 4.0
        // Make absolutely sure no insets, line widths, or backing borders eat
        // pixels off the column. The host is pinned edge-to-edge to the clip
        // view below; these calls remove the last sources of side margins.
        sv.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
        sv.scrollerInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
        sv.automaticallyAdjustsContentInsets = false
        sv.contentView.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
        sv.contentView.automaticallyAdjustsContentInsets = false

        let host = NSHostingView(rootView: content())
        host.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = host

        // Pin host width to the scroll view's visible width so the SwiftUI
        // page column lays out at the right size. The host's intrinsic
        // height flows naturally below the top anchor.
        NSLayoutConstraint.activate([
            // Pin to the CLIP view (the visible content area), not the outer
            // scroll view — this guarantees no scroller width or border can
            // produce side gutters.
            host.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor),
            host.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
        ])

        sv.contentView.postsBoundsChangedNotifications = true
        context.coordinator.attach(scrollView: sv, initialPage: initialPage, pageCount: pageCount)

        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Reassigning rootView on every state change rebuilds the entire
        // webtoon page column — which was making the page-counter overlay
        // jitter during scroll. Refresh only when the page list shape OR the
        // available width actually changes (e.g. on window resize).
        if let host = sv.documentView as? NSHostingView<Content>,
           context.coordinator.lastPageCount != pageCount
            || abs(context.coordinator.lastHostedWidth - containerWidth) > 0.5 {
            host.rootView = content()
            context.coordinator.lastPageCount = pageCount
            context.coordinator.lastHostedWidth = containerWidth
        }
        context.coordinator.setSpeed(pixelsPerSecond)
        // Honor any pending scroll-to-page request from the parent (e.g.
        // the page-counter slider). Defer the binding-clear so we don't
        // mutate state mid-update.
        if let target = scrollRequest {
            context.coordinator.scrollToPage(target, pageCount: pageCount)
            DispatchQueue.main.async { self.scrollRequest = nil }
        }
    }

    static func dismantleNSView(_ sv: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor final class Coordinator: NSObject {
        var parent: WebtoonScrollView
        weak var scrollView: NSScrollView?
        private var timer: Timer?
        private var lastTime: CFTimeInterval = 0
        private var localMonitor: Any?
        var lastPageCount: Int = -1
        var lastHostedWidth: CGFloat = -1
        private var lastBoundsReport: CFTimeInterval = 0
        private var initialScrollPage: Int = 0
        private var initialScrollPageCount: Int = 0
        private var initialScrollDone: Bool = false

        init(_ parent: WebtoonScrollView) {
            self.parent = parent
        }

        func attach(scrollView: NSScrollView, initialPage: Int, pageCount: Int) {
            self.scrollView = scrollView
            self.initialScrollPage = initialPage
            self.initialScrollPageCount = pageCount
            self.initialScrollDone = false
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(boundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            if let doc = scrollView.documentView {
                doc.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(documentFrameChanged),
                    name: NSView.frameDidChangeNotification,
                    object: doc
                )
            }
            // Watch local scroll-wheel events targeting this scroll view —
            // if the user scrolls themselves, pause auto-scroll so we don't
            // fight their input.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self else { return event }
                if event.scrollingDeltaY != 0, self.parent.pixelsPerSecond > 0 {
                    self.parent.pixelsPerSecond = 0
                }
                return event
            }
        }

        @objc private func documentFrameChanged() {
            guard !initialScrollDone,
                  let sv = scrollView,
                  let doc = sv.documentView else { return }
            let clipH = sv.contentView.bounds.height
            guard clipH > 0, doc.frame.height > clipH else { return }
            initialScrollDone = true
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: doc)
            scrollToPage(initialScrollPage, pageCount: initialScrollPageCount)
        }

        func detach() {
            stopTimer()
            NotificationCenter.default.removeObserver(self)
            if let m = localMonitor { NSEvent.removeMonitor(m) }
            localMonitor = nil
            scrollView = nil
        }

        func setSpeed(_ pps: Double) {
            if pps > 0 { startTimer(pps: pps) } else { stopTimer() }
        }

        private func startTimer(pps: Double) {
            stopTimer()
            lastTime = CACurrentMediaTime()
            // 60 Hz nudge — good enough; macOS coalesces scroll updates.
            timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick(pps: pps) }
            }
        }

        private func stopTimer() {
            timer?.invalidate()
            timer = nil
        }

        private func tick(pps: Double) {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            let now = CACurrentMediaTime()
            let dt = now - lastTime
            lastTime = now
            let delta = CGFloat(pps * dt)
            let visibleY = sv.contentView.bounds.origin.y
            let maxScroll = max(doc.frame.height - sv.contentView.bounds.height, 0)
            let newY = Swift.min(visibleY + delta, maxScroll)
            sv.contentView.scroll(to: CGPoint(x: 0, y: newY))
            sv.reflectScrolledClipView(sv.contentView)
            if newY >= maxScroll {
                // Reached end — stop driving.
                self.parent.pixelsPerSecond = 0
            }
        }

        @objc private func boundsChanged() {
            guard let sv = scrollView, let doc = sv.documentView else { return }
            // AppKit emits these on every scroll tick — throttle to ~10 Hz so
            // we don't re-render the page counter / seekbar on every frame.
            let now = CACurrentMediaTime()
            if now - lastBoundsReport < 0.1 { return }
            lastBoundsReport = now
            let total = doc.frame.height
            let viewH = sv.contentView.bounds.height
            let scrollY = sv.contentView.bounds.origin.y
            let maxScroll = Swift.max(total - viewH, 1)
            let fraction = Swift.min(Swift.max(scrollY / maxScroll, 0), 1)
            let pageCount = parent.pageCount
            guard pageCount > 0 else { return }
            let idx = Swift.min(Swift.max(Int(round(fraction * Double(pageCount - 1))), 0), pageCount - 1)
            if idx != parent.currentPage {
                parent.currentPage = idx
            }
        }

        /// Manual scroll-to-page for resume-from-history or slider scrubs.
        /// Maps the page index to a vertical fraction of the document height
        /// and snaps the clip view there. Allows page 0 (top of column).
        func scrollToPage(_ page: Int, pageCount: Int) {
            guard let sv = scrollView, let doc = sv.documentView, pageCount > 0 else { return }
            let clamped = Swift.min(Swift.max(page, 0), pageCount - 1)
            let total = doc.frame.height
            let viewH = sv.contentView.bounds.height
            let maxScroll = Swift.max(total - viewH, 1)
            // pageCount-1 in the denominator so the LAST page maps to maxScroll.
            let fraction = pageCount > 1 ? Double(clamped) / Double(pageCount - 1) : 0
            let targetY = CGFloat(fraction) * maxScroll
            sv.contentView.scroll(to: CGPoint(x: 0, y: targetY))
            sv.reflectScrolledClipView(sv.contentView)
        }
    }
}

