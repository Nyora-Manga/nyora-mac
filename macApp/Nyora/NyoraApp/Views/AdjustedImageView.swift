import SwiftUI
import Cocoa

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
                let displayImage = adjustedImage ?? ColorFilterEngine.cachedResult(for: baseImage, adjustments: adjustments, cacheKey: url) ?? baseImage

                // Display using scaled layout
                scaleImage(Image(nsImage: displayImage), size: baseImage.size)
                    .onChange(of: adjustments) { _, _ in
                        scheduleAdjust(base: baseImage)
                    }
                    .onAppear {
                        scheduleAdjust(base: baseImage)
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
            if let newImage = newImage {
                onImageLoaded?(newImage.size)
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
                if let img = NSImage(data: data) {
                    originalImage = img
                    onImageLoaded?(img.size)
                    scheduleAdjust(base: img)
                } else { hasFailed = true }
            } catch { hasFailed = !Task.isCancelled }
            isLoading = false
        }
    }

    private func scheduleAdjust(base: NSImage) {
        adjustTask?.cancel()
        adjustedImage = nil
        adjustTask = Task {
            let result = await ColorFilterEngine.apply(to: base, adjustments: adjustments, cacheKey: url)
            guard !Task.isCancelled else { return }
            adjustedImage = result
        }
    }
}
