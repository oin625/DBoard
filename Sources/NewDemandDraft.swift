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
                  file.draft.id.range(of: #"^[DP][0-9]{3,}$"#, options: .regularExpression) != nil else {
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
    func beginNewItemDraft(kind: DemandKind? = nil, centerIn: NSRect? = nil) {
        newDemandWindowCenterRect = centerIn
        if newItemFormOpen {
            newDemandWindowPresenter?(self)
            return
        }
        var value = newItemDraft ?? DItemDraft(newID: "", priority: .p1)
        if let kind, !value.hasUserInput {
            value.kind = kind
            if kind == .incident { value.priority = .p0; value.status = .inProgress }
        }
        // A long-lived draft does not reserve an ID while other tasks are created.
        value.id = DItemStore.nextID(kind: value.effectiveKind)
        newItemDraft = value
        newItemFormInWindow = newDemandWindowPresenter != nil
        if !newItemFormInWindow {
            NotificationCenter.default.post(name: .init("DBoardEditorWillOpen"), object: nil)
        }
        newItemFormOpen = true
        updateNewItemDraft(value)
        newDemandWindowPresenter?(self)
    }

    func updateNewItemDraft(_ value: DItemDraft, previousID: String? = nil) {
        // Only the current editor can switch ID namespaces; late callbacks cannot resurrect a draft.
        guard newItemDraft != nil, newItemDraft?.id == (previousID ?? value.id) else { return }
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
        newItemFormInWindow = false
        newItemDraft = nil
    }

    func clearNewItemDraft() {
        if let store = newItemDraftStore, !store.clear() {
            newItemDraftError = store.error
            return
        }
        newItemDraftError = nil
        newItemFormOpen = false
        newItemFormInWindow = false
        newItemDraft = nil
    }
}
