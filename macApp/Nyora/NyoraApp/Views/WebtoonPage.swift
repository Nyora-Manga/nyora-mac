import SwiftUI
import AppKit

/// A single webtoon page rendered by AppKit so we can pixel-pin the width to
/// the parent column. SwiftUI's `image.resizable().aspectRatio(.fit)` chain
/// inside an `NSHostingView` doesn't always commit to a definite width — that
/// was the source of the residual left/right gutters you could see in webtoon
/// mode. Going through `NSImageView` removes that uncertainty: we set the
/// frame explicitly and AppKit honors it down to the pixel.
///
/// Sizing math:
///   width  = containerWidth                                  (forced)
///   height = containerWidth × (image.height / image.width)   (aspect-preserving)
///
/// While the image is loading we reserve `placeholderHeight` of vertical space
/// so the VStack column always has enough content to scroll.
struct WebtoonPageView: NSViewRepresentable {
    let url: String
    let containerWidth: CGFloat
    let placeholderHeight: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let v = Container()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        // Width pinned to the column width.
        v.widthConstraint = v.widthAnchor.constraint(equalToConstant: containerWidth)
        // Height starts at the placeholder; replaced when the image lands.
        v.heightConstraint = v.heightAnchor.constraint(equalToConstant: placeholderHeight)
        v.widthConstraint?.isActive = true
        v.heightConstraint?.isActive = true

        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignTop
        iv.translatesAutoresizingMaskIntoConstraints = false
        // NSImageView's default `imageFrameStyle` is `.grayBezel`, which
        // draws a few-pixel inset border. That's what was producing the
        // visible vertical gap between webtoon pages — kill it.
        iv.imageFrameStyle = .none
        iv.isEditable = false
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.clear.cgColor
        v.imageView = iv
        v.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            iv.topAnchor.constraint(equalTo: v.topAnchor),
            iv.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])

        context.coordinator.load(url: url, into: v, containerWidth: containerWidth, placeholderHeight: placeholderHeight)
        return v
    }

    func updateNSView(_ v: Container, context: Context) {
        v.widthConstraint?.constant = containerWidth
        // If the natural aspect is known, re-derive the height from the new width.
        if let aspect = v.aspectRatio, aspect > 0 {
            v.heightConstraint?.constant = containerWidth / aspect
        } else {
            v.heightConstraint?.constant = placeholderHeight
        }
        if v.loadedURL != url {
            context.coordinator.load(url: url, into: v, containerWidth: containerWidth, placeholderHeight: placeholderHeight)
        }
    }

    /// The container view owns the image view + the two sizing constraints +
    /// the loaded image's intrinsic aspect ratio (width / height).
    final class Container: NSView {
        var imageView: NSImageView?
        var widthConstraint: NSLayoutConstraint?
        var heightConstraint: NSLayoutConstraint?
        var aspectRatio: CGFloat?      // image.width / image.height
        var loadedURL: String?
        override var isFlipped: Bool { true }
    }

    final class Coordinator: NSObject {
        private var session: URLSessionDataTask?

        func load(url: String, into container: Container, containerWidth: CGFloat, placeholderHeight: CGFloat) {
            session?.cancel()
            container.loadedURL = url
            guard let u = URL(string: url) else { return }
            session = URLSession.shared.dataTask(with: u) { [weak container] data, _, _ in
                guard let container = container,
                      let data = data,
                      let img = NSImage(data: data) else { return }
                let size = img.size
                let aspect: CGFloat = size.height > 0 ? size.width / size.height : 1.0
                DispatchQueue.main.async {
                    container.imageView?.image = img
                    container.aspectRatio = aspect
                    // Recompute height from the *current* width, not the
                    // captured one — the column may have resized while we
                    // were downloading.
                    let w = container.widthConstraint?.constant ?? containerWidth
                    container.heightConstraint?.constant = aspect > 0 ? w / aspect : placeholderHeight
                }
            }
            session?.resume()
        }
    }
}
