import Foundation
import Combine

/// Unpublished prompt edits are scoped to their demand and kept separate from AI-visible context.
final class DemandPromptDraftStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/dboard-prompt-drafts.json")

    struct Draft: Codable, Equatable {
        let originalPrompt: String
        let sections: DemandPromptSections
    }

    private struct File: Codable {
        let version: Int
        let drafts: [String: Draft]
    }

    private let url: URL?
    private var unreadable = false
    private(set) var drafts: [String: Draft] = [:]
    private(set) var error: String?

    init(url: URL? = DemandPromptDraftStore.defaultURL) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard file.version == 1,
                  file.drafts.keys.allSatisfy({ $0.range(of: #"^D[0-9]{3,}$"#, options: .regularExpression) != nil }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            drafts = file.drafts
        } catch {
            unreadable = true
            self.error = "咒言草稿无法读取，原文件已保留；请先检查本机草稿文件。"
        }
    }

    @discardableResult
    func save(_ draft: Draft, for id: String) -> Bool {
        // Keep the latest input in memory even when writing fails.
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
            self.error = "咒言草稿保存失败，输入仍保留在当前 D板；请先复制备份。"
            return false
        }
    }
}

/// Persist binding changes immediately so closing or recreating a sheet cannot lose edits.
final class DemandPromptDraftSession: ObservableObject {
    let id: String
    let originalPrompt: String
    let restored: Bool
    @Published var sections: DemandPromptSections {
        didSet { preserve() }
    }
    @Published private(set) var error: String?
    private let store: DemandPromptDraftStore
    private var finished = false

    init(id: String, prompt: String, store: DemandPromptDraftStore) {
        self.id = id
        self.store = store
        if let draft = store.drafts[id], draft.sections != DemandPromptSections(stored: prompt) {
            originalPrompt = draft.originalPrompt
            sections = draft.sections
            restored = true
        } else {
            // This also reconciles a successful save followed by interrupted draft cleanup.
            _ = store.remove(for: id)
            originalPrompt = prompt
            sections = DemandPromptSections(stored: prompt)
            restored = false
        }
        error = store.error
    }

    var changed: Bool { sections != DemandPromptSections(stored: originalPrompt) }

    @discardableResult
    func preserve() -> Bool {
        guard !finished else { return true }
        let saved = changed
            ? store.save(.init(originalPrompt: originalPrompt, sections: sections), for: id)
            : store.remove(for: id)
        error = store.error
        return saved
    }

    @discardableResult
    func discard() -> Bool {
        guard store.remove(for: id) else { error = store.error; return false }
        finished = true
        return true
    }

    @discardableResult
    func markSaved() -> Bool {
        // Late view callbacks must never resurrect a successfully saved draft.
        finished = true
        let cleaned = store.remove(for: id)
        error = store.error
        return cleaned
    }
}
