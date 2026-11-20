import Foundation
import Combine

/// Shared with dboard-ai. Missing or unreadable settings always disable chat access.
final class DemandChatPrivacy: ObservableObject {
    static let shared = DemandChatPrivacy()
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/dboard/privacy.json")
    }
    static var isEnabled: Bool { readEnabled(at: settingsURL) }

    private struct Settings: Codable {
        var demand_chat_enabled: Bool
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var error: String?
    private let url: URL

    init(url: URL = DemandChatPrivacy.settingsURL) {
        self.url = url
        enabled = Self.readEnabled(at: url)
    }

    static func readEnabled(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return false }
        return settings.demand_chat_enabled
    }

    func setEnabled(_ value: Bool) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Settings(demand_chat_enabled: value))
            try data.write(to: url, options: .atomic)
            enabled = value
            error = nil
        } catch {
            self.error = "隐私设置未保存，请重试。"
        }
    }
}
