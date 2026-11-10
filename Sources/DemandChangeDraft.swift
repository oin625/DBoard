import Foundation
import Combine

/// An unsubmitted change belongs to one demand and never enters its formal AI context.
final class DemandChangeDraftStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/dboard-change-drafts.json")

    struct Draft: Codable, Equatable {
        let intent: String
        let originalChangeIDs: [String]
    }

    private struct File: Codable {
        let version: Int
        let drafts: [String: Draft]
    }

    private let url: URL?
    private var unreadable = false
    private(set) var drafts: [String: Draft] = [:]
    private(set) var error: String?

    init(url: URL? = DemandChangeDraftStore.defaultURL) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard file.version == 1,
                  file.drafts.keys.allSatisfy({ $0.range(of: #"^[DP][0-9]{3,}$"#, options: .regularExpression) != nil }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            drafts = file.drafts
        } catch {
            unreadable = true
            self.error = "变更草稿无法读取，原文件已保留；请先检查本机草稿文件。"
        }
    }

    @discardableResult
    func save(_ draft: Draft, for id: String) -> Bool {
        // A disk failure must not lose input when reopening within the same app.
        drafts[id] = draft
        return persist(drafts)
    }

    @discardableResult
    func remove(for id: String) -> Bool {
        guard drafts[id] != nil else { return true }
        var updated = drafts
        updated.removeValue(forKey: id)
        guard persist(updated) else { return false }
        drafts = updated
        return true
    }

    private func persist(_ values: [String: Draft]) -> Bool {
        guard !unreadable else { return false }
        guard let url else { error = nil; return true }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try encoder.encode(File(version: 1, drafts: values)).write(to: url, options: .atomic)
            error = nil
            return true
        } catch {
            self.error = "变更草稿保存失败，输入仍保留在当前 D板；请先复制备份。"
            return false
        }
    }
}

final class DemandChangeDraftSession: ObservableObject {
    let id: String
    @Published private(set) var intent: String
    @Published private(set) var restored: Bool
    @Published private(set) var error: String?
    @Published private(set) var generation = UUID()
    private let store: DemandChangeDraftStore
    private var originalChangeIDs: [String]
    private var finished = false

    init(id: String, changes: [DemandChange], store: DemandChangeDraftStore) {
        self.id = id
        self.store = store
        if let draft = store.drafts[id] {
            intent = draft.intent
            originalChangeIDs = draft.originalChangeIDs
            restored = true
        } else {
            intent = ""
            originalChangeIDs = changes.map(\.id)
            restored = false
        }
        error = store.error
        reconcile(with: changes)
    }

    /// The generation prevents callbacks from a submitted/discarded editor resurrecting its input.
    func updateIntent(_ text: String, generation: UUID) {
        guard !finished, generation == self.generation else { return }
        intent = text
        preserve()
    }

    @discardableResult
    func preserve() -> Bool {
        guard !finished else { return true }
        let saved = intent.isEmpty
            ? store.remove(for: id)
            : store.save(.init(intent: intent, originalChangeIDs: originalChangeIDs), for: id)
        error = store.error
        return saved
    }

    /// If formal append succeeded just before the app quit, do not restore it as another change.
    func reconcile(with changes: [DemandChange]) {
        guard !finished else { return }
        if intent.isEmpty {
            originalChangeIDs = changes.map(\.id)
        } else if changes.contains(where: { !originalChangeIDs.contains($0.id) && $0.intent == intent }) {
            reset(after: changes.map(\.id))
        }
    }

    @discardableResult
    func markAdded(_ change: DemandChange) -> Bool {
        reset(after: originalChangeIDs + [change.id])
    }

    @discardableResult
    private func reset(after ids: [String]) -> Bool {
        let cleaned = store.remove(for: id)
        originalChangeIDs = ids
        generation = UUID()
        intent = ""
        restored = false
        error = store.error
        return cleaned
    }

    @discardableResult
    func discard() -> Bool {
        guard store.remove(for: id) else { error = store.error; return false }
        finished = true
        generation = UUID()
        error = store.error
        return true
    }
}
