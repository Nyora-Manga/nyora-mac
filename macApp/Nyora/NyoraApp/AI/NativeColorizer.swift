import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import AppKit
import CryptoKit
import OnnxRuntimeBindings

/// On-device manga colorization, run NATIVELY through ONNX Runtime (no WKWebView).
///
/// This is the exact model + pipeline nyora-web ships (`web/core/colorize/`), ported
/// to Swift/CoreGraphics and driven by the ORT Objective-C API:
/// `manga-colorization-v2` (fp16, ~62 MB, MIT) — a manga/anime-trained generator.
///
/// I/O (verified, matches the web worker): input `input` float32 [1,5,H,W] — channel 0
/// = grayscale in [0,1], channels 1-4 = 0 (automatic colourisation, no hint); output
/// `rgb` float32 [1,3,H,W] in 0..1. H,W must be multiples of 32.
///
/// To keep line art CRISP the model's colour is recombined with the ORIGINAL
/// full-resolution luminance (YCbCr): Y from the source page, Cb/Cr from the
/// upscaled model output scaled by SAT — coloured page, sharp lines.
///
/// One instance lives on AppState (`colorizer`). The reader binds to
/// `colorizedImages[pageIndex]`, exactly like it binds to
/// `chapterTranslator.paintedImages[pageIndex]`.
@MainActor
final class NativeColorizer: ObservableObject {
    static let shared = NativeColorizer()

    // MARK: - Published reader state (mirrors ChapterTranslator)

    /// pageIndex → colorized page. Reader prefers this over the source URL when present.
    @Published var colorizedImages: [Int: NSImage] = [:]
    /// Chapter currently being colorized (nil = idle).
    @Published var activeChapterId: String?
    /// How many pages have finished colorizing.
    @Published var completedCount: Int = 0
    /// Total page count of the active chapter.
    @Published var totalCount: Int = 0
    /// True between start() and the chapter task finishing.
    @Published var isRunning: Bool = false

    // MARK: - Model state (Settings "AI colorization" UI)

    enum ModelState: Equatable {
        case notInstalled
        case downloading(Double)   // 0…1
        case ready
        case failed(String)
    }
    @Published var modelState: ModelState

    /// Approximate download size, for the Settings row.
    static let modelApproxMB = 62

    // MARK: - Model constants (mirror web/core/colorize/model.js — same weights, same hash)

    private static let modelURL = URL(string: "https://huggingface.co/Faridzar/manga-colorization-v2-onnx/resolve/5515e06d31b08ffd107af686cba5e98e95e8d4cf/manga-colorize-fp16.onnx")!
    private static let modelBytes = 61_650_260
    private static let modelSHA256 = "39660d0047ea6f1a0ddee6aa89054997f95ea566f4d56ff762f66dbcf1a1a7ef"

    private let engine = ColorizerEngine()
    private var task: Task<Void, Never>?
    /// The reader's current page — the loop always colorizes the nearest un-done
    /// page to this, so navigation re-prioritises what gets coloured next.
    private var focusPage: Int = 0
    /// Skip the (mapped) SHA-256 re-check after it has passed once this run.
    private var verifiedThisRun = false

    private init() {
        modelState = FileManager.default.fileExists(atPath: Self.modelPath.path) ? .ready : .notInstalled
    }

    // MARK: - Chapter colorization

    /// Cancel any in-flight work and colorize every page of a new chapter,
    /// starting from `startAt` (the page the user is on) so it shows first.
    /// Pages flow into `colorizedImages[idx]` as they finish; the reader binds to it.
    func start(chapterId: String, pageUrls: [URL], startAt: Int = 0) {
        if isRunning && activeChapterId == chapterId { return }
        task?.cancel()

        activeChapterId = chapterId
        colorizedImages = [:]
        completedCount = 0
        totalCount = pageUrls.count
        isRunning = true
        log("start chapter=\(chapterId) pages=\(pageUrls.count) from=\(startAt)")

        task = Task { [weak self] in
            await self?.runLoop(chapterId: chapterId, pageUrls: pageUrls, startAt: startAt)
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
        colorizedImages = [:]
        completedCount = 0
        totalCount = 0
    }

    private func runLoop(chapterId: String, pageUrls: [URL], startAt: Int) async {
        do {
            let path = try await ensureModel()
            try await engine.ensureLoaded(modelPath: path)
        } catch {
            log("model/engine load failed — \(error.localizedDescription)")
            modelState = .failed(error.localizedDescription)
            isRunning = false
            return
        }

        focusPage = max(0, min(startAt, pageUrls.count - 1))
        // FOCUS-DRIVEN: always colorize the un-done page NEAREST to where the user
        // is looking (`focusPage`), re-read every iteration so paging re-prioritises
        // live — the page you're on gets colorized next, then it fans out around it.
        // Sequential: the engine actor serialises inference anyway, so concurrency
        // buys little and this gives the snappiest "colorize the page I'm on".
        while !Task.isCancelled {
            let focus = focusPage
            var next: Int? = nil
            var bestDist = Int.max
            for idx in pageUrls.indices where colorizedImages[idx] == nil {
                let d = abs(idx - focus)
                if d < bestDist { bestDist = d; next = idx }
            }
            guard let pageIdx = next else { break }   // every page done
            await colorizeOnePage(idx: pageIdx, url: pageUrls[pageIdx])
        }
        log("loop complete for \(chapterId)")
        await finish()
    }

    /// Tell the running loop which page the reader is on so it re-prioritises the
    /// nearest un-colorized page to it. Cheap — safe to call on every page turn.
    func setFocus(_ pageIndex: Int) {
        focusPage = pageIndex
    }

    /// Colorize a single page on demand (⌘-colorize / current page). Same model
    /// pass as the chapter loop, just one page; publishes to `colorizedImages[pageIndex]`.
    func colorizeSinglePage(chapterId: String, pageIndex: Int, pageUrl: URL) async {
        if activeChapterId == chapterId, colorizedImages[pageIndex] != nil {
            log("singlePage chapter=\(chapterId) idx=\(pageIndex) — already colorized, skipping")
            return
        }
        do {
            let path = try await ensureModel()
            try await engine.ensureLoaded(modelPath: path)
        } catch {
            log("singlePage model/engine load failed — \(error.localizedDescription)")
            modelState = .failed(error.localizedDescription)
            return
        }
        activeChapterId = chapterId
        isRunning = true
        log("singlePage chapter=\(chapterId) idx=\(pageIndex)")
        await colorizeOnePage(idx: pageIndex, url: pageUrl)
        isRunning = false
    }

    // MARK: - Per-page pipeline

    private func colorizeOnePage(idx: Int, url: URL) async {
        if colorizedImages[idx] != nil { return }
        let t0 = DispatchTime.now()
        do {
            let cg = try await downloadImage(url: url)
            if Task.isCancelled { return }

            // Preprocess (resize_pad + grayscale tensor) off the main actor.
            guard let prep = await Task.detached(priority: .userInitiated, operation: {
                NativeColorizer.preprocess(cg)
            }).value else {
                log("page \(idx): preprocess failed")
                return
            }

            let rgb = try await engine.run(input: prep.input, mh: prep.mh, mw: prep.mw)
            if Task.isCancelled { return }

            // Postprocess (upscale valid region + YCbCr luminance blend) off-main.
            guard let out = await Task.detached(priority: .userInitiated, operation: {
                NativeColorizer.postprocess(original: cg, rgb: rgb, prep: prep)
            }).value else {
                log("page \(idx): postprocess failed")
                return
            }

            let ns = NSImage(cgImage: out, size: NSSize(width: prep.ow, height: prep.oh))
            colorizedImages[idx] = ns
            completedCount = colorizedImages.count
            // Compose with translation: if this page is already translated, re-bake
            // the bubbles onto the freshly colorized image so both show together.
            Task { await ChapterTranslator.shared.repaintOnColorized(pageIdx: idx) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
            log("page \(idx): colorized \(prep.ow)×\(prep.oh) (model \(prep.mw)×\(prep.mh)) in \(Int(ms))ms")
        } catch {
            log("page \(idx): ERROR \(error.localizedDescription)")
        }
    }

    private func finish() async {
        isRunning = false
    }

    // MARK: - Model download / cache / verify (Settings + lazy on first colorize)

    /// Where the verified model lives: ~/Library/Application Support/Nyora/models/.
    static var modelPath: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("Nyora/models", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("manga-colorize-v2-fp16.onnx")
    }

    var modelInstalled: Bool { FileManager.default.fileExists(atPath: Self.modelPath.path) }

    /// Ensure the model is present + integrity-checked; download it if missing.
    /// Returns the local file path. Safe to call before every colorize.
    @discardableResult
    func ensureModel() async throws -> String {
        let dest = Self.modelPath
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            if verifiedThisRun { return dest.path }
            // The cache survives across launches, so a bad copy would otherwise
            // persist forever — re-verify once per run before trusting it.
            let data = try Data(contentsOf: dest, options: .mappedIfSafe)
            if Self.sha256(data) == Self.modelSHA256 {
                verifiedThisRun = true
                modelState = .ready
                return dest.path
            }
            log("cached model failed integrity check — re-downloading")
            try? fm.removeItem(at: dest)
        }
        modelState = .downloading(0)
        try await downloadModel(to: dest)
        verifiedThisRun = true
        modelState = .ready
        log("model downloaded + verified")
        return dest.path
    }

    /// Settings entry point: download the model up-front so the first colorize is instant.
    func downloadModelIfNeeded() async {
        do { try await ensureModel() }
        catch {
            modelState = .failed(error.localizedDescription)
            log("settings download failed — \(error.localizedDescription)")
        }
    }

    /// Settings: delete the cached model to reclaim ~62 MB.
    func deleteModel() {
        try? FileManager.default.removeItem(at: Self.modelPath)
        verifiedThisRun = false
        modelState = .notInstalled
    }

    private func downloadModel(to dest: URL) async throws {
        let delegate = ModelDownloadDelegate { [weak self] pct in
            Task { @MainActor in
                guard let self, case .downloading = self.modelState else { return }
                self.modelState = .downloading(pct)
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let tmp: URL = try await withCheckedThrowingContinuation { c in
            delegate.continuation = c
            session.downloadTask(with: Self.modelURL).resume()
        }
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Verify BEFORE moving into place, so bad bytes never persist in the cache.
        let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
        guard Self.sha256(data) == Self.modelSHA256 else {
            throw ColorizerError.integrity
        }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: dest)
    }

    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Download (identity-encoded URLSession.shared) — same as ChapterTranslator

    private func downloadImage(url: URL) async throws -> CGImage {
        var req = URLRequest(url: url)
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, _) = try await URLSession.shared.data(for: req)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw URLError(.cannotDecodeContentData) }
        return cg
    }

    // MARK: - Log

    private func log(_ s: String) {
        let line = "[NativeColorizer] \(s)\n"
        try? line.appendLine(to: NyoraLog.colorize)
    }
}

// MARK: - Pre / post processing (pure, nonisolated — run off the main actor)
//
// Faithful port of web/core/colorize/worker.js. All CoreGraphics bitmap contexts
// store memory row 0 == the TOP row of the image (drawing flips the bottom-left
// context origin onto top-down CGImage memory, and makeImage() reads it back
// top-down — the two flips cancel). Every buffer below uses that same convention,
// so the per-pixel YCbCr recombination lines up across the model canvas, the
// upscaled colour, and the original page.

extension NativeColorizer {
    /// Prepared model input plus the geometry needed to reconstruct the page.
    struct Prepared: Sendable {
        let input: [Float]   // [1,5,mh,mw] flattened, ch0=gray, ch1-4=0
        let mw: Int          // padded model width  (×32)
        let mh: Int          // padded model height (×32)
        let vw: Int          // valid (unpadded) width  drawn top-left
        let vh: Int          // valid (unpadded) height drawn top-left
        let ow: Int          // original page width
        let oh: Int          // original page height
    }

    nonisolated static func preprocess(_ cg: CGImage) -> Prepared? {
        let ow = cg.width, oh = cg.height
        guard ow > 0, oh > 0 else { return nil }

        // resize_pad (utils/utils.py): portrait → WIDTH = SIZE, landscape →
        // HEIGHT = SIZE*1.5, then pad to a multiple of 32 with white.
        let size = 576.0
        let vw: Int, vh: Int
        if oh < ow {
            vh = Int((size * 1.5).rounded())
            vw = Int(ceil(Double(ow) / (Double(oh) / (size * 1.5))))
        } else {
            vw = Int(size)
            vh = Int(ceil(Double(oh) / (Double(ow) / size)))
        }
        let mw = max(32, Int(ceil(Double(vw) / 32.0)) * 32)
        let mh = max(32, Int(ceil(Double(vh) / 32.0)) * 32)

        guard let ctx = makeContext(width: mw, height: mh) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: mw, height: mh))
        ctx.interpolationQuality = .high
        // Page at TOP-LEFT occupying vw×vh; padding fills the bottom/right. In the
        // context's bottom-left-origin space the top-left region sits at y = mh−vh.
        ctx.draw(cg, in: CGRect(x: 0, y: mh - vh, width: vw, height: vh))

        guard let buf = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let ptr = buf.bindMemory(to: UInt8.self, capacity: bpr * mh)
        let plane = mw * mh
        var input = [Float](repeating: 0, count: 5 * plane)   // ch1-4 stay 0
        input.withUnsafeMutableBufferPointer { ibuf in
            let dst = ibuf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: mh) { y in
                let row = y * bpr
                for x in 0..<mw {
                    let p = row + x * 4
                    let r = Float(ptr[p]), g = Float(ptr[p + 1]), b = Float(ptr[p + 2])
                    dst[y * mw + x] = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                }
            }
        }
        return Prepared(input: input, mw: mw, mh: mh, vw: vw, vh: vh, ow: ow, oh: oh)
    }

    nonisolated static func postprocess(original cg: CGImage, rgb: [Float], prep: Prepared) -> CGImage? {
        let mw = prep.mw, mh = prep.mh, vw = prep.vw, vh = prep.vh, ow = prep.ow, oh = prep.oh
        let plane = mw * mh
        guard rgb.count >= 3 * plane else { return nil }

        // 1) model colour → mw×mh RGBA image
        guard let colorCtx = makeContext(width: mw, height: mh), let cbuf = colorCtx.data else { return nil }
        let cbpr = colorCtx.bytesPerRow
        let cptr = cbuf.bindMemory(to: UInt8.self, capacity: cbpr * mh)
        DispatchQueue.concurrentPerform(iterations: mh) { y in
            let row = y * cbpr
            for x in 0..<mw {
                let i = y * mw + x
                let p = row + x * 4
                cptr[p]     = clamp255(rgb[i] * 255)
                cptr[p + 1] = clamp255(rgb[plane + i] * 255)
                cptr[p + 2] = clamp255(rgb[2 * plane + i] * 255)
                cptr[p + 3] = 255
            }
        }
        guard let colorImage = colorCtx.makeImage(),
              // 2) crop the valid (unpadded) top-left vw×vh region — CGImage crop
              //    is top-left origin, so (0,0,vw,vh) is exactly the drawn page.
              let cropped = colorImage.cropping(to: CGRect(x: 0, y: 0, width: vw, height: vh))
        else { return nil }

        // 3) upscale the model colour to original size
        guard let upCtx = makeContext(width: ow, height: oh), let ubuf = upCtx.data else { return nil }
        upCtx.interpolationQuality = .high
        upCtx.draw(cropped, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        let ubpr = upCtx.bytesPerRow
        let uptr = ubuf.bindMemory(to: UInt8.self, capacity: ubpr * oh)

        // 4) original page at full res, for luminance
        guard let origCtx = makeContext(width: ow, height: oh), let obuf = origCtx.data else { return nil }
        origCtx.draw(cg, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        let obpr = origCtx.bytesPerRow
        let optr = obuf.bindMemory(to: UInt8.self, capacity: obpr * oh)

        // 5) combine: source Y (crisp line art) + model Cb/Cr scaled by SAT.
        // The raw generator output is duller than the author's published samples;
        // 1.28× lands the chroma on their measured value. Chroma-only — luminance
        // (the line art) is untouched.
        let sat: Float = 1.28
        guard let outCtx = makeContext(width: ow, height: oh), let outBuf = outCtx.data else { return nil }
        let outBpr = outCtx.bytesPerRow
        let outPtr = outBuf.bindMemory(to: UInt8.self, capacity: outBpr * oh)
        // Parallel across rows — this full-page blend is the heaviest CPU step
        // outside inference; each row writes a disjoint range so it's race-free.
        DispatchQueue.concurrentPerform(iterations: oh) { y in
            let orow = y * obpr, urow = y * ubpr, outRow = y * outBpr
            for x in 0..<ow {
                let op = orow + x * 4, up = urow + x * 4, xp = outRow + x * 4
                let sr = Float(optr[op]), sg = Float(optr[op + 1]), sb = Float(optr[op + 2])
                let yLum = 0.299 * sr + 0.587 * sg + 0.114 * sb
                let cr = Float(uptr[up]), cg2 = Float(uptr[up + 1]), cb = Float(uptr[up + 2])
                let cbC = (-0.168736 * cr - 0.331264 * cg2 + 0.5 * cb) * sat
                let crC = (0.5 * cr - 0.418688 * cg2 - 0.081312 * cb) * sat
                outPtr[xp]     = clamp255(yLum + 1.402 * crC)
                outPtr[xp + 1] = clamp255(yLum - 0.344136 * cbC - 0.714136 * crC)
                outPtr[xp + 2] = clamp255(yLum + 1.772 * cbC)
                outPtr[xp + 3] = 255
            }
        }
        return outCtx.makeImage()
    }

    nonisolated static func makeContext(width: Int, height: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    }

    nonisolated static func clamp255(_ v: Float) -> UInt8 {
        v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v))
    }
}

// MARK: - ORT engine (serialized inference, owns the non-Sendable session)

enum ColorizerError: LocalizedError {
    case notLoaded
    case noOutput
    case integrity
    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Colorization model not loaded"
        case .noOutput:  return "Colorization model produced no output"
        case .integrity: return "Colorization model failed its integrity check"
        }
    }
}

/// Owns the ORT env/session and runs inference. An actor so the non-Sendable ORT
/// objects never cross a concurrency boundary, and so forward passes serialize
/// (bounding peak memory + keeping the box responsive).
private actor ColorizerEngine {
    private var env: ORTEnv?
    private var session: ORTSession?
    private var loadedPath: String?

    func ensureLoaded(modelPath: String) throws {
        if session != nil, loadedPath == modelPath { return }
        let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        // GPU via CoreML — matching the web colorizer's WebGPU path. This fp16 GAN is
        // the heaviest model in the app, so CPU-only was needlessly slow. Fall back to
        // CPU if CoreML can't take the model.
        func gpu(mlProgram: Bool) throws -> ORTSession {
            let o = try ORTSessionOptions()
            try? o.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
            let ml = ORTCoreMLExecutionProviderOptions()
            ml.createMLProgram = mlProgram   // MLProgram is faster when the graph builds
            try o.appendCoreMLExecutionProvider(with: ml)
            return try ORTSession(env: env, modelPath: modelPath, sessionOptions: o)
        }
        func cpu() throws -> ORTSession {
            let o = try ORTSessionOptions()
            try? o.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
            try? o.setIntraOpNumThreads(Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
            return try ORTSession(env: env, modelPath: modelPath, sessionOptions: o)
        }
        // Prefer MLProgram (faster); fall back to the classic NeuralNetwork format
        // if it can't build an execution plan, then CPU.
        if let g = try? gpu(mlProgram: true) {
            session = g
            try? "[ColorizerEngine] CoreML GPU (MLProgram)\n".appendLine(to: NyoraLog.colorize)
        } else if let g = try? gpu(mlProgram: false) {
            session = g
            try? "[ColorizerEngine] CoreML GPU (NeuralNetwork)\n".appendLine(to: NyoraLog.colorize)
        } else {
            session = try cpu()
            try? "[ColorizerEngine] CPU\n".appendLine(to: NyoraLog.colorize)
        }
        self.env = env
        self.loadedPath = modelPath
    }

    /// Run the generator. `input` is [1,5,mh,mw] float32; returns `rgb` [1,3,mh,mw] flat.
    func run(input: [Float], mh: Int, mw: Int) throws -> [Float] {
        guard let session else { throw ColorizerError.notLoaded }
        let data = input.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
        }
        let shape: [NSNumber] = [1, 5, NSNumber(value: mh), NSNumber(value: mw)]
        let value = try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.float, shape: shape)
        let outputs = try session.run(
            withInputs: ["input": value],
            outputNames: ["rgb"],
            runOptions: nil
        )
        guard let rgb = outputs["rgb"] else { throw ColorizerError.noOutput }
        let out = try rgb.tensorData() as Data
        let n = out.count / MemoryLayout<Float>.stride
        return out.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: n))
        }
    }
}

// MARK: - Progress-reporting model downloader

/// A `URLSessionDownloadDelegate` that streams the 62 MB model to disk while
/// reporting progress — `URLSession.data(for:)` gives no progress and
/// `AsyncBytes` would iterate 62M single bytes, so we use a download task.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : 61_650_260
        onProgress(min(1, max(0, Double(totalBytesWritten) / total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this callback returns — move it out now.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("onnx")
        do {
            try FileManager.default.moveItem(at: location, to: tmp)
            continuation?.resume(returning: tmp)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
