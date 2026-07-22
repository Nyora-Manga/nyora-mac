import Foundation
import CoreGraphics
import CoreText
import AppKit

/// Paints translation INTO the page image instead of overlaying it.
///
/// Per-bubble: find the actual speech bubble outline via ray-casting from
/// the detected text rect outward through white pixels until hitting the
/// black bubble border. Fill that whole bubble interior with white, then
/// draw the translated text inside.
///
/// Text whose rays escape past any border (i.e. text floating in panel art,
/// not inside a balloon) is skipped — those cause the worst visual artifacts.
enum PageImagePainter {

    /// One bubble to repaint. `bg*` are the sampled balloon-fill colour (0…1,
    /// sRGB) — carried as plain Doubles so the value is Sendable across the
    /// off-main paint task. Mirrors the web overlay's per-block `bg`.
    struct Bubble: Sendable {
        let rect: CGRect
        let text: String
        let bgR: Double
        let bgG: Double
        let bgB: Double
        var nsColor: NSColor { NSColor(srgbRed: bgR, green: bgG, blue: bgB, alpha: 1) }
    }

    static func paint(
        cgImage: CGImage,
        bubbles: [Bubble],
        originalSize: CGSize,
        textScale: CGFloat = 1.0
    ) -> CGImage? {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        let canvasW = CGFloat(w), canvasH = CGFloat(h)

        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        ctx.translateBy(x: 0, y: canvasH)
        ctx.scaleBy(x: 1, y: -1)

        // Follow the web overlay: paint at the OCR-detected bubble box directly.
        // The shared YOLO bubble detector already returns whole-balloon boxes
        // (refined + padded upstream, same as the web), so ray-casting an outline
        // here only risks escaping into the panel art. Just clamp to the canvas.
        var resolved: [(bubble: CGRect, text: String, bg: NSColor)] = []
        for b in bubbles {
            let trimmed = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let r = b.rect
            let x = max(2, r.minX), y = max(2, r.minY)
            let bubbleRect = CGRect(
                x: x, y: y,
                width: min(canvasW - 4 - x, r.width),
                height: min(canvasH - 4 - y, r.height)
            )
            resolved.append((bubbleRect, trimmed, b.nsColor))
        }

        // Merge overlapping bubbles (two text rects inside the same balloon
        // expanded to the same outline → union them, keep both texts).
        let merged = mergeOverlapping(resolved)

        let responseScale = textScale.clamped(to: 0.75...1.6)
        for (bubble, text, bg) in merged {
            paintBubble(in: ctx, bubble: bubble, text: text, bg: bg, canvas: CGSize(width: canvasW, height: canvasH), textScale: responseScale)
        }

        return ctx.makeImage()
    }

    // MARK: - Overlap merging

    private static func mergeOverlapping(_ items: [(bubble: CGRect, text: String, bg: NSColor)]) -> [(bubble: CGRect, text: String, bg: NSColor)] {
        // Merge resolved bubble rects that overlap.
        // Two cases both require merging:
        //   a) Ray-casting gives the same balloon outline for two text rects
        //      inside the same speech balloon → IoU ≈ 1.0.
        //   b) Ray-casting fails for one and falls back to a padded rect:
        //      padded rects from adjacent tategaki columns still overlap
        //      by 35-70% → caught by the overlap-of-smaller check.
        // Threshold: 0.35 of the smaller box must be inside the larger,
        // OR IoU > 0.20. Adjacent separate balloons have < 5% overlap
        // so they're never merged.
        guard !items.isEmpty else { return [] }
        var used = Set<Int>()
        var out: [(bubble: CGRect, text: String, bg: NSColor)] = []
        for i in items.indices {
            if used.contains(i) { continue }
            var rect = items[i].bubble
            var texts = [items[i].text]
            let bg = items[i].bg
            used.insert(i)
            var grew = true
            while grew {
                grew = false
                for j in items.indices where !used.contains(j) {
                    let inter = rect.intersection(items[j].bubble)
                    guard !inter.isNull, !inter.isEmpty else { continue }
                    let interArea = inter.width * inter.height
                    let aArea = rect.width * rect.height
                    let bArea = items[j].bubble.width * items[j].bubble.height
                    let smaller = min(aArea, bArea)
                    let unionArea = aArea + bArea - interArea
                    let iou = unionArea > 0 ? interArea / unionArea : 0
                    let ofSmaller = smaller > 0 ? interArea / smaller : 0
                    if iou > 0.20 || ofSmaller > 0.35 {
                        rect = rect.union(items[j].bubble)
                        texts.append(items[j].text)
                        used.insert(j)
                        grew = true
                    }
                }
            }
            out.append((rect, texts.joined(separator: " "), bg))
        }
        return out
    }

    // MARK: - Bubble outline detection (ray casting)

    /// Walk outward from a few seed points around the text rect until rays
    /// hit the bubble's black border. Returns the bounding box of the
    /// detected bubble interior, or nil if the text isn't inside a closed
    /// shape (e.g. floating SFX).
    private static func findBubbleBounds(reader: PixelReader, around textRect: CGRect) -> CGRect? {
        let textWidth = textRect.width
        let textHeight = textRect.height
        // How far we're willing to walk. For tategaki, a single detected
        // column is ~25-40px wide but the full balloon may be 150-200px wide
        // (5-6 columns). The ray walking LEFT from column 1 needs to travel
        // 150px to find the right border. Use 4× the larger dimension, capped
        // at 200px. The area/axis sanity checks below still catch escaping rays.
        let maxWalk = Int(min(200, max(60, max(textWidth, textHeight) * 2)))

        // Probe just outside each edge of the text rect, mid-edge — those
        // points sit in the bubble's white interior margin (between text and
        // border). For each, walk outward perpendicular to the edge.
        let safePad = 3
        let topSeed    = (Int(textRect.midX), max(0, Int(textRect.minY) - safePad))
        let bottomSeed = (Int(textRect.midX), min(reader.height - 1, Int(textRect.maxY) + safePad))
        let leftSeed   = (max(0, Int(textRect.minX) - safePad), Int(textRect.midY))
        let rightSeed  = (min(reader.width - 1, Int(textRect.maxX) + safePad), Int(textRect.midY))

        let up    = rayWalk(reader: reader, from: topSeed,    dx: 0,  dy: -1, max: maxWalk)
        let down  = rayWalk(reader: reader, from: bottomSeed, dx: 0,  dy: 1,  max: maxWalk)
        let left  = rayWalk(reader: reader, from: leftSeed,   dx: -1, dy: 0,  max: maxWalk)
        let right = rayWalk(reader: reader, from: rightSeed,  dx: 1,  dy: 0,  max: maxWalk)
        
        let upLeft    = rayWalk(reader: reader, from: topSeed,    dx: -1, dy: -1, max: maxWalk)
        let upRight   = rayWalk(reader: reader, from: topSeed,    dx: 1,  dy: -1, max: maxWalk)
        let downLeft  = rayWalk(reader: reader, from: bottomSeed, dx: -1, dy: 1,  max: maxWalk)
        let downRight = rayWalk(reader: reader, from: bottomSeed, dx: 1,  dy: 1,  max: maxWalk)

        // No bubble found if any of the cardinal directions ran out without hitting a border.
        // Diagonals are extra data but cardinals are essential for a box.
        guard let up, let down, let left, let right else { return nil }

        // Compute bubble extent
        var minX = Int(textRect.minX) - left
        var maxX = Int(textRect.maxX) + right
        var minY = Int(textRect.minY) - up
        var maxY = Int(textRect.maxY) + down
        
        // Refine with diagonals if they hit something
        if let ul = upLeft {
            minX = min(minX, Int(textRect.midX) - ul)
            minY = min(minY, Int(textRect.minY) - ul)
        }
        if let ur = upRight {
            maxX = max(maxX, Int(textRect.midX) + ur)
            minY = min(minY, Int(textRect.minY) - ur)
        }
        if let dl = downLeft {
            minX = min(minX, Int(textRect.midX) - dl)
            maxY = max(maxY, Int(textRect.maxY) + dl)
        }
        if let dr = downRight {
            maxX = max(maxX, Int(textRect.midX) + dr)
            maxY = max(maxY, Int(textRect.maxY) + dr)
        }

        let bounds = CGRect(
            x: CGFloat(max(0, minX)),
            y: CGFloat(max(0, minY)),
            width: CGFloat(min(reader.width - 1, maxX) - max(0, minX)),
            height: CGFloat(min(reader.height - 1, maxY) - max(0, minY))
        )

        // Sanity 1: bubble must be at least slightly larger than the text
        // rect — otherwise the ray hit text glyphs and reported the text
        // rect itself.
        if bounds.width < textWidth + 8 || bounds.height < textHeight + 8 {
            return nil
        }
        // Sanity 2: bubble area can't blow up beyond ~12× the text rect area.
        // When rays escape through a gap in the outline the bounds get
        // dragged toward the panel border and the result is a page-spanning
        // rectangle that paints over neighbouring bubbles. Reject — caller
        // will fall back to a moderately-padded text rect.
        let textArea = textWidth * textHeight
        let bubbleArea = bounds.width * bounds.height
        if textArea > 0, bubbleArea / textArea > 12 {
            return nil
        }
        // Sanity 3: per-axis ratio. Tategaki columns are narrow — one column
        // may be 25px wide while the full balloon spans 5 columns (125px+).
        // Allow up to 10× on width so multi-column tategaki isn't rejected.
        // Height stays at 4× (columns typically fill the balloon height).
        if bounds.width > textWidth * 10 || bounds.height > textHeight * 4 {
            return nil
        }

        return bounds
    }

    /// Walk pixel-by-pixel in (dx, dy) starting at `from`. Returns the
    /// distance to the first sustained dark-pixel line (the bubble border),
    /// or nil if we never hit one within `max` steps.
    private static func rayWalk(reader: PixelReader, from: (Int, Int), dx: Int, dy: Int, max: Int) -> Int? {
        let (x0, y0) = from
        var consecutiveDark = 0
        let darkThreshold: CGFloat = 0.45
        for step in 1...max {
            let x = x0 + dx * step
            let y = y0 + dy * step
            if x < 0 || x >= reader.width || y < 0 || y >= reader.height {
                // Walked off image without finding a border — not inside a
                // bubble at this side.
                return nil
            }
            let b = reader.brightness(x: x, y: y)
            if b < darkThreshold {
                consecutiveDark += 1
                // 2 consecutive dark pixels = bubble border (1 could be noise
                // or a stray glyph pixel that leaked outside the text rect).
                if consecutiveDark >= 2 {
                    return step - consecutiveDark
                }
            } else {
                consecutiveDark = 0
            }
        }
        return nil
    }

    // MARK: - Per-bubble paint

    private static func paintBubble(
        in ctx: CGContext,
        bubble: CGRect,
        text: String,
        bg: NSColor,
        canvas: CGSize,
        textScale: CGFloat
    ) {
        // Grow if too small for readable text (single-char bubbles, etc.)
        let bgRect = fitForText(text: text, around: bubble, canvas: canvas, textScale: textScale)

        let radius = min(14, bgRect.height * 0.28)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let fill = bg.usingColorSpace(.sRGB) ?? NSColor.white

        ctx.saveGState()
        // Repaint the balloon interior in its own SAMPLED colour with a soft
        // feathered edge (the web overlay's `box-shadow: 0 0 6px 4px bg`), rather
        // than a hard white box + black outline — so the fill blends into the
        // original bubble border and the surrounding page instead of stamping a
        // visible rectangle over the art.
        ctx.setShadow(offset: .zero, blur: max(3, bgRect.height * 0.05), color: fill.cgColor)
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        let inset: CGFloat = max(6 * textScale, bgRect.height * 0.08)
        let drawRect = CGRect(
            x: bgRect.minX + inset,
            y: canvas.height - bgRect.maxY + inset,
            width: bgRect.width - inset * 2,
            height: bgRect.height - inset * 2
        )
        drawCenteredText(text, in: drawRect, ctx: ctx, color: textColor(forFill: fill), textScale: textScale)
        ctx.restoreGState()
    }

    /// Legible text colour for a fill (web's `textColorFor`): white on a dark
    /// balloon, near-black on a light one.
    private static func textColor(forFill fill: NSColor) -> NSColor {
        let c = fill.usingColorSpace(.sRGB) ?? fill
        let lum = 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        return lum < 0.5 ? .white : NSColor(white: 0.07, alpha: 1)
    }

    private static func fitForText(text: String, around rect: CGRect, canvas: CGSize, textScale: CGFloat) -> CGRect {
        // Strategy: keep the bubble's CENTER fixed. Detected bubbles are
        // (usually) tategaki — tall + narrow. The translation is short
        // wide English. Forcing English into a narrow column wrapped to
        // ~6px-wide leaves the bubble narrow but absurdly tall. Instead:
        //   1. Pick a font that scales with the bubble's *area*, not just
        //      its height, with a 10pt floor for readability.
        //   2. If the wrapped text still exceeds 1.5× the bubble height,
        //      grow the WIDTH instead of the height to find a friendlier
        //      aspect ratio (no taller than the original × 1.5 ever).
        //   3. Center the rectangle on the original bubble's centre so we
        //      don't drift into neighbouring panels.
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minW: CGFloat = 70 * textScale, minH: CGFloat = 30 * textScale
        var bubble = CGRect(
            x: center.x - max(rect.width, minW) / 2,
            y: center.y - max(rect.height, minH) / 2,
            width: max(rect.width, minW),
            height: max(rect.height, minH)
        )

        let textInset: CGFloat = 8 * textScale
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping

        // Font size: scale with the smaller bubble dimension, clamped 10-18.
        let smaller = min(bubble.width, bubble.height)
        let targetFontSize: CGFloat = max(10 * textScale, min(smaller * 0.30 * textScale, 18 * textScale))
        let font = NSFont(name: "Comic Sans MS Bold", size: targetFontSize) ?? NSFont.systemFont(ofSize: targetFontSize, weight: .bold)

        func measure(at width: CGFloat) -> CGSize {
            let bounds = NSAttributedString(string: text, attributes: [
                .font: font, .paragraphStyle: style
            ]).boundingRect(
                with: CGSize(width: width - textInset * 2, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return CGSize(width: ceil(bounds.width) + textInset * 2,
                          height: ceil(bounds.height) + textInset * 2)
        }

        // Hard ceiling on vertical growth (was canvas × 0.5 — way too lax).
        let maxH = max(rect.height * 1.5 * textScale, minH * 1.5)
        // Hard ceiling on horizontal growth: 30% of canvas width so a single
        // bubble never spans nearly half the page. Tighter rect.width cap too.
        let maxW = min(canvas.width * 0.42, rect.width * 2.5 * textScale + 40 * textScale)

        // Pass 1 — try the current width.
        var size = measure(at: bubble.width)
        // Pass 2 — if too tall, grow horizontally until we fit under maxH
        //          (binary widen, capped at maxW).
        var probeWidth = bubble.width
        while size.height > maxH, probeWidth < maxW {
            probeWidth = min(probeWidth * 1.5, maxW)
            size = measure(at: probeWidth)
        }
        // Pass 3 — clamp anyway.
        let finalW = min(max(size.width, bubble.width), maxW)
        let finalH = min(size.height, maxH)
        bubble = CGRect(
            x: center.x - finalW / 2,
            y: center.y - finalH / 2,
            width: finalW,
            height: finalH
        )

        // Final sanity clamping to image canvas
        var c = bubble
        if c.minX < 4 { c.origin.x = 4 }
        if c.minY < 4 { c.origin.y = 4 }
        if c.maxX > canvas.width - 4 { c.origin.x = max(4, canvas.width - 4 - c.width) }
        if c.maxY > canvas.height - 4 { c.origin.y = max(4, canvas.height - 4 - c.height) }
        return c
    }

    private static func drawCenteredText(_ text: String, in rect: CGRect, ctx: CGContext, color: NSColor, textScale: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1
        style.hyphenationFactor = 0 // Disable hyphenation to prevent word splitting

        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let preferredFont: CGFloat = max(10 * textScale, min(rect.height * 0.35 * textScale, 18 * textScale))
        var fontSize = preferredFont
        // 6pt floor, matching nyora-web's fitter — one step lower than before so more whole
        // words survive intact before we ever consider breaking one.
        let minFont: CGFloat = 6
        var attr = NSAttributedString()
        var bounds: CGRect = .zero
        var longestWordFits = true

        while fontSize >= minFont {
            let font = NSFont(name: "Comic Sans MS Bold", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)

            // Whole words are unbreakable (byWordWrapping + no hyphenation), so the ONLY way to
            // fit a too-wide word is to shrink the font. Check the longest word explicitly:
            // boundingRect alone would happily report "fits" while a word overflows its line.
            // The unbreakable unit is a whole Latin word but a single CJK character (CJK wraps
            // between characters), so CJK targets don't over-shrink.
            func unitWidth(_ s: String) -> CGFloat {
                NSAttributedString(string: s, attributes: [.font: font]).size().width
            }
            let longestWordWidth = words.map { word -> CGFloat in
                word.unicodeScalars.contains(where: TextFit.isCJK)
                    ? (word.map { unitWidth(String($0)) }.max() ?? 0)
                    : unitWidth(word)
            }.max() ?? 0

            attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style
            ])
            bounds = attr.boundingRect(
                with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )

            longestWordFits = longestWordWidth <= rect.width * 0.95
            if bounds.height <= rect.height && longestWordFits {
                break
            }
            fontSize -= 0.5
        }

        // Last resort: a single token (e.g. a long URL) that can't fit whole even at the 6pt
        // floor. Break WITHIN the word rather than let the CTFrame clip it — mirrors the web,
        // which prefers breaking a URL over silently swallowing the text. Whole-word shrink is
        // always attempted first above; this only engages when that genuinely can't succeed.
        if !longestWordFits {
            let floorSize = max(minFont, fontSize)
            style.lineBreakMode = .byCharWrapping
            attr = NSAttributedString(string: text, attributes: [
                .font: NSFont(name: "Comic Sans MS Bold", size: floorSize) ?? NSFont.systemFont(ofSize: floorSize, weight: .bold),
                .foregroundColor: color,
                .paragraphStyle: style
            ])
            bounds = attr.boundingRect(
                with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }

        let h = min(bounds.height, rect.height)
        let originY = rect.midY - h / 2
        let textRect = CGRect(x: rect.minX, y: originY, width: rect.width, height: h)
        let path = CGPath(rect: textRect, transform: nil)
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, attr.length), path, nil)
        CTFrameDraw(frame, ctx)
    }
}

// MARK: - PixelReader

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Direct read access to a CGImage's bytes. Only supports the standard
/// premultiplied-RGBA format Vision/CoreGraphics decode hands us; falls back
/// to nil for exotic pixel layouts (caller skips ray-casting).
private final class PixelReader {
    private let bytes: [UInt8]   // Swift-owned copy; no raw pointer lifetime dependency
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytesPerPixel: Int
    let length: Int

    init?(cgImage: CGImage) {
        guard let provider = cgImage.dataProvider,
              let cfData = provider.data,
              let p = CFDataGetBytePtr(cfData) else { return nil }
        let bpp = cgImage.bitsPerPixel / 8
        // We need at least 3 channels (RGB). 1 (grayscale) is also fine for
        // brightness but we'd index differently — restrict to common cases.
        guard bpp == 4 || bpp == 3 || bpp == 1 else { return nil }
        let len = CFDataGetLength(cfData)
        self.bytes = Array(UnsafeBufferPointer(start: p, count: len))
        self.width = cgImage.width
        self.height = cgImage.height
        self.bytesPerRow = cgImage.bytesPerRow
        self.bytesPerPixel = bpp
        self.length = len
    }

    /// Brightness 0..1. Bounds-checked.
    @inline(__always)
    func brightness(x: Int, y: Int) -> CGFloat {
        let off = y * bytesPerRow + x * bytesPerPixel
        guard off + bytesPerPixel - 1 < length else { return 0 }
        if bytesPerPixel == 1 {
            return CGFloat(bytes[off]) / 255
        }
        let r = CGFloat(bytes[off])
        let g = CGFloat(bytes[off + 1])
        let b = CGFloat(bytes[off + 2])
        return (r + g + b) / (3 * 255)
    }
}
