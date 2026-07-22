import Foundation
import Network

/// A tiny localhost HTTP/1.1 server that serves the bundled OCR web assets (`harness.html`,
/// `ocr-bridge.js`, `tl-worker.js`) under a single real origin, so the WKWebView can create a
/// module `Worker` and the page can be cross-origin isolated (COOP/COEP) for wasm threads.
///
/// A `file://` origin can't host a module worker or be cross-origin isolated, and custom scheme
/// handlers are unreliable for module workers — a real http://127.0.0.1 origin is what the web app
/// itself uses, so it's the faithful, proven route. The worker's model/runtime fetches go straight
/// to their public CDNs (jsdelivr / HuggingFace), which is why COEP is `credentialless`.
final class OcrAssetServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nyora.ocr.assets")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    /// Bundled files by request path. Loaded once at start; the OCR asset set is tiny + static.
    private var files: [String: (data: Data, contentType: String)] = [:]

    /// Boot the server and return its port, or nil if the assets are missing / bind failed.
    func start() -> UInt16? {
        guard loadAssets() else { return nil }
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            self.listener = listener
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .global())
                self?.receive(on: conn, buffer: Data())
            }
            let sem = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state {
                    self?.port = self?.listener?.port?.rawValue ?? 0
                    sem.signal()
                } else if case .failed = state {
                    sem.signal()
                }
            }
            listener.start(queue: queue)
            _ = sem.wait(timeout: .now() + 5)
            return port == 0 ? nil : port
        } catch {
            return nil
        }
    }

    // Resolve the three assets from the app bundle. `.copy("Resources/ocr")` keeps them together;
    // try the likely subdirectories so this survives SPM/Xcode bundle-layout differences.
    private func loadAssets() -> Bool {
        let items: [(name: String, ext: String, path: String, ct: String)] = [
            ("harness", "html", "/", "text/html; charset=utf-8"),
            ("ocr-bridge", "js", "/ocr-bridge.js", "text/javascript; charset=utf-8"),
            ("tl-worker", "js", "/tl-worker.js", "text/javascript; charset=utf-8"),
        ]
        for item in items {
            let url = Self.locate(item.name, ext: item.ext)
            guard let url, let data = try? Data(contentsOf: url) else { return false }
            files[item.path] = (data, item.ct)
            if item.path == "/" { files["/harness.html"] = (data, item.ct) }
        }
        return true
    }

    private static func locate(_ name: String, ext: String) -> URL? {
        let subdirs: [String?] = ["ocr", "Resources/ocr", nil]
        for sub in subdirs {
            if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub) {
                return url
            }
        }
        #if SWIFT_PACKAGE
        for sub in subdirs {
            if let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: sub) {
                return url
            }
        }
        #endif
        return nil
    }

    // MARK: - Minimal HTTP/1.1

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            // We only need the request line (GET /path HTTP/1.1) — headers end at \r\n\r\n.
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf.subdata(in: buf.startIndex..<range.lowerBound), encoding: .utf8) ?? ""
                self.handle(head, on: conn)
                return
            }
            if isComplete || error != nil { conn.cancel(); return }
            self.receive(on: conn, buffer: buf)
        }
    }

    private func handle(_ head: String, on conn: NWConnection) {
        let requestLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = requestLine.split(separator: " ")
        var path = parts.count >= 2 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") { path = String(path[path.startIndex..<q]) }

        guard let asset = files[path] else {
            respond(conn, status: "404 Not Found", body: Data("not found".utf8), contentType: "text/plain")
            return
        }
        respond(conn, status: "200 OK", body: asset.data, contentType: asset.contentType)
    }

    private func respond(_ conn: NWConnection, status: String, body: Data, contentType: String) {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // Cross-origin isolation → SharedArrayBuffer wasm threads. `credentialless` lets the
        // worker fetch the ORT runtime + models from public CDNs without CORP headers on them.
        head += "Cross-Origin-Opener-Policy: same-origin\r\n"
        head += "Cross-Origin-Embedder-Policy: credentialless\r\n"
        head += "Cross-Origin-Resource-Policy: cross-origin\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
