import SwiftUI
import AppKit
import QuartzCore

/// Paged reader image. Two-layer structure:
///
///   `Container` (NSView, layer-backed) — owns the CATransition for page-curl.
///   └── `NSImageView` (NOT layer-backed) — does the actual AppKit drawing
///       with `.scaleProportionallyUpOrDown`, which fits the page to the
///       container's bounds while preserving aspect ratio.
///
/// Keeping `wantsLayer = false` on the NSImageView is essential — when an
/// image view is layer-backed, AppKit's image-scaling pipeline ends up
/// drawing the image at its natural size and CALayer scales it up to fill,
/// which looked like an aggressive zoom for any page wider/taller than the
/// viewport. With layer-backing on the *container* only, NSImageView draws
/// fit-to-bounds the way it's supposed to.
///
/// Also reports the image's natural pixel size back to the parent so the
/// translation overlay can map block coordinates correctly.
struct PagedCurlImageView: NSViewRepresentable {
    let url: String
    let isRTL: Bool
    let direction: PageCurlDirection
    /// Called on the main queue after the image finishes loading. The
    /// CGSize is the image's natural (pixel) size — used by the translation
    /// overlay to lay out OCR blocks.
    var onImageLoaded: ((CGSize) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let container = Container()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.imageFrameStyle = .none
        iv.isEditable = false
        // Critical: do NOT layer-back the image view (see file doc above).
        iv.wantsLayer = false
        iv.translatesAutoresizingMaskIntoConstraints = false
        container.imageView = iv
        container.addSubview(iv)
        // Centre horizontally + top/bottom-pin to container so height is
        // always the container's height. Width is driven by an explicit
        // constraint that the coordinator updates once the image's aspect
        // ratio is known.
        let widthConstraint = iv.widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.priority = .defaultHigh
        container.imageWidthConstraint = widthConstraint
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            widthConstraint,
        ])

        context.coordinator.load(
            url: url, container: container,
            animated: false, direction: direction, isRTL: isRTL,
            onImageLoaded: onImageLoaded
        )
        return container
    }

    func updateNSView(_ container: Container, context: Context) {
        // Re-derive the width constraint from the current container height
        // and the cached image aspect so live window resizing re-fits.
        container.applyHeightFit()
        guard context.coordinator.lastURL != url else { return }
        context.coordinator.load(
            url: url, container: container,
            animated: true, direction: direction, isRTL: isRTL,
            onImageLoaded: onImageLoaded
        )
    }

    /// Container view that holds the page-curl layer transition. Owns the
    /// inner image view and the width constraint that drives the
    /// fit-by-height sizing.
    final class Container: NSView {
        var imageView: NSImageView?
        var imageWidthConstraint: NSLayoutConstraint?
        /// imageWidth ÷ imageHeight, captured once the image lands.
        var aspectRatio: CGFloat = 0
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            applyHeightFit()
        }
        /// Resize the inner NSImageView to (height × aspect) so it sits at
        /// container height with its natural aspect. No-ops until aspect
        /// is known.
        func applyHeightFit() {
            guard aspectRatio > 0,
                  let constraint = imageWidthConstraint else { return }
            constraint.constant = bounds.height * aspectRatio
        }
    }

    @MainActor final class Coordinator: NSObject {
        var lastURL: String?
        private var task: URLSessionDataTask?
        private var pendingImageLoaded: ((CGSize) -> Void)?

        func load(
            url: String,
            container: Container,
            animated: Bool,
            direction: PageCurlDirection,
            isRTL: Bool,
            onImageLoaded: ((CGSize) -> Void)?
        ) {
            task?.cancel()
            lastURL = url
            pendingImageLoaded = onImageLoaded
            guard let u = URL(string: url) else { return }
            task = URLSession.shared.dataTask(with: u) { [weak self, weak container] data, _, _ in
                guard let data else { return }
                Task { @MainActor [weak self, weak container] in
                    guard let self, let container,
                          let image = NSImage(data: data) else { return }
                    if animated {
                        self.applyPageCurl(on: container.layer, direction: direction, isRTL: isRTL)
                    }
                    container.imageView?.image = image
                    let size = image.size
                    if size.height > 0 {
                        container.aspectRatio = size.width / size.height
                        container.applyHeightFit()
                    }
                    self.pendingImageLoaded?(size)
                }
            }
            task?.resume()
        }

        /// Apply the Apple page-curl Core Animation transition to the
        /// container's layer. Direction maps:
        ///   forward + LTR / backward + RTL → pageCurl  + fromRight
        ///   backward + LTR / forward + RTL → pageUnCurl + fromLeft
        private func applyPageCurl(
            on layer: CALayer?,
            direction: PageCurlDirection,
            isRTL: Bool
        ) {
            guard let layer = layer else { return }
            let transition = CATransition()
            transition.duration = 0.55
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let lifting = (direction == .forward) != isRTL
            transition.type = CATransitionType(rawValue: lifting ? "pageCurl" : "pageUnCurl")
            transition.subtype = CATransitionSubtype(rawValue: lifting ? "fromRight" : "fromLeft")
            layer.add(transition, forKey: "pageCurl")
        }
    }
}

enum PageCurlDirection {
    case forward, backward
}
