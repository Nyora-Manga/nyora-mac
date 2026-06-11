import Vision
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit

/// Apple Vision OCR with the same preprocessing + ensemble strategy used by
/// Nyora Android (`MangaTranslator.preprocessBitmapForOcr` and
/// `OcrProvider.runEnsembleOcr`):
///
///   1. **Preprocess** the page: 1.5× upscale → grayscale → contrast 1.8.
///      This makes text "pop" against screentones and bubble borders.
///   2. **Ensemble** OCR: run 4 parallel Vision passes (JA, ZH, KO, EN), each
///      with its specific recognition language. Score each pass by total text
///      length + CJK-character bonus and keep the winner. Mirrors Android's
///      `ja/zh/ko/en` separate ML Kit recognizers.
///   3. **Tile** very tall webtoon strips (aspect > 2.5) into 1800-px chunks
///      with 200-px overlap, then dedupe.
///
/// This yields the best result Apple Vision can produce on its own, including
/// reasonable handling of vertical Japanese (Vision's `ja-JP` recognizer
/// supports tategaki out of the box — the bottleneck is image quality, which
/// the preprocessing pass addresses).
actor OcrProvider {
    struct MangaBlock {
        let text: String
        let boundingBox: CGRect
    }

    struct TextResult {
        let blocks: [MangaBlock]
        let language: String
        var isEmpty: Bool { blocks.isEmpty }
    }

    /// High-level pipeline tier — single setting that trades quality for
    /// wall-time. Maps internally to (a) the brute-force OCR config grid,
    /// (b) the dHash dedup threshold, (c) whether the Apple Intelligence
    /// polish step runs after MT. Surfaced in Settings → AI Translation →
    /// Pipeline as a single-select Picker.
    enum Tier: String, Sendable, CaseIterable, Codable, Identifiable {
        case fast       // ~1-2 s / page — minimum viable OCR
        case tuned      // Recommended: Fastest with best quality (8-pass grid)
        case balanced   // ~4-5 s / page — 16-pass grid
        case quality    // ~8-10 s / page — full 24-pass grid

        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .fast:     return "Fast"
            case .tuned:    return "Tuned"
            case .balanced: return "Balanced"
            case .quality:  return "Quality"
            }
        }
        public var subtitle: String {
            switch self {
            case .fast:     return "≈ 1s · cardinal rotations only"
            case .tuned:    return "Recommended · Best quality + high speed (8-pass)"
            case .balanced: return "≈ 4s · 8 rotations × 2 layers"
            case .quality:  return "≈ 8s · full 3-layer grid + tategaki split"
            }
        }
        /// When `true` `readBubbleText` runs the column-split for wide
        /// crops (tategaki support). Skipped on .fast to save Vision calls.
        public var runsColumnSplit: Bool { self != .fast }
    }

    /// Pipeline knobs. Defaults reflect the production-best settings; the
    /// per-flag booleans aren't surfaced in Settings anymore (the high-level
    /// `tier` is the only knob the user sees), but they remain in the
    /// struct so power users / future debugging can flip them through code.
    struct PipelineConfig: Sendable {
        var adaptiveUpscale: Bool = true
        var medianDenoise: Bool = true
        var histogramStretch: Bool = true
        var inversionPass: Bool = true
        var rotationPass: Bool = true
        /// High-level speed-vs-quality tier (Settings → AI Translation →
        /// Pipeline).
        var tier: Tier = .quality
        /// Independent on/off for the post-MT Apple Intelligence polish
        /// step. Settings exposes this as a single switch that the user
        /// can flip regardless of which tier they're on.
        var applePolish: Bool = true

        static let `default` = PipelineConfig()
    }

    private let scaleFactor: CGFloat = 2.2
    private let tilePixelHeight: CGFloat = 2200
    private let tileOverlap: CGFloat = 300

    /// Per-crop OCR cache, keyed by the crop's dHash signature. Two bubbles
    /// (or the same bubble visited twice) with visually equivalent crops
    /// produce identical OCR output — so we memoize the result.
    /// Bounded LRU at 500 entries; eviction is O(n) on bump but the bound
    /// stays small enough for it not to matter.
    private var ocrCache: [UInt64: String] = [:]
    private var ocrCacheLRU: [UInt64] = []
    private let ocrCacheCapacity = 500

    // MARK: - Entry point

    func runOcr(cgImage: CGImage,
                imageSize: CGSize,
                sourceLang: String,
                config: PipelineConfig = .default) async -> TextResult {
        let aspect = imageSize.height / max(imageSize.width, 1)
        if aspect > 2.5 {
            return await runTiledOcr(cgImage: cgImage, imageSize: imageSize, sourceLang: sourceLang, config: config)
        }
        // Preprocess once
        let processed = preprocess(cgImage, config: config)

        // FINAL PEAK ENSEMBLE:
        // Pass 1: Normal
        // Pass 2: 90° Rotated (for vertical) — gated on `rotationPass`
        // Pass 3: Inverted (for white-on-black SFX/shouting) — gated on `inversionPass`

        async let normalBlocks = ensembleOcr(image: processed, sourceLang: sourceLang)

        async let rotBlocks: [MangaBlock] = {
            // Rotated pass benefits vertically-set scripts (Japanese tategaki,
            // Chinese 直書き, Korean 세로쓰기). Gate it on the user-controlled
            // toggle but otherwise let it run for any language — Vision
            // gracefully no-ops if rotation doesn't help the source script.
            guard config.rotationPass else { return [] }
            guard let rotated = Self.rotate90CW(processed) else { return [] }
            let blocks = await self.ensembleOcr(image: rotated, sourceLang: sourceLang)
            return Self.mapBoxesFromRotated90CW(blocks, originalSize: CGSize(width: CGFloat(processed.width), height: CGFloat(processed.height)))
        }()

        async let invBlocks: [MangaBlock] = {
            guard config.inversionPass else { return [] }
            guard let inverted = Self.invertImage(processed) else { return [] }
            return await self.ensembleOcr(image: inverted, sourceLang: sourceLang)
        }()

        let combined = await mergeDuplicates(normalBlocks + rotBlocks + invBlocks)
        let mapped = remapToOriginal(blocks: combined, processed: processed, original: imageSize)

        return TextResult(
            blocks: mapped,
            language: Self.detectScript(mapped.map(\.text).joined())
        )
    }

    // MARK: - Tiled OCR for webtoons / very tall images

    private func runTiledOcr(cgImage: CGImage, imageSize: CGSize, sourceLang: String, config: PipelineConfig) async -> TextResult {
        let totalH = imageSize.height
        let step = tilePixelHeight - tileOverlap
        var collected: [MangaBlock] = []

        var y: CGFloat = 0
        while y < totalH {
            let h = min(tilePixelHeight, totalH - y)
            if h < 100 { break }
            let cropRect = CGRect(x: 0, y: y, width: imageSize.width, height: h)
            guard let tile = cgImage.cropping(to: cropRect) else { y += step; continue }
            let processed = preprocess(tile, config: config)

            let tileBlocks = await ensembleOcr(image: processed, sourceLang: sourceLang)
            let mappedToTile = remapToOriginal(
                blocks: tileBlocks,
                processed: processed,
                original: CGSize(width: imageSize.width, height: h)
            )
            // Shift Y by tile offset so we end up in global image coords
            collected.append(contentsOf: mappedToTile.map {
                MangaBlock(
                    text: $0.text,
                    boundingBox: CGRect(
                        x: $0.boundingBox.minX,
                        y: $0.boundingBox.minY + y,
                        width: $0.boundingBox.width,
                        height: $0.boundingBox.height
                    )
                )
            })
            y += step
        }

        let deduped = dedupe(collected)
        return TextResult(blocks: deduped, language: Self.detectScript(deduped.map(\.text).joined()))
    }

    private func dedupe(_ blocks: [MangaBlock]) -> [MangaBlock] {
        var out: [MangaBlock] = []
        for b in blocks {
            let isDup = out.contains { existing in
                existing.text == b.text &&
                abs(existing.boundingBox.midY - b.boundingBox.midY) < 60 &&
                abs(existing.boundingBox.midX - b.boundingBox.midX) < 80
            }
            if !isDup { out.append(b) }
        }
        return out
    }

    // MARK: - Android-style preprocessing
    //
    // From nyora-android/MangaTranslator.kt:preprocessBitmapForOcr —
    //   scaleFactor = 1.5
    //   ColorMatrix setSaturation(0)               // grayscale
    //   ColorMatrix contrast scale=1.8, translate=(-.5*1.8 + .5)*255 = -102
    //
    // Equivalent CIImage chain: scale → grayscale → contrast.

    private func preprocess(_ cgImage: CGImage,
                            targetHeight: CGFloat = 3000,
                            config: PipelineConfig = .default) -> CGImage {
        // Small crops (typical bubble crops — under 400px on the short side)
        // have no pixel detail to amplify; the heavy contrast 3.2 + stretch
        // chain collapses thin Japanese strokes into solid blobs and Vision
        // returns empty. For those we use a gentler chain: a 2× upscale, mild
        // contrast 1.6, light sharpen. Full pages still get the heavy chain.
        let shortSide = min(cgImage.width, cgImage.height)
        let smallCrop = shortSide < 400

        // Target a consistent height (~3000px) instead of a fixed multiplier.
        // This prevents over-scaling high-res images while boosting low-res ones.
        // When `adaptiveUpscale` is off we keep the source resolution.
        let scale: CGFloat
        if !config.adaptiveUpscale {
            scale = 1.0
        } else if smallCrop {
            // Don't blow tiny crops up 6× to 3000px — Lanczos can't invent
            // detail. A 2× bilinear gives Vision enough room without
            // hallucinating strokes.
            scale = 2.0
        } else {
            scale = targetHeight / CGFloat(cgImage.height)
        }
        let w = max(1, Int(CGFloat(cgImage.width) * scale))
        let h = max(1, Int(CGFloat(cgImage.height) * scale))

        var ci = CIImage(cgImage: cgImage)

        // 1. Bilinear/Lanczos upscale — toggle: adaptiveUpscale
        if config.adaptiveUpscale {
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = ci
            lanczos.scale = Float(scale)
            lanczos.aspectRatio = 1.0
            if let scaled = lanczos.outputImage { ci = scaled }
        }

        // 2. Median Filter (Neural Denoise) — toggle: medianDenoise
        //    Removes screentone dots while keeping text edges sharp.
        //    Skip on small crops — at this scale median eats single-stroke
        //    katakana like ノ・リ・ソ.
        if config.medianDenoise && !smallCrop {
            let median = CIFilter.median()
            median.inputImage = ci
            if let m = median.outputImage { ci = m }
        }

        // 3. Grayscale + Subtle Darkening (always on — neutral signal-conditioning)
        let gray = CIFilter.colorControls()
        gray.inputImage = ci
        gray.saturation = 0.0
        gray.brightness = -0.05
        gray.contrast = 1.0
        if let g = gray.outputImage { ci = g }

        // 4. Contrast — mild for bubble crops, peaked for full pages
        let contrast = CIFilter.colorControls()
        contrast.inputImage = ci
        contrast.contrast = smallCrop ? 1.6 : 3.2
        if let c = contrast.outputImage { ci = c }

        // 5. Stretch black and white points by 12% each — toggle: histogramStretch
        //    Skipped on small crops; the stretch's intent is to fix faded
        //    scans, but bubble crops are already high-contrast islands.
        if config.histogramStretch && !smallCrop {
            let stretch = CIFilter.colorPolynomial()
            stretch.inputImage = ci
            stretch.redCoefficients   = CIVector(x: -0.12, y: 1.25, z: 0, w: 0)
            stretch.greenCoefficients = CIVector(x: -0.12, y: 1.25, z: 0, w: 0)
            stretch.blueCoefficients  = CIVector(x: -0.12, y: 1.25, z: 0, w: 0)
            if let s = stretch.outputImage { ci = s }
        }

        // 6. Unsharp Mask — milder on small crops to avoid haloing strokes
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = ci
        sharpen.radius = smallCrop ? 0.8 : 1.2
        sharpen.intensity = smallCrop ? 0.6 : 1.0
        if let s = sharpen.outputImage { ci = s }

        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        let extent = ci.extent.intersection(CGRect(x: 0, y: 0, width: w, height: h))
        if let outCG = ctx.createCGImage(ci, from: extent.isEmpty ? CGRect(x: 0, y: 0, width: w, height: h) : extent) {
            return outCG
        }
        return cgImage
    }

    // MARK: - Ensemble OCR (Android's parallel-pass-per-language strategy)

    private func ensembleOcr(image: CGImage, sourceLang: String) async -> [MangaBlock] {
        let langPasses: [(name: String, langs: [String])]
        switch sourceLang.lowercased() {
        case "japanese", "ja":
            langPasses = [("ja", ["ja-JP"]), ("zh", ["zh-Hans"]), ("ko", ["ko-KR"]), ("en", ["en-US"])]
        case "korean", "ko":
            langPasses = [("ko", ["ko-KR"]), ("ja", ["ja-JP"]), ("en", ["en-US"])]
        case "chinese", "zh":
            langPasses = [("zh", ["zh-Hans", "zh-Hant"]), ("ja", ["ja-JP"]), ("en", ["en-US"])]
        case "auto", "":
            langPasses = [("ja", ["ja-JP"]), ("zh", ["zh-Hans"]), ("ko", ["ko-KR"]), ("en", ["en-US"])]
        default:
            let langs = Self.recognitionLanguages(for: sourceLang)
            langPasses = [(sourceLang, langs)]
        }

        let results = await withTaskGroup(of: (String, [MangaBlock]).self) { group -> [(String, [MangaBlock])] in
            for pass in langPasses {
                group.addTask {
                    let blocks = await Self.visionRecognise(cgImage: image, languages: pass.langs)
                    return (pass.name, blocks)
                }
            }
            var out: [(String, [MangaBlock])] = []
            for await r in group { out.append(r) }
            return out
        }

        let scored = results.map { (name, blocks) -> (String, [MangaBlock], Int) in
            (name, blocks, Self.score(blocks.map(\.text).joined()))
        }
        for s in scored {
            try? "[OcrProvider] pass \(s.0): \(s.1.count) blocks, score=\(s.2)\n".appendLine(to: NyoraLog.translate)
        }
        let best = scored.max { $0.2 < $1.2 } ?? ("none", [], 0)
        return best.1
    }

    private static func score(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        let cjkCount = text.unicodeScalars.reduce(0) { acc, s in
            acc + (
                (0x4E00...0x9FFF).contains(s.value) ||
                (0x3040...0x30FF).contains(s.value) ||
                (0xAC00...0xD7AF).contains(s.value)
                ? 1 : 0
            )
        }
        return text.count + cjkCount * 5
    }

    // MARK: - Vision (single-pass, off-actor on GCD)

    /// Minimum per-candidate confidence we accept from Vision. Below this
    /// the read is almost always rotation hallucination or screentone
    /// pareidolia, and accepting it just feeds the union noise.
    private static let visionConfidenceFloor: VNConfidence = 0.3

    /// Bounded queue for Vision OCR calls.
    ///
    /// **DO NOT replace with `DispatchQueue.global() + DispatchSemaphore`.**
    /// That pattern deadlocks at scale: each dispatched block ACQUIRES a
    /// GCD worker thread immediately, then sits in `semaphore.wait()`
    /// holding that thread. The brute-force grid queues 100s of Vision
    /// calls in parallel — GCD's 64-thread soft cap is hit before the
    /// semaphore slots can drain. Confirmed via `sample(1)` on /tmp/repro_hang
    /// (CLI repro), output: *"Dispatch Thread Soft Limit: 64 reached --
    /// too many dispatch threads blocked in synchronous operations"*.
    ///
    /// `OperationQueue` with `maxConcurrentOperationCount` keeps queued
    /// operations in its own internal queue WITHOUT consuming threads;
    /// it only assigns a worker thread when an operation actually starts.
    /// 8 in flight saturates Vision's internal pipeline (ANE + GPU + CPU)
    /// without choking GCD.
    private static let visionQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 8
        q.qualityOfService = .userInitiated
        q.name = "com.nyora.vision"
        return q
    }()

    private static func visionRecognise(cgImage: CGImage, languages: [String]) async -> [MangaBlock] {
        await withCheckedContinuation { cont in
            Self.visionQueue.addOperation {
                let request = VNRecognizeTextRequest { req, error in
                    guard error == nil,
                          let obs = req.results as? [VNRecognizedTextObservation],
                          !obs.isEmpty
                    else {
                        cont.resume(returning: [])
                        return
                    }
                    let w = CGFloat(cgImage.width)
                    let h = CGFloat(cgImage.height)
                    let blocks: [MangaBlock] = obs.compactMap { o in
                        guard let top = o.topCandidates(1).first,
                              top.confidence >= Self.visionConfidenceFloor,
                              !top.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        else { return nil }
                        let box = CGRect(
                            x: o.boundingBox.minX * w,
                            y: (1.0 - o.boundingBox.maxY) * h,
                            width: o.boundingBox.width * w,
                            height: o.boundingBox.height * h
                        )
                        return MangaBlock(text: top.string, boundingBox: box)
                    }
                    cont.resume(returning: blocks)
                }
                request.recognitionLevel = .accurate
                // Filter to languages actually supported on this device
                let supported = Set((try? request.supportedRecognitionLanguages()) ?? [])
                let usable = languages.filter { supported.contains($0) }
                request.recognitionLanguages = usable.isEmpty ? ["en-US"] : usable
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = false
                request.minimumTextHeight = 0
                // Always pick the latest revision Vision supports on the
                // current macOS. Newer revisions are materially better on CJK
                // at small text heights.
                request.revision = VNRecognizeTextRequest.currentRevision
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do { try handler.perform([request]) } catch { cont.resume(returning: []) }
            }
        }
    }

    // MARK: - Helpers

    private func remapToOriginal(blocks: [MangaBlock], processed: CGImage, original: CGSize) -> [MangaBlock] {
        let sx = original.width / CGFloat(processed.width)
        let sy = original.height / CGFloat(processed.height)
        return blocks.map {
            MangaBlock(
                text: $0.text,
                boundingBox: CGRect(
                    x: $0.boundingBox.minX * sx,
                    y: $0.boundingBox.minY * sy,
                    width: $0.boundingBox.width * sx,
                    height: $0.boundingBox.height * sy
                )
            )
        }
    }

    static func recognitionLanguages(for sourceLang: String) -> [String] {
        switch sourceLang.lowercased() {
        case "japanese", "ja":             return ["ja-JP", "en-US"]
        case "chinese", "zh":             return ["zh-Hans", "zh-Hant", "en-US"]
        case "korean",  "ko":             return ["ko-KR", "en-US"]
        case "russian", "ru":             return ["ru-RU", "en-US"]
        case "arabic",  "ar":             return ["ar-SA", "en-US"]
        case "thai",    "th":             return ["th-TH", "en-US"]
        case "vietnamese", "vi":          return ["vi-VN", "en-US"]
        case "indonesian", "id":          return ["id-ID", "en-US"]
        case "turkish", "tr":             return ["tr-TR", "en-US"]
        case "auto", "english", "en", "": return ["en-US", "ja-JP", "zh-Hans", "ko-KR"]
        default:                           return ["en-US"]
        }
    }

    static func deviceSupportedLanguages() -> [String] {
        let req = VNRecognizeTextRequest()
        return (try? req.supportedRecognitionLanguages()) ?? []
    }

    /// macOS 26+ `RecognizeDocumentsRequest` — Apple's newer document-aware
    /// OCR. Uses a different neural model than `VNRecognizeTextRequest` and
    /// reports structured paragraph/line boxes. Worth running as an extra
    /// detection pass: it sometimes catches text the older model misses.
    /// Returns image-pixel rects, top-left origin. Empty on older macOS.
    func detectViaRecognizeDocuments(cgImage: CGImage, imageSize: CGSize) async -> [CGRect] {
        guard #available(macOS 26.0, *) else { return [] }
        return await Self.runRecognizeDocuments(cgImage: cgImage, imageSize: imageSize)
    }

    @available(macOS 26.0, *)
    private static func runRecognizeDocuments(cgImage: CGImage, imageSize: CGSize) async -> [CGRect] {
        // New Vision API style — request.perform(on:) is async, no handler.
        let request = RecognizeDocumentsRequest()
        do {
            let observations = try await request.perform(on: cgImage)
            let w = imageSize.width, h = imageSize.height
            var rects: [CGRect] = []
            for obs in observations {
                // Each DocumentObservation has nested paragraphs/lines —
                // we walk down to line level for fine-grained bubble rects.
                let document = obs.document
                for paragraph in document.paragraphs {
                    for line in paragraph.lines {
                        // NormalizedRect → CGRect via .cgRect on full image
                        let nb = line.boundingRegion.boundingBox.cgRect
                        if nb.width > 0, nb.height > 0 {
                            rects.append(CGRect(
                                x: nb.minX * w,
                                y: (1.0 - nb.maxY) * h,
                                width: nb.width * w,
                                height: nb.height * h
                            ))
                        }
                    }
                }
            }
            return rects
        } catch {
            return []
        }
    }

    /// Pure text DETECTION (no recognition) — finds every text-like region in
    /// the image. Returns image-pixel bounding boxes (top-left origin).
    ///
    /// `VNDetectTextRectanglesRequest` is far more permissive than
    /// `VNRecognizeTextRequest` — it just looks for text-shaped contours and
    /// doesn't care about language or orientation. Catches vertical Japanese
    /// bubbles that the recognition path misses entirely.
    func detectAllTextRegions(cgImage: CGImage, imageSize: CGSize) async -> [CGRect] {
        // Two passes with different sensitivities. Pass 1 is the default
        // text-rect detector with character boxes for sub-line detail. Pass 2
        // is a VNRecognizeTextRequest in `.fast` mode with a very low
        // `minimumTextHeight` — its bounding boxes alone (regardless of the
        // recognised string) catch small side-comments and single-character
        // bubbles that the default ~3% min-height detector skips.
        async let primary = runRectDetect(cgImage: cgImage, imageSize: imageSize,
                                          characterBoxes: true)
        async let fine    = runRecognizeBoxes(cgImage: cgImage, imageSize: imageSize,
                                              minHeight: 0.003)
        let combined = await primary + fine
        return mergeDuplicates(combined)
    }

    private func runRectDetect(cgImage: CGImage,
                               imageSize: CGSize,
                               characterBoxes: Bool) async -> [CGRect] {
        await withCheckedContinuation { cont in
            Self.visionQueue.addOperation {
                let req = VNDetectTextRectanglesRequest { req, error in
                    guard error == nil,
                          let obs = req.results as? [VNTextObservation]
                    else {
                        cont.resume(returning: [])
                        return
                    }
                    let w = imageSize.width, h = imageSize.height
                    let rects: [CGRect] = obs.compactMap { o in
                        let r = o.boundingBox
                        return CGRect(
                            x: r.minX * w,
                            y: (1.0 - r.maxY) * h,
                            width: r.width * w,
                            height: r.height * h
                        )
                    }
                    cont.resume(returning: rects)
                }
                req.reportCharacterBoxes = characterBoxes
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do { try handler.perform([req]) } catch { cont.resume(returning: []) }
            }
        }
    }

    /// Use VNRecognizeTextRequest's bounding boxes — its `minimumTextHeight`
    /// goes far lower than the rect detector's effective floor, so it picks
    /// up tiny bubbles. We ignore the recognised strings (they're often wrong
    /// for vertical Japanese) and only use the boxes.
    private func runRecognizeBoxes(cgImage: CGImage,
                                   imageSize: CGSize,
                                   minHeight: Float) async -> [CGRect] {
        await withCheckedContinuation { cont in
            Self.visionQueue.addOperation {
                let req = VNRecognizeTextRequest { req, error in
                    guard error == nil,
                          let obs = req.results as? [VNRecognizedTextObservation]
                    else {
                        cont.resume(returning: [])
                        return
                    }
                    let w = imageSize.width, h = imageSize.height
                    let rects: [CGRect] = obs.map { o in
                        let r = o.boundingBox
                        return CGRect(
                            x: r.minX * w,
                            y: (1.0 - r.maxY) * h,
                            width: r.width * w,
                            height: r.height * h
                        )
                    }
                    cont.resume(returning: rects)
                }
                req.recognitionLevel = .fast
                req.usesLanguageCorrection = false
                req.minimumTextHeight = minHeight
                // Use the instance-method form; the class-method variant was
                // deprecated in macOS 12.
                let supported = Set((try? req.supportedRecognitionLanguages()) ?? [])
                let prefer = ["ja-JP", "zh-Hans", "en-US"].filter { supported.contains($0) }
                if !prefer.isEmpty { req.recognitionLanguages = prefer }
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do { try handler.perform([req]) } catch { cont.resume(returning: []) }
            }
        }
    }

    /// Drop near-identical blocks from multiple passes.
    private func mergeDuplicates(_ blocks: [MangaBlock]) -> [MangaBlock] {
        var out: [MangaBlock] = []
        for b in blocks {
            // High IoU + same text = duplicate.
            // High IoU + different text = keep the one with more CJK or longer string.
            if let idx = out.firstIndex(where: { OcrProvider.iou($0.boundingBox, b.boundingBox) > 0.7 }) {
                let existing = out[idx]
                if Self.score(b.text) > Self.score(existing.text) {
                    out[idx] = b
                }
                continue
            }
            out.append(b)
        }
        return out
    }

    /// Drop near-identical rects via a sweep-line: sort by `minX`, keep an
    /// active set whose `maxX ≥ r.minX`. Each new rect only needs to compare
    /// against still-active rects — amortised O(n log n + n·k) where k is the
    /// average active-set size, vs the O(n²) pairwise sweep we used to do.
    private func mergeDuplicates(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        let sorted = rects.sorted { $0.minX < $1.minX }
        var active: [CGRect] = []
        var out: [CGRect] = []
        for r in sorted {
            // Evict rects whose right edge is to the left of `r` — they can
            // no longer overlap anything we'll see later.
            active.removeAll { $0.maxX < r.minX }
            if active.contains(where: { OcrProvider.iou($0, r) > 0.6 }) { continue }
            active.append(r)
            out.append(r)
        }
        return out
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        if inter.isNull || inter.isEmpty { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// Cluster nearby/overlapping text rects into single bubble-sized regions.
    /// Vision's text detection often returns one rect per LINE — we want one
    /// rect per BUBBLE for the in-image overlay.
    ///
    /// Uses a Disjoint-Set Union (Union-Find with path compression + union by
    /// size). The old implementation re-ran an inner "did anything change?"
    /// loop on each cluster start, so a single i picking up a chain of N
    /// neighbours did O(N²) work; DSU collapses that to ~O(N·α(N)). The outer
    /// O(n²) pairwise scan is unchanged (rect-closeness can't be replaced by
    /// a 1-D sweep here because closeness is 2-D and direction-sensitive),
    /// but every found pair is now a single `union(i, j)` call.
    static func clusterRects(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty else { return [] }
        let n = rects.count
        var parent = Array(0..<n)
        var size = Array(repeating: 1, count: n)

        func find(_ x: Int) -> Int {
            var node = x
            while parent[node] != node { node = parent[node] }
            // Path compression: point every visited node directly at the root.
            var hop = x
            while parent[hop] != node {
                let next = parent[hop]
                parent[hop] = node
                hop = next
            }
            return node
        }

        func union(_ x: Int, _ y: Int) {
            let rx = find(x), ry = find(y)
            if rx == ry { return }
            // Union by size for ≤ log(n) tree height.
            if size[rx] < size[ry] {
                parent[rx] = ry
                size[ry] += size[rx]
            } else {
                parent[ry] = rx
                size[rx] += size[ry]
            }
        }

        for i in 0..<n {
            for j in (i + 1)..<n {
                if rectsAreClose(rects[i], rects[j]) {
                    union(i, j)
                }
            }
        }

        var bucket: [Int: CGRect] = [:]
        for i in 0..<n {
            let root = find(i)
            if let existing = bucket[root] {
                bucket[root] = existing.union(rects[i])
            } else {
                bucket[root] = rects[i]
            }
        }
        let clusters = Array(bucket.values)
        return clusters
    }

    private static func rectsAreClose(_ a: CGRect, _ b: CGRect) -> Bool {
        // Size-aware: very different sized rects (typical of "small note
        // bubble next to big dialog bubble") should NOT merge — that's how
        // tiny bubbles get swallowed by their neighbors. Require similar
        // height before considering merge.
        let minH = min(a.height, b.height)
        let maxH = max(a.height, b.height)
        if maxH / max(minH, 1) > 2.2 { return false }

        // Edge-to-edge gap (more precise than center distance — center
        // distance forces large rects to overlap before being "close").
        let gapX = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let gapY = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))

        // Lines in the same vertical bubble: small vertical gap, x-ranges
        // overlap. Lines in the same horizontal bubble: small horizontal gap,
        // y-ranges overlap. Tightened from 1.2× to 0.8× so tight columns of
        // small bubbles stay separate.
        let lineGap   = min(a.height, b.height) * 0.8
        let columnGap = min(a.width,  b.width)  * 0.8
        let xOverlap  = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let yOverlap  = min(a.maxY, b.maxY) - max(a.minY, b.minY)

        let sameColumn = xOverlap > 0 && gapY < lineGap
        let sameRow    = yOverlap > 0 && gapX < columnGap
        return sameColumn || sameRow
    }

    // MARK: - Bubble detection for Japanese (used when CoreML manga-ocr is on)

    /// Find candidate text regions on a Japanese page, in ORIGINAL image
    /// coordinates. Combines two passes:
    ///   1. Normal-orientation Vision pass (catches horizontal SFX/captions)
    ///   2. 90° clockwise rotated pass (catches vertical tategaki — Vision is
    ///      much better at detecting horizontal-looking text)
    /// Boxes from the rotated pass are mapped back to original orientation.
    /// We then merge + dedupe + pad slightly so the crop covers the whole bubble.
    func detectBubbleBoxes(cgImage: CGImage,
                           imageSize: CGSize,
                           sourceLang: String = "auto",
                           config: PipelineConfig = .default) async -> [MangaBlock] {
        let processed = preprocess(cgImage, config: config)
        let pw = CGFloat(processed.width)
        let ph = CGFloat(processed.height)
        let detectLangs = Self.recognitionLanguages(for: sourceLang)

        // Five parallel passes to maximise coverage. Vision's ja-JP RECOGNIZER
        // is sparse on vertical tategaki — it often returns nothing for a
        // bubble it can't read, so we lose the box entirely. Combine:
        //   1. Vision recognize (normal, processed) — best for horizontal text
        //   2. Vision recognize (rot90, processed) — vertical → horizontal (gated)
        //   3. Detection on the ORIGINAL image — preprocessing's high
        //      contrast + unsharp mask kills VNDetectTextRectangles (Vision
        //      detection seems to need smooth gradients to find text contours;
        //      logs show 0/0/0 from the processed pass even when bubbles are
        //      obvious). Running on the raw image gets back to ~10-20 boxes.
        //   4. Detection on rot90 ORIGINAL — catches vertical-text shapes
        //      Vision's contour detector misses in portrait orientation (gated).
        // All boxes feed manga-ocr, which can actually READ tategaki.
        async let normalPass = Self.visionRecognise(cgImage: processed, languages: detectLangs)
        async let rotPass: [MangaBlock] = {
            guard config.rotationPass else { return [] }
            guard let rotated = Self.rotate90CW(processed) else { return [] }
            let blocks = await Self.visionRecognise(cgImage: rotated, languages: detectLangs)
            return Self.mapBoxesFromRotated90CW(blocks, originalSize: CGSize(width: pw, height: ph))
        }()
        async let rawDetect = self.detectAllTextRegions(cgImage: cgImage, imageSize: imageSize)
        async let docDetect = self.detectViaRecognizeDocuments(cgImage: cgImage, imageSize: imageSize)
        async let rotRawDetect: [CGRect] = {
            guard config.rotationPass else { return [] }
            guard let rotated = Self.rotate90CW(cgImage) else { return [] }
            let rects = await self.detectAllTextRegions(
                cgImage: rotated,
                imageSize: CGSize(width: CGFloat(rotated.width), height: CGFloat(rotated.height))
            )
            // Convert rotated-image rects back into MangaBlocks then unrotate
            let blocks = rects.map { MangaBlock(text: "", boundingBox: $0) }
            return Self.mapBoxesFromRotated90CW(blocks, originalSize: imageSize).map { $0.boundingBox }
        }()

        let n = await normalPass
        let r = await rotPass
        let rawRects = await rawDetect
        let rotRects = await rotRawDetect
        let docRects = await docDetect
        // Detection-only boxes are already in ORIGINAL coords (no preprocess
        // scaling to undo). Recognition boxes (n, r) are in processed coords
        // and get rescaled at the end of this function.
        let detectedOriginal: [MangaBlock] = (rawRects + rotRects + docRects).map {
            MangaBlock(text: "", boundingBox: $0)
        }

        try? "[OcrProvider] detect ja: normal=\(n.count) rot90=\(r.count) rawDetect=\(rawRects.count) rotRawDetect=\(rotRects.count) docDetect=\(docRects.count)\n"
            .appendLine(to: NyoraLog.translate)

        // Rescale recognition-pass boxes from processed → original first,
        // then merge with detection boxes (which are already in original
        // coords).
        let sx = imageSize.width / pw
        let sy = imageSize.height / ph
        func rescale(_ b: MangaBlock) -> MangaBlock {
            MangaBlock(
                text: b.text,
                boundingBox: CGRect(
                    x: b.boundingBox.minX * sx,
                    y: b.boundingBox.minY * sy,
                    width: b.boundingBox.width * sx,
                    height: b.boundingBox.height * sy
                )
            )
        }
        let rescaledN = n.map(rescale)
        let rescaledR = r.map(rescale)

        // Merge + Union by IoU. We take the geometric UNION of all boxes that
        // overlap significantly. Raised from 0.2 → 0.4 — the 0.2 threshold
        // was producing 20+ "bubbles" per page where ~10 are actually unique
        // (each real bubble detected once by the recogniser, once by rect
        // detect, once by RecognizeDocuments). Fewer bubbles → linear
        // savings in the brute-force OCR budget downstream.
        var merged: [MangaBlock] = []
        for source in [rescaledN, rescaledR, detectedOriginal] {
            for b in source {
                if let idx = merged.firstIndex(where: { OcrProvider.iou($0.boundingBox, b.boundingBox) > 0.4 }) {
                    let existing = merged[idx]
                    let unionBox = existing.boundingBox.union(b.boundingBox)
                    let betterText = Self.score(b.text) > Self.score(existing.text) ? b.text : existing.text
                    merged[idx] = MangaBlock(text: betterText, boundingBox: unionBox)
                } else {
                    merged.append(b)
                }
            }
        }
        // Second pass: cluster boxes that are now very close after unioning
        return Self.clusterRects(merged.map { $0.boundingBox }).map { MangaBlock(text: "", boundingBox: $0) }
    }

    // MARK: - Per-bubble Apple Vision read
    //
    // Used in the manga-ocr-style pipeline (detect bubbles → crop → read each
    // crop individually) but with Apple Vision as the recogniser instead of
    // CoreML manga-ocr. Mirrors the techniques the page-level OCR already
    // uses: preprocess (upscale + grayscale + contrast + sharpen), parallel
    // language passes, plus a 90° rotated pass so vertical Japanese gets a
    // chance to be read as horizontal.

    /// Read the text content of a single pre-cropped bubble. Returns the
    /// best-scoring string across (normal + rot90) × (ja/zh/ko/en) passes.
    func readBubbleText(crop: CGImage,
                        sourceLang: String,
                        config: PipelineConfig = .default) async -> String {
        // Cache check — same crop, same answer. The dHash is invariant to
        // global brightness/contrast shifts, so re-translating the same page
        // (⌘T twice, or chapter-mode → ⌘T) returns instantly without
        // re-running the brute-force sweep.
        let cropHash = Self.dHash(crop)
        if let cached = ocrCache[cropHash] {
            bumpLRU(cropHash)
            return cached
        }

        let result = await readBubbleTextUncached(crop: crop, sourceLang: sourceLang, config: config)
        storeCache(hash: cropHash, value: result)
        return result
    }

    /// Bounded LRU bookkeeping. Cheap because the cache is only ~500 entries
    /// and the LRU vector is rebalanced via single removeAll on each bump.
    private func bumpLRU(_ hash: UInt64) {
        ocrCacheLRU.removeAll { $0 == hash }
        ocrCacheLRU.append(hash)
    }

    private func storeCache(hash: UInt64, value: String) {
        ocrCache[hash] = value
        ocrCacheLRU.append(hash)
        while ocrCacheLRU.count > ocrCacheCapacity {
            let evict = ocrCacheLRU.removeFirst()
            ocrCache.removeValue(forKey: evict)
        }
    }

    private func readBubbleTextUncached(crop: CGImage,
                                        sourceLang: String,
                                        config: PipelineConfig) async -> String {
        let tier = config.tier
        let aspect = CGFloat(crop.width) / CGFloat(max(crop.height, 1))
        // Column split is tategaki-specific (and expensive). Skip it on
        // the .fast tier where the user has explicitly opted for speed.
        if aspect > 1.6 && tier.runsColumnSplit {
            let columns = Self.splitIntoColumns(crop)
            if columns.count >= 2 {
                let ordered = columns.sorted(by: { $0.minX > $1.minX })
                let parts = await withTaskGroup(of: (Int, String).self) { group in
                    for (i, col) in ordered.enumerated() {
                        guard let sub = crop.cropping(to: col) else { continue }
                        group.addTask {
                            let text = await Self.bruteForceColumnOcr(sub, sourceLang: sourceLang, tier: tier)
                            return (i, text)
                        }
                    }
                    var byIndex: [(Int, String)] = []
                    for await pair in group { byIndex.append(pair) }
                    return byIndex
                        .sorted { $0.0 < $1.0 }
                        .map { $0.1 }
                        .filter { !$0.isEmpty }
                }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
        }
        return await Self.bruteForceColumnOcr(crop, sourceLang: sourceLang, tier: tier)
    }

    /// Return rectangles for each ink column in a tategaki bubble crop.
    /// Detects vertical whitespace valleys in the column-mean luminance profile.
    /// Each returned rect is full-height; only the X-range varies.
    static func splitIntoColumns(_ cg: CGImage, gapThreshold: Double = 240,
                                 minGap: Int = 3, minColumn: Int = 8) -> [CGRect] {
        let w = cg.width, h = cg.height
        let bpr = w * 4
        var data = [UInt8](repeating: 0, count: h * bpr)
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var lum = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var s: Double = 0
            for y in 0..<h { s += Double(data[y * bpr + x * 4]) }
            lum[x] = s / Double(h)
        }

        // Smooth `lum` with a 5-tap box filter using a running-sum trick —
        // O(w) instead of O(w·k). The smoothing cuts false splits from
        // single-pixel screentone gaps; without it the gap detector kept
        // ripping every column down the middle on the test page.
        let smoothed = boxBlur1D(lum, radius: 2)

        // RLE pass over the smoothed signal: collect [inkStart, inkEnd]
        // intervals separated by gap runs ≥ minGap of "gap" samples.
        var cols: [CGRect] = []
        var inkStart: Int?
        var gapRun = 0
        for x in 0..<w {
            let isGap = smoothed[x] >= gapThreshold
            if !isGap {
                if inkStart == nil { inkStart = x }
                gapRun = 0
            } else if let s = inkStart {
                gapRun += 1
                if gapRun >= minGap {
                    let end = x - gapRun + 1
                    if end - s >= minColumn {
                        cols.append(CGRect(x: s, y: 0, width: end - s, height: h))
                    }
                    inkStart = nil
                    gapRun = 0
                }
            }
        }
        if let s = inkStart, w - s >= minColumn {
            cols.append(CGRect(x: s, y: 0, width: w - s, height: h))
        }
        return cols
    }

    /// 1D box-blur (moving-average) using a prefix-sum / sliding-window trick.
    /// O(n) regardless of radius — for each i, the windowed sum is updated
    /// by adding the entering sample and subtracting the leaving one.
    /// Outer samples (near the edges) average over a smaller window so we
    /// don't bias the signal toward the bubble's white border.
    private static func boxBlur1D(_ input: [Double], radius: Int) -> [Double] {
        let n = input.count
        guard n > 0, radius > 0 else { return input }
        var out = [Double](repeating: 0, count: n)
        var window: Double = 0
        var count = 0
        // Seed the window with the first `radius+1` samples.
        for k in 0...min(radius, n - 1) {
            window += input[k]
            count += 1
        }
        for i in 0..<n {
            out[i] = window / Double(count)
            // Slide: the sample leaving on the left, the one entering on the right.
            let leftLeaving = i - radius
            let rightEntering = i + radius + 1
            if rightEntering < n {
                window += input[rightEntering]
                count += 1
            }
            if leftLeaving >= 0 {
                window -= input[leftLeaving]
                count -= 1
            }
        }
        return out
    }

    /// Brute-force OCR a single-column-or-bubble crop.
    ///
    /// The grid is tiered so easy crops finish in ~3 Vision calls; only the
    /// hard ones pay the full cost. We **early-terminate** the union sweep
    /// as soon as the strongest single candidate hits `earlyStopCjk = 6`,
    /// which empirical sweeps showed is enough to capture all material
    /// information in a column.
    ///
    /// Total grid (when not terminated early):
    ///   tonal ∈ {raw, binarize@128, invert} × upscale ∈ {4} × rotation ∈
    ///   {0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°} = 24 Vision calls.
    ///
    /// The previous 120-call grid (5 layers × 3 upscales × 8 rotations) hung
    /// the app — every page launched ~2000 Vision tasks into a GCD pool
    /// with ~6-way concurrency, so the wall-time was multiple minutes per
    /// page. 24 is enough to keep the diagonal-rotation and binarize wins
    /// while staying interactive.
    static func bruteForceColumnOcr(_ cg: CGImage, sourceLang: String, tier: Tier = .quality) async -> String {
        let langs: [String] = recognitionLanguages(for: sourceLang)

        enum Layer { case raw, binarize(UInt8), invert }
        struct Cfg { let layer: Layer; let up: CGFloat; let rot: Int }

        // Config grid is a function of the tier. Lower tiers run a strictly
        // smaller subset so the time budget shrinks linearly.
        let cardinalRotations = [0, 90, 180, 270]
        let allRotations      = [0, 45, 90, 135, 180, 225, 270, 315]
        let configs: [Cfg] = {
            switch tier {
            case .fast:
                // Raw crop × 4 cardinal rotations = 4 configs. Hash-dedup
                // collapses identical pairs (rot0/rot180 often hash close),
                // so typical Vision call count is 2-3 per crop.
                return cardinalRotations.map { Cfg(layer: .raw, up: 4, rot: $0) }
            case .tuned:
                // THE PEAK: Cardinal rotations × Raw + Invert = 8 configs.
                // Best quality/speed ratio: captures vertical + reversed colors.
                return cardinalRotations.flatMap { rot in
                    [Cfg(layer: .raw, up: 4, rot: rot),
                     Cfg(layer: .invert, up: 4, rot: rot)]
                }
            case .balanced:
                // Raw + binarize, all 8 rotations = 16 configs. Drops the
                // invert layer (rarely useful) and shaves ~40% of work.
                return allRotations.flatMap { rot in
                    [Cfg(layer: .raw, up: 4, rot: rot),
                     Cfg(layer: .binarize(128), up: 4, rot: rot)]
                }
            case .quality:
                // Current full grid: 3 layers × 8 rotations = 24 configs.
                return allRotations.flatMap { rot in
                    [Cfg(layer: .raw, up: 4, rot: rot),
                     Cfg(layer: .binarize(128), up: 4, rot: rot),
                     Cfg(layer: .invert, up: 4, rot: rot)]
                }
            }
        }()
        // Early-stop threshold: once the best-so-far candidate hits this many
        // CJK chars we stop issuing new Vision calls. Tier-dependent so the
        // quality tier exhausts the full 24-config grid before deciding.
        // quality = Int.max means "never stop early" — run every config.
        let earlyStopCjk: Int = {
            switch tier {
            case .fast:     return 4
            case .tuned:    return 6
            case .balanced: return 8
            case .quality:  return .max
            }
        }()

        // PHASE 1 — parallel preprocess + perceptual hash. This is the
        // "feature extractor" you asked about: a cheap 64-bit dHash of each
        // transformed image. Two configs whose hashes are within Hamming
        // distance 6 produce visually-equivalent inputs to Vision and would
        // OCR identically, so we collapse them into a single Vision call.
        //
        // Typical reduction on a manga page: ~24 configs → ~10 unique
        // (binarize@128 collapses with raw for already-binary text; invert
        // collapses with raw when the bubble is plain white-on-black).
        struct Prep { let cfg: Cfg; let image: CGImage; let hash: UInt64 }
        let prepared: [Prep] = await withTaskGroup(of: Prep?.self) { group in
            for cfg in configs {
                group.addTask {
                    if Task.isCancelled { return nil }
                    let layer: CGImage = {
                        switch cfg.layer {
                        case .raw:                  return cg
                        case .binarize(let t):      return Self.binarize(cg, threshold: t) ?? cg
                        case .invert:               return Self.invertGrayscale(cg) ?? cg
                        }
                    }()
                    guard let scaled = Self.upscale(layer, factor: cfg.up) else { return nil }
                    guard let rotated = Self.rotateAny(scaled, degrees: cfg.rot) else { return nil }
                    let h = Self.dHash(rotated)
                    return Prep(cfg: cfg, image: rotated, hash: h)
                }
            }
            var out: [Prep] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }

        // PHASE 2 — Hamming-distance dedup. O(n²) on the prepared list, but
        // n ≤ 24 and each comparison is one XOR + popcount, so cost is trivial.
        // Preserve insertion order so Tier 1 (best historical configs) wins
        // ties against later tiers.
        //
        // Threshold 8 picked from /tmp/sync_bench sweep across 10
        // production bubble crops:
        //   ham=6  → 143/160 unique, 3.68s wall   (baseline)
        //   ham=8  → 120/160 unique, 2.91s wall   (-21%, -28 CJK across 10 crops)
        //   ham=12 → 80/160 unique, 1.90s wall   (-48%, but -64 CJK — too aggressive)
        // 8 is the inflection point where dedup wins outpace quality loss.
        // (Tried bumping to 12 with the 16-config grid for speed but quality
        // dropped visibly in production — reverted.)
        var uniqueByHash: [Prep] = []
        // Hamming threshold also varies by tier — looser dedup on fast tiers
        // since users opting for speed accept lower quality.
        let hammingThreshold: Int = {
            switch tier {
            case .fast:     return 16
            case .tuned:    return 14
            case .balanced: return 12
            case .quality:  return 8
            }
        }()
        for p in prepared {
            if uniqueByHash.contains(where: { Self.hamming($0.hash, p.hash) <= hammingThreshold }) {
                continue
            }
            uniqueByHash.append(p)
        }

        // PHASE 3 — parallel Vision OCR on the dedup'd subset.
        let texts: [String] = await withTaskGroup(of: String.self) { group in
            for p in uniqueByHash {
                group.addTask {
                    if Task.isCancelled { return "" }
                    return await Self.visionRecognise(cgImage: p.image, languages: langs)
                        .map(\.text).joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            var collected: [String] = []
            var bestCjk = 0
            for await t in group {
                if !t.isEmpty {
                    collected.append(t)
                    let c = Self.cjkCharCount(t)
                    if c > bestCjk {
                        bestCjk = c
                        if bestCjk >= earlyStopCjk {
                            group.cancelAll()
                            break
                        }
                    }
                }
            }
            return collected
        }

        return Self.unionCandidates(texts)
    }

    /// UNION strategy with similarity-cluster dedup + multi-stage quality
    /// gates. With binarization-layer × 8-rotation sweeping, Vision
    /// hallucinates many near-duplicate variants of the same column
    /// (e.g. 11 garbled readings of "離婚した": "椎醬した", "群醬しね",
    /// "湘悔しな" …). The pipeline below tries to keep only the *real* reads.
    ///
    /// Pipeline:
    ///   0. **Artifact strip** — drop spurious single-stroke leading glyphs
    ///      ("一", "ー", "ニ", "・" …) followed by a space; those are
    ///      almost always the bubble border picked up by 45° rotations.
    ///   1. **Mixed-script rejection** — drop candidates that mix CJK with
    ///      Latin letters; those are misreads ("3井さN", "sEし").
    ///   2. **Density gate** — CJK density ≥ 0.6, ≥ 3 CJK chars total.
    ///   3. **Cluster dedup** — Jaccard on CJK character sets; single-link
    ///      at 0.5 threshold. Longest member becomes cluster rep.
    ///   4. **Accretion** — start from strongest rep; each additional rep
    ///      must contribute ≥ 2 new glyphs. Hard-capped at 2 accretions.
    static func unionCandidates(_ candidates: [String]) -> String {
        guard !candidates.isEmpty else { return "" }
        // 0. Strip rotation-artifact prefixes.
        var stripped = candidates.map(stripRotationArtifacts)
        // 0b. Statistical "一"/"ー"/"・" prefix strip. These CJK glyphs are
        //     also common rotation artifacts (45° passes pick up the bubble
        //     border as 一 / horizontal bar). We can't strip them
        //     unconditionally — "一人" / "一日" are real words — so use a
        //     vote: if MORE THAN HALF of the non-empty candidates share the
        //     same suspicious prefix, AND at least one candidate doesn't
        //     have it, treat it as a column-level artifact and strip it
        //     from every candidate.
        let suspicious: [Character] = ["一", "ー", "・"]
        for suspect in suspicious {
            let withPrefix = stripped.filter { $0.first == suspect }.count
            let withoutPrefix = stripped.filter { !$0.isEmpty && $0.first != suspect }.count
            // Only strip when both populations exist (so we know "without"
            // is reachable) AND the suspect majority dominates.
            if withPrefix > 0, withoutPrefix > 0, withPrefix >= (stripped.count + 1) / 2 {
                stripped = stripped.map { s in
                    guard s.first == suspect else { return s }
                    return String(s.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        // 1-2. Density + mixed-script gates.
        let filtered = stripped.filter { text in
            // Mixed-script rejection: any Latin letter present?
            if text.unicodeScalars.contains(where: {
                ($0.value >= 0x41 && $0.value <= 0x5A) ||
                ($0.value >= 0x61 && $0.value <= 0x7A)
            }) { return false }
            let c = cjkCharCount(text)
            guard c >= 2 else { return false }
            let meaningful = text.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0) &&
                !CharacterSet.punctuationCharacters.contains($0)
            }.count
            guard meaningful > 0 else { return false }
            return Double(c) / Double(meaningful) >= 0.6
        }
        // Fallback: if the strict gates eat every candidate, return the
        // best raw candidate (highest CJK count) instead of empty so the
        // bubble still gets translated. A noisy translation downstream is
        // strictly better than silently dropping the bubble.
        guard !filtered.isEmpty else {
            let salvage = stripped
                .filter { cjkCharCount($0) >= 1 }
                .max { cjkCharCount($0) < cjkCharCount($1) }
            return salvage ?? ""
        }
        var seen = Set<String>()
        let unique = filtered.filter { seen.insert($0).inserted }
        let sorted = unique.sorted { cjkCharCount($0) > cjkCharCount($1) }

        // 2. Similarity-cluster dedup.
        struct Cluster { var rep: String; var chars: Set<Unicode.Scalar> }
        var clusters: [Cluster] = []
        let jaccardThreshold: Double = 0.5
        for candidate in sorted {
            let cChars = cjkSet(candidate)
            var attached = false
            for i in clusters.indices {
                let inter = cChars.intersection(clusters[i].chars).count
                let union = cChars.union(clusters[i].chars).count
                let jacc = union == 0 ? 0 : Double(inter) / Double(union)
                if jacc >= jaccardThreshold {
                    // Same cluster — promote the longer representative.
                    if cjkCharCount(candidate) > cjkCharCount(clusters[i].rep) {
                        clusters[i].rep = candidate
                        clusters[i].chars = cChars
                    }
                    attached = true
                    break
                }
            }
            if !attached { clusters.append(Cluster(rep: candidate, chars: cChars)) }
        }
        // Reps sorted strongest-first.
        let reps = clusters.sorted { cjkCharCount($0.rep) > cjkCharCount($1.rep) }
        guard !reps.isEmpty else { return "" }

        // 3. Accrete cluster reps that contribute new glyphs. CAP at 3 total
        //    accretions — binarization variants frequently produce many small
        //    clusters that pairwise share few chars (so Jaccard doesn't merge
        //    them) but are each pure hallucination. Most legitimate column
        //    reads collapse to 1-2 dominant candidates; the rest is noise.
        var union = reps[0].rep
        var unionCjkChars = reps[0].chars
        var accreted = 0
        let maxAccretion = 2
        for cluster in reps.dropFirst() {
            if accreted >= maxAccretion { break }
            if union.contains(cluster.rep) { continue }
            let newChars = cluster.chars.subtracting(unionCjkChars)
            guard newChars.count >= 2 else { continue }
            union += " " + cluster.rep
            unionCjkChars.formUnion(newChars)
            accreted += 1
        }
        return union
    }

    private static func cjkSet(_ s: String) -> Set<Unicode.Scalar> {
        Set(s.unicodeScalars.filter {
            (0x3040...0x30FF).contains($0.value) ||
            (0x4E00...0x9FFF).contains($0.value) ||
            (0xFF66...0xFF9F).contains($0.value)
        })
    }

    /// Strip leading rotation-artifact glyphs. Diagonal rotations frequently
    /// turn the bubble's rotated border into a leading non-CJK glyph
    /// ("一", "ー", "■", "1", "・", "—", "□", etc.) before the real text.
    /// Repeatedly drop leading non-CJK characters as long as CJK content
    /// remains — this catches every variant without hand-listing them.
    ///
    /// Safe because we only strip when CJK content survives: a candidate
    /// like "Hello" stays intact (no CJK remains after stripping `H`), and
    /// a legitimate read like "あの…" keeps its `あ` (first char is CJK).
    static func stripRotationArtifacts(_ s: String) -> String {
        var working = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while !working.isEmpty {
            let first = working.unicodeScalars.first!
            let isCJK = (0x3040...0x30FF).contains(first.value) ||  // hiragana + katakana
                        (0x4E00...0x9FFF).contains(first.value) ||  // CJK unified ideographs
                        (0xFF66...0xFF9F).contains(first.value)     // halfwidth katakana
            if isCJK { break }
            // Look at the rest — if there's no CJK left, the whole string is
            // non-CJK (Latin, digits, etc.) and we shouldn't keep stripping.
            let rest = String(working.unicodeScalars.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard cjkCharCount(rest) > 0 else { break }
            working = rest
        }
        return working
    }

    // MARK: - Brute-force helpers

    private static func upscale(_ cg: CGImage, factor: CGFloat) -> CGImage? {
        if factor == 1.0 { return cg }
        let ci = CIImage(cgImage: cg)
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = ci; f.scale = Float(factor); f.aspectRatio = 1
        guard let o = f.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(o, from: o.extent)
    }

    private static func boostContrast(_ cg: CGImage, contrast: Float) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        let f = CIFilter.colorControls()
        f.inputImage = ci; f.saturation = 0; f.brightness = -0.05; f.contrast = contrast
        guard let o = f.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(o, from: o.extent)
    }

    /// Binarize a grayscale image at `threshold` — every pixel < threshold
    /// goes to 0 (black), every pixel ≥ threshold goes to 255 (white). Done
    /// via a piecewise-linear `colorPolynomial` filter on the GPU:
    ///   y = clamp((x - t/255) · 1e6, 0, 1)
    /// The huge slope turns the function into a step at `t/255`.
    private static func binarize(_ cg: CGImage, threshold: UInt8) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        // Drop to grayscale first so each channel agrees on the threshold.
        let gray = CIFilter.colorControls()
        gray.inputImage = ci
        gray.saturation = 0
        gray.brightness = 0
        gray.contrast = 1
        guard let g = gray.outputImage else { return nil }
        // Piecewise step around threshold. CIColorPolynomial evaluates
        //   y = c0 + c1·x + c2·x² + c3·x³ per channel, clamped [0,1].
        // We want a steep ramp at t/255 — use a huge linear coefficient and
        // a negative bias so the ramp crosses zero at exactly t/255.
        let t = CGFloat(threshold) / 255
        let slope: CGFloat = 1_000
        let bias  = -slope * t
        let coeffs = CIVector(x: bias, y: slope, z: 0, w: 0)
        let step = CIFilter.colorPolynomial()
        step.inputImage = g
        step.redCoefficients   = coeffs
        step.greenCoefficients = coeffs
        step.blueCoefficients  = coeffs
        guard let o = step.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(o, from: o.extent)
    }

    /// Photographic-negative the grayscale crop. Used to recover white-on-
    /// black SFX and shout text where the ink lives in the "bright" channel
    /// rather than the dark one.
    private static func invertGrayscale(_ cg: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        let gray = CIFilter.colorControls()
        gray.inputImage = ci
        gray.saturation = 0
        gray.brightness = 0
        gray.contrast = 1
        guard let g = gray.outputImage else { return nil }
        let invert = CIFilter.colorInvert()
        invert.inputImage = g
        guard let o = invert.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(o, from: o.extent)
    }

    /// Rotate a CGImage by an arbitrary `degrees` value (CW). Used to expand
    /// the brute-force OCR sweep from 4 canonical rotations to all 8 ordinal
    /// directions (0°/45°/90°/135°/…). For non-axis-aligned rotations the
    /// output canvas is sized to fit the rotated image's bounding box; the
    /// uncovered corners are filled white so VNRecognizeTextRequest doesn't
    /// trip on alpha noise.
    private static func rotateAny(_ cg: CGImage, degrees: Int) -> CGImage? {
        if degrees == 0 { return cg }
        // Fast path for 90°-multiples — no trig, no padding.
        if degrees % 90 == 0 {
            return rotateOrthogonal(cg, degrees: ((degrees % 360) + 360) % 360)
        }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let theta = CGFloat(degrees) * .pi / 180
        let cosT = abs(cos(theta))
        let sinT = abs(sin(theta))
        let outW = Int((w * cosT + h * sinT).rounded(.up))
        let outH = Int((w * sinT + h * cosT).rounded(.up))
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }
        // Fill white — Vision reads paper-style backgrounds better than
        // transparent corners.
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        // Rotate around the centre.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: theta)
        ctx.draw(cg, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }

    private static func rotateOrthogonal(_ cg: CGImage, degrees: Int) -> CGImage? {
        let w = cg.width, h = cg.height
        let outW: Int, outH: Int
        switch degrees {
        case 90, 270: outW = h; outH = w
        case 180:     outW = w; outH = h
        default:      return cg
        }
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }
        switch degrees {
        case 90:  ctx.translateBy(x: CGFloat(outW), y: 0); ctx.rotate(by: .pi / 2)
        case 180: ctx.translateBy(x: CGFloat(outW), y: CGFloat(outH)); ctx.rotate(by: .pi)
        case 270: ctx.translateBy(x: 0, y: CGFloat(outH)); ctx.rotate(by: -.pi / 2)
        default: break
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func cjkCharCount(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { acc, u in
            acc + (((0x3040...0x30FF).contains(u.value) ||
                    (0x4E00...0x9FFF).contains(u.value) ||
                    (0xFF66...0xFF9F).contains(u.value)) ? 1 : 0)
        }
    }

    /// Perceptual difference hash (dHash). Downsample the image to 9×8
    /// grayscale, then for each row compare horizontally-adjacent pixels:
    /// 1 if `left > right`, else 0. 8 rows × 8 comparisons = 64 bits.
    ///
    /// Properties:
    ///   - Invariant to brightness/contrast shifts (relative comparison).
    ///   - Cheap: ~10 µs per image (memory-bandwidth bound on 72-byte buffer).
    ///   - Hamming distance ≤ 6 ≈ "visually equivalent for OCR".
    ///
    /// Used to dedup the brute-force OCR grid — multiple preprocessing
    /// pipelines that converge to similar pixel data only run Vision once.
    static func dHash(_ cg: CGImage) -> UInt64 {
        let w = 9, h = 8
        var data = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &data, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.interpolationQuality = .low
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<8 {
                let l = data[y * w + x]
                let r = data[y * w + x + 1]
                if l > r {
                    hash |= UInt64(1) << UInt64(y * 8 + x)
                }
            }
        }
        return hash
    }

    /// Hamming distance between two 64-bit hashes — just XOR + popcount.
    /// `nonzeroBitCount` compiles to a single `popcnt` / `cnt` instruction.
    @inline(__always)
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - 90° rotation helpers (used for vertical-text detection only)

    private static func invertImage(_ cgImage: CGImage) -> CGImage? {
        let ci = CIImage(cgImage: cgImage)
        let invert = CIFilter.colorInvert()
        invert.inputImage = ci
        guard let out = invert.outputImage else { return nil }
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        return ctx.createCGImage(out, from: out.extent)
    }

    private static func rotate90CW(_ cgImage: CGImage) -> CGImage? {
        let w = cgImage.width, h = cgImage.height
        guard let ctx = CGContext(
            data: nil, width: h, height: w,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func mapBoxesFromRotated90CW(_ blocks: [MangaBlock], originalSize: CGSize) -> [MangaBlock] {
        let W = originalSize.width
        return blocks.map { b in
            let r = b.boundingBox
            return MangaBlock(
                text: b.text,
                boundingBox: CGRect(
                    x: r.minY,
                    y: W - r.minX - r.width,
                    width: r.height,
                    height: r.width
                )
            )
        }
    }

    static func detectScript(_ text: String) -> String {
        for s in text.unicodeScalars {
            if (0xAC00...0xD7AF).contains(s.value) { return "ko" }
            if (0x3040...0x30FF).contains(s.value) { return "ja" }
            if (0x0900...0x097F).contains(s.value) { return "hi" }
        }
        if text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { return "zh" }
        return "en"
    }
}
