import Foundation
import Network

/// A tiny localhost HTTP/1.1 server the JVM helper calls to fetch Cloudflare-protected
/// content THROUGH the app's WKWebView. cf_clearance is bound to the WebView's browser
/// session, so the helper's OkHttp can never use it — instead the helper POSTs the request
/// here and we replay it inside the solved WebView session (MacCloudflareSolver.fetchViaWebView).
///
/// Protocol (one route):
///   POST /relay  body {"url","method","headers":{}}
///        resp    {"status","headers":{},"bodyBase64"}   (5xx {"error"} on failure)
// Mutable state (_port) is guarded by portLock; the listener runs on a private queue.
final class WebViewRelayServer: @unchecked Sendable {
    static let shared = WebViewRelayServer()

    private let queue = DispatchQueue(label: "nyora.webview-relay")
    private var listener: NWListener?
    private let portLock = NSLock()
    private var _port: UInt16 = 0
    var port: UInt16 { portLock.lock(); defer { portLock.unlock() }; return _port }

    /// Start on an ephemeral loopback port. Returns the port, or nil on failure.
    @discardableResult
    func start() -> UInt16? {
        if port != 0 { return port }
        let ready = DispatchSemaphore(value: 0)
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            let listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] conn in
                conn.start(queue: self?.queue ?? .global())
                self?.receive(on: conn, buffer: Data())
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let p = listener.port {
                    self?.portLock.lock(); self?._port = p.rawValue; self?.portLock.unlock()
                    ready.signal()
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            _ = ready.wait(timeout: .now() + 3)
            return port == 0 ? nil : port
        } catch {
            return nil
        }
    }

    // MARK: - Minimal HTTP/1.1 request reading

    private func receive(on conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            if let request = Self.parseRequest(buffer) {
                Task { await self.handle(request, on: conn) }
                return
            }
            if error != nil || isComplete { conn.cancel(); return }
            self.receive(on: conn, buffer: buffer)
        }
    }

    private struct Request { let method: String; let path: String; let body: Data }

    /// Returns a Request once the full headers + Content-Length body have arrived, else nil.
    private static func parseRequest(_ buffer: Data) -> Request? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }
        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        if available < contentLength { return nil }
        let body = buffer.subdata(in: bodyStart..<buffer.index(bodyStart, offsetBy: contentLength))
        return Request(method: parts[0], path: parts[1], body: body)
    }

    // MARK: - Routing

    private func handle(_ request: Request, on conn: NWConnection) async {
        guard request.method == "POST", request.path == "/relay" else {
            respond(conn, status: 404, json: ["error": "not found"]); return
        }
        guard let obj = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let url = obj["url"] as? String else {
            respond(conn, status: 400, json: ["error": "bad request"]); return
        }
        let method = (obj["method"] as? String) ?? "GET"
        var headers = (obj["headers"] as? [String: String]) ?? [:]
        let bodyBase64 = obj["bodyBase64"] as? String
        if let ct = obj["bodyContentType"] as? String, headers["Content-Type"] == nil {
            headers["Content-Type"] = ct
        }

        guard let result = await MacCloudflareSolver.shared.fetchViaWebView(
            url: url, method: method, headers: headers, bodyBase64: bodyBase64
        ) else {
            respond(conn, status: 502, json: ["error": "webview fetch failed"]); return
        }
        respond(conn, status: 200, json: [
            "status": result.0,
            "headers": result.1,
            "bodyBase64": result.2.base64EncodedString(),
        ])
    }

    private func respond(_ conn: NWConnection, status: Int, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        var head = "HTTP/1.1 \(status) OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
