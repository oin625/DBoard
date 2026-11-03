import Foundation
import AppKit
import Combine

enum AudiLocalLaunch {
    static var repositoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("work/code/audi", isDirectory: true)
    }

    static let defaultBaseURL = URL(string: "http://localhost:3000")!
    static let consolePath = "/test-console"
    static let startupTimeout: TimeInterval = 120

    static func pageURL(base: URL, page: String) -> URL? {
        guard page.hasPrefix("/"), !page.contains("//"),
              !page.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 }),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme, ["http", "https"].contains(scheme),
              components.host != nil else { return nil }
        components.path = page == "/" ? "/" : page.hasSuffix("/") ? String(page.dropLast()) : page
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func localBaseURL(in text: String) -> URL? {
        guard let range = text.range(of: #"https?://(?:localhost|127\.0\.0\.1):[0-9]{2,5}"#,
                                     options: .regularExpression) else { return nil }
        return URL(string: String(text[range]))
    }

    static var nextExecutable: URL {
        repositoryURL.appendingPathComponent("node_modules/next/dist/bin/next")
    }

    static func resolveNodeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let versions = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: versions.path) {
            for name in names.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let path = versions.appendingPathComponent(name).appendingPathComponent("bin/node").path
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        let fallbacks = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            home.appendingPathComponent(".volta/bin/node").path,
            home.appendingPathComponent(".local/share/fnm/aliases/default/bin/node").path,
            "/usr/bin/node"
        ]
        if let path = fallbacks.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        let result = ProcessRunner.run("/bin/zsh", arguments: ["-lc", "command -v node"], timeout: 3)
        guard result.succeeded, let text = String(data: result.stdout, encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) })
    }

    static var probeURL: URL {
        pageURL(base: defaultBaseURL, page: consolePath) ?? defaultBaseURL
    }
}

final class LocalAudiServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(base: URL, external: Bool)
        case failed(String)
    }

    static let shared = LocalAudiServer()

    @Published private(set) var state: State = .stopped
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var process: Process?
    private var pendingPage: String?
    private var generation = UUID()
    private var detectedBaseURL: URL?
    private var startedAt = Date()
    private let outputLock = NSLock()
    private var outputBuffer = Data()

    private init() {}

    var isStarting: Bool {
        if case .starting = state { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func startAndOpen(page: String) {
        switch state {
        case .running(let base, _):
            open(page: page, base: base)
        case .starting:
            pendingPage = page
        case .stopped, .failed:
            pendingPage = page
            begin()
        }
    }

    func open(page: String) {
        guard case .running(let base, _) = state else { return }
        open(page: page, base: base)
    }

    func stop() {
        invalidateRun()
        terminateProcess()
        pendingPage = nil
        state = .stopped
    }

    private func begin() {
        invalidateRun()
        terminateProcess()
        state = .starting
        detectedBaseURL = nil
        startedAt = Date()
        resetOutput()
        let run = generation

        Self.probeAudi(AudiLocalLaunch.probeURL) { [weak self] reachable in
            DispatchQueue.main.async {
                guard let self, self.generation == run, self.isStarting else { return }
                if reachable {
                    self.state = .running(base: AudiLocalLaunch.defaultBaseURL, external: true)
                    self.flushPending()
                } else {
                    self.launch(run: run)
                }
            }
        }
    }

    private func launch(run: UUID) {
        guard generation == run, isStarting else { return }
        let directory = AudiLocalLaunch.repositoryURL
        let next = AudiLocalLaunch.nextExecutable
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("package.json").path) else {
            fail("找不到本地 audi 仓库：" + directory.path)
            return
        }
        guard FileManager.default.fileExists(atPath: next.path) else {
            fail("本地 audi 依赖未安装，请先在仓库运行 npm install")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let node = AudiLocalLaunch.resolveNodeExecutable()
            DispatchQueue.main.async {
                guard let self, self.generation == run, self.isStarting else { return }
                guard let node else {
                    self.fail("找不到可用的 node，请检查本地开发环境")
                    return
                }
                self.spawn(node: node, next: next, directory: directory, run: run)
            }
        }
    }

    private func spawn(node: String, next: URL, directory: URL, run: UUID) {
        guard generation == run, isStarting else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [next.path, "dev"]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path +
            ":/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["NO_COLOR"] = "1"
        environment["FORCE_COLOR"] = "0"
        environment["NODE_ENV"] = "development"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data, run: run)
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                self.process = nil
                guard self.isStarting || self.isRunning else { return }
                let tail = self.lastOutputLine()
                let code = finished.terminationReason == .uncaughtSignal ? "信号终止" : "退出码 \(finished.terminationStatus)"
                self.state = .failed(tail.isEmpty ? "本地 audi 已退出（\(code)）" : "本地 audi 已退出（\(code)）：\(tail)")
            }
        }

        do {
            try process.run()
            self.process = process
            waitUntilReady(run: run)
        } catch {
            fail("本地 audi 启动失败：" + error.localizedDescription)
        }
    }

    private func waitUntilReady(run: UUID) {
        guard generation == run, isStarting else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= AudiLocalLaunch.startupTimeout {
            fail("本地 audi 启动超时，请检查 audi 仓库能否手动运行 npm run dev")
            return
        }
        guard let base = detectedBaseURL ?? (elapsed >= 8 ? AudiLocalLaunch.defaultBaseURL : nil) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.waitUntilReady(run: run) }
            return
        }

        Self.probe(AudiLocalLaunch.pageURL(base: base, page: AudiLocalLaunch.consolePath) ?? base) { [weak self] reachable in
            DispatchQueue.main.async {
                guard let self, self.generation == run, self.isStarting else { return }
                if reachable {
                    self.state = .running(base: base, external: false)
                    self.flushPending()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.waitUntilReady(run: run)
                    }
                }
            }
        }
    }

    private func consume(_ data: Data, run: UUID) {
        guard let base = appendingOutput(data).flatMap(AudiLocalLaunch.localBaseURL(in:)) else { return }
        DispatchQueue.main.async {
            guard self.generation == run, self.isStarting else { return }
            self.detectedBaseURL = base
        }
    }

    private func open(page: String, base: URL) {
        guard let url = AudiLocalLaunch.pageURL(base: base, page: page) else { return }
        openURL(url)
    }

    private func flushPending() {
        guard let page = pendingPage else { return }
        pendingPage = nil
        open(page: page)
    }

    private func fail(_ message: String) {
        invalidateRun()
        terminateProcess()
        pendingPage = nil
        state = .failed(message)
    }

    private func invalidateRun() {
        generation = UUID()
        detectedBaseURL = nil
        resetOutput()
    }

    private func terminateProcess() {
        guard let process else { return }
        self.process = nil
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    private func lastOutputLine() -> String {
        let text = currentOutput()
        let cleaned = text.replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]",
                                                with: "", options: .regularExpression)
        return cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
    }

    private func appendingOutput(_ data: Data) -> String? {
        outputLock.lock(); defer { outputLock.unlock() }
        outputBuffer.append(data)
        if outputBuffer.count > 32_768 { outputBuffer = outputBuffer.suffix(16_384) }
        return String(data: outputBuffer, encoding: .utf8)
    }

    private func currentOutput() -> String {
        outputLock.lock(); defer { outputLock.unlock() }
        return String(data: outputBuffer, encoding: .utf8) ?? ""
    }

    private func resetOutput() {
        outputLock.lock(); defer { outputLock.unlock() }
        outputBuffer.removeAll(keepingCapacity: true)
    }

    private static func probeAudi(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            guard let http = response as? HTTPURLResponse,
                  (200..<400).contains(http.statusCode),
                  (http.value(forHTTPHeaderField: "X-Powered-By") ?? "").contains("Next") else {
                completion(false)
                return
            }
            completion(true)
        }.resume()
    }

    private static func probe(_ url: URL, completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse) != nil)
        }.resume()
    }
}