import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import AppKit

/// Observable owner of chapter-wide translation state.
///
/// Single source of truth — the UI binds to `pageResults` and `pageImageSizes`
/// directly via `@EnvironmentObject` / `@ObservedObject`. Internally runs a
/// single background `Task` that translates every page of the chapter
/// sequentially: download → OCR (with webtoon tile support) → MT.
///
/// One instance lives on AppState; we don't tear it down between chapters,
/// just call `start(chapterId:...)` again — it cancels the current task and
/// resets state.
@MainActor
final class ChapterTranslator: ObservableObject {
    /// Shared instance — the global `NativeColorizer` re-triggers translation
    /// repaints on this, so both must reference the same translator AppState uses.
    static let shared = ChapterTranslator()

    /// pageIndex → translated blocks
    @Published var pageResults: [Int: [TranslatedBlock]] = [:]
    /// pageIndex → source image pixel size (used by overlay for coord mapping)
    @Published var pageImageSizes: [Int: CGSize] = [:]
    /// pageIndex → painted image (original with translations baked into bubbles).
    /// Reader prefers this over the source URL when present.
    @Published var paintedImages: [Int: NSImage] = [:]
    /// Current chapter being translated (nil = idle)
    @Published var activeChapterId: String?
    /// How many pages have completed (cached)
    @Published var completedCount: Int = 0
    /// Total page count of the active chapter
    @Published var totalCount: Int = 0
    /// True between start() and the chapter task finishing
    @Published var isRunning: Bool = false

    private let google = GoogleTranslate()
    private var task: Task<Void, Never>?

    // The settings snapshot used for the current chapter run.
    private var settingsSnapshot: TranslationSettings?
    /// Last response-text scale, kept so a colorizer-triggered repaint matches.
    private var responseScale: CGFloat = 1.0

    /// Cancel any in-flight work and start translating a new chapter, beginning
    /// from `startAt` (the page the user is on) so it's painted first.
    func start(
        chapterId: String,
        pageUrls: [URL],
        sourceLang: String,
        targetCode: String,
        settings: TranslationSettings,
        responseTextScale: CGFloat = 1.0,
        startAt: Int = 0
    ) {
        if isRunning && activeChapterId == chapterId { return }
        task?.cancel()

        activeChapterId = chapterId
        pageResults = [:]
        pageImageSizes = [:]
        completedCount = 0
        totalCount = pageUrls.count
        isRunning = true
        settingsSnapshot = settings
        responseScale = responseTextScale

        log("start chapter=\(chapterId) pages=\(pageUrls.count) from=\(startAt) src=\(sourceLang) tgt=\(targetCode) llm=\(settings.hasLLMConfigured && !settings.isOffline)")

        task = Task { [weak self] in
            await self?.runLoop(chapterId: chapterId, pageUrls: pageUrls,
                                sourceLang: sourceLang, targetCode: targetCode,
                                settings: settings,
                                responseTextScale: responseTextScale,
                                startAt: startAt)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        log("stop chapter=\(activeChapterId ?? "nil")")
    }


    func reset() {
        stop()
        activeChapterId = nil
        pageResults = [:]
        pageImageSizes = [:]
        paintedImages = [:]
        completedCount = 0
        totalCount = 0
    }

    // MARK: - Pipeline (runs on background priority, posts results back to MainActor)

    private func runLoop(
        chapterId: String,
        pageUrls: [URL],
        sourceLang: String,
        targetCode: String,
        settings: TranslationSettings,
        responseTextScale: CGFloat = 1.0,
        startAt: Int = 0
    ) async {
        // Bounded page parallelism. Unlimited fan-out overwhelms the CDN
        // (40+ simultaneous downloads → timeouts). 8 in-flight pages saturates
        // the Vision OperationQueue (cap=8) and keeps Google MT + download
        // fully pipelined without hammering the image server.
        let maxConcurrent = 8
        var queue = Array(pageUrls.enumerated())
        // Translate the page the user is on FIRST, then forward, then wrap — so
        // the visible page paints quickly instead of after every earlier page.
        // Keys stay the original page index.
        if startAt > 0, startAt < queue.count {
            queue = Array(queue[startAt...]) + Array(queue[..<startAt])
        }
        await withTaskGroup(of: Void.self) { group in
            func enqueue() {
                guard !Task.isCancelled, !queue.isEmpty else { return }
                let (idx, url) = queue.removeFirst()
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.translateOnePage(
                        idx: idx, url: url,
                        sourceLang: sourceLang, targetCode: targetCode,
                        settings: settings,
                        responseTextScale: responseTextScale
                    )
                }
            }
            for _ in 0..<min(maxConcurrent, queue.count) { enqueue() }
            for await _ in group {
                if Task.isCancelled {
                    log("cancelled mid-loop")
                    group.cancelAll()
                    break
                }
                enqueue()
            }
        }
        log("loop complete for \(chapterId)")
        await finish()
    }

    /// Per-page work, factored out so both the chapter loop and the
    /// single-page entry point (`translateSinglePage`) share the exact same
    /// bubble-detect → per-bubble OCR → Apple Intelligence refine → MT pipeline.
    ///
    /// `onStage` (optional, MainActor-isolated) is called as the pipeline
    /// transitions between phases so the reader HUD can advance its chips.
    /// Chapter-loop callers leave it `nil` (the chapter UI uses its own
    /// progress affordance); ⌘T passes one that drives `AppState.beginStage`.
    private func translateOnePage(
        idx: Int,
        url: URL,
        sourceLang: String,
        targetCode: String,
        settings: TranslationSettings,
        responseTextScale: CGFloat,
        onStage: (@MainActor @Sendable (TranslationStage) -> Void)? = nil
    ) async {
        do {
            let (cgImage, imageSize) = try await downloadImage(url: url)
            if Task.isCancelled { return }

            log("page \(idx): downloaded \(Int(imageSize.width))×\(Int(imageSize.height))")

            // Native ONNX OCR pipeline (nyora-web's proven models, run on-device via
            // ONNX Runtime — no WKWebView): a shared bubble YOLO detector localizes speech
            // balloons, then manga-ocr (ja) / PaddleOCR (zh/en/ko) reads each one — detection
            // AND recognition in a single call that returns bubble boxes already paired with
            // their text. Replaces Apple Vision.
            let bubbles: [Bubble]
            do {
                let ocrBlocks = try await NativeOcrProvider.shared.ocr(cgImage: cgImage, lang: Self.ocrLang(sourceLang))
                bubbles = ocrBlocks
                    .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .map { Bubble(text: $0.text, box: $0.box) }
                log("page \(idx): native OCR read \(bubbles.count) bubbles")
            } catch {
                log("page \(idx): native OCR failed — \(error.localizedDescription)")
                await commit(pageIdx: idx, blocks: [], imageSize: imageSize)
                return
            }
            if Task.isCancelled { return }

            if bubbles.isEmpty {
                await commit(pageIdx: idx, blocks: [], imageSize: imageSize)
                return
            }

            // No pre-translation OCR cleanup step. Apple Intelligence runs
            // AFTER translation now (polishing the target-language output),
            // not before — per user preference.
            var blocks: [TranslatedBlock] = bubbles.enumerated().map { (bIdx, bubble) in
                TranslatedBlock(
                    id: "p\(idx)_b\(bIdx)",
                    originalText: bubble.text,
                    translatedText: bubble.text,
                    boundingBox: bubble.box,
                    state: .translating,
                    backgroundColor: Color(white: 1.0)
                )
            }

            // ── Translation ─────────────────────────────────────────────
            // Google Translate is the PRIMARY MT (web parity — most accurate for manga).
            // Apple Intelligence then OPTIONALLY polishes the output on-device.
            //
            // OCR cleanup first: collapse repeated ellipses/middle-dots/dashes
            // ("…・…・・" → "…"), strip the union pipe, drop stray ASCII digits.
            if let onStage { await MainActor.run { onStage(.mt) } }
            let originals = blocks.map { Self.cleanOcrForMT($0.originalText) }
            let aiTargetLang = await MainActor.run { settings.targetLang }
            var translations: [String]
            do {
                translations = try await google.translateBatch(originals, to: targetCode)
                log("page \(idx): Google MT done, first='\(translations.first?.prefix(40) ?? "")'")
            } catch {
                log("page \(idx): Google MT failed — \(error.localizedDescription)")
                translations = originals
            }

            if Task.isCancelled { return }

            blocks = blocks.enumerated().map { (i, block) in
                var b = block
                b.translatedText = translations[safe: i] ?? block.originalText
                b.state = .mt
                b.backgroundColor = sampleBgColor(cgImage: cgImage, box: block.boundingBox)
                return b
            }
            // Publish the MT result immediately; the optional polish overwrites it.
            await commit(pageIdx: idx, blocks: blocks, imageSize: imageSize)
            await paintAndPublish(pageIdx: idx, cgImage: cgImage, blocks: blocks, imageSize: imageSize, responseTextScale: responseTextScale)

            // Optional BYOK LLM refine — one chat call rewrites the whole page's Google
            // drafts, kept coherent in reading order and using the series-context
            // "reference" for names/terms. Falls back to the Google text when the LLM
            // isn't configured or the reply can't be split back 1:1 (mirrors the web).
            let (llmOn, endpoint, apiKey, model, refCtx) = await MainActor.run {
                (settings.hasLLMConfigured && !settings.isOffline,
                 settings.effectiveEndpoint, settings.apiKey, settings.effectiveModel, settings.context)
            }
            if llmOn {
                if let onStage { await MainActor.run { onStage(.refining) } }
                let originalsForLLM = blocks.map(\.originalText)
                let draftsForLLM = blocks.map(\.translatedText)
                do {
                    let refined = try await LLMRefiner.refine(
                        originals: originalsForLLM, drafts: draftsForLLM,
                        targetLangName: aiTargetLang, context: refCtx,
                        endpoint: endpoint, apiKey: apiKey, model: model
                    )
                    if Task.isCancelled { return }
                    if let refined, refined.count == blocks.count {
                        blocks = blocks.enumerated().map { (i, block) in
                            var b = block
                            if let new = refined[safe: i]?.trimmingCharacters(in: .whitespacesAndNewlines), !new.isEmpty {
                                b.translatedText = new
                            }
                            b.state = .refined
                            return b
                        }
                        log("page \(idx): LLM refined \(blocks.count) bubbles")
                        await commit(pageIdx: idx, blocks: blocks, imageSize: imageSize)
                        await paintAndPublish(pageIdx: idx, cgImage: cgImage, blocks: blocks, imageSize: imageSize, responseTextScale: responseTextScale)
                    } else {
                        log("page \(idx): LLM refine misaligned — keeping Google MT")
                    }
                } catch {
                    log("page \(idx): LLM refine failed — \(error.localizedDescription)")
                }
            }
        } catch {
            log("page \(idx): ERROR \(error.localizedDescription)")
        }
    }

    /// Translate a single page in place — used by ⌘T. Same pipeline as the
    /// chapter loop, just one page. Publishes results to `pageResults[pageIndex]`
    /// and `paintedImages[pageIndex]`, which the reader already binds to.
    /// Returns when the page is done (after MT, and after LLM refine if enabled).
    func translateSinglePage(
        chapterId: String,
        pageIndex: Int,
        pageUrl: URL,
        sourceLang: String,
        targetCode: String,
        settings: TranslationSettings,
        responseTextScale: CGFloat = 1.0,
        onStage: (@MainActor @Sendable (TranslationStage) -> Void)? = nil
    ) async {
        // Short-circuit: if this page has already been translated in this
        // chapter (chapter-mode auto-translate or earlier ⌘T) and we have a
        // painted result, don't re-run the pipeline. The reader is already
        // showing the painted bubbles.
        if activeChapterId == chapterId,
           let blocks = pageResults[pageIndex],
           !blocks.isEmpty,
           paintedImages[pageIndex] != nil {
            log("singlePage chapter=\(chapterId) idx=\(pageIndex) — already translated (\(blocks.count) blocks), skipping")
            return
        }

        // Cancel any in-flight chapter loop so we don't fight it for the actor.
        task?.cancel()
        task = nil
        activeChapterId = chapterId
        isRunning = true
        settingsSnapshot = settings
        responseScale = responseTextScale
        log("singlePage chapter=\(chapterId) idx=\(pageIndex) src=\(sourceLang) tgt=\(targetCode) llm=\(settings.hasLLMConfigured && !settings.isOffline)")

        await translateOnePage(
            idx: pageIndex, url: pageUrl,
            sourceLang: sourceLang, targetCode: targetCode,
            settings: settings,
            responseTextScale: responseTextScale,
            onStage: onStage
        )
        await finish()
    }

    private func commit(pageIdx: Int, blocks: [TranslatedBlock], imageSize: CGSize) async {
        await MainActor.run {
            pageResults[pageIdx] = blocks
            pageImageSizes[pageIdx] = imageSize
            completedCount = pageResults.count
        }
    }

    /// Paint the translation into the page image and publish — runs off-main
    /// so we don't block the OCR loop. Called after each commit.
    private func paintAndPublish(pageIdx: Int, cgImage: CGImage, blocks: [TranslatedBlock], imageSize: CGSize, responseTextScale: CGFloat) async {
        // Filter out blocks with no usable translation — painting an empty
        // white box on the page just makes the result look broken.
        var dropped: [String] = []
        let bubbles: [PageImagePainter.Bubble] = blocks.compactMap { block in
            let t = block.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else {
                dropped.append("'\(block.originalText.prefix(20))' (empty translation)")
                return nil
            }
            // Sampled balloon-fill colour → sRGB components so the painter repaints
            // the bubble in its own colour (not a flat white box).
            let ns = NSColor(block.backgroundColor).usingColorSpace(.sRGB) ?? .white
            return PageImagePainter.Bubble(
                rect: block.boundingBox, text: t,
                bgR: Double(ns.redComponent), bgG: Double(ns.greenComponent), bgB: Double(ns.blueComponent)
            )
        }
        if !dropped.isEmpty {
            log("page \(pageIdx): dropped \(dropped.count) bubbles: \(dropped.joined(separator: ", "))")
        }
        guard !bubbles.isEmpty else {
            log("page \(pageIdx): no non-empty translations, skipping paint")
            return
        }
        // Compose with colorization: if a colorized version of this page exists,
        // paint the bubbles onto IT so translate + colorize show together (same
        // source image → same pixel size, so the bubble coords line up). Otherwise
        // paint on the original; the colorizer re-triggers a repaint when its page
        // finishes (see NativeColorizer.colorizeOnePage → repaintOnColorized).
        let baseCG: CGImage = NativeColorizer.shared.colorizedImages[pageIdx]?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) ?? cgImage
        let painted: CGImage? = await Task.detached(priority: .userInitiated) {
            PageImagePainter.paint(cgImage: baseCG, bubbles: bubbles, originalSize: imageSize, textScale: responseTextScale)
        }.value
        guard let painted else { return }
        let ns = NSImage(cgImage: painted, size: imageSize)
        await MainActor.run {
            paintedImages[pageIdx] = ns
        }
        log("page \(pageIdx): painted image published (\(bubbles.count) bubbles, colorized=\(NativeColorizer.shared.colorizedImages[pageIdx] != nil))")
    }

    /// Re-bake a page's translation onto its now-available colorized image so
    /// translate + colorize compose regardless of which pipeline finished first.
    /// Called by the colorizer when it completes a page. No-op if the page isn't
    /// translated yet.
    func repaintOnColorized(pageIdx: Int) async {
        guard let blocks = pageResults[pageIdx], !blocks.isEmpty,
              let imageSize = pageImageSizes[pageIdx],
              let colorized = NativeColorizer.shared.colorizedImages[pageIdx],
              let cg = colorized.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        await paintAndPublish(pageIdx: pageIdx, cgImage: cg, blocks: blocks,
                              imageSize: imageSize, responseTextScale: responseScale)
    }

    private func finish() async {
        await MainActor.run { isRunning = false }
    }

    // MARK: - OCR helpers

    private struct Bubble { let text: String; let box: CGRect }

    /// Map the reader's source-language string to the OCR engine key the web worker expects
    /// (`ja` manga-ocr, `zh`/`en` PP-OCRv6, `ko` PP-OCRv5). Defaults to Japanese — the common
    /// manga case — mirroring the web's `source = 'ja'` default.
    static func ocrLang(_ sourceLang: String) -> String {
        let s = sourceLang.lowercased()
        if s.hasPrefix("ja") || s.contains("japan") { return "ja" }
        if s.hasPrefix("ko") || s.contains("korea") { return "ko" }
        if s.hasPrefix("zh") || s.contains("chin") { return "zh" }
        if s.hasPrefix("en") || s.contains("engl") { return "en" }
        return "ja"
    }

    /// Human-readable name for an OCR language key, used in the Apple Intelligence
    /// translate instructions ("Translate the given <Japanese> dialogue …").
    static func ocrDisplayName(_ key: String) -> String {
        switch key {
        case "ko": return "Korean"
        case "zh": return "Chinese"
        case "en": return "English"
        default:   return "Japanese"
        }
    }

    /// Tidy OCR output before machine translation: collapse stretched ellipses / middle-dots /
    /// dashes to a single "…", squash repeated whitespace, drop the union pipe separator.
    static func cleanOcrForMT(_ s: String) -> String {
        var t = s
        // Union separator → space
        t = t.replacingOccurrences(of: " | ", with: " ")
        // Replace stretched ellipses (mixing of "…", ".", "・") with one "…"
        let dotsPattern = "[\\u{2026}\\.\\u{30FB}\\u{2014}\\u{2015}]{2,}"
        if let re = try? NSRegularExpression(pattern: dotsPattern) {
            let range = NSRange(t.startIndex..., in: t)
            t = re.stringByReplacingMatches(in: t, range: range, withTemplate: "…")
        }
        // Collapse repeated whitespace
        let wsPattern = "[\\s\\u{3000}]{2,}"
        if let re = try? NSRegularExpression(pattern: wsPattern) {
            let range = NSRange(t.startIndex..., in: t)
            t = re.stringByReplacingMatches(in: t, range: range, withTemplate: " ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Background sampling

    private func sampleBgColor(cgImage: CGImage, box: CGRect) -> Color {
        let w = cgImage.width, h = cgImage.height
        guard let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return .white }
        let bpr = cgImage.bytesPerRow
        let bpp = cgImage.bitsPerPixel / 8
        let xs = [box.minX + box.width * 0.25, box.midX, box.minX + box.width * 0.75]
        let ys = [box.minY + box.height * 0.25, box.midY, box.minY + box.height * 0.75]
        var best: (Int, Color) = (-1, .white)
        for x in xs {
            for y in ys {
                let xi = Int(x), yi = Int(y)
                guard xi >= 0, xi < w, yi >= 0, yi < h else { continue }
                let off = yi * bpr + xi * bpp
                guard off + 2 < CFDataGetLength(data) else { continue }
                let r = Int(ptr[off]), g = Int(ptr[off+1]), b = Int(ptr[off+2])
                let brightness = r + g + b
                if brightness > best.0 {
                    best = (brightness, Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
                }
            }
        }
        return best.1
    }

    // MARK: - Download (identity-encoded URLSession.shared)

    private func downloadImage(url: URL) async throws -> (CGImage, CGSize) {
        var req = URLRequest(url: url)
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, _) = try await URLSession.shared.data(for: req)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw URLError(.cannotDecodeContentData) }
        return (cg, CGSize(width: cg.width, height: cg.height))
    }

    // MARK: - Log

    private func log(_ s: String) {
        let line = "[ChapterTranslator] \(s)\n"
        try? line.appendLine(to: NyoraLog.translate)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }

    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
