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

    private let ocr = OcrProvider()
    private let google = GoogleTranslate()
    private var task: Task<Void, Never>?

    // The settings snapshot used for the current chapter run.
    private var settingsSnapshot: TranslationSettings?

    /// Cancel any in-flight work and start translating a new chapter from page 0.
    func start(
        chapterId: String,
        pageUrls: [URL],
        sourceLang: String,
        targetCode: String,
        settings: TranslationSettings,
        pipelineConfig: OcrProvider.PipelineConfig = .default,
        responseTextScale: CGFloat = 1.0
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

        let aiState: String
        switch AppleIntelligenceRefiner.shared.state {
        case .ready:                       aiState = "ready"
        case .unsupportedOS:               aiState = "unsupportedOS"
        case .unavailable(let reason):     aiState = "unavailable(\(reason))"
        }
        log("start chapter=\(chapterId) pages=\(pageUrls.count) src=\(sourceLang) tgt=\(targetCode) appleAI=\(aiState) pipeline=upscale:\(pipelineConfig.adaptiveUpscale) denoise:\(pipelineConfig.medianDenoise) stretch:\(pipelineConfig.histogramStretch) invert:\(pipelineConfig.inversionPass) rot:\(pipelineConfig.rotationPass)")

        task = Task { [weak self] in
            await self?.runLoop(chapterId: chapterId, pageUrls: pageUrls,
                                sourceLang: sourceLang, targetCode: targetCode,
                                settings: settings, pipelineConfig: pipelineConfig,
                                responseTextScale: responseTextScale)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        log("stop chapter=\(activeChapterId ?? "nil")")
    }

    /// Quick OCR on a single cropped region — used by tap-to-translate.
    /// Returns the joined text of all detected blocks (single string).
    func singleRegionOcr(cgImage: CGImage, sourceLang: String) async -> String {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let result = await ocr.runOcr(cgImage: cgImage, imageSize: size, sourceLang: sourceLang)
        return result.blocks
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// OCR returning one text string per detected block — used by the
    /// translation sheet so each line is rendered as its own entry instead
    /// of a wall of merged text.
    func ocrLines(cgImage: CGImage, sourceLang: String) async -> [String] {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let result = await ocr.runOcr(cgImage: cgImage, imageSize: size, sourceLang: sourceLang)
        return result.blocks
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Pure text detection (no recognition) — returns bounding boxes of every
    /// text-like region. Catches vertical Japanese that recognition misses.
    func detectTextRegions(cgImage: CGImage, imageSize: CGSize) async -> [CGRect] {
        await ocr.detectAllTextRegions(cgImage: cgImage, imageSize: imageSize)
    }

    /// Same as `ocrLines` but also returns each block's bounding box in
    /// image-pixel coords. Used by in-image overlays so translations can be
    /// rendered at the bubble's actual location.
    func ocrLineRects(cgImage: CGImage, sourceLang: String) async -> [(text: String, rect: CGRect)] {
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let result = await ocr.runOcr(cgImage: cgImage, imageSize: size, sourceLang: sourceLang)
        return result.blocks
            .map { ($0.text.trimmingCharacters(in: .whitespacesAndNewlines), $0.boundingBox) }
            .filter { !$0.0.isEmpty }
            .map { (text: $0.0, rect: $0.1) }
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
        pipelineConfig: OcrProvider.PipelineConfig = .default,
        responseTextScale: CGFloat = 1.0
    ) async {
        // Bounded page parallelism. Unlimited fan-out overwhelms the CDN
        // (40+ simultaneous downloads → timeouts). 8 in-flight pages saturates
        // the Vision OperationQueue (cap=8) and keeps Google MT + download
        // fully pipelined without hammering the image server.
        let maxConcurrent = 8
        var queue = Array(pageUrls.enumerated())
        await withTaskGroup(of: Void.self) { group in
            func enqueue() {
                guard !Task.isCancelled, !queue.isEmpty else { return }
                let (idx, url) = queue.removeFirst()
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.translateOnePage(
                        idx: idx, url: url,
                        sourceLang: sourceLang, targetCode: targetCode,
                        settings: settings, pipelineConfig: pipelineConfig,
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
        pipelineConfig: OcrProvider.PipelineConfig,
        responseTextScale: CGFloat,
        onStage: (@MainActor @Sendable (TranslationStage) -> Void)? = nil
    ) async {
        do {
            let (cgImage, imageSize) = try await downloadImage(url: url)
            if Task.isCancelled { return }

            log("page \(idx): downloaded \(Int(imageSize.width))×\(Int(imageSize.height))")

            // Apple Vision pipeline: detect bubble boxes → cluster into
            // bubble-level rects → per-bubble OCR (with preprocess +
            // ensemble + rot90 inside readBubblesWithVision).
            let candidateBoxes = await ocr.detectBubbleBoxes(cgImage: cgImage, imageSize: imageSize, sourceLang: sourceLang, config: pipelineConfig)
            log("page \(idx): Vision detected \(candidateBoxes.count) candidate text boxes")
            // detectBubbleBoxes already runs clusterRects internally — skip the
            // second cluster pass that was merging separate speech balloons into
            // giant mega-boxes. Convert directly to the Bubble type.
            let allBubbles = candidateBoxes.map { Bubble(text: $0.text, box: $0.boundingBox) }
            log("page \(idx): \(allBubbles.count) bubbles to read")
            let bubbles = await readBubblesWithVision(bubbles: allBubbles, fullImage: cgImage, sourceLang: sourceLang, pipelineConfig: pipelineConfig)
            log("page \(idx): Vision KEPT text for \(bubbles.count) bubbles")
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

            // Translation pass. Prefer Apple Intelligence (on-device, free,
            // tone-aware) when available; fall back to Google Translate
            // when AI is unavailable (macOS < 26, AI disabled, or session
            // creation fails).
            //
            // OCR cleanup first: collapse repeated ellipses/middle-dots/
            // dashes ("…・…・・" → "…"), strip the chunk-separator pipe we
            // use inside union, drop stray ASCII digits.
            if let onStage { await MainActor.run { onStage(.mt) } }
            let originals = blocks.map { Self.cleanOcrForMT($0.originalText) }
            // Translation step is Google Translate — more reliable than
            // Apple Intelligence (no safety-filter refusals, no per-bubble
            // length penalty). Apple Intelligence still runs the *polish*
            // step after this, rewriting each line as a manga editor would.
            // Target language as a human-readable string for the polish
            // session ("English", "Hindi", …). Settings stores it that way;
            // falls back to the targetCode ("en", "hi") if missing.
            let aiTargetLang = await MainActor.run { settings.targetLang }
            let translations: [String]
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
            // Publish MT result immediately so the user sees a translation
            // fast; we'll overwrite it with the polished version once Apple
            // Intelligence finishes its post-edit pass.
            await commit(pageIdx: idx, blocks: blocks, imageSize: imageSize)
            await paintAndPublish(pageIdx: idx, cgImage: cgImage, blocks: blocks, imageSize: imageSize, responseTextScale: responseTextScale)

            // Apple Intelligence polish pass — runs AFTER translation when
            // the user has enabled the toggle. Independent of the speed
            // tier; adds 1-3 s per page in exchange for tone-aware editing
            // of the MT output. Silently skipped on macOS < 26.
            if pipelineConfig.applePolish && AppleIntelligenceRefiner.shared.isReady {
                if let onStage { await MainActor.run { onStage(.refining) } }
                let mtTexts = blocks.map(\.translatedText)
                let polished = await AppleIntelligenceRefiner.shared.polishTranslation(
                    mtTexts, targetLang: aiTargetLang
                )
                if Task.isCancelled { return }
                var changed = 0
                blocks = blocks.enumerated().map { (i, block) in
                    var b = block
                    let new = polished[safe: i] ?? block.translatedText
                    if new != block.translatedText { changed += 1 }
                    b.translatedText = new
                    b.state = .refined
                    return b
                }
                log("page \(idx): AI polish rewrote \(changed) / \(blocks.count) bubbles")
                // Re-commit + re-paint with the polished text.
                await commit(pageIdx: idx, blocks: blocks, imageSize: imageSize)
                await paintAndPublish(pageIdx: idx, cgImage: cgImage, blocks: blocks, imageSize: imageSize, responseTextScale: responseTextScale)
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
        pipelineConfig: OcrProvider.PipelineConfig = .default,
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
        log("singlePage chapter=\(chapterId) idx=\(pageIndex) src=\(sourceLang) tgt=\(targetCode) pipeline=upscale:\(pipelineConfig.adaptiveUpscale) denoise:\(pipelineConfig.medianDenoise) stretch:\(pipelineConfig.histogramStretch) invert:\(pipelineConfig.inversionPass) rot:\(pipelineConfig.rotationPass)")

        await translateOnePage(
            idx: pageIndex, url: pageUrl,
            sourceLang: sourceLang, targetCode: targetCode,
            settings: settings, pipelineConfig: pipelineConfig,
            responseTextScale: responseTextScale,
            onStage: onStage
        )
        await finish()
    }

    // MARK: - Apple Vision per-bubble reader
    //
    // Was manga-ocr; now Apple Vision using the same preprocess + ensemble +
    // 90° rotation tricks the page-level OCR uses. Detection finds the bubble
    // boxes, we crop each with padding, then ask Vision (normal + rot90 ×
    // ja/zh/ko/en) to read the crop. Vision's `ja-JP` recogniser handles
    // tategaki when given a tight bubble crop, and the rot90 pass catches
    // text it still gets wrong upright. No fallback grid — empty pages stay
    // empty rather than fabricating hallucinated text.

    private func readBubblesWithVision(
        bubbles: [Bubble],
        fullImage: CGImage,
        sourceLang: String,
        pipelineConfig: OcrProvider.PipelineConfig = .default
    ) async -> [Bubble] {
        // Bubble-level parallelism with explicit bounded concurrency. We
        // capture `ocr` directly (avoids the MainActor hop that `self.ocr`
        // would force inside each Task) and cap in-flight bubbles at 4 so
        // the OcrProvider actor + Vision GCD pool don't get flooded with
        // 20+ simultaneous calls — that case caused page 14 to hang.
        let fullW = CGFloat(fullImage.width)
        let fullH = CGFloat(fullImage.height)
        let ocrRef = ocr  // capture the actor before fanning out
        struct Read { let idx: Int; let bubble: Bubble; let text: String; let skipped: Bool; let reason: String }

        // Pre-compute all crops + dark-ratio screens on the caller (cheap,
        // synchronous, no Vision). Tasks then only do the OCR work.
        struct Pending { let idx: Int; let bubble: Bubble; let crop: CGImage }
        var pending: [Pending] = []
        for (i, bubble) in bubbles.enumerated() {
            let pad: CGFloat = max(12, min(bubble.box.width, bubble.box.height) * 0.25)
            let cropRect = bubble.box.insetBy(dx: -pad, dy: -pad)
            let clamped = CGRect(
                x: max(0, cropRect.minX),
                y: max(0, cropRect.minY),
                width:  min(fullW - max(0, cropRect.minX), cropRect.width),
                height: min(fullH - max(0, cropRect.minY), cropRect.height)
            )
            guard clamped.width > 10, clamped.height > 10,
                  let crop = fullImage.cropping(to: clamped) else { continue }
            let darkRatio = Self.darkPixelRatio(crop)
            if darkRatio < 0.02 {
                log("vision bubble \(i) SKIP empty crop (dark=\(String(format: "%.3f", darkRatio)))")
                continue
            }
            pending.append(Pending(idx: i, bubble: bubble, crop: crop))
        }

        // Bounded-concurrency fan-out. Pump primes maxConcurrent tasks then
        // replenishes one-per-finish so we never exceed the cap.
        let maxConcurrent = 4
        var queue = pending
        let reads: [Read] = await withTaskGroup(of: Read.self) { group in
            func enqueue() {
                if Task.isCancelled || queue.isEmpty { return }
                let p = queue.removeFirst()
                group.addTask {
                    let raw = await ocrRef.readBubbleText(crop: p.crop, sourceLang: sourceLang, config: pipelineConfig)
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        return Read(idx: p.idx, bubble: p.bubble, text: text, skipped: true, reason: "empty OCR")
                    }
                    // Accept any script — not just Japanese. Korean (hangul),
                    // Chinese, and sound effects in romaji all need translation.
                    let meaningfulChars = text.unicodeScalars.filter {
                        !CharacterSet.punctuationCharacters.contains($0) &&
                        !CharacterSet.symbols.contains($0) &&
                        !CharacterSet.whitespaces.contains($0)
                    }.count
                    if meaningfulChars < 2 {
                        return Read(idx: p.idx, bubble: p.bubble, text: text, skipped: true, reason: "no real content")
                    }
                    return Read(idx: p.idx, bubble: p.bubble, text: text, skipped: false, reason: "")
                }
            }
            for _ in 0..<maxConcurrent { enqueue() }
            var collected: [Read] = []
            while let r = await group.next() {
                collected.append(r)
                if Task.isCancelled { group.cancelAll(); break }
                enqueue()
            }
            return collected.sorted { $0.idx < $1.idx }
        }

        var out: [Bubble] = []
        var textCounts: [String: Int] = [:]
        for read in reads {
            if read.skipped {
                log("vision bubble \(read.idx) DISCARD '\(read.text)' (\(read.reason))")
                continue
            }
            log("vision bubble \(read.idx) KEEP '\(read.text)'")
            textCounts[read.text, default: 0] += 1
            out.append(Bubble(text: read.text, box: read.bubble.box))
        }
        let hallucinations = Set(textCounts.filter { $0.value >= 3 }.keys)
        if !hallucinations.isEmpty {
            log("hallucination purge: \(hallucinations.map { "'\($0)'" }.joined(separator: ", "))")
            out.removeAll { hallucinations.contains($0.text) }
        }
        return dedupeOverlappingBubbles(out)
    }

    /// Fraction of pixels darker than 50% brightness. Used to gate empty
    /// crops before manga-ocr (which hallucinates on whitespace). Samples
    /// every 4th pixel for speed — accuracy isn't critical, we just need to
    /// distinguish "has text" from "blank".
    /// Sanitize an OCR string before Google Translate sees it. The union /
    /// brute-force pipeline emits things like "の…・…・・", "But, with that
    /// in mind... . . .", or "の | は | か" (our union separator).
    /// MT handles those eventually but the cleaner the input, the cleaner
    /// the translation — and shorter strings cost fewer characters at the
    /// MT provider.
    ///
    /// Cleanup steps (order matters):
    ///   1. Replace our union separator " | " with " ".
    ///   2. Collapse runs of horizontal-ellipsis / dots / middle-dot / dashes
    ///      to a single "…".
    ///   3. Collapse runs of full-width space + half-width space to one space.
    ///   4. Trim trailing whitespace / punctuation noise.
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

    private static func darkPixelRatio(_ cgImage: CGImage) -> Double {
        guard let data = cgImage.dataProvider?.data,
              CFDataGetBytePtr(data) != nil else { return 0.5 }
        let bpp = cgImage.bitsPerPixel / 8
        guard bpp == 4 || bpp == 3 || bpp == 1 else { return 0.5 }
        let w = cgImage.width, h = cgImage.height
        let bpr = cgImage.bytesPerRow
        let length = CFDataGetLength(data)
        var dark = 0, total = 0
        let stride = 4
        return withExtendedLifetime(data) { () -> Double in
            let ptr = CFDataGetBytePtr(data)!
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let off = y * bpr + x * bpp
                    if off + bpp - 1 < length {
                        let brightness: Int
                        if bpp == 1 {
                            brightness = Int(ptr[off])
                        } else {
                            brightness = (Int(ptr[off]) + Int(ptr[off+1]) + Int(ptr[off+2])) / 3
                        }
                        if brightness < 128 { dark += 1 }
                        total += 1
                    }
                    x += stride
                }
                y += stride
            }
            return total > 0 ? Double(dark) / Double(total) : 0
        }
    }

    /// Drop near-duplicate bubbles — the grid fallback often produces multiple
    /// tiles covering the same speech bubble, all returning the same text.
    /// IoU > 0.4 OR identical text + close centers ⇒ drop.
    private func dedupeOverlappingBubbles(_ bubbles: [Bubble]) -> [Bubble] {
        var result: [Bubble] = []
        for b in bubbles {
            let dup = result.contains { existing in
                if existing.text == b.text {
                    let dx = abs(existing.box.midX - b.box.midX)
                    let dy = abs(existing.box.midY - b.box.midY)
                    if dx < 100 && dy < 100 { return true }
                }
                let inter = existing.box.intersection(b.box)
                if inter.isNull || inter.isEmpty { return false }
                let unionArea = existing.box.union(b.box)
                let iou = (inter.width * inter.height) / max(1, unionArea.width * unionArea.height)
                return iou > 0.4
            }
            if !dup { result.append(b) }
        }
        return result
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
        let bubbles: [(rect: CGRect, text: String)] = blocks.compactMap { block in
            let t = block.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else {
                dropped.append("'\(block.originalText.prefix(20))' (empty translation)")
                return nil
            }
            return (block.boundingBox, t)
        }
        if !dropped.isEmpty {
            log("page \(pageIdx): dropped \(dropped.count) bubbles: \(dropped.joined(separator: ", "))")
        }
        guard !bubbles.isEmpty else {
            log("page \(pageIdx): no non-empty translations, skipping paint")
            return
        }
        let painted: CGImage? = await Task.detached(priority: .userInitiated) {
            PageImagePainter.paint(cgImage: cgImage, bubbles: bubbles, originalSize: imageSize, textScale: responseTextScale)
        }.value
        guard let painted else { return }
        let ns = NSImage(cgImage: painted, size: imageSize)
        await MainActor.run {
            paintedImages[pageIdx] = ns
        }
        log("page \(pageIdx): painted image published (\(bubbles.count) bubbles)")
    }

    private func finish() async {
        await MainActor.run { isRunning = false }
    }

    // MARK: - Bubble clustering (ports Android's grid-merge logic)

    private struct Bubble { let text: String; let box: CGRect }

    /// Brute-force fallback: when Vision finds no text candidates, slice the
    /// page into a 4-column × 5-row grid with 30% overlap and treat each tile
    /// as a candidate bubble. manga-ocr returns text for tiles that actually
    /// contain Japanese; the CJK filter in `readBubblesWithCoreML` discards
    /// tiles that don't.
    ///
    /// 4×5 = 20 tiles per page × ~0.5s per manga-ocr call ≈ 10s extra per
    /// page when this fallback kicks in. Only runs when Vision fails.
    private func generateGridTiles(imageSize: CGSize) -> [Bubble] {
        let cols = 4
        let rows = 5
        let tileW = imageSize.width / CGFloat(cols) * 1.3   // 30% overlap
        let tileH = imageSize.height / CGFloat(rows) * 1.3
        let stepX = imageSize.width / CGFloat(cols)
        let stepY = imageSize.height / CGFloat(rows)
        var out: [Bubble] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x = CGFloat(c) * stepX
                let y = CGFloat(r) * stepY
                let w = min(tileW, imageSize.width - x)
                let h = min(tileH, imageSize.height - y)
                if w < 50 || h < 50 { continue }
                out.append(Bubble(text: "", box: CGRect(x: x, y: y, width: w, height: h)))
            }
        }
        return out
    }

    private func clusterBubbles(_ blocks: [OcrProvider.MangaBlock]) -> [Bubble] {
        guard !blocks.isEmpty else { return [] }
        var used = Set<Int>()
        var result: [Bubble] = []
        let sorted = blocks.indices.sorted {
            blocks[$0].boundingBox.minY < blocks[$1].boundingBox.minY
        }

        for i in sorted {
            guard !used.contains(i) else { continue }
            var cluster = [blocks[i]]
            used.insert(i)
            var changed = true
            while changed {
                changed = false
                for j in sorted where !used.contains(j) {
                    if cluster.contains(where: { isClose($0.boundingBox, blocks[j].boundingBox) }) {
                        cluster.append(blocks[j])
                        used.insert(j)
                        changed = true
                    }
                }
            }
            let text = cluster
                .sorted { $0.boundingBox.minY < $1.boundingBox.minY }
                .map(\.text)
                .joined(separator: " ")
            let box = cluster.reduce(cluster[0].boundingBox) { $0.union($1.boundingBox) }
            result.append(Bubble(text: text, box: box))
        }
        return result
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        let hOv = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let vOv = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let vGap = a.maxY < b.minY ? b.minY - a.maxY : (b.maxY < a.minY ? a.minY - b.maxY : 0)
        let hGap = a.maxX < b.minX ? b.minX - a.maxX : (b.maxX < a.minX ? a.minX - b.maxX : 0)
        let minH = min(a.height, b.height)
        let avgH = (a.height + b.height) / 2

        // Stacked text lines (horizontal layout) or stacked column tops
        // (vertical Japanese reads top-to-bottom in each column): small vertical
        // gap, any X-overlap.
        let vNear = vGap <= max(35, avgH * 0.6) && hOv > 0
        // Vertical Japanese in adjacent columns within the same bubble: large
        // Y-overlap (full column height), horizontal gap up to ~70% of the
        // column height (column spacing scales with text size, not column
        // width which is just one character). Without this, every column
        // becomes its own "bubble" and gets a separate painted rect.
        let hNear = hGap <= max(40, avgH * 0.7) && vOv >= minH * 0.3
        return vNear || hNear || a.intersects(b)
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
