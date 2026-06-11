import SwiftUI
import AppKit

/// Renders translated speech-bubble blocks over a manga page.
/// Pass 1 paints an opaque background to erase the original text.
/// Pass 2 draws the translated text on top.
struct TranslationOverlayView: View {
    @EnvironmentObject var appState: AppState
    let blocks: [TranslatedBlock]
    let imageSize: CGSize
    let containerSize: CGSize

    @State private var cachedFontSizes: [String: CGFloat] = [:]

    // Expand the cover rect beyond the OCR box to ensure full text erasure
    private let coverExpand: CGFloat = 6
    private let textPad: CGFloat = 5
    private let minFont: CGFloat = 8
    private let maxFont: CGFloat = 38
    private var responseScale: CGFloat {
        CGFloat(appState.readerPrefs.translationResponseScale)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear // anchor: ZStack adopts containerSize

            // Pass 1 — opaque solid fill to erase original text
            ForEach(blocks) { block in
                if block.state != .translating {
                    let vr = coverRect(for: block.boundingBox)
                    block.backgroundColor
                        .frame(width: vr.width, height: vr.height)
                        .position(x: vr.midX, y: vr.midY)
                }
            }

            // Pass 2 — translated text
            ForEach(blocks) { block in
                if block.state != .translating, !block.translatedText.isEmpty {
                    let vr = coverRect(for: block.boundingBox)
                    let isDark = block.backgroundColor.luminance < 0.45
                    let cacheKey = "\(block.id)|\(vr.width)|\(vr.height)"
                    let fs = cachedFontSizes[cacheKey] ?? fitFontSize(text: block.translatedText,
                                        box: vr.insetBy(dx: textPad, dy: textPad))
                    Text(block.translatedText)
                        .font(.system(size: fs * responseScale, weight: .medium, design: .rounded))
                        .foregroundStyle(isDark ? Color.white : Color.black)
                        .multilineTextAlignment(.center)
                        .lineSpacing(responseScale)
                        .minimumScaleFactor(0.5)
                        .frame(width: vr.width - textPad * 2,
                               height: vr.height - textPad * 2,
                               alignment: .center)
                        .position(x: vr.midX, y: vr.midY)
                }
            }
        }
        .frame(width: containerSize.width, height: containerSize.height)
        .allowsHitTesting(false)
        .onChange(of: blocks) { _, _ in rebuildFontSizeCache() }
        .onChange(of: imageSize) { _, _ in rebuildFontSizeCache() }
        .onChange(of: containerSize) { _, _ in rebuildFontSizeCache() }
        .onAppear { rebuildFontSizeCache() }
    }

    private func rebuildFontSizeCache() {
        var newCache: [String: CGFloat] = [:]
        for block in blocks where block.state != .translating && !block.translatedText.isEmpty {
            let vr = coverRect(for: block.boundingBox)
            let cacheKey = "\(block.id)|\(vr.width)|\(vr.height)"
            newCache[cacheKey] = fitFontSize(text: block.translatedText,
                                             box: vr.insetBy(dx: textPad, dy: textPad))
        }
        cachedFontSizes = newCache
    }

    // MARK: - Coordinate mapping

    private var aspectFitTransform: (scale: CGFloat, dx: CGFloat, dy: CGFloat) {
        guard imageSize.width > 0, imageSize.height > 0 else { return (1, 0, 0) }
        let s = min(containerSize.width / imageSize.width,
                    containerSize.height / imageSize.height)
        return (s,
                (containerSize.width  - imageSize.width  * s) / 2,
                (containerSize.height - imageSize.height * s) / 2)
    }

    private func viewRect(for imgBox: CGRect) -> CGRect {
        let (s, dx, dy) = aspectFitTransform
        return CGRect(x: imgBox.minX * s + dx,
                      y: imgBox.minY * s + dy,
                      width: imgBox.width * s,
                      height: imgBox.height * s)
    }

    // Expanded rect — covers original text + a margin so nothing bleeds through
    private func coverRect(for imgBox: CGRect) -> CGRect {
        viewRect(for: imgBox).insetBy(dx: -coverExpand, dy: -coverExpand)
    }

    // MARK: - Font sizing

    private func fitFontSize(text: String, box: CGRect) -> CGFloat {
        guard box.width > 0, box.height > 0 else { return minFont }
        let base = (box.height * 0.45).clamped(to: minFont...maxFont)
        for size in stride(from: base, through: minFont, by: -1) {
            let h = measureHeight(text, fontSize: size * responseScale, maxWidth: box.width)
            if h <= box.height { return size }
        }
        return minFont
    }

    private func measureHeight(_ text: String, fontSize: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let size = CGSize(width: maxWidth, height: .greatestFiniteMagnitude)
        return (text as NSString)
            .boundingRect(with: size, options: [.usesLineFragmentOrigin], attributes: attrs)
            .height
    }
}

// MARK: - Helpers

private extension Color {
    var luminance: Double {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return 1 }
        return ns.redComponent * 0.299 + ns.greenComponent * 0.587 + ns.blueComponent * 0.114
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
