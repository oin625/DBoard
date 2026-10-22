import Foundation
import Security

/// DBoard 的统一 AI 执行入口。
/// 默认只调用国内版 qodercli；调用失败直接返回错误，绝不自动回退到 Codex。
struct DBoardAIProvider {
    struct Config: Codable {
        var command: String = NSHomeDirectory() + "/.local/bin/qoderclicn"
        var lightModel: String = "Qwen3.7-Flash"
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

/// 日志分析专用的公司 OpenAI-compatible 客户端。Token 只从 macOS 钥匙串读取。
struct DBoardLogAIClient {
    static let shared = DBoardLogAIClient()
    static let keychainService = "com.zz.dboard.tmyc-api"
    static let keychainAccount = NSUserName()

    private let endpoint = URL(
        string: "https://prod-i0-tokenproxy.tmallyc-inc.net/compatible-mode/v1/chat/completions"
    )!
    // 日志面板强调即时反馈；同代 flash 模型在公司网关下显著更快，也更不易触发 504。
    private let model = "qwen3.8-flash"

    enum ClientError: LocalizedError {
        case missingToken
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingToken: return "未在 macOS 钥匙串中找到 AI Token"
            case .invalidResponse: return "AI 服务返回格式异常"
            case .server(let message): return message
            }
        }
    }

    func text(_ prompt: String, timeout: TimeInterval = 18) -> Result<String, ClientError> {
        guard let token = loadToken() else { return .failure(.missingToken) }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 700,
            "messages": [
                ["role": "system", "content": "你是严谨、简洁的生产日志助手，只依据给出的日志作答，不强行把普通日志解释成故障。"],
                ["role": "user", "content": prompt]
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure(.invalidResponse)
        }
        request.httpBody = bodyData

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, ClientError> = .failure(.invalidResponse)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = .failure(.server(error.localizedDescription))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = .failure(.invalidResponse)
                return
            }
            guard (200...299).contains(http.statusCode), let data else {
                if http.statusCode == 504 {
                    result = .failure(.server("AI 服务响应超时，已停止等待"))
                } else {
                    result = .failure(.server("AI 服务暂时不可用（HTTP \(http.statusCode)）"))
                }
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                result = .failure(.invalidResponse)
                return
            }
            let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
            result = value.isEmpty ? .failure(.invalidResponse) : .success(value)
        }
        task.resume()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            return .failure(.server("18 秒内没有返回，已停止等待"))
        }
        return result
    }

    private func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return nil }
        return value
    }
}
