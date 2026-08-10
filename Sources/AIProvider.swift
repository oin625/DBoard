import Foundation

/// DBoard 的统一 AI 执行入口。
/// 默认只调用国内版 qodercli；调用失败直接返回错误，绝不自动回退到 Codex。
struct DBoardAIProvider {
    struct Config: Codable {
        var command: String = NSHomeDirectory() + "/.local/bin/qoderclicn"
        var lightModel: String = "Qwen3.6-Flash"
        var strongModel: String = "Qwen3.8-Max"
    }

    enum Tier { case light, strong }

    static let configPath = NSHomeDirectory() + "/.config/dboard/ai-provider.json"
    static let shared = DBoardAIProvider()

    let config: Config

    init() {
        guard let data = FileManager.default.contents(atPath: Self.configPath),
              let decoded = try? JSONDecoder().decode(Config.self, from: data) else {
            config = Config()
            return
        }
        config = decoded
    }

    func model(for tier: Tier) -> String {
        tier == .light ? config.lightModel : config.strongModel
    }

    func makeProcess(tier: Tier, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: NSString(string: config.command).expandingTildeInPath)
        process.arguments = ["-m", model(for: tier)] + arguments
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["BUN_OPTIONS"] = "--preload=" + home + "/.loongsuite-pilot/hooks/qodercli-token-intercept.mjs"
        environment["PATH"] = (environment["PATH"] ?? "") + ":" + home + "/.local/bin:/opt/homebrew/bin"
        process.environment = environment
        return process
    }

    /// 轻量纯文本调用。失败返回 nil，不触发任何其他 Provider。
    func text(_ prompt: String, timeout: TimeInterval = 100) -> String? {
        let process = makeProcess(tier: .light, arguments: [
            "--tools", "", "--no-session-persistence", "-p", prompt
        ])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.4) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
