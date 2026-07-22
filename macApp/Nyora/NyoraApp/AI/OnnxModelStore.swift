import Foundation
import CryptoKit

/// Errors surfaced by the on-device ONNX model store + engines.
enum OnnxError: LocalizedError {
    case integrity(String)
    case download(String)
    case notLoaded(String)
    case badOutput(String)
    var errorDescription: String? {
        switch self {
        case let .integrity(m):  return "\(m) failed its integrity check — refusing to load it"
        case let .download(m):   return "\(m) download failed"
        case let .notLoaded(m):  return "\(m) model not loaded"
        case let .badOutput(m):  return "\(m) produced unexpected output"
        }
    }
}

/// Shared on-device model store: downloads (with progress), SHA-256 verifies, and
/// caches ONNX models + their vocab/dict text files under Application Support.
///
/// Same artefacts + pinned commit URLs the web app uses (`web/core/translate/tl-worker.js`
/// and `web/core/colorize/model.js`), so the native pipeline reads byte-identical models.
enum OnnxModelStore {
    static var dir: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let d = base.appendingPathComponent("Nyora/models", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func localURL(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func isCached(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: localURL(name).path)
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func log(_ s: String) {
        try? "[OnnxModelStore] \(s)\n".appendLine(to: NyoraLog.translate)
    }

    /// Ensure a binary model is present and (if `sha256` given) integrity-checked.
    /// Returns the local file path. `cacheName` is the on-disk filename.
    @discardableResult
    static func fetchModel(url: URL, cacheName: String, sha256 expected: String?,
                           sizeHint: Int, label: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = localURL(cacheName)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            guard let expected else { log("\(cacheName): cache hit (unverified)"); return dest }
            // The cache is exempt from any cleanup, so a bad copy would be sticky —
            // re-verify before trusting it, exactly like the web worker does.
            let data = try Data(contentsOf: dest, options: .mappedIfSafe)
            if sha256(data) == expected { log("\(cacheName): cache hit (verified)"); return dest }
            log("\(cacheName): cached copy failed integrity — re-downloading")
            try? fm.removeItem(at: dest)
        }
        log("\(cacheName): downloading from \(url.absoluteString)")
        let tmp: URL
        do {
            tmp = try await download(url: url, sizeHint: sizeHint, progress: progress)
        } catch {
            log("\(cacheName): DOWNLOAD FAILED — \(error)")
            throw error
        }
        defer { try? fm.removeItem(at: tmp) }
        log("\(cacheName): downloaded, verifying")
        if let expected {
            let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
            let got = sha256(data)
            guard got == expected else {
                log("\(cacheName): SHA MISMATCH got=\(got.prefix(12)) want=\(expected.prefix(12))")
                throw OnnxError.integrity(label)
            }
        }
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: dest)
        log("\(cacheName): SAVED (\((try? fm.attributesOfItem(atPath: dest.path)[.size]) as? Int ?? 0) bytes)")
        return dest
    }

    /// Ensure a text file (vocab/dict) is cached; return its contents. No SHA — these
    /// are small non-LFS blobs already made immutable by the commit-pinned URL.
    static func fetchText(url: URL, cacheName: String, label: String) async throws -> String {
        let dest = localURL(cacheName)
        if let data = try? Data(contentsOf: dest), let s = String(data: data, encoding: .utf8) {
            return s
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw OnnxError.download(label)
        }
        guard let s = String(data: data, encoding: .utf8) else { throw OnnxError.download(label) }
        try? data.write(to: dest)
        return s
    }

    private static func download(url: URL, sizeHint: Int,
                                 progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        // Prevent App Nap from suspending an in-flight download when the window
        // loses focus (a freshly-created URLSession holds no power assertion of
        // its own, so a backgrounded GUI app can otherwise freeze it).
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .suddenTerminationDisabled],
            reason: "Downloading on-device model"
        )
        let delegate = OnnxDownloadDelegate(sizeHint: sizeHint, onProgress: progress)
        // An ephemeral config avoids any interaction with the app's customized
        // URLCache.shared, and a generous timeout survives slow first bytes.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForResource = 600
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer {
            session.finishTasksAndInvalidate()
            ProcessInfo.processInfo.endActivity(activity)
        }
        return try await withCheckedThrowingContinuation { c in
            delegate.continuation = c
            session.downloadTask(with: url).resume()
        }
    }
}

/// Streams a download to disk while reporting progress. `URLSession.data(for:)` gives
/// no progress and `AsyncBytes` would iterate one byte at a time, so we use a task.
private final class OnnxDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let sizeHint: Int
    private let onProgress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<URL, Error>?

    init(sizeHint: Int, onProgress: @escaping @Sendable (Double) -> Void) {
        self.sizeHint = sizeHint
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite)
                                                  : Double(max(1, sizeHint))
        onProgress(min(1, max(0, Double(totalBytesWritten) / total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns — move it out synchronously.
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
