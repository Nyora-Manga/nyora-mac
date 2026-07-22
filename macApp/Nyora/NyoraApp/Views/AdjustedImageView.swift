import SwiftUI
import Cocoa
import ImageIO

/// Custom View that fetches an image from a URL or uses a pre-painted NSImage,
/// applies hardware-accelerated Core Image adjustments on the GPU, and handles aspect ratios and scaling.
struct AdjustedImageView: View {
    let url: String?
    let paintedImage: NSImage?
    let adjustments: ColorAdjustments
    let containerSize: CGSize
    let zoomMode: String // "fit_width", "fit_height", "fill", "fit_center"
    var onImageLoaded: ((CGSize) -> Void)? = nil
    
    @State private var originalImage: NSImage? = nil
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var loadedUrl: String? = nil
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var adjustedImage: NSImage? = nil
    @State private var adjustTask: Task<Void, Never>? = nil

    var body: some View {
        Group {
            if let baseImage = paintedImage ?? originalImage {
                // A painted/colorized image is transient and its adjusted form must
                // NOT be read from the url-keyed cache (that holds the ORIGINAL page's
                // adjusted result) — otherwise a translated/colorized page shows the
                // stale original until the view is rebuilt.
                let displayImage: NSImage = paintedImage != nil
                    ? (adjustedImage ?? baseImage)
                    : (adjustedImage ?? ColorFilterEngine.cachedResult(for: baseImage, adjustments: adjustments, cacheKey: url) ?? baseImage)

                // Display using scaled layout
                scaleImage(Image(nsImage: displayImage), size: baseImage.size)
                    .onChange(of: adjustments) { _, _ in
                        scheduleAdjust(base: baseImage, cacheKey: paintedImage != nil ? nil : url)
                    }
                    .onAppear {
                        scheduleAdjust(base: baseImage, cacheKey: paintedImage != nil ? nil : url)
                    }
            } else if isLoading {
                if zoomMode == "fit_width" {
                    // Webtoon loading placeholder
                    Rectangle()
                        .fill(Color(white: 0.12))
                        .frame(width: containerSize.width, height: containerSize.height)
                        .overlay(ProgressView().tint(.white))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: containerSize.width, height: containerSize.height)
                }
            } else if hasFailed {
                if zoomMode == "fit_width" {
                    Rectangle()
                        .fill(Color(white: 0.15))
                        .frame(width: containerSize.width, height: 300)
                        .overlay(
                            Label("Page failed to load", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.white)
                        )
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36)).foregroundStyle(.orange)
                        Text("Page failed to load").font(.headline).foregroundStyle(.white)
                    }
                    .frame(width: containerSize.width, height: containerSize.height)
                }
            } else {
                Color.clear
                    .onAppear {
                        loadImage()
                    }
            }
        }
        .onChange(of: url) { _, _ in
            adjustTask?.cancel()
            adjustedImage = nil
            loadTask?.cancel()
            loadImage()
        }
        .onAppear {
            if let painted = paintedImage {
                onImageLoaded?(painted.size)
            } else {
                loadImage()
            }
        }
        .onChange(of: paintedImage) { _, newImage in
            // The translated/colorized image just arrived (or was cleared) — re-run
            // the adjust pass on the new base so the reader updates LIVE on the
            // current page instead of only after navigating away and back.
            if let newImage {
                onImageLoaded?(newImage.size)
                scheduleAdjust(base: newImage, cacheKey: nil)
            } else {
                adjustTask?.cancel()
                adjustedImage = nil
                if let orig = originalImage { scheduleAdjust(base: orig, cacheKey: url) }
            }
        }
    }
    
    @ViewBuilder
    private func scaleImage(_ image: Image, size: CGSize) -> some View {
        if zoomMode == "fit_width" {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: containerSize.width, height: containerSize.height)
        } else if zoomMode == "fit_height" {
            image
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(height: containerSize.height)
                .frame(maxWidth: containerSize.width, alignment: .center)
                .clipped()
        } else if zoomMode == "fill" {
            image
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: containerSize.width, height: containerSize.height)
                .clipped()
        } else {
            // fit_center / default
            image
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: containerSize.width, height: containerSize.height)
        }
    }
    
    private func loadImage() {
        guard paintedImage == nil,
              let urlString = url, let url = URL(string: urlString),
              loadedUrl != urlString else { return }
        loadedUrl = urlString
        isLoading = true; hasFailed = false; originalImage = nil
        loadTask?.cancel()
        loadTask = Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, loadedUrl == urlString else { return }
                // FULL-resolution decode, but OFF the main thread. The reader's
                // stall was the decode running on the main actor — not the
                // resolution — so we keep every pixel and just move the work.
                let cg = await Task.detached(priority: .userInitiated) {
                    AdjustedImageView.fullResCGImage(from: data)
                }.value
                guard !Task.isCancelled, loadedUrl == urlString else { return }
                if let cg {
                    let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                    originalImage = img
                    onImageLoaded?(img.size)
                    if paintedImage == nil { scheduleAdjust(base: img, cacheKey: urlString) }
                } else { hasFailed = true }
            } catch { hasFailed = !Task.isCancelled }
            isLoading = false
        }
    }

    /// Full-resolution decode via ImageIO, forced to fully materialize the pixels
    /// off-thread (`kCGImageSourceShouldCacheImmediately`) so nothing is deferred
    /// to a lazy main-thread decode at draw time. No downsampling — full quality.
    /// `nonisolated static` so it can run on a detached (off-main) task.
    nonisolated static func fullResCGImage(from data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData,
                                                    [kCGImageSourceShouldCache: true] as CFDictionary)
        else { return NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
            ?? NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// Small downsampled decode — used ONLY for the tiny scrub-bar preview
    /// thumbnail (rendered ~118×166), never for the page you actually read.
    /// `nonisolated static` so it can run on a detached (off-main) task.
    nonisolated static func downsampledCGImage(from data: Data, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData,
                                                    [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private func scheduleAdjust(base: NSImage, cacheKey: String?) {
        adjustTask?.cancel()
        adjustedImage = nil
        adjustTask = Task {
            let result = await ColorFilterEngine.apply(to: base, adjustments: adjustments, cacheKey: cacheKey)
            guard !Task.isCancelled else { return }
            adjustedImage = result
        }
    }
}
