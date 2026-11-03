import Foundation

/// User-entered code references stay independent from CLI-reported Git worktrees and branches.
enum DemandRepositoryEntries {
    static func parse(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.components(separatedBy: CharacterSet(charactersIn: "\n\r;；"))
            .map { $0.trimmed }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// An unfinished form is stored separately from saved demands and never synced.
final class NewDemandDraftStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/dboard-new-demand-draft.json")
    private let url: URL
    private var unreadable = false
    private(set) var draft: DItemDraft?
    private(set) var error: String?

    private struct File: Codable {
        let version: Int
        let draft: DItemDraft
    }

    init(url: URL = NewDemandDraftStore.defaultURL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            guard file.version == 1,
                  file.draft.id.range(of: #"^D[0-9]{3,}$"#, options: .regularExpression) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            draft = file.draft
        } catch {
            unreadable = true
            self.error = "草稿无法读取，原文件已保留；请先检查本机草稿文件。"
        }
    }

    @discardableResult
    func save(_ value: DItemDraft) -> Bool {
        guard !unreadable else { return false }
        // Incomplete fields must also persist: validation belongs to demand creation.
        guard value.hasUserInput else { return clear() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try encoder.encode(File(version: 1, draft: value)).write(to: url, options: .atomic)
            draft = value
            error = nil
            return true
        } catch {
            self.error = "草稿自动保存失败，输入仍保留在当前面板；请先复制备份。"
            return false
        }
    }

    @discardableResult
    func clear() -> Bool {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            draft = nil
            unreadable = false
            error = nil
            return true
        } catch {
            self.error = "草稿清除失败，原草稿仍保留。"
            return false
        }
    }
}

extension DBoardViewModel {
    func beginNewItemDraft() {
        NotificationCenter.default.post(name: .init("DBoardEditorWillOpen"), object: nil)
        let nextID = DItemStore.nextID()
        var value = newItemDraft ?? DItemDraft(newID: nextID, priority: .p1)
        // A long-lived draft doesn't reserve an ID while other demands are created.
        value.id = nextID
        newItemDraft = value
        newItemFormOpen = true
        updateNewItemDraft(value)
    }

    func updateNewItemDraft(_ value: DItemDraft) {
        // Disappearing forms must not resurrect a draft after successful creation or explicit clearing.
        guard newItemDraft?.id == value.id else { return }
        newItemDraft = value
        if let store = newItemDraftStore {
            _ = store.save(value)
            newItemDraftError = store.error
        }
    }

    func finishNewItemDraft() {
        if let store = newItemDraftStore, !store.clear() {
            newItemDraftError = "需求已创建，但草稿清除失败；请勿重复创建。"
        } else { newItemDraftError = nil }
        newItemFormOpen = false
        newItemDraft = nil
    }

    func clearNewItemDraft() {
        if let store = newItemDraftStore, !store.clear() {
            newItemDraftError = store.error
            return
        }
        newItemDraftError = nil
        newItemFormOpen = false
        newItemDraft = nil
    }
}
