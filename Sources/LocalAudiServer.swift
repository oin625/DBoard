import Foundation
import AppKit
import Combine
import Darwin

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

/// A single local audi instance is shared by demands using the same directory and branch.
final class LocalAudiServer: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running(base: URL, external: Bool)
        case stopping
        case failed(String)
    }
    static let shared = LocalAudiServer()
    @Published private(set) var state: State = .stopped
    @Published private(set) var activeTarget: AudiLocalTarget?
    @Published private(set) var demandIDs: Set<String> = []
    @Published private(set) var issue: String?
    @Published private(set) var issueDemandID: String?
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var process: Process?
    private var request: URLSessionDataTask?
    private var pendingPage: String?
    private var pageRequest = UUID()
    private var generation = UUID()
    private var lookup = UUID()
    private var startedAt = Date()
    private var failureAfterStop: String?
    private let outputLock = NSLock()
    private var outputBuffer = Data()
    private var outputRun = UUID()
    private let loadTarget: @Sendable (String, URL) throws -> AudiLocalTarget
    private let resolveNode: @Sendable () -> String?
    private let helper: URL
    private let session: URLSession
    private let timeout: TimeInterval

    init(loadTarget: @escaping @Sendable (String, URL) throws -> AudiLocalTarget = { try AudiLocalTarget.load(id: $0, at: $1) },
         resolveNode: @escaping @Sendable () -> String? = { AudiLocalLaunch.resolveNodeExecutable() },
         helper: URL = LocalAudiServer.helperURL,
         session: URLSession = URLSession(configuration: .ephemeral),
         timeout: TimeInterval = AudiLocalLaunch.startupTimeout) {
        self.loadTarget = loadTarget; self.resolveNode = resolveNode
        self.helper = helper; self.session = session; self.timeout = timeout
    }

    static var helperURL: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("CLI/audi_local_server.py"),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/audi_local_server.py")
    }

    var isStarting: Bool { state == .starting }
    var isRunning: Bool { if case .running = state { return true }; return false }
    var isActive: Bool { isStarting || isRunning || state == .stopping }

    func startAndOpen(id: String, at cacheURL: URL = URL(fileURLWithPath: CacheFile.path)) {
        guard !isStarting, state != .stopping else { return }
        issue = nil; issueDemandID = id
        if !isRunning {
            generation = UUID()
            state = .starting
            demandIDs = [id]
        }
        let run = generation, ticket = UUID()
        lookup = ticket
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let result = Result { () -> (AudiLocalTarget, String) in
                let target = try self.loadTarget(id, cacheURL)
                guard let node = self.resolveNode() else { throw AudiLocalError.message("找不到 node，请检查本地开发环境。") }
                return (target, node)
            }
            DispatchQueue.main.async {
                guard self.generation == run, self.lookup == ticket, self.state != .stopping else { return }
                do {
                    let (target, node) = try result.get()
                    if case .running(let base, _) = self.state {
                        guard self.activeTarget?.repository == target.repository,
                              self.activeTarget?.branch == target.branch else {
                            throw AudiLocalError.message("本地 audi 正在另一个目录或分支运行，请先停止，再启动本需求。")
                        }
                        self.demandIDs.insert(id)
                        self.checkPage(base: base, page: target.page, run: run, openingOnly: true)
                    } else {
                        self.activeTarget = target
                        self.pendingPage = target.page
                        try self.spawn(node: node, target: target, run: run)
                    }
                } catch {
                    if self.isRunning { self.issue = error.localizedDescription }
                    else { self.fail(error.localizedDescription) }
                }
            }
        }
    }

    func stop() {
        lookup = UUID()
        request?.cancel(); request = nil
        pendingPage = nil
        issue = nil
        failureAfterStop = nil
        guard let process, process.isRunning else {
            self.process = nil; activeTarget = nil; demandIDs = []
            generation = UUID(); state = .stopped
            return
        }
        state = .stopping
        // The supervisor terminates its entire owned group, including Next workers.
        process.terminate()
    }

    private func spawn(node: String, target: AudiLocalTarget, run: UUID) throws {
        guard FileManager.default.fileExists(atPath: helper.path) else {
            throw AudiLocalError.message("本地启动工具缺失，请重新安装 D板。")
        }
        let port = try Self.availablePort()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [helper.path, "--parent", String(ProcessInfo.processInfo.processIdentifier),
            "--repo", target.repository.path, "--node", node, "--port", String(port)]
        process.currentDirectoryURL = target.repository
        process.standardInput = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["NODE_ENV"] = "development"
        environment["NEXT_TELEMETRY_DISABLED"] = "1"
        environment["NO_COLOR"] = "1"; environment["FORCE_COLOR"] = "0"
        process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        outputLock.lock(); outputBuffer = Data(); outputRun = run; outputLock.unlock()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendOutput(data, run: run)
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.generation == run else { return }
                self.request?.cancel(); self.request = nil
                self.process = nil
                let stopping = self.state == .stopping
                let error = self.failureAfterStop
                self.activeTarget = nil; self.demandIDs = []
                self.generation = UUID()
                if let error { self.state = .failed(error) }
                else if stopping { self.state = .stopped }
                else { self.state = .failed("本地 audi 已退出。 " + self.lastOutputLine()) }
                self.failureAfterStop = nil
            }
        }
        try process.run()
        self.process = process
        startedAt = Date()
        let base = URL(string: "http://127.0.0.1:" + String(port))!
        waitUntilReady(base: base, page: target.page, run: run)
    }

    private func waitUntilReady(base: URL, page: String, run: UUID) {
        guard generation == run, isStarting else { return }
        guard Date().timeIntervalSince(startedAt) < timeout else {
            fail("本地 audi 启动超时。 " + lastOutputLine()); return
        }
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier, port = base.port!
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let owned = Self.ownsListener(port: port, supervisorPID: pid)
            DispatchQueue.main.async {
                guard let self, self.generation == run, self.isStarting else { return }
                if owned { self.checkPage(base: base, page: page, run: run, openingOnly: false) }
                else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.waitUntilReady(base: base, page: page, run: run)
                    }
                }
            }
        }
    }

    private func checkPage(base: URL, page: String, run: UUID, openingOnly: Bool) {
        guard let url = AudiLocalLaunch.pageURL(base: base, page: page) else { fail("调试页路径无效。"); return }
        let ticket = UUID()
        pageRequest = ticket
        request?.cancel()
        var query = URLRequest(url: url)
        query.timeoutInterval = openingOnly ? 30 : min(30, max(1, timeout - Date().timeIntervalSince(startedAt)))
        query.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request = session.dataTask(with: query) { [weak self] _, response, error in
            DispatchQueue.main.async {
                guard let self, self.generation == run, self.pageRequest == ticket, self.state != .stopping else { return }
                self.request = nil
                let http = response as? HTTPURLResponse
                if Self.pageReady(response: http, requested: url) {
                    if !openingOnly { self.state = .running(base: base, external: false) }
                    self.pendingPage = nil
                    self.openURL(url)
                } else if let http {
                    let reason = "调试页 " + page + " 未就绪（HTTP " + String(http.statusCode) + "），请检查页面或编译错误。"
                    if openingOnly { self.issue = reason } else { self.fail(reason + " " + self.lastOutputLine()) }
                } else if openingOnly {
                    self.issue = "本地调试页暂时无法访问：" + (error?.localizedDescription ?? "连接失败")
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.waitUntilReady(base: base, page: page, run: run)
                    }
                }
            }
        }
        request?.resume()
    }

    static func pageReady(response: HTTPURLResponse?, requested: URL) -> Bool {
        guard let response, (200..<300).contains(response.statusCode), let actual = response.url else { return false }
        return actual.scheme == requested.scheme && actual.host == requested.host &&
            actual.port == requested.port && actual.path == requested.path
    }

    static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AudiLocalError.message("无法分配本地端口。") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw AudiLocalError.message("无法分配本地端口。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard result == 0 else { throw AudiLocalError.message("无法读取本地端口。") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func ownsListener(port: Int, supervisorPID: Int32) -> Bool {
        let result = ProcessRunner.run("/usr/sbin/lsof",
            arguments: ["-nP", "-t", "-iTCP:" + String(port), "-sTCP:LISTEN"], timeout: 2)
        guard result.succeeded else { return false }
        return String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            .compactMap { Int32($0) }.contains { getpgid($0) == supervisorPID }
    }

    private func fail(_ message: String) {
        request?.cancel(); request = nil
        pendingPage = nil
        if let process, process.isRunning {
            failureAfterStop = message
            state = .stopping
            process.terminate()
        } else {
            activeTarget = nil; demandIDs = []
            generation = UUID(); state = .failed(message)
        }
    }

    private func appendOutput(_ data: Data, run: UUID) {
        outputLock.lock(); defer { outputLock.unlock() }
        guard outputRun == run else { return }
        outputBuffer.append(data)
        if outputBuffer.count > 32_768 { outputBuffer = outputBuffer.suffix(16_384) }
    }

    private func lastOutputLine() -> String {
        outputLock.lock(); let data = outputBuffer; outputLock.unlock()
        let text = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{001B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        return text.components(separatedBy: .newlines).map(\.trimmed).last(where: { !$0.isEmpty }) ?? ""
    }
}
