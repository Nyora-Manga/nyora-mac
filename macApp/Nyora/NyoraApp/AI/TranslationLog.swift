import Foundation

// The translate-pipeline log helpers. These lived in the (now-removed) MangaTranslator; moved
// here so ChapterTranslator's `log(_:)` keeps writing to ~/Library/Logs/Nyora/translate.log.

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

    /// Colorization-pipeline log path (native ONNX manga-colorization-v2).
    static let colorize: URL = {
        let fm = FileManager.default
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Nyora", isDirectory: true)
            ?? fm.temporaryDirectory.appendingPathComponent("Nyora", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("colorize.log")
    }()
}
