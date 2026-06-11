import Foundation
import AppKit
import CoreGraphics
import ImageIO
import SwiftUI

actor MangaTranslator {
    private let ocr = OcrProvider()
    private let googleTranslate = GoogleTranslate()
    private let storyBrain = StoryBrain()

    // Caches keyed by chapterId
    private var chapterCache:   [String: [String: String]] = [:]  // id → refined
    private var mtCache:        [String: [String: String]] = [:]  // id → mt draft
    private var pageBlockCache: [String: [Int: [TranslatedBlock]]] = [:]  // id → page → blocks
    private var refinedTextCache: [String: String] = [:]

    // Android-style chapter-wide translation cache:
    // chapterId → pageIndex → (translated blocks, source image dimensions)
    private var chapterPageResults: [String: [Int: (blocks: [TranslatedBlock], imageSize: CGSize)]] = [:]
    private var activeChapterTask: Task<Void, Never>?
    private var activeChapterId: String?

    typealias PageReadyCallback = @MainActor @Sendable (Int, [TranslatedBlock], CGSize) -> Void

    // MARK: - Public API

    func clearChapterContext(chapterId: String) {
        chapterCache.removeValue(forKey: chapterId)
        mtCache.removeValue(forKey: chapterId)
        pageBlockCache.removeValue(forKey: chapterId)
        chapterPageResults.removeValue(forKey: chapterId)
        Task { await storyBrain.clear() }
    }

    /// Cache lookup — returns previously-translated page if available.
    func cachedPage(chapterId: String, pageIndex: Int) -> (blocks: [TranslatedBlock], imageSize: CGSize)? {
        chapterPageResults[chapterId]?[pageIndex]
    }

    /// Android pattern: pre-translate every page of the chapter in the background.
    /// The callback fires (on MainActor) for each page as soon as its blocks
    /// are ready, so the UI can update the overlay immediately if the user is
    /// already viewing that page.
    func startChapter(
        chapterId: String,
        pageUrls: [URL],
        sourceLang: String,
        targetCode: String,
        pipelineConfig: OcrProvider.PipelineConfig = .default,
        onPageReady: @escaping PageReadyCallback
    ) {
        // Cancel any in-flight chapter translation
        activeChapterTask?.cancel()
        activeChapterId = chapterId
        if chapterPageResults[chapterId] == nil {
            chapterPageResults[chapterId] = [:]
        }

        let cache = chapterPageResults[chapterId] ?? [:]

        activeChapterTask = Task { [weak self] in
            guard let self else { return }
            try? "chapter: start id=\(chapterId) pages=\(pageUrls.count) src=\(sourceLang) tgt=\(targetCode)\n".appendLine(to: NyoraLog.translate)

            for (idx, url) in pageUrls.enumerated() {
                if Task.isCancelled {
                    try? "chapter: cancelled at page \(idx)\n".appendLine(to: NyoraLog.translate)
                    return
                }

                // Skip if already cached
                if let cached = cache[idx] {
                    await onPageReady(idx, cached.blocks, cached.imageSize)
                    continue
                }

                do {
                    let (cgImage, imageSize) = try await MangaTranslator.downloadImage(url: url)
                    if Task.isCancelled { return }

                    let ocrResult = await self.ocr.runOcr(
                        cgImage: cgImage, imageSize: imageSize,
                        sourceLang: sourceLang, config: pipelineConfig
                    )
                    if Task.isCancelled { return }

                    try? "chapter: page \(idx) OCR \(ocrResult.blocks.count) blocks\n".appendLine(to: NyoraLog.translate)

                    if ocrResult.blocks.isEmpty {
                        await self.storePageResult(chapterId: chapterId, pageIdx: idx, blocks: [], imageSize: imageSize)
                        await onPageReady(idx, [], imageSize)
                        continue
                    }

                    let bubbles = await self.mergeBlocksIntoBubbles(ocrResult.blocks)
                    var blocks = await self.buildInitialBlocks(
                        bubbles: bubbles, pageIndex: idx, chapterId: chapterId, cgImage: cgImage
                    )

                    // MT pass (always — Google Translate, no key needed)
                    blocks = await self.runMTPass(blocks: blocks, chapterId: chapterId, targetCode: targetCode)

                    if Task.isCancelled { return }

                    await self.storePageResult(chapterId: chapterId, pageIdx: idx, blocks: blocks, imageSize: imageSize)
                    await onPageReady(idx, blocks, imageSize)
                } catch {
                    try? "chapter: page \(idx) FAILED \(error.localizedDescription)\n".appendLine(to: NyoraLog.translate)
                }
            }

            try? "chapter: done\n".appendLine(to: NyoraLog.translate)
        }
    }

    func stopChapter() {
        activeChapterTask?.cancel()
        activeChapterTask = nil
        activeChapterId = nil
    }

    private func storePageResult(chapterId: String, pageIdx: Int, blocks: [TranslatedBlock], imageSize: CGSize) {
        chapterPageResults[chapterId, default: [:]][pageIdx] = (blocks, imageSize)
    }

    /// Returns an AsyncStream that emits [TranslatedBlock] at each stage:
    /// 1. OCR placeholder (TRANSLATING state)
    /// 2. After MT (MT state)
    /// 3. After LLM refinement (REFINED state)
    func translatePageStream(
        chapterId: String,
        pageIndex: Int,
        cgImage: CGImage,
        imageSize: CGSize,
        settings: TranslationSettings,
        pipelineConfig: OcrProvider.PipelineConfig = .default
    ) -> AsyncStream<[TranslatedBlock]> {
        AsyncStream { cont in
            Task { [weak self] in
                guard let self else { return }
                await self.runTranslateStream(
                    cont: cont,
                    chapterId: chapterId,
                    pageIndex: pageIndex,
                    cgImage: cgImage,
                    imageSize: imageSize,
                    settings: settings,
                    pipelineConfig: pipelineConfig
                )
            }
        }
    }

    private func runTranslateStream(
        cont: AsyncStream<[TranslatedBlock]>.Continuation,
        chapterId: String,
        pageIndex: Int,
        cgImage: CGImage,
        imageSize: CGSize,
        settings: TranslationSettings,
        pipelineConfig: OcrProvider.PipelineConfig
    ) async {
        // Serve from cache if fully refined
        if let cached = pageBlockCache[chapterId]?[pageIndex] {
            let merged = applyCache(blocks: cached, chapterId: chapterId)
            cont.yield(merged)
            if merged.allSatisfy({ $0.state == .refined }) {
                cont.finish(); return
            }
        }

        let sourceLang = await settings.sourceLang
        let targetLang = await settings.targetLang
        let targetCode = await settings.googleLangCode(for: targetLang)

        // OCR — pass source language so Vision uses the right script model
        let ocrResult = await ocr.runOcr(cgImage: cgImage, imageSize: imageSize,
                                          sourceLang: sourceLang, config: pipelineConfig)
        try? "OCR: \(ocrResult.blocks.count) blocks, lang=\(ocrResult.language), src=\(sourceLang)\n".appendLine(to: NyoraLog.translate)
        if ocrResult.blocks.isEmpty { cont.finish(); return }

        let bubbles = mergeBlocksIntoBubbles(ocrResult.blocks)
        var blocks = buildInitialBlocks(bubbles: bubbles, pageIndex: pageIndex,
                                        chapterId: chapterId, cgImage: cgImage)
        pageBlockCache[chapterId, default: [:]][pageIndex] = blocks
        cont.yield(blocks)

        // MT pass — always Google Translate, no key needed.
        // No further LLM step; Apple Intelligence already refined
        // OCR output upstream in the chapter pipeline.
        blocks = await runMTPass(blocks: blocks, chapterId: chapterId,
                                 targetCode: targetCode)
        pageBlockCache[chapterId, default: [:]][pageIndex] = blocks
        cont.yield(blocks)
        cont.finish()
    }

    // MARK: - MT (always Google Translate — free, no key needed)

    private func runMTPass(
        blocks: [TranslatedBlock],
        chapterId: String,
        targetCode: String
    ) async -> [TranslatedBlock] {
        let toTranslate = blocks.filter { $0.state == .translating }
        guard !toTranslate.isEmpty else { return blocks }

        let originals = toTranslate.map(\.originalText)
        try? "MT: \(originals.count) texts → \(targetCode), first='\(originals.first?.prefix(40) ?? "nil")'\n".appendLine(to: NyoraLog.translate)
        let translations: [String]
        do {
            translations = try await googleTranslate.translateBatch(originals, to: targetCode)
            try? "MT done: first='\(translations.first?.prefix(40) ?? "nil")'\n".appendLine(to: NyoraLog.translate)
        } catch {
            try? "MT error: \(error)\n".appendLine(to: NyoraLog.translate)
            translations = originals
        }

        var updated = blocks
        for (i, block) in toTranslate.enumerated() {
            let mt = translations[safe: i] ?? block.originalText
            mtCache[chapterId, default: [:]][block.id] = mt
            if let idx = updated.firstIndex(where: { $0.id == block.id }) {
                updated[idx] = TranslatedBlock(
                    id: block.id,
                    originalText: block.originalText,
                    translatedText: mt,
                    boundingBox: block.boundingBox,
                    state: .mt,
                    backgroundColor: block.backgroundColor
                )
            }
        }
        return updated
    }

    // MARK: - Helpers

    private func buildInitialBlocks(
        bubbles: [MangaBubble],
        pageIndex: Int,
        chapterId: String,
        cgImage: CGImage
    ) -> [TranslatedBlock] {
        bubbles.enumerated().map { (bIndex, bubble) in
            let id = "p\(pageIndex)_b\(bIndex)"
            let refined = chapterCache[chapterId]?[id]
            let mt = mtCache[chapterId]?[id]
            return TranslatedBlock(
                id: id,
                originalText: bubble.text,
                translatedText: refined ?? mt ?? "",
                boundingBox: bubble.box,
                state: refined != nil ? .refined : (mt != nil ? .mt : .translating),
                backgroundColor: sampleBgColor(cgImage: cgImage, box: bubble.box)
            )
        }
    }

    private func applyCache(blocks: [TranslatedBlock], chapterId: String) -> [TranslatedBlock] {
        blocks.map { block in
            let refined = chapterCache[chapterId]?[block.id]
            let mt = mtCache[chapterId]?[block.id]
            guard refined != nil || mt != nil else { return block }
            return TranslatedBlock(
                id: block.id,
                originalText: block.originalText,
                translatedText: refined ?? mt ?? block.translatedText,
                boundingBox: block.boundingBox,
                state: refined != nil ? .refined : .mt,
                backgroundColor: block.backgroundColor
            )
        }
    }

    private func sampleBgColor(cgImage: CGImage, box: CGRect) -> Color {
        let w = cgImage.width, h = cgImage.height
        // Sample from interior points (25%, 50%, 75% along each axis).
        // Corners hit the bubble border (black), giving wrong dark color.
        let xs = [box.minX + box.width * 0.25, box.midX, box.minX + box.width * 0.75]
        let ys = [box.minY + box.height * 0.25, box.midY, box.minY + box.height * 0.75]
        let points: [(Int, Int)] = xs.flatMap { x in ys.map { y in (Int(x), Int(y)) } }
            .filter { $0.0 >= 0 && $0.0 < w && $0.1 >= 0 && $0.1 < h }

        guard !points.isEmpty,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data)
        else { return .white }

        let bpp = cgImage.bitsPerPixel / 8
        let bpr = cgImage.bytesPerRow
        // Pick the BRIGHTEST sampled pixel — that's the bubble background, not the text.
        var best: (Int, Color) = (-1, .white)

        for (x, y) in points {
            let offset = y * bpr + x * bpp
            guard offset + 2 < CFDataGetLength(data) else { continue }
            let r = Int(ptr[offset])
            let g = Int(ptr[offset + 1])
            let b = Int(ptr[offset + 2])
            let brightness = r + g + b
            if brightness > best.0 {
                best = (brightness, Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
            }
        }
        return best.1
    }

    // MARK: - Block clustering (ported from Android)

    private struct MangaBubble { let text: String; let box: CGRect }

    private func mergeBlocksIntoBubbles(_ blocks: [OcrProvider.MangaBlock]) -> [MangaBubble] {
        var used = Set<Int>()
        var result = [MangaBubble]()
        let sorted = blocks.indices.sorted {
            blocks[$0].boundingBox.minY < blocks[$1].boundingBox.minY ||
            (blocks[$0].boundingBox.minY == blocks[$1].boundingBox.minY &&
             blocks[$0].boundingBox.minX < blocks[$1].boundingBox.minX)
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
                .sorted { $0.boundingBox.minY < $1.boundingBox.minY || ($0.boundingBox.minY == $1.boundingBox.minY && $0.boundingBox.minX < $1.boundingBox.minX) }
                .map(\.text).joined(separator: " ")
            let box = cluster.reduce(cluster[0].boundingBox) { $0.union($1.boundingBox) }
            result.append(MangaBubble(text: text, box: box))
        }
        return result
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        let hOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let vOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let vGap = a.maxY < b.minY ? b.minY - a.maxY : (b.maxY < a.minY ? a.minY - b.maxY : 0)
        let hGap = a.maxX < b.minX ? b.minX - a.maxX : (b.maxX < a.minX ? a.minX - b.maxX : 0)
        let minW = min(a.width, b.width)
        let minH = min(a.height, b.height)
        let avgW = (a.width + b.width) / 2
        let avgH = (a.height + b.height) / 2
        let vNeighbor = vGap <= max(25, avgH * 0.35) && hOverlap >= minW * 0.3
        let hNeighbor = hGap <= max(25, avgW * 0.35) && vOverlap >= minH * 0.3
        return vNeighbor || hNeighbor || a.intersects(b)
    }

    // MARK: - Image download helper

    static func downloadImage(url: URL) async throws -> (CGImage, CGSize) {
        // Use URLSession.shared — the same session AsyncImage uses to display
        // these proxy URLs successfully. Our custom ephemeral session with
        // Accept-Encoding: identity was causing URLSession to throw -1016 when
        // the proxy response had mismatched content encoding.
        let (data, response) = try await URLSession.shared.data(from: url)

        // Log to file for debugging
        if let http = response as? HTTPURLResponse {
            let log = "downloadImage: \(http.statusCode) \(url.absoluteString.prefix(120))\n  data=\(data.count) bytes\n  Content-Encoding=\(http.value(forHTTPHeaderField:"Content-Encoding") ?? "none")\n  Content-Type=\(http.value(forHTTPHeaderField:"Content-Type") ?? "?")\n"
            try? log.appendLine(to: NyoraLog.translate)
        }

        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            let first8 = data.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
            try? "downloadImage: DECODE FAILED data=\(data.count) first8=[\(first8)]\n".appendLine(to: NyoraLog.translate)
            throw URLError(.cannotDecodeContentData)
        }
        try? "downloadImage: decoded \(cgImage.width)×\(cgImage.height) bpp=\(cgImage.bitsPerPixel)\n".appendLine(to: NyoraLog.translate)
        return (cgImage, CGSize(width: cgImage.width, height: cgImage.height))
    }
}

extension String {
    func appendLine(to url: URL) throws {
        // Make sure the parent directory exists — first write of the session
        // needs to create ~/Library/Logs/Nyora/ before the FileHandle path.
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try write(to: url, atomically: false, encoding: .utf8)
        }
    }
}

/// Canonical translate-pipeline log path. Falls back to a temp directory only
/// if `~/Library/Logs` isn't reachable, which shouldn't happen on a real Mac.
enum NyoraLog {
    static let translate: URL = {
        let fm = FileManager.default
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Nyora", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Nyora", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("translate.log")
    }()
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
