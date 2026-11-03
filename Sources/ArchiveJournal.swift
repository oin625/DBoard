import Foundation

/// 在远端追加前持久记录快照。结果未知不自动重发；已上传仅重试本地移除。
final class ArchiveJournal {
    struct Entry: Codable {
        enum State: String, Codable { case submitted, uploaded, removed }
        let id: String
        let original: [String]
        let archived: [String]
        var state: State
        let createdAt: Date
    }
    private let url: URL
    private(set) var entries: [String: Entry] = [:]
    private(set) var readable = true

    init(url: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/dboard-archive-journal.json")) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do { entries = try JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: url)) }
            catch { readable = false }
        }
    }

    @discardableResult
    func save(_ entry: Entry) -> Bool {
        guard readable else { return false }
        var updated = entries
        updated[entry.id] = entry
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            entries = updated
            return true
        } catch { return false }
    }
}
