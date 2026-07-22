import Foundation

/// Launches the Nyora JVM helper sidecar from inside the SwiftUI app.
///
/// Locates `nyora-helper.jar` (dev tree first, then the app bundle's Resources)
/// and spawns it with `java`. Falls back to a clear status message if Java is
/// not on the user's PATH.
///
/// The helper writes its bound port to ~/Library/Application Support/Nyora/helper.port;
/// `NyoraHelperBridge` polls that file once we've started the process.
actor HelperLauncher {
    enum LaunchResult {
        case launched(URL)            // jar location
        case alreadyRunning           // port file present + responsive
        case javaMissing
        case jarMissing
        case failed(String)
    }

    private var process: Process?
    private var stderrPipe: Pipe?
    private var stdoutPipe: Pipe?

    func currentProcess() -> Process? { process }

    func launchIfNeeded() async -> LaunchResult {
        if await isHelperReachable() { return .alreadyRunning }

        guard let java = locateJava() else { return .javaMissing }
        guard let jar = locateHelperJar() else { return .jarMissing }

        // Clear any stale port file from a previous (crashed) launch.
        if let portFile = portFileURL() {
            try? FileManager.default.removeItem(at: portFile)
        }

        let proc = Process()
        proc.executableURL = java
        proc.arguments = [
            "-Dapple.awt.UIElement=true",
            "-Xss512k",
            "-jar",
            jar.path,
            "--watch-pid=\(ProcessInfo.processInfo.processIdentifier)",
        ]
        // Solve Cloudflare with our own WKWebView (MacCloudflareSolver) instead of a
        // headless Chrome. The helper then reports a challenge as
        // "Cloudflare challenge: <host>" rather than shelling out to FlareSolverr, and
        // NyoraHelperBridge solves it and POSTs the clearance back. WebKit ships with
        // macOS, runs on the user's own IP, and a human can clear Turnstile — none of
        // which a bundled Chromium would give us. FlareSolverr is also belt-and-braces
        // disabled: nothing should ever try to reach 127.0.0.1:8191 from the app.
        var env = ProcessInfo.processInfo.environment
        env["NYORA_NATIVE_CF_SOLVER"] = "1"
        env["NYORA_FLARESOLVERR_DISABLED"] = "1"
        // Start the WebView relay and tell the helper where it is. Cloudflare-protected
        // requests are fetched through the app's WKWebView (the session that holds the
        // clearance) instead of the helper's OkHttp, which the clearance rejects.
        if let relayPort = WebViewRelayServer.shared.start() {
            env["NYORA_WEBVIEW_RELAY_URL"] = "http://127.0.0.1:\(relayPort)/relay"
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        stdoutPipe = outPipe
        stderrPipe = errPipe

        do {
            try proc.run()
            process = proc
            return .launched(jar)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func terminate() async {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        proc.waitUntilExit()
        process = nil
    }

    /// Read whatever the helper has emitted to stderr so far without blocking.
    /// Used by AppState to surface launch errors in the status banner.
    func collectStderr() -> String? {
        guard let pipe = stderrPipe else { return nil }
        let data = pipe.fileHandleForReading.availableData
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Discovery

    private func isHelperReachable() async -> Bool {
        guard let portFile = portFileURL(),
              let portString = try? String(contentsOf: portFile, encoding: .utf8),
              let port = Int(portString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        var req = URLRequest(url: url); req.timeoutInterval = 0.6
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    private func locateJava() -> URL? {
        // 1. NYORA_JAVA env var.
        if let custom = ProcessInfo.processInfo.environment["NYORA_JAVA"],
           !custom.isEmpty,
           FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        // 2. The JRE bundled inside the app (Contents/Resources/jre), shipped by
        //    scripts/build-dmg.sh. This MUST be tried before any system path: a released
        //    build has to run on a Mac with no JDK installed, and /usr/bin/java below is
        //    always present as an Apple stub that prompts to install one rather than
        //    running anything.
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("jre/bin/java")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        // 3. Well-known macOS locations — development fallback, when running outside a
        //    packaged bundle. /usr/bin/java is deliberately last: it exists even with no
        //    JDK, so preferring it would shadow a real JVM found further down.
        let candidates = [
            "/opt/homebrew/opt/openjdk@17/bin/java",                  // Homebrew arm64
            "/usr/local/opt/openjdk@17/bin/java",                     // Homebrew x86_64
            "/Library/Java/JavaVirtualMachines/openjdk-17.jdk/Contents/Home/bin/java",
            "/usr/bin/java",                                          // Apple stub (asks to install a JDK)
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // 3. /usr/bin/which java
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        which.arguments = ["which", "java"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            if which.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func locateHelperJar() -> URL? {
        // 1. NYORA_HELPER_JAR env var.
        if let custom = ProcessInfo.processInfo.environment["NYORA_HELPER_JAR"],
           !custom.isEmpty,
           FileManager.default.fileExists(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        // 2. Inside the running app bundle (Contents/Resources/nyora-helper.jar).
        if let bundled = Bundle.main.url(forResource: "nyora-helper", withExtension: "jar") {
            return bundled
        }
        // 3. Dev tree: walk up from the executable until we find shared/build/libs.
        let exec = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exec.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("shared/build/libs/nyora-helper.jar")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            // Some layouts have shared under nyora-mac/shared from the parent.
            let candidate2 = dir.appendingPathComponent("nyora-mac/shared/build/libs/nyora-helper.jar")
            if fm.fileExists(atPath: candidate2.path) { return candidate2 }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    private func portFileURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("Nyora/helper.port")
    }
}
