import Darwin
import Foundation

struct CodexHookControl {
    struct Status: Equatable {
        var total = 0
        var enabled = 0
        var awaitingTrust = 0
    }

    struct Inspection: Equatable {
        let status: Status
        let hooks: [HookDetail]
    }

    struct HookDetail: Identifiable, Equatable {
        let id: String
        let eventName: String
        let command: String
        let matcher: String?
        let timeout: Int?
        let asynchronous: Bool
        let enabled: Bool
        let trusted: Bool

        var title: String {
            switch eventName {
            case "preToolUse": return "工具调用前"
            case "postToolUse": return "工具调用后"
            case "postToolUseFailure": return "工具调用失败"
            case "userPromptSubmit": return "提交提示"
            case "stop": return "本轮结束"
            default: return eventName
            }
        }
        var contentSummary: String {
            switch eventName {
            case "preToolUse": return "工具名称、输入参数及会话上下文。"
            case "postToolUse": return "工具调用信息、返回结果及会话上下文。"
            case "postToolUseFailure": return "工具调用信息、失败信息及会话上下文。"
            case "userPromptSubmit": return "提交的提示内容、附件信息及会话上下文。"
            case "stop": return "本轮结束的事件上下文，以及 Codex 提供的其他字段。"
            default: return "Codex 传给此事件的完整 JSON。"
            }
        }
        var scriptURL: URL? {
            guard let match = command.firstMatch(of: #/(?:"([^"]+)"|'([^']+)'|(\S+))\s*$/#),
                  let argument = match.1 ?? match.2 ?? match.3 else { return nil }
            return URL(fileURLWithPath: String(argument)).resolvingSymlinksInPath()
        }
        var version: String { scriptURL?.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent ?? "未知" }
    }

    private struct Hook: Decodable, Equatable {
        let key: String
        let command: String?
        let source: String
        let sourcePath: String
        let isManaged: Bool
        let enabled: Bool
        let trustStatus: String
        let eventName: String
        let matcher: String?
        let timeoutSec: Int?
        let async: Bool?
    }

    private struct HookList: Decodable {
        struct Entry: Decodable {
            let hooks: [Hook]
            let errors: [ConfigError]
        }
        struct ConfigError: Decodable { let path: String }
        let data: [Entry]
    }

    enum ControlError: LocalizedError {
        case missingCodex, invalidResponse, timeout, configuration, overridden, hooksChanged

        var errorDescription: String? {
            switch self {
            case .missingCodex: return "未找到 ChatGPT 桌面端自带的 Codex。"
            case .invalidResponse: return "无法读取 Codex Hooks 状态，请检查桌面端和本机配置。"
            case .timeout: return "读取或保存超时，请刷新状态后重试。"
            case .configuration: return "Codex 无法读取用户 hooks.json，请在 Codex 设置中检查。"
            case .overridden: return "Codex 配置未应用，请查看 Codex 设置中的 Hooks。"
            case .hooksChanged: return "Luban Hooks 已变更，请刷新后再操作。"
            }
        }
    }

    let home: URL
    let executable: URL?

    init(home: URL? = nil, executable: URL? = nil) {
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let configuredHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        self.home = home ?? configuredHome.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? userHome.appendingPathComponent(".codex")
        self.executable = executable ?? [
            URL(fileURLWithPath: "/Applications"),
            userHome.appendingPathComponent("Applications")
        ].map {
            $0.appendingPathComponent("ChatGPT.app/Contents/Resources/codex-cli/bin/codex")
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    func status() throws -> Status { try inspect().status }
    func setEnabled(_ enabled: Bool) throws -> Status { try inspect(enabled: enabled).status }

    func inspect(enabled: Bool? = nil) throws -> Inspection {
        try withCodex { client in
            var hooks = try list(using: client)
            if let enabled {
                guard !hooks.isEmpty else { throw ControlError.hooksChanged }
                let encoder = JSONEncoder()
                encoder.outputFormatting = .withoutEscapingSlashes
                let edits = try hooks.filter { $0.enabled != enabled }.map { hook in
                    let key = try encoder.encode(hook.key)
                    return [
                        "keyPath": "hooks.state.\(String(decoding: key, as: UTF8.self)).enabled",
                        "value": enabled,
                        "mergeStrategy": "upsert"
                    ] as [String: Any]
                }
                if !edits.isEmpty {
                    let result = try client.request("config/batchWrite", ["edits": edits, "reloadUserConfig": true])
                    guard result["status"] as? String == "ok" else { throw ControlError.overridden }
                    let updated = try list(using: client)
                    guard Set(updated.map(\.key)) == Set(hooks.map(\.key)) else { throw ControlError.hooksChanged }
                    guard updated.allSatisfy({ $0.enabled == enabled }) else { throw ControlError.overridden }
                    hooks = updated
                }
            }
            return inspection(of: hooks)
        }
    }

    /// The same decoder is used by the live API and fixture verification.
    func decodeInspection(_ data: Data) throws -> Inspection {
        inspection(of: try decodedHooks(data))
    }

    private func list(using client: CodexHookConnection) throws -> [Hook] {
        let result = try client.request("hooks/list", ["cwds": [home.deletingLastPathComponent().path]])
        return try decodedHooks(JSONSerialization.data(withJSONObject: result))
    }

    private func decodedHooks(_ data: Data) throws -> [Hook] {
        let entries = try JSONDecoder().decode(HookList.self, from: data)
        let userHooksPath = home.appendingPathComponent("hooks.json").resolvingSymlinksInPath().path
        let scriptRoot = home.appendingPathComponent("luban").resolvingSymlinksInPath().path
        let script = #/(?:"([^"]+)"|'([^']+)'|(\S+))\s*$/#
        guard !entries.data.isEmpty else { throw ControlError.invalidResponse }
        var hooks: [String: Hook] = [:]
        for entry in entries.data {
            if entry.errors.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == userHooksPath }) {
                throw ControlError.configuration
            }
            for hook in entry.hooks where hook.source == "user" && !hook.isManaged {
                guard URL(fileURLWithPath: hook.sourcePath).resolvingSymlinksInPath().path == userHooksPath,
                      let match = hook.command?.firstMatch(of: script),
                      let argument = match.1 ?? match.2 ?? match.3,
                      argument.hasPrefix("/") else { continue }
                let scriptURL = URL(fileURLWithPath: String(argument)).resolvingSymlinksInPath()
                let versionDirectory = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
                guard scriptURL.lastPathComponent == "report-event.js",
                      scriptURL.deletingLastPathComponent().lastPathComponent == "hooks",
                      versionDirectory.deletingLastPathComponent().path == scriptRoot else { continue }
                hooks[hook.key] = hook
            }
        }
        return hooks.values.sorted { $0.key < $1.key }
    }

    private func inspection(of hooks: [Hook]) -> Inspection {
        let details = hooks.map {
            HookDetail(id: $0.key, eventName: $0.eventName, command: $0.command ?? "",
                matcher: $0.matcher, timeout: $0.timeoutSec, asynchronous: $0.async ?? false,
                enabled: $0.enabled, trusted: $0.trustStatus == "trusted")
        }
        return Inspection(status: status(of: hooks), hooks: details)
    }

    private func status(of hooks: [Hook]) -> Status {
        let enabled = hooks.filter(\.enabled)
        return Status(total: hooks.count, enabled: enabled.count,
                      awaitingTrust: enabled.filter { $0.trustStatus != "trusted" }.count)
    }

    private func withCodex<Result>(_ operation: (CodexHookConnection) throws -> Result) throws -> Result {
        guard let executable else { throw ControlError.missingCodex }
        let client = try CodexHookConnection(executable: executable, home: home)
        defer { client.close() }
        _ = try client.request("initialize", [
            "clientInfo": ["name": "dboard", "version": "1"],
            "capabilities": ["experimentalApi": true]
        ])
        try client.send(["method": "initialized"])
        return try operation(client)
    }
}

private final class CodexHookConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var requestID = 0

    init(executable: URL, home: URL) throws {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.currentDirectoryURL = home.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    func send(_ message: [String: Any]) throws {
        var line = try JSONSerialization.data(withJSONObject: message)
        line.append(10)
        try input.fileHandleForWriting.write(contentsOf: line)
    }

    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        requestID += 1
        try send(["id": requestID, "method": method, "params": params])
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        let reader = output.fileHandleForReading
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      message["id"] as? Int == requestID else { continue }
                guard let result = message["result"] as? [String: Any] else {
                    throw CodexHookControl.ControlError.invalidResponse
                }
                return result
            }
            var descriptor = pollfd(fd: reader.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let milliseconds = max(0, deadline - ProcessInfo.processInfo.systemUptime) * 1_000
            let ready = poll(&descriptor, 1, Int32(milliseconds.rounded(.up)))
            if ready == 0 { break }
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else {
                throw CodexHookControl.ControlError.invalidResponse
            }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(reader.fileDescriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw CodexHookControl.ControlError.invalidResponse }
            buffer.append(contentsOf: chunk.prefix(count))
        }
        throw CodexHookControl.ControlError.timeout
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        try? output.fileHandleForReading.close()
    }
}
