import Foundation
import SwiftUI
import CoreGraphics
import ImageIO
import AppKit
import OnnxRuntimeBindings

/// On-device manga OCR, run NATIVELY through ONNX Runtime (no hidden WKWebView).
///
/// A faithful Swift/CoreGraphics port of nyora-web's `web/core/translate/tl-worker.js`,
/// driven by the ORT Objective-C API. Same models, same pinned commits, same
/// pre/post-processing — so the Mac reads byte-for-byte what the web reads:
///
///   detection  Kiuyha/Manga-Bubble-YOLO `yolo26n.onnx` (6 MB) — end-to-end, output
///              (1,N,6) [x1,y1,x2,y2,score,cls] in input space. Shared by every language.
///   ja         kha-white/manga-ocr (ViT encoder + char-level BERT decoder), hand
///              greedy-decoded (no KV cache in the export).
///   zh / en    PP-OCRv6 small rec (+ shared PP-OCRv5 DB line detector); ko keeps
///              korean_PP-OCRv5 rec. PP-OCR reads single lines, so bubbles are split
///              into lines by the DB detector first, then CTC-decoded.
///
/// Drop-in for the old `WebOcrProvider`: same `shared`, `Block`, `ocr(cgImage:lang:)`,
/// `preload(lang:)`, and Settings download state. Inference is CPU-only (matches the
/// web wasm path exactly), serialized through `OcrEngine` (an actor) so pages queue
/// one at a time — mirroring the web worker's single-page queue.
@MainActor
final class NativeOcrProvider: ObservableObject {
    static let shared = NativeOcrProvider()

    /// One detected + recognized region: pixel bbox (top-left origin, source space),
    /// the text, and the balloon fill colour as a CSS `rgb(...)` string.
    struct Block: Sendable {
        let text: String
        let box: CGRect
        let bg: String
    }

    /// Languages offered for pre-download in Settings (worker keys). `en` shares `zh`.
    static let downloadableLangs: [(key: String, title: String, approxMB: Int)] = [
        ("ja", "Japanese", 200),
        ("zh", "Chinese / English", 32),
        ("ko", "Korean", 24),
    ]

    // Live download state for the Settings "Offline OCR models" UI (same surface
    // WebOcrProvider exposed, so the view binds unchanged).
    @Published var downloadingLang: String? = nil
    @Published var downloadProgress: Double = 0
    @Published var downloadLabel: String = ""
    @Published private(set) var installedLangs: Set<String> = []
    /// Last download/preload failure, surfaced in Settings (nil = none).
    @Published var downloadError: String? = nil

    private let engine = OcrEngine()
    private var detectorTask: Task<Void, Error>?
    private var langTasks: [String: Task<Void, Error>] = [:]

    private init() {
        installedLangs = detectInstalled()
    }

    // MARK: - Public API (drop-in for WebOcrProvider)

    /// OCR one page. `lang` is the source language: `ja`, `zh`, `en`, or `ko`.
    func ocr(cgImage: CGImage, lang: String) async throws -> [Block] {
        try await ensureLang(lang)
        return try await engine.ocr(cgImage: cgImage, lang: lang)
    }

    /// Pre-download a language's models so the first real translation is instant.
    func preload(lang: String) async throws {
        guard downloadingLang == nil else { return }
        downloadingLang = lang
        downloadProgress = 0
        downloadLabel = "Preparing…"
        downloadError = nil
        log("preload(\(lang)) start")
        defer {
            downloadingLang = nil
            downloadProgress = 0
            downloadLabel = ""
        }
        do {
            try await ensureLang(lang)
            markInstalled(lang == "en" ? "zh" : lang)
            log("preload(\(lang)) complete")
        } catch {
            downloadError = "\(lang): \(error.localizedDescription)"
            log("preload(\(lang)) FAILED — \(error)")
            throw error
        }
    }

    private func log(_ s: String) {
        try? "[NativeOcrProvider] \(s)\n".appendLine(to: NyoraLog.translate)
    }

    /// Best-effort background dry-run of every already-installed language's models,
    /// so CoreML compiles the GPU programs before the first real page needs them.
    /// Called at launch from AppState.bootstrap.
    func warmupInstalled() async {
        for key in installedLangs {
            do {
                try await ensureLang(key)
                await engine.warmup(lang: key)
                log("warmup(\(key)) complete")
            } catch {
                log("warmup(\(key)) failed — \(error)")
            }
        }
    }

    // MARK: - Lazy load (deduped so 8 concurrent pages download once)

    private func ensureDetector() async throws {
        if let t = detectorTask { return try await t.value }
        let t = Task { try await self.loadDetector() }
        detectorTask = t
        do { try await t.value } catch { detectorTask = nil; throw error }
    }

    private func ensureLang(_ lang: String) async throws {
        try await ensureDetector()
        let key = lang == "en" ? "zh" : lang
        if let t = langTasks[key] { return try await t.value }
        let t = Task { try await self.loadLang(key) }
        langTasks[key] = t
        do { try await t.value } catch { langTasks[key] = nil; throw error }
    }

    private func loadDetector() async throws {
        let path = try await fetch(Models.detectorURL, Models.detector, Models.sha[Models.detector],
                                   6_100_000, "bubble detector")
        try await engine.loadDetector(path: path.path)
    }

    private func loadLang(_ key: String) async throws {
        if key == "ja" {
            let enc = try await fetch(Models.mangaEncURL, Models.mangaEnc, Models.sha[Models.mangaEnc],
                                      163_000_000, "Japanese OCR model (1/2)")
            let dec = try await fetch(Models.mangaDecURL, Models.mangaDec, Models.sha[Models.mangaDec],
                                      30_000_000, "Japanese OCR model (2/2)")
            let vocabText = try await OnnxModelStore.fetchText(url: Models.mangaVocabURL,
                                                               cacheName: Models.mangaVocab, label: "vocab")
            let vocab = vocabText.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
            try await engine.loadManga(encPath: enc.path, decPath: dec.path, vocab: vocab)
        } else {
            let det = try await fetch(Models.paddleDetURL, Models.paddleDet, Models.sha[Models.paddleDet],
                                      4_900_000, "text-line detector")
            let cfg = Models.paddle[key]!
            let rec = try await fetch(cfg.model, cfg.recName, Models.sha[cfg.recName], cfg.size, cfg.label)
            let dictText = try await OnnxModelStore.fetchText(url: cfg.dict, cacheName: cfg.dictName, label: "OCR dict")
            var dict = dictText.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
            if dict.last == "" { dict.removeLast() }
            let table = [""] + dict + [" "]   // CTC: blank + dict + space (use_space_char)
            try await engine.loadPaddle(key: key, detPath: det.path, recPath: rec.path, table: table)
        }
        markInstalled(key)
    }

    /// Fetch one model, surfacing progress to the Settings UI while a preload is active.
    private func fetch(_ url: URL, _ cacheName: String, _ sha: String?, _ size: Int, _ label: String) async throws -> URL {
        if downloadingLang != nil { downloadLabel = label; downloadProgress = 0 }
        return try await OnnxModelStore.fetchModel(
            url: url, cacheName: cacheName, sha256: sha, sizeHint: size, label: label
        ) { [weak self] pct in
            Task { @MainActor in
                guard let self, self.downloadingLang != nil else { return }
                self.downloadProgress = pct
            }
        }
    }

    // MARK: - Installed detection (source of truth = files on disk)

    private func markInstalled(_ key: String) {
        installedLangs.insert(key)
    }

    private func detectInstalled() -> Set<String> {
        guard OnnxModelStore.isCached(Models.detector) else { return [] }
        var s = Set<String>()
        if OnnxModelStore.isCached(Models.mangaEnc) && OnnxModelStore.isCached(Models.mangaDec) { s.insert("ja") }
        if OnnxModelStore.isCached(Models.paddleDet) {
            if OnnxModelStore.isCached(Models.paddle["zh"]!.recName) { s.insert("zh") }
            if OnnxModelStore.isCached(Models.paddle["ko"]!.recName) { s.insert("ko") }
        }
        return s
    }
}

// MARK: - Model catalogue (URLs, cache names, hashes — mirror tl-worker.js)

private enum Models {
    static let detector = "yolo26n.onnx"
    static let detectorURL = URL(string: "https://huggingface.co/Kiuyha/Manga-Bubble-YOLO/resolve/fb646500455e8a8a3a807fd27b855c8e4fc63766/onnx/yolo26n.onnx")!

    static let mangaBase = "https://huggingface.co/onnx-community/manga-ocr-base-ONNX/resolve/f9023406bb2f6b17df67bc4a327c56ecd20611f0/onnx/"
    // Encoder: fp16 (fp32 I/O, fp16 compute) — CoreML runs its fp16 conv/matmul on the
    // GPU, and it's MORE accurate than the uint8 variant the web uses. (The web is stuck
    // on uint8 only because its wasm EP lacks ConvInteger; CoreML rejects that uint8 QDQ
    // model — error -7 — so fp16 is the correct native choice.) Decoder stays uint8: it's
    // autoregressive/per-token on CPU, and it takes fp32 encoder_hidden_states, so the
    // fp16 encoder's fp32 output feeds it directly.
    static let mangaEnc = "manga-ocr-encoder-fp16.onnx"
    static let mangaDec = "manga-ocr-decoder-uint8.onnx"
    static let mangaVocab = "manga-ocr-vocab.txt"
    static let mangaEncURL = URL(string: mangaBase + "encoder_model_fp16.onnx")!
    static let mangaDecURL = URL(string: mangaBase + "decoder_model_uint8.onnx")!
    static let mangaVocabURL = URL(string: "https://huggingface.co/kha-white/manga-ocr-base/resolve/aa6573bd10b0d446cbf622e29c3e084914df9741/vocab.txt")!

    static let paddleDet = "ppocrv5-det.onnx"
    static let paddleDetURL = URL(string: "https://huggingface.co/PaddlePaddle/PP-OCRv5_mobile_det_onnx/resolve/e6f4fa85f00e168c862bc462aebca69eef9b3d3d/inference.onnx")!

    struct Paddle { let model: URL; let dict: URL; let recName: String; let dictName: String; let label: String; let size: Int }
    static let paddle: [String: Paddle] = [
        "zh": Paddle(
            model: URL(string: "https://huggingface.co/ogkalu/ppocr-v6-onnx/resolve/8caf024d9ec9df361c3b89adc812a68ae803ea1b/PP-OCRv6_small_rec.onnx")!,
            dict: URL(string: "https://huggingface.co/ogkalu/ppocr-v6-onnx/resolve/8caf024d9ec9df361c3b89adc812a68ae803ea1b/PP-OCRv6_small_rec.txt")!,
            recName: "ppocrv6-rec-zh.onnx", dictName: "ppocrv6-rec-zh.txt",
            label: "Chinese/English OCR model", size: 21_200_000),
        "ko": Paddle(
            model: URL(string: "https://huggingface.co/PaddlePaddle/korean_PP-OCRv5_mobile_rec_onnx/resolve/5c6f574b8e2230adf4287b33e736d71b9fabd28e/inference.onnx")!,
            dict: URL(string: "https://raw.githubusercontent.com/PaddlePaddle/PaddleOCR/0a8a6354f10388ecd601f9a86639dd3c44d95057/ppocr/utils/dict/ppocrv5_korean_dict.txt")!,
            recName: "ppocrv5-rec-ko.onnx", dictName: "ppocrv5-rec-ko.txt",
            label: "Korean OCR model", size: 13_400_000),
    ]

    // SHA-256 (HF LFS oid = content hash), keyed by cache name.
    static let sha: [String: String] = [
        detector:  "b45c2e12cf0c3c1d2abfbbb9123c9f96f040f2ac36a0842382ecd9d859c851c7",
        mangaEnc:  "1a6a57bc3608195c4577b13ac3aadab810dce42fa22c5a3acf0570bffc013b60",
        mangaDec:  "cc7a42534759864c7b6937aaacc4cc91b37c9207eeae05ee359a04e6d4d222a5",
        paddleDet: "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d",
        "ppocrv6-rec-zh.onnx": "5435fd747c9e0efe15a96d0b378d5bd157e9492ed8fd80edf08f30d02fa24634",
        "ppocrv5-rec-ko.onnx": "92f0b7785e64fc9090106a241cf4c1eb97472824558272751b88a2a4476d3a08",
    ]
}

// MARK: - Pipeline constants (mirror tl-worker.js)

private let DETECTOR_SIZE = 1280
private let DETECTOR_THRESHOLD: Float = 0.2
private let MANGA_OCR_SIZE = 224
private let MANGA_OCR_START: Int64 = 2   // [CLS]
private let MANGA_OCR_EOS: Int64 = 3     // [SEP]
private let MANGA_OCR_MAX_TOKENS = 64
private let MANGA_OCR_BATCH = 8
private let PADDLE_H = 48
private let PADDLE_MAX_W = 1536
private let DET_MAX_SIDE = 960
private let DET_BIN: Float = 0.3
private let DET_BOX_SCORE: Float = 0.5
private let DET_UNCLIP = 2.0

private struct Det { var x: Int; var y: Int; var w: Int; var h: Int; var score: Float }
private struct IntRect { var x: Int; var y: Int; var w: Int; var h: Int }
/// A rendered RGBA8 buffer, row 0 == top (CoreGraphics double-flip cancels).
private struct Raster { let px: [UInt8]; let w: Int; let h: Int; let bpr: Int }

// MARK: - OCR engine (owns the ORT sessions, serializes inference)

private actor OcrEngine {
    private var _env: ORTEnv?

    private var detector: ORTSession?
    private var detIn = "images", detOut = "output"

    private var lineDet: ORTSession?
    private var lineDetIn = "x", lineDetOut = "save_infer_model/scale_0.tmp_0"

    private var mangaEnc: ORTSession?
    private var mangaDec: ORTSession?
    private var mangaEncIn = "pixel_values", mangaEncOut = "last_hidden_state"
    private var mangaDecHidden = "encoder_hidden_states", mangaDecOut = "logits"
    private var mangaVocab: [String] = []

    private struct PaddleEngine { let rec: ORTSession; let recIn: String; let recOut: String; let table: [String] }
    private var paddle: [String: PaddleEngine] = [:]

    // MARK: session setup

    private func ortEnv() throws -> ORTEnv {
        if let e = _env { return e }
        let e = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        _env = e
        return e
    }

    /// Build a session. `preferGpu` mirrors the web worker's `createSession(buf, preferGpu)`:
    /// the heavy encoders (manga-ocr encoder, PP-OCR recognizer) run on the GPU — via
    /// CoreML here, WebGPU on the web — while the small/serial models stay on CPU. Falls
    /// back to CPU if CoreML can't take the model.
    private func makeSession(_ path: String, preferGpu: Bool) throws -> ORTSession {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if preferGpu {
            // Try several CoreML configs — the MLProgram path fails to build an
            // execution plan (-7) for these graphs, so NeuralNetwork + all-units is
            // tried first. First one that creates a session wins; else CPU.
            let configs: [(label: String, mlProgram: Bool, cpuAndGpu: Bool)] = [
                ("NeuralNetwork/all", false, false),
                ("NeuralNetwork/cpu+gpu", false, true),
                ("MLProgram/all", true, false),
            ]
            for c in configs {
                do {
                    let opts = try ORTSessionOptions()
                    try? opts.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
                    let ml = ORTCoreMLExecutionProviderOptions()
                    ml.createMLProgram = c.mlProgram
                    if c.cpuAndGpu { ml.useCPUAndGPU = true }
                    try opts.appendCoreMLExecutionProvider(with: ml)
                    let s = try ORTSession(env: try ortEnv(), modelPath: path, sessionOptions: opts)
                    log("\(name): CoreML GPU [\(c.label)]")
                    return s
                } catch {
                    log("\(name): CoreML [\(c.label)] failed — \(error)")
                }
            }
            log("\(name): all CoreML configs failed — CPU")
        }
        let opts = try ORTSessionOptions()
        try? opts.setGraphOptimizationLevel(ORTGraphOptimizationLevel.all)
        try? opts.setIntraOpNumThreads(Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        let s = try ORTSession(env: try ortEnv(), modelPath: path, sessionOptions: opts)
        log("\(name): CPU")
        return s
    }

    private func log(_ s: String) {
        try? "[OcrEngine] \(s)\n".appendLine(to: NyoraLog.translate)
    }

    func loadDetector(path: String) throws {
        if detector != nil { return }
        let s = try makeSession(path, preferGpu: false)   // small (6 MB) — CPU, like web
        detector = s
        if let n = (try? s.inputNames())?.first { detIn = n }
        if let n = (try? s.outputNames())?.first { detOut = n }
    }

    func loadManga(encPath: String, decPath: String, vocab: [String]) throws {
        if mangaEnc == nil {
            let e = try makeSession(encPath, preferGpu: true)   // heavy ViT encoder — GPU
            mangaEnc = e
            if let n = (try? e.inputNames())?.first { mangaEncIn = n }
            if let n = (try? e.outputNames())?.first { mangaEncOut = n }
        }
        if mangaDec == nil {
            let d = try makeSession(decPath, preferGpu: false)  // autoregressive, tiny/step — CPU
            mangaDec = d
            if let names = try? d.inputNames() {
                mangaDecHidden = names.first { $0 != "input_ids" } ?? mangaDecHidden
            }
            if let n = (try? d.outputNames())?.first { mangaDecOut = n }
        }
        mangaVocab = vocab
    }

    func loadPaddle(key: String, detPath: String, recPath: String, table: [String]) throws {
        if lineDet == nil {
            let l = try makeSession(detPath, preferGpu: false)  // DB line detector — CPU, like web
            lineDet = l
            if let n = (try? l.inputNames())?.first { lineDetIn = n }
            if let n = (try? l.outputNames())?.first { lineDetOut = n }
        }
        if paddle[key] == nil {
            let r = try makeSession(recPath, preferGpu: true)   // heavy CTC recognizer — GPU
            let recIn = (try? r.inputNames())?.first ?? "x"
            let recOut = (try? r.outputNames())?.first ?? "softmax_0.tmp_0"
            paddle[key] = PaddleEngine(rec: r, recIn: recIn, recOut: recOut, table: table)
        }
    }

    /// Dry-run each loaded session for `lang` once, so CoreML compiles its Metal
    /// program up front — otherwise that ~10-30 s compile lands on the first real page.
    func warmup(lang: String) {
        let key = lang == "en" ? "zh" : lang
        if let detector {
            _ = try? runF32(detector, detIn,
                            [Float](repeating: 0.5, count: 3 * DETECTOR_SIZE * DETECTOR_SIZE),
                            [1, 3, DETECTOR_SIZE, DETECTOR_SIZE], detOut)
        }
        if key == "ja" {
            guard let enc = mangaEnc else { log("warmup(\(lang)): no manga session"); return }
            let (h, hs) = (try? runF32(enc, mangaEncIn,
                                       [Float](repeating: 0, count: 3 * MANGA_OCR_SIZE * MANGA_OCR_SIZE),
                                       [1, 3, MANGA_OCR_SIZE, MANGA_OCR_SIZE], mangaEncOut)) ?? ([], [])
            if let dec = mangaDec, hs.count >= 3 {
                let T = hs[1], C = hs[2]
                let hData = h.withUnsafeBufferPointer {
                    NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
                }
                if let hVal = try? ORTValue(tensorData: hData, elementType: ORTTensorElementDataType.float,
                                            shape: [1, T, C].map { NSNumber(value: $0) }) {
                    let ids: [Int64] = [MANGA_OCR_START]
                    let idData = ids.withUnsafeBufferPointer {
                        NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Int64>.stride)
                    }
                    if let idVal = try? ORTValue(tensorData: idData, elementType: ORTTensorElementDataType.int64,
                                                 shape: [1, 1].map { NSNumber(value: $0) }) {
                        _ = try? dec.run(withInputs: ["input_ids": idVal, mangaDecHidden: hVal],
                                         outputNames: [mangaDecOut], runOptions: nil)
                    }
                }
            }
        } else {
            if let lineDet {
                _ = try? runF32(lineDet, lineDetIn, [Float](repeating: 0, count: 3 * 64 * 64), [1, 3, 64, 64], lineDetOut)
            }
            if let p = paddle[key] {
                _ = try? runF32(p.rec, p.recIn, [Float](repeating: 0, count: 3 * PADDLE_H * 320), [1, 3, PADDLE_H, 320], p.recOut)
            }
        }
        log("warmup(\(lang)) done")
    }

    // MARK: ORT run helpers

    private func floats(_ v: ORTValue) throws -> [Float] {
        let d = try v.tensorData() as Data
        let n = d.count / MemoryLayout<Float>.stride
        return d.withUnsafeBytes { raw in
            Array(UnsafeBufferPointer(start: raw.bindMemory(to: Float.self).baseAddress, count: n))
        }
    }

    private func shapeOf(_ v: ORTValue) throws -> [Int] {
        let info = try v.tensorTypeAndShapeInfo()
        return info.shape.map { $0.intValue }
    }

    private func runF32(_ session: ORTSession, _ inName: String, _ input: [Float], _ shape: [Int], _ outName: String) throws -> ([Float], [Int]) {
        let data = input.withUnsafeBufferPointer {
            NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
        }
        let val = try ORTValue(tensorData: data, elementType: ORTTensorElementDataType.float,
                               shape: shape.map { NSNumber(value: $0) })
        let outs = try session.run(withInputs: [inName: val], outputNames: [outName], runOptions: nil)
        guard let o = outs[outName] else { throw OnnxError.badOutput(outName) }
        return (try floats(o), try shapeOf(o))
    }

    // MARK: - Full page pipeline (port of handlePage)

    func ocr(cgImage cg: CGImage, lang: String) throws -> [NativeOcrProvider.Block] {
        let t0 = DispatchTime.now()
        let W = cg.width, H = cg.height
        guard W > 0, H > 0, let detector else { return [] }

        // 1) detect on vertical tiles (webtoon-safe), then dedupe across seams.
        var boxes: [Det] = []
        for rect in Self.tileRects(W, H) {
            if Task.isCancelled { return [] }
            boxes += (try? detectTile(cg, rect, detector)) ?? []
        }
        boxes = Self.dedupe(boxes)

        // 2) full-source raster for CPU sampling (ink profiles + bg colour).
        guard let src = Self.raster(cg, W, H) else { return [] }

        // 3) resolve padded crop rects (+ bg colour) up front.
        var rects: [(r: IntRect, bg: String)] = []
        for b0 in boxes {
            let b = Self.refineWideBox(src, b0, W)
            let pad = Int(min(28.0, max(6.0, Double(min(b.w, b.h)) * 0.12)).rounded())
            let padX = pad + Int((Double(b.w) * 0.03).rounded())
            let x = max(0, b.x - padX)
            let y = max(0, b.y - pad)
            let w = min(W - x, b.w + padX * 2)
            let h = min(H - y, b.h + pad * 2)
            if w < 14 || h < 14 { continue }
            rects.append((IntRect(x: x, y: y, w: w, h: h), Self.sampleBg(src, x, y, w, h)))
        }

        // 4) OCR each crop.
        var blocks: [NativeOcrProvider.Block] = []
        let key = lang == "en" ? "zh" : lang
        if key == "ja" {
            // Keep crops aligned with their rects (a failed crop drops both).
            var crops: [CGImage] = []
            var mangaRects: [(r: IntRect, bg: String)] = []
            for entry in rects {
                if let c = cg.cropping(to: entry.r.cgRect) { crops.append(c); mangaRects.append(entry) }
            }
            let texts = (try? mangaOcrBatch(crops)) ?? []
            for (i, entry) in mangaRects.enumerated() {
                guard i < texts.count else { break }
                let t = texts[i]
                if !t.isEmpty, !Self.isJunk(t) {
                    blocks.append(.init(text: t, box: entry.r.cgRect, bg: entry.bg))
                }
            }
        } else {
            let joiner = key == "zh" && lang != "en" ? "" : " "   // zh joins tight; en/ko space
            for entry in rects {
                if Task.isCancelled { break }
                guard let crop = cg.cropping(to: CGRect(x: entry.r.x, y: entry.r.y, width: entry.r.w, height: entry.r.h)) else { continue }
                let t = (try? paddleOcrCrop(key, crop, joiner)) ?? ""
                if !t.isEmpty, !Self.isJunk(t) {
                    blocks.append(.init(text: t, box: entry.r.cgRect, bg: entry.bg))
                }
            }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        log("ocr[\(lang)] \(W)×\(H): \(rects.count) boxes, \(blocks.count) read in \(Int(ms))ms")
        return blocks
    }

    // MARK: detection

    private func detectTile(_ cg: CGImage, _ rect: IntRect, _ detector: ORTSession) throws -> [Det] {
        let size = DETECTOR_SIZE
        let scale = min(Double(size) / Double(rect.w), Double(size) / Double(rect.h))
        let dw = max(1, Int((Double(rect.w) * scale).rounded()))
        let dh = max(1, Int((Double(rect.h) * scale).rounded()))
        guard let sub = cg.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)),
              let ras = Self.raster(sub, size, size, draw: { ctx in
                  ctx.setFillColor(CGColor(red: 114/255, green: 114/255, blue: 114/255, alpha: 1))
                  ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
                  ctx.interpolationQuality = .medium
                  ctx.draw(sub, in: CGRect(x: 0, y: size - dh, width: dw, height: dh)) // top-left letterbox
              })
        else { return [] }

        let plane = size * size
        var input = [Float](repeating: 0, count: 3 * plane)
        // Parallel across rows — the 1280² planar tensor build is the heaviest
        // CPU step in detection. Raw buffers so it's a race-free row split.
        let bpr = ras.bpr
        ras.px.withUnsafeBufferPointer { srcBuf in
            input.withUnsafeMutableBufferPointer { dstBuf in
                let src = srcBuf.baseAddress!
                let dst = dstBuf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: size) { y in
                    let row = y * bpr
                    for x in 0..<size {
                        let p = row + x * 4, i = y * size + x
                        dst[i] = Float(src[p]) / 255
                        dst[i + plane] = Float(src[p + 1]) / 255
                        dst[i + 2 * plane] = Float(src[p + 2]) / 255
                    }
                }
            }
        }
        let (out, sh) = try runF32(detector, detIn, input, [1, 3, size, size], detOut)
        var boxes: [Det] = []
        guard sh.count == 3, sh[2] >= 6 else { return boxes }
        let stride = sh[2]
        for i in 0..<sh[1] {
            let o = i * stride
            let score = out[o + 4]
            if score < DETECTOR_THRESHOLD { continue }
            let x1 = Double(out[o]) / scale + Double(rect.x)
            let y1 = Double(out[o + 1]) / scale + Double(rect.y)
            let x2 = Double(out[o + 2]) / scale + Double(rect.x)
            let y2 = Double(out[o + 3]) / scale + Double(rect.y)
            let bw = Int((x2 - x1).rounded()), bh = Int((y2 - y1).rounded())
            if bw > 6, bh > 6 {
                boxes.append(Det(x: max(0, Int(x1.rounded())), y: max(0, Int(y1.rounded())), w: bw, h: bh, score: score))
            }
        }
        return boxes
    }

    // MARK: manga-ocr (ja) — batched greedy VisionEncoderDecoder loop

    private func mangaOcrBatch(_ crops: [CGImage]) throws -> [String] {
        guard let enc = mangaEnc, let dec = mangaDec else { throw OnnxError.notLoaded("Japanese OCR") }
        var texts = [String](repeating: "", count: crops.count)
        var base = 0
        while base < crops.count {
            let chunk = Array(crops[base..<min(base + MANGA_OCR_BATCH, crops.count)])
            let n = chunk.count
            do {
                // Encode each crop (sequential, bounded memory); stack hidden [n,T,C].
                var T = 0, C = 0
                var encoded: [[Float]] = []
                for crop in chunk {
                    let input = Self.mangaPre(crop)
                    let (h, hs) = try runF32(enc, mangaEncIn, input, [1, 3, MANGA_OCR_SIZE, MANGA_OCR_SIZE], mangaEncOut)
                    T = hs.count > 1 ? hs[1] : 0
                    C = hs.count > 2 ? hs[2] : 0
                    encoded.append(h)
                }
                guard T > 0, C > 0 else { base += MANGA_OCR_BATCH; continue }
                var hid = [Float](repeating: 0, count: n * T * C)
                for (i, d) in encoded.enumerated() {
                    let dst = i * T * C
                    let cnt = min(d.count, T * C)
                    hid.withUnsafeMutableBufferPointer { buf in
                        d.withUnsafeBufferPointer { s in
                            buf.baseAddress!.advanced(by: dst).update(from: s.baseAddress!, count: cnt)
                        }
                    }
                }
                let hData = hid.withUnsafeBufferPointer {
                    NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
                }
                let hVal = try ORTValue(tensorData: hData, elementType: ORTTensorElementDataType.float,
                                        shape: [n, T, C].map { NSNumber(value: $0) })

                var seqs = [[Int64]](repeating: [MANGA_OCR_START], count: n)
                var finished = [Bool](repeating: false, count: n)
                var step = 0
                while step < MANGA_OCR_MAX_TOKENS, finished.contains(false) {
                    if Task.isCancelled { break }
                    let len = seqs[0].count
                    var ids = [Int64](repeating: 0, count: n * len)
                    for i in 0..<n { for j in 0..<len { ids[i * len + j] = seqs[i][j] } }
                    let idData = ids.withUnsafeBufferPointer {
                        NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Int64>.stride)
                    }
                    let idVal = try ORTValue(tensorData: idData, elementType: ORTTensorElementDataType.int64,
                                             shape: [n, len].map { NSNumber(value: $0) })
                    let outs = try dec.run(withInputs: ["input_ids": idVal, mangaDecHidden: hVal],
                                           outputNames: [mangaDecOut], runOptions: nil)
                    guard let lv = outs[mangaDecOut] else { break }
                    let logits = try floats(lv)
                    let lshape = try shapeOf(lv)          // [n, len, V]
                    let V = lshape.count > 2 ? lshape[2] : 0
                    guard V > 0 else { break }
                    for i in 0..<n {
                        if finished[i] { seqs[i].append(0); continue }  // [PAD] filler
                        let off = (i * len + (len - 1)) * V
                        var best = 0
                        var bestV = -Float.greatestFiniteMagnitude
                        for v in 0..<V where logits[off + v] > bestV { bestV = logits[off + v]; best = v }
                        if Int64(best) == MANGA_OCR_EOS { finished[i] = true; seqs[i].append(0) }
                        else { seqs[i].append(Int64(best)) }
                    }
                    step += 1
                }
                for i in 0..<n {
                    var text = ""
                    for idb in seqs[i].dropFirst() {
                        let id = Int(idb)
                        if id == 0 { continue }
                        guard id >= 0, id < mangaVocab.count else { continue }
                        let tk = mangaVocab[id]
                        if tk.isEmpty || tk.hasPrefix("[") || tk.hasPrefix("<unused") { continue }
                        text += tk.hasPrefix("##") ? String(tk.dropFirst(2)) : tk
                    }
                    texts[base + i] = Self.mangaPost(text)
                }
            } catch { /* one bad chunk must not sink the page */ }
            base += MANGA_OCR_BATCH
        }
        return texts
    }

    // MARK: PP-OCR (zh/en/ko) — DB line detect + CTC recognize

    private func paddleOcrCrop(_ key: String, _ crop: CGImage, _ joiner: String) throws -> String {
        var lines = try detTextLines(crop)
        if lines.isEmpty { lines = [IntRect(x: 0, y: 0, w: crop.width, h: crop.height)] }
        var parts: [String] = []
        for rect in lines {
            let line = (try? paddleRecLine(key, crop, rect)) ?? ""
            if !line.isEmpty { parts.append(line) }
        }
        return parts.joined(separator: joiner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func detTextLines(_ crop: CGImage) throws -> [IntRect] {
        guard let lineDet else { return [] }
        let W0 = crop.width, H0 = crop.height
        let scale = min(1.0, Double(DET_MAX_SIDE) / Double(max(W0, H0)))
        let W = max(32, Int((Double(W0) * scale / 32).rounded()) * 32)
        let H = max(32, Int((Double(H0) * scale / 32).rounded()) * 32)
        guard let ras = Self.raster(crop, W, H) else { return [] }
        let plane = W * H
        var input = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<H {
            let row = y * ras.bpr
            for x in 0..<W {
                let p = row + x * 4, i = y * W + x
                input[i] = (Float(ras.px[p + 2]) / 255 - 0.485) / 0.229   // BGR, ImageNet mean/std
                input[i + plane] = (Float(ras.px[p + 1]) / 255 - 0.456) / 0.224
                input[i + 2 * plane] = (Float(ras.px[p]) / 255 - 0.406) / 0.225
            }
        }
        let (prob, _) = try runF32(lineDet, lineDetIn, input, [1, 3, H, W], lineDetOut)
        guard prob.count >= plane else { return [] }

        var bin = [Bool](repeating: false, count: plane)
        for i in 0..<plane { bin[i] = prob[i] > DET_BIN }
        var seen = [Bool](repeating: false, count: plane)
        var qx = [Int32](repeating: 0, count: plane)
        var qy = [Int32](repeating: 0, count: plane)
        var raw: [(x: Int, y: Int, x2: Int, y2: Int)] = []
        for y in 0..<H {
            for x in 0..<W {
                let idx = y * W + x
                if !bin[idx] || seen[idx] { continue }
                var head = 0, tail = 0
                qx[tail] = Int32(x); qy[tail] = Int32(y); tail += 1
                seen[idx] = true
                var minX = x, maxX = x, minY = y, maxY = y
                var sum: Float = 0, cnt = 0
                while head < tail {
                    let cxx = Int(qx[head]), cyy = Int(qy[head]); head += 1
                    sum += prob[cyy * W + cxx]; cnt += 1
                    if cxx < minX { minX = cxx }; if cxx > maxX { maxX = cxx }
                    if cyy < minY { minY = cyy }; if cyy > maxY { maxY = cyy }
                    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let nx = cxx + dx, ny = cyy + dy
                        if nx < 0 || ny < 0 || nx >= W || ny >= H { continue }
                        let ni = ny * W + nx
                        if bin[ni], !seen[ni] { seen[ni] = true; qx[tail] = Int32(nx); qy[tail] = Int32(ny); tail += 1 }
                    }
                }
                let bw = maxX - minX + 1, bh = maxY - minY + 1
                if bw < 3 || bh < 3 || cnt < 10 { continue }
                if sum / Float(cnt) < DET_BOX_SCORE { continue }
                let off = Int((Double(bw * bh) * DET_UNCLIP / Double(2 * (bw + bh))).rounded())
                raw.append((max(0, minX - off), max(0, minY - off), min(W, maxX + off), min(H, maxY + off)))
            }
        }
        let sx = Double(W0) / Double(W), sy = Double(H0) / Double(H)
        var lines = raw.map { b in
            IntRect(x: Int((Double(b.x) * sx).rounded()),
                    y: Int((Double(b.y) * sy).rounded()),
                    w: max(1, Int((Double(b.x2 - b.x) * sx).rounded())),
                    h: max(1, Int((Double(b.y2 - b.y) * sy).rounded())))
        }
        // Cluster into rows by vertical overlap, read rows top→bottom, each row left→right.
        lines.sort { (Double($0.y) + Double($0.h) / 2) < (Double($1.y) + Double($1.h) / 2) }
        var rows: [(cy: Double, h: Double, items: [IntRect])] = []
        for l in lines {
            let cy = Double(l.y) + Double(l.h) / 2
            if let ri = rows.firstIndex(where: { abs($0.cy - cy) < max($0.h, Double(l.h)) * 0.55 }) {
                rows[ri].items.append(l)
                rows[ri].cy = (rows[ri].cy * Double(rows[ri].items.count - 1) + cy) / Double(rows[ri].items.count)
                rows[ri].h = max(rows[ri].h, Double(l.h))
            } else {
                rows.append((cy, Double(l.h), [l]))
            }
        }
        rows.sort { $0.cy < $1.cy }
        return rows.flatMap { $0.items.sorted { $0.x < $1.x } }
    }

    private func paddleRecLine(_ key: String, _ crop: CGImage, _ rect: IntRect) throws -> String {
        guard let p = paddle[key], rect.h > 0 else { return "" }
        let w = max(16, min(PADDLE_MAX_W, Int((Double(rect.w) * (Double(PADDLE_H) / Double(rect.h))).rounded())))
        guard let sub = crop.cropping(to: CGRect(x: rect.x, y: rect.y, width: rect.w, height: rect.h)),
              let ras = Self.raster(sub, w, PADDLE_H) else { return "" }
        let plane = PADDLE_H * w
        var input = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<PADDLE_H {
            let row = y * ras.bpr
            for x in 0..<w {
                let pp = row + x * 4, i = y * w + x
                input[i] = Float(ras.px[pp + 2]) / 127.5 - 1        // BGR, (x/255 − .5)/.5
                input[i + plane] = Float(ras.px[pp + 1]) / 127.5 - 1
                input[i + 2 * plane] = Float(ras.px[pp]) / 127.5 - 1
            }
        }
        let (d, sh) = try runF32(p.rec, p.recIn, input, [1, 3, PADDLE_H, w], p.recOut)
        guard sh.count >= 3 else { return "" }
        let T = sh[1], C = sh[2]
        var text = ""
        var prev = 0
        for s in 0..<T {
            let off = s * C
            var best = 0
            var bestV = -Float.greatestFiniteMagnitude
            for i in 0..<C where d[off + i] > bestV { bestV = d[off + i]; best = i }
            if best != 0, best != prev, best < p.table.count { text += p.table[best] }
            prev = best
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - CPU helpers (nonisolated statics)

private extension OcrEngine {
    static func ctx(_ w: Int, _ h: Int) -> CGContext? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    }

    /// Rasterize `cg` into a w×h RGBA buffer. `draw` overrides the default fill-and-draw.
    static func raster(_ cg: CGImage, _ w: Int, _ h: Int, draw: ((CGContext) -> Void)? = nil) -> Raster? {
        guard w > 0, h > 0, let ctx = ctx(w, h) else { return nil }
        if let draw { draw(ctx) } else { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        guard let data = ctx.data else { return nil }
        let bpr = ctx.bytesPerRow
        let count = bpr * h
        let buf = data.bindMemory(to: UInt8.self, capacity: count)
        return Raster(px: Array(UnsafeBufferPointer(start: buf, count: count)), w: w, h: h, bpr: bpr)
    }

    // -- detection tiling / dedupe --

    static func tileRects(_ w: Int, _ h: Int) -> [IntRect] {
        let tileH = min(h, Int((Double(w) * 1.6).rounded()))
        if tileH >= h { return [IntRect(x: 0, y: 0, w: w, h: h)] }
        let step = max(1, Int((Double(tileH) * 0.8).rounded()))
        var rects: [IntRect] = []
        var y = 0
        while true {
            rects.append(IntRect(x: 0, y: min(y, h - tileH), w: w, h: tileH))
            if y + tileH >= h { break }
            y += step
        }
        return rects
    }

    static func overlapArea(_ a: Det, _ b: Det) -> Int {
        let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
        let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        return w > 0 && h > 0 ? w * h : 0
    }

    static func dedupe(_ boxes0: [Det]) -> [Det] {
        let boxes = boxes0.sorted { $0.score > $1.score }
        var kept: [Det] = []
        for b in boxes {
            let dup = kept.contains { k in
                let ov = overlapArea(k, b)
                return Double(ov) / Double(k.w * k.h + b.w * b.h - ov) > 0.45
            }
            if !dup { kept.append(b) }
        }
        kept.sort { $0.w * $0.h > $1.w * $1.h }
        var out: [Det] = []
        for b in kept {
            let inside = out.contains { k in Double(overlapArea(k, b)) / Double(max(1, b.w * b.h)) > 0.75 }
            if !inside { out.append(b) }
        }
        // Reading order: top-to-bottom, then right-to-left (manga).
        out.sort { a, b in
            let ay = Double(a.y) + Double(a.h) / 2, by = Double(b.y) + Double(b.h) / 2
            if ay != by { return ay < by }
            return (Double(b.x) + Double(b.w) / 2) < (Double(a.x) + Double(a.w) / 2)
        }
        return out
    }

    // -- Otsu ink mask + wide-box refinement --

    static func inkMask(_ src: Raster, _ rx: Int, _ ry: Int, _ rw: Int, _ rh: Int) -> [UInt8] {
        let total = rw * rh
        guard total > 0 else { return [] }
        var lum = [UInt8](repeating: 0, count: total)
        var hist = [Int](repeating: 0, count: 256)
        for j in 0..<rh {
            let sy = ry + j
            for i in 0..<rw {
                let sx = rx + i
                let p = sy * src.bpr + sx * 4
                let l = (Int(src.px[p]) * 77 + Int(src.px[p + 1]) * 150 + Int(src.px[p + 2]) * 29) >> 8
                lum[j * rw + i] = UInt8(l)
                hist[l] += 1
            }
        }
        var sum = 0
        for i in 0..<256 { sum += i * hist[i] }
        var sumB = 0, wB = 0, maxVar = -1.0, thr = 128
        for i in 0..<256 {
            wB += hist[i]
            if wB == 0 || wB == total { continue }
            sumB += i * hist[i]
            let mB = Double(sumB) / Double(wB)
            let mF = Double(sum - sumB) / Double(total - wB)
            let v = Double(wB) * Double(total - wB) * (mB - mF) * (mB - mF)
            if v > maxVar { maxVar = v; thr = i }
        }
        var dark = 0
        for i in 0..<total where Int(lum[i]) < thr { dark += 1 }
        let textIsDark = dark <= total - dark
        var ink = [UInt8](repeating: 0, count: total)
        for i in 0..<total { ink[i] = ((Int(lum[i]) < thr) == textIsDark) ? 1 : 0 }
        return ink
    }

    static func refineWideBox(_ src: Raster, _ b: Det, _ W: Int) -> Det {
        if b.w < Int(Double(b.h) * 2.2) { return b }
        let maxExt = Int((Double(b.w) * 0.4).rounded())
        let x0 = max(0, b.x - maxExt)
        let x1 = min(W, b.x + b.w + maxExt)
        let w = x1 - x0
        if w <= 0 || b.h <= 0 || b.y < 0 || b.y + b.h > src.h { return b }
        let ink = inkMask(src, x0, b.y, w, b.h)
        guard ink.count == w * b.h else { return b }
        var cols = [Int](repeating: 0, count: w)
        for y in 0..<b.h { for x in 0..<w { cols[x] += Int(ink[y * w + x]) } }
        let minInk = max(1, Int((Double(b.h) * 0.06).rounded()))
        let gapMax = max(6, min(90, Int((Double(b.h) * 0.8).rounded())))
        var left = b.x - x0, gap = 0
        var x = left - 1
        while x >= 0 { if cols[x] > minInk { left = x; gap = 0 } else { gap += 1; if gap > gapMax { break } }; x -= 1 }
        var right = b.x + b.w - x0; gap = 0
        x = right + 1
        while x < w { if cols[x] > minInk { right = x; gap = 0 } else { gap += 1; if gap > gapMax { break } }; x += 1 }
        return Det(x: x0 + left, y: b.y, w: right - left + 1, h: b.h, score: b.score)
    }

    // -- background colour sampling (Android's sampleBackgroundColor) --

    static func sampleBg(_ src: Raster, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> String {
        let ins = max(2, Int((Double(min(w, h)) * 0.12).rounded()))
        let pts = [(x + ins, y + ins), (x + w - ins, y + ins), (x + ins, y + h - ins), (x + w - ins, y + h - ins)]
        var best = (r: 255, g: 255, b: 255)
        var bestLum = -1.0
        for (px, py) in pts {
            guard px >= 0, py >= 0, px < src.w, py < src.h else { continue }
            let p = py * src.bpr + px * 4
            let r = Int(src.px[p]), g = Int(src.px[p + 1]), b = Int(src.px[p + 2])
            let lum = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            if lum > bestLum { bestLum = lum; best = (r, g, b) }
        }
        return "rgb(\(best.r),\(best.g),\(best.b))"
    }

    // -- manga-ocr pre / post --

    static func mangaPre(_ crop: CGImage) -> [Float] {
        let s = MANGA_OCR_SIZE
        let ras = raster(crop, s, s, draw: { ctx in
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))
            ctx.interpolationQuality = .high
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: s, height: s))   // ViT squashes aspect
        })
        let plane = s * s
        var input = [Float](repeating: 0, count: 3 * plane)
        guard let ras else { return input }
        for y in 0..<s {
            let row = y * ras.bpr
            for x in 0..<s {
                let p = row + x * 4, i = y * s + x
                input[i] = Float(ras.px[p]) / 127.5 - 1
                input[i + plane] = Float(ras.px[p + 1]) / 127.5 - 1
                input[i + 2 * plane] = Float(ras.px[p + 2]) / 127.5 - 1
            }
        }
        return input
    }

    /// manga-ocr's own post_process: strip whitespace → '…'→'...' → collapse ・/. runs
    /// → half-width ASCII to FULL-WIDTH (proper Japanese text). JA path only.
    static func mangaPost(_ s0: String) -> String {
        var s = s0.components(separatedBy: .whitespacesAndNewlines).joined()
        s = s.replacingOccurrences(of: "…", with: "...")
        var out = ""
        var run: [Character] = []
        func flush() {
            if run.count >= 2 { out += String(repeating: ".", count: run.count) }
            else { out += String(run) }
            run.removeAll(keepingCapacity: true)
        }
        for ch in s {
            if ch == "・" || ch == "." { run.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        var res = ""
        res.unicodeScalars.reserveCapacity(out.unicodeScalars.count)
        for u in out.unicodeScalars {
            if u.value >= 0x21, u.value <= 0x7E, let full = Unicode.Scalar(u.value + 0xFEE0) {
                res.unicodeScalars.append(full)
            } else {
                res.unicodeScalars.append(u)
            }
        }
        return res
    }

    // -- SFX/punctuation-only junk filter --

    static let junkSet: Set<Character> = [
        ".", "。", "‥", "…", "・", "･", "·", "、", ",", "*", "×", "+", "~", "〜",
        "ー", "—", "-", "!", "?", "！", "？", "'", "\"", "\u{201C}", "\u{201D}",
    ]

    static func isJunk(_ t: String) -> Bool {
        for ch in t where !ch.isWhitespace && !junkSet.contains(ch) { return false }
        return true   // empty or all-punctuation
    }
}

private extension IntRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
