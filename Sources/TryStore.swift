import Foundation
import Combine
import Darwin

enum DBoardSpace: String, CaseIterable { case main, personal
    var title: String { self == .main ? "主 Main" : "次 Try" }
}
enum TryKind: String, Codable, CaseIterable, Identifiable {
    case idea, task, digestion
    static let workspaceKinds: [TryKind] = [.digestion, .idea]
    var id: String { rawValue }
    var title: String { switch self { case .idea: return "想法"; case .task: return "任务"; case .digestion: return "学习" } }
    var placeholder: String {
        switch self {
        case .idea: return "一个念头、一张图，或者一个还没想明白的问题…"
        case .task: return "这次想做什么？写下目标，就可以交给 AI 继续。"
        case .digestion: return "想学什么？写下第一篇笔记、一个疑问，或贴入参考资料…"
        }
    }
    var aiAction: String { switch self { case .idea: return "继续讨论"; case .task: return "继续执行"; case .digestion: return "帮我弄懂" } }
    var doneTitle: String { switch self { case .idea: return "该想法告一段落了～"; case .task: return "确认完成"; case .digestion: return "本轮消化完成" } }
}
enum TryStatus: String, Codable { case active, done, shelved }

struct TryAddition: Codable, Equatable, Identifiable {
    var id: String
    var body: String
    var createdAt: Double
    var revision = 1
    var completedAt: Double? = nil
    var completionSummary: String? = nil
    var withdrawnAt: Double? = nil
    var pending: Bool { completedAt == nil && withdrawnAt == nil }
    var preview: String {
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.hasPrefix("![") ? "图片附件" : first
    }
}
struct TryAdditionDraft: Codable, Equatable {
    var body = ""
    var editingID: String? = nil
    var expectedRevision: Int? = nil
    var bookmark: TryBookmark? = nil
    var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

struct TryReport: Codable, Equatable, Identifiable {
    var id: String
    var at: Double
    var summary: String
    var details: String
    var fingerprint: String? = nil
}
struct TryConversion: Codable, Equatable {
    var from: TryKind
    var to: TryKind
    var at: Double
}
struct TryLearningNote: Codable, Equatable, Identifiable {
    var id: String
    var title = ""
    var body: String
    var createdAt: Double
    var updatedAt: Double
    var bookmark: TryBookmark? = nil
    var deletedAt: Double? = nil
    var learningStageID: String? = nil
    var topicIDs: [String]? = nil
    var unitIDs: [String]? = nil
    var origin: String? = nil
    var sourceNotes: [TryLearningNoteSnapshot]? = nil
    var contentUpdatedAt: Double? = nil
    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return first.hasPrefix("![") ? "图片笔记" : (first.isEmpty ? "未命名笔记" : String(TryNoteMarkup.plainLabel(first).prefix(40)))
    }
}
struct TryLearningNoteDraft: Codable, Equatable {
    var learningStageID: String? = nil
    var topicIDs: [String]? = nil
    var unitIDs: [String]? = nil
    var title = ""
    var body = ""
    var bookmark: TryBookmark? = nil
    var isEmpty: Bool { [title, body].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}
struct TryLearningOutcome: Codable, Equatable, Identifiable {
    var id: String
    var text: String
    var noteID: String? = nil
    var reference = ""
}
struct TryLearningSuggestion: Codable, Equatable {
    var configRevision: Int? = nil
    var planID: String? = nil
    var stageID: String? = nil
    var progress: String? = nil
    var nextStep: String? = nil
    var outcomes: [TryLearningOutcome] = []
}

struct TryEntry: Codable, Equatable, Identifiable {
    var id: String
    var kind: TryKind
    var title = ""
    var body = ""
    var projectID: String? = nil
    var relatedIDs: [String] = []
    var status: TryStatus = .active
    var progress = ""
    var nextStep = ""
    var aiSummary = ""
    var aiResult = ""
    var reports: [TryReport] = []
    var conversions: [TryConversion] = []
    var createdAt: Double
    var updatedAt: Double
    var revision = 1
    var deletedAt: Double? = nil
    var additions: [TryAddition]? = nil
    var notes: [TryLearningNote]? = nil
    var outcomes: [TryLearningOutcome]? = nil
    var learningNoteDraft: TryLearningNoteDraft? = nil
    var selectedLearningNoteID: String? = nil
    var learningSources: String? = nil
    var learningSuggestion: TryLearningSuggestion? = nil
    var learningConfig: TryLearningConfig? = nil
    var learningConfigDraft: TryLearningConfig? = nil
    var learningPlan: TryLearningPlan? = nil
    var learningPlanProposal: TryLearningPlan? = nil
    var learningPlanFeedback: String? = nil
    var currentLearningStageID: String? = nil
    var learningStageChecks: [TryLearningStageCheck]? = nil
    var learningCheckHistory: [TryLearningStageCheck]? = nil
    var learningPreferences: TryLearningPreferences? = nil
    var learningTopics: [TryLearningTopic]? = nil
    var learningUnits: [TryLearningUnit]? = nil
    var currentLearningUnitID: String? = nil
    var learningOrganizations: [TryLearningOrganization]? = nil
    var learningFeedback: [TryLearningFeedback]? = nil
    var learningLesson: TryLearningLesson? = nil
    var learningLessons: [TryLearningLesson]? = nil
    var learningReview: String? = nil
    var learningReviewConfigRevision: Int? = nil
    var learningReviewPlanID: String? = nil
    var learningReviewEvidenceVersions: [String: Double]? = nil
    var learningFinishedAt: Double? = nil
    var learningGoalReached: Bool? = nil
    var learningNotes: [TryLearningNote] {
        // Old learning records become readable notes without rewriting their original text.
        if let notes { return notes.filter { $0.deletedAt == nil } }
        guard kind == .digestion, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [TryLearningNote(id: "N001", body: body, createdAt: createdAt, updatedAt: updatedAt)]
    }
    var learningOutcomes: [TryLearningOutcome] { outcomes ?? [] }
    var learningDraft: TryLearningNoteDraft { learningNoteDraft ?? TryLearningNoteDraft() }
    var learningPreview: String {
        if !learningOutcomes.isEmpty { return learningOutcomes.prefix(2).map(\.text).joined(separator: "；") }
        return learningNotes.last?.body ?? body
    }
    var ideaSupplements: [TryAddition] { kind == .idea ? (additions ?? []).filter { $0.withdrawnAt == nil } : [] }
    var pendingAdditions: [TryAddition] { kind == .idea ? [] : (additions ?? []).filter(\.pending) }

    var displayTitle: String {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
        let first = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if first.hasPrefix("![") { return "图片" + kind.title }
        if first.isEmpty, let note = learningNotes.first { return note.displayTitle }
        return first.isEmpty ? "未命名" + kind.title : String(first.prefix(40))
    }
    var statusTitle: String {
        if status == .shelved { return "已搁置" }
        if status == .active { return "进行中" }
        return kind == .task ? "已完成" : (kind == .digestion ? "本轮已完成" : "已告一段落")
    }
    var isEmpty: Bool {
        [title, body, progress, nextStep, aiSummary, aiResult].allSatisfy {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } && reports.isEmpty && conversions.isEmpty && relatedIDs.isEmpty && (additions ?? []).isEmpty && learningNotes.isEmpty && learningOutcomes.isEmpty && learningDraft.isEmpty
    }
}
struct TryProject: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var context: String
    var createdAt: Double
    var revision = 1
}
struct TryBookmark: Codable, Equatable {
    var location: Int
    var length: Int
    var scrollY: Double
}
struct TryCaptureDraft: Codable, Equatable {
    var learningConfig: TryLearningConfig? = nil
    var body = ""
    var title = ""
    var projectID: String? = nil
    var relatedID: String? = nil
    var bookmark: TryBookmark? = nil
    var isEmpty: Bool { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (learningConfig?.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
}

struct TryDocument: Codable, Equatable {
    var version = 1
    var entries: [TryEntry] = []
    var projects: [TryProject] = []
    var bookmarks: [String: TryBookmark] = [:]
    var captureDrafts: [String: TryCaptureDraft]? = nil
    var lastEntryNumber: Int? = nil
    var additionDrafts: [String: TryAdditionDraft]? = nil
}

/// Personal data has its own atomic file and lock; it never enters the DingTalk demand cache.
enum TryDisk {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/dboard-try.json")
    enum Failure: LocalizedError {
        case unsupported, unreadable, lock, missing, invalid, unfinished, changedAddition
        var errorDescription: String? {
            switch self {
            case .unsupported: return "个人空间数据版本暂不支持，原文件已保留"
            case .unreadable: return "个人空间数据无法读取，原文件已保留"
            case .lock: return "个人空间正被更新，请稍后重试"
            case .missing: return "这条记录不存在，请刷新后重试"
            case .invalid: return "内容格式不正确，未修改原数据"
            case .unfinished: return "还有追加内容待处理，请先逐项确认。"
            case .changedAddition: return "这次追加已变化，请重新核对；编辑草稿仍保留。"
            }
        }
    }
    static func read(_ url: URL) throws -> TryDocument {
        guard FileManager.default.fileExists(atPath: url.path) else { return TryDocument() }
        let value: TryDocument
        do { value = try JSONDecoder().decode(TryDocument.self, from: Data(contentsOf: url)) }
        catch { throw Failure.unreadable }
        guard value.version == 1 else { throw Failure.unsupported }
        guard Set(value.entries.map(\.id)).count == value.entries.count,
              Set(value.projects.map(\.id)).count == value.projects.count,
              value.entries.allSatisfy({ $0.revision > 0 }),
              value.lastEntryNumber == nil || value.lastEntryNumber! >= 0,
              value.entries.allSatisfy({ item in
                  let notes = item.notes ?? []
                  let outcomes = item.outcomes ?? []
                  return Set(notes.map(\.id)).count == notes.count &&
                      Set(outcomes.map(\.id)).count == outcomes.count &&
                      outcomes.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }),
              value.entries.allSatisfy({ item in
                  let additions = item.additions ?? []
                  return Set(additions.map(\.id)).count == additions.count &&
                      additions.allSatisfy { $0.revision > 0 && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
              }) else { throw Failure.invalid }
        return value
    }
    @discardableResult
    static func change(_ url: URL, _ action: (inout TryDocument) throws -> Void) throws -> TryDocument {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw Failure.lock }
        defer { close(fd) }
        // Avoid hanging the typing thread if another client is in the middle of a write.
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.lock }
        defer { flock(fd, LOCK_UN) }
        var document = try read(url)
        try action(&document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return document
    }
    static func reserveEntryNumbers(_ document: inout TryDocument) {
        let maximum = document.entries.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        document.lastEntryNumber = max(document.lastEntryNumber ?? 0, maximum)
    }
    static func allocateEntryID(_ document: inout TryDocument) -> String {
        reserveEntryNumbers(&document)
        document.lastEntryNumber = (document.lastEntryNumber ?? 0) + 1
        return "T" + String(format: "%03d", document.lastEntryNumber!)
    }
    static func nextID(prefix: String, ids: [String]) -> String {
        let maximum = ids.compactMap { id -> Int? in
            guard id.hasPrefix(prefix) else { return nil }
            return Int(id.dropFirst(prefix.count))
        }.max() ?? 0
        return prefix + String(format: "%03d", maximum + 1)
    }
}

final class TryStore: ObservableObject {
    static let shared = TryStore()
    let url: URL
    @Published private(set) var document = TryDocument()
    @Published private(set) var error: String?
    @Published private(set) var saving = false
    @Published var selectedID: String?
    var bookmarks: [String: TryBookmark] { document.bookmarks }
    private var pending: [String: [String: String]] = [:]
    private var pendingCaptures: [String: TryCaptureDraft] = [:]
    private var pendingAdditionDrafts: [String: TryAdditionDraft] = [:]
    @Published private(set) var additionGenerations: [String: Int] = [:]
    @Published private(set) var captureGenerations: [String: Int] = [:]
    @Published private(set) var learningGenerations: [String: Int] = [:]
    private var saveWork: DispatchWorkItem?
    private var observer: FileRefreshObserver?
    private var tokens: [NSObjectProtocol] = []
    init(url: URL = TryDisk.defaultURL, watching: Bool = true) {
        self.url = url
        reload()
        if watching {
            observer = FileRefreshObserver(url: url, interval: 5) { [weak self] in self?.reload() }
            for name in [Notification.Name("DBoardFlushPersonalDrafts"), Notification.Name("NSApplicationWillTerminateNotification")] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in _ = self?.flush() })
            }
        }
    }
    deinit {
        saveWork?.cancel()
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
    func entry(_ id: String) -> TryEntry? { document.entries.first { $0.id == id && $0.deletedAt == nil } }
    var trashed: [TryEntry] { document.entries.filter { $0.deletedAt != nil }.sorted { ($0.deletedAt ?? 0) > ($1.deletedAt ?? 0) } }
    var emptyEntries: [TryEntry] { document.entries.filter { $0.deletedAt == nil && $0.isEmpty } }
    var selected: TryEntry? { selectedID.flatMap(entry) }
    func reload() {
        do {
            var fresh = try TryDisk.read(url)
            for (id, fields) in pending {
                if let index = fresh.entries.firstIndex(where: { $0.id == id }) {
                    for (field, value) in fields { Self.assign(field, value: value, entry: &fresh.entries[index]) }
                } else if let index = fresh.projects.firstIndex(where: { $0.id == id }) {
                    if let name = fields["name"] { fresh.projects[index].name = name }
                    if let context = fields["context"] { fresh.projects[index].context = context }
                }
            }
            for (key, draft) in pendingCaptures {
                if fresh.captureDrafts == nil { fresh.captureDrafts = [:] }
                fresh.captureDrafts?[key] = draft
            }
            for (key, draft) in pendingAdditionDrafts {
                if fresh.additionDrafts == nil { fresh.additionDrafts = [:] }
                fresh.additionDrafts?[key] = draft
            }
            if fresh != document { document = fresh }
            if selectedID != nil && selected == nil { selectedID = nil }
            if pending.isEmpty && pendingCaptures.isEmpty && pendingAdditionDrafts.isEmpty { error = nil }
        } catch { self.error = error.localizedDescription }
    }
    private static func assign(_ field: String, value: String, entry: inout TryEntry) {
        switch field {
        case "title": entry.title = value
        case "body": entry.body = value
        case "progress": entry.progress = value
        case "nextStep": entry.nextStep = value
        case "learningSources": entry.learningSources = value
        case "learningPlanFeedback": entry.learningPlanFeedback = value
        case "learningConfigDraft": entry.learningConfigDraft = value.data(using: .utf8).flatMap { try? JSONDecoder().decode(TryLearningConfig.self, from: $0) }
        case "selectedLearningNoteID": entry.selectedLearningNoteID = value.isEmpty ? nil : value
        default:
            if field.hasPrefix("noteDraft.") {
                var draft = entry.learningDraft
                switch field.dropFirst(10) {
                case "body": draft.body = value
                case "title": draft.title = value
                case "learningStageID": draft.learningStageID = value.isEmpty ? nil : value
                case "bookmark": draft.bookmark = value.data(using: .utf8).flatMap { try? JSONDecoder().decode(TryBookmark.self, from: $0) }
                default: return
                }
                entry.learningNoteDraft = draft
            } else if field.hasPrefix("note.") {
                let parts = field.split(separator: ".", maxSplits: 2).map(String.init)
                guard parts.count == 3 else { return }
                if entry.notes == nil { entry.notes = entry.learningNotes }
                guard let index = entry.notes?.firstIndex(where: { $0.id == parts[1] && $0.deletedAt == nil }) else { return }
                if entry.notes?[index].contentUpdatedAt == nil {
                    let previousVersion = entry.notes?[index].updatedAt
                    entry.notes?[index].contentUpdatedAt = previousVersion
                }
                switch parts[2] {
                case "body":
                    if entry.notes?[index].body != value {
                        entry.notes?[index].contentUpdatedAt = Date().timeIntervalSince1970
                    }
                    entry.notes?[index].body = value
                case "title": entry.notes?[index].title = value
                case "learningStageID": entry.notes?[index].learningStageID = value.isEmpty ? nil : value
                case "topicIDs": entry.notes?[index].topicIDs = value.split(separator: ",").map(String.init)
                case "unitIDs": entry.notes?[index].unitIDs = value.split(separator: ",").map(String.init)
                case "bookmark": entry.notes?[index].bookmark = value.data(using: .utf8).flatMap { try? JSONDecoder().decode(TryBookmark.self, from: $0) }
                default: return
                }
                if parts[2] != "bookmark" { entry.notes?[index].updatedAt = Date().timeIntervalSince1970 }
            }

        }
    }
    func edit(_ id: String, field: String, value: String) {
        guard let index = document.entries.firstIndex(where: { $0.id == id }) else { return }
        pending[id, default: [:]][field] = value
        Self.assign(field, value: value, entry: &document.entries[index])
        saving = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    func editProject(_ id: String, field: String, value: String) {
        guard let index = document.projects.firstIndex(where: { $0.id == id }) else { return }
        pending[id, default: [:]][field] = value
        if field == "name" { document.projects[index].name = value }
        if field == "context" { document.projects[index].context = value }
        saving = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    @discardableResult
    func flush() -> Bool {
        saveWork?.cancel()
        guard !pending.isEmpty || !pendingCaptures.isEmpty || !pendingAdditionDrafts.isEmpty else {
            // A rejected action must not block the next valid action indefinitely.
            reload()
            return error == nil
        }
        let patch = pending
        let capturePatch = pendingCaptures
        let additionPatch = pendingAdditionDrafts
        do {
            document = try TryDisk.change(url) { value in
                if !capturePatch.isEmpty {
                    if value.captureDrafts == nil { value.captureDrafts = [:] }
                    for (key, draft) in capturePatch { value.captureDrafts?[key] = draft }
                }
                if !additionPatch.isEmpty {
                    if value.additionDrafts == nil { value.additionDrafts = [:] }
                    for (key, draft) in additionPatch {
                        guard value.entries.contains(where: { $0.id == key }) else { throw TryDisk.Failure.missing }
                        value.additionDrafts?[key] = draft
                    }
                }
                for (id, fields) in patch {
                    if let index = value.entries.firstIndex(where: { $0.id == id }) {
                        for (field, text) in fields { Self.assign(field, value: text, entry: &value.entries[index]) }
                        value.entries[index].updatedAt = Date().timeIntervalSince1970
                        value.entries[index].revision += 1
                    } else if let index = value.projects.firstIndex(where: { $0.id == id }) {
                        if let name = fields["name"] { value.projects[index].name = name }
                        if let context = fields["context"] { value.projects[index].context = context }
                        value.projects[index].revision += 1
                    } else { throw TryDisk.Failure.missing }
                }
            }
            pending = [:]; pendingCaptures = [:]; pendingAdditionDrafts = [:]; saving = false; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult
    private func transact(_ action: (inout TryDocument) throws -> Void) -> Bool {
        if !pending.isEmpty || !pendingCaptures.isEmpty || !pendingAdditionDrafts.isEmpty {
            guard flush() else { return false }
        }
        do { document = try TryDisk.change(url, action); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    @discardableResult
    func create(_ kind: TryKind, projectID: String? = nil, relatedID: String? = nil, selectCreated: Bool = true) -> String? {
        var id: String?
        guard transact({ document in
            guard projectID == nil || document.projects.contains(where: { $0.id == projectID }) else { throw TryDisk.Failure.missing }
            let next = TryDisk.allocateEntryID(&document)
            let now = Date().timeIntervalSince1970
            var entry = TryEntry(id: next, kind: kind, createdAt: now, updatedAt: now)
            entry.projectID = projectID
            if let relatedID, document.entries.contains(where: { $0.id == relatedID }) {
                entry.relatedIDs = [relatedID]
                if let index = document.entries.firstIndex(where: { $0.id == relatedID }) {
                    document.entries[index].relatedIDs.append(next)
                    document.entries[index].revision += 1
                }
            }
            document.entries.append(entry); id = next
        }) else { return nil }
        if selectCreated { selectedID = id }
        return id
    }
    func capture(_ kind: TryKind) -> TryCaptureDraft { document.captureDrafts?[kind.rawValue] ?? TryCaptureDraft() }
    func captureGeneration(_ kind: TryKind) -> Int { captureGenerations[kind.rawValue] ?? 0 }
    func editCapture(_ kind: TryKind, field: String, value: String, generation: Int) {
        guard generation == captureGeneration(kind) else { return }
        var draft = capture(kind)
        if field == "body" { draft.body = value }
        else if field == "title" { draft.title = value }
        else if field == "learningConfig" { draft.learningConfig = value.data(using: .utf8).flatMap { try? JSONDecoder().decode(TryLearningConfig.self, from: $0) } }
        else { return }
        saveCapture(kind, draft: draft)
    }
    func prepareCapture(_ kind: TryKind, projectID: String? = nil, relatedID: String? = nil) {
        var draft = capture(kind)
        if let projectID { draft.projectID = projectID }
        if let relatedID { draft.relatedID = relatedID }
        if draft != capture(kind) { saveCapture(kind, draft: draft) }
    }
    func setCaptureProject(_ kind: TryKind, projectID: String?) {
        guard projectID == nil || document.projects.contains(where: { $0.id == projectID }) else { return }
        var draft = capture(kind); draft.projectID = projectID
        saveCapture(kind, draft: draft)
    }
    func rememberCapture(_ kind: TryKind, bookmark: TryBookmark, generation: Int) {
        guard generation == captureGeneration(kind) else { return }
        var draft = capture(kind)
        guard draft.bookmark != bookmark else { return }
        draft.bookmark = bookmark
        saveCapture(kind, draft: draft)
    }
    private func saveCapture(_ kind: TryKind, draft: TryCaptureDraft) {
        pendingCaptures[kind.rawValue] = draft
        if document.captureDrafts == nil { document.captureDrafts = [:] }
        document.captureDrafts?[kind.rawValue] = draft
        saving = true; saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    @discardableResult
    func submitCapture(_ kind: TryKind, selectCreated: Bool = false) -> String? {
        guard !capture(kind).isEmpty else { return nil }
        var result: String?
        guard transact({ document in
            guard let draft = document.captureDrafts?[kind.rawValue], !draft.isEmpty else { throw TryDisk.Failure.invalid }
            guard draft.projectID == nil || document.projects.contains(where: { $0.id == draft.projectID }) else { throw TryDisk.Failure.missing }
            guard draft.relatedID == nil || document.entries.contains(where: { $0.id == draft.relatedID && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            let id = TryDisk.allocateEntryID(&document)
            let now = Date().timeIntervalSince1970
            var entry = TryEntry(id: id, kind: kind, createdAt: now, updatedAt: now)
            entry.body = draft.body; entry.title = draft.title; entry.projectID = draft.projectID
            if kind == .digestion {
                entry.title = draft.title.isEmpty ? entry.displayTitle : draft.title
                entry.notes = draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] :
                    [TryLearningNote(id: "N001", body: draft.body, createdAt: now, updatedAt: now, bookmark: draft.bookmark)]
                entry.selectedLearningNoteID = entry.notes?.first?.id
                entry.body = ""
                entry.projectID = nil
                if var config = draft.learningConfig, config.valid {
                    config.revision = 1; entry.learningConfig = config
                    if draft.title.isEmpty { entry.title = String(config.goal.prefix(60)) }
                }
            }
            if let relatedID = draft.relatedID,
               let index = document.entries.firstIndex(where: { $0.id == relatedID && $0.deletedAt == nil }) {
                entry.relatedIDs = [relatedID]
                document.entries[index].relatedIDs.append(id)
                document.entries[index].revision += 1
            }
            document.entries.append(entry)
            if let bookmark = draft.bookmark { document.bookmarks[id] = bookmark }
            document.captureDrafts?.removeValue(forKey: kind.rawValue)
            result = id
        }) else { return nil }
        captureGenerations[kind.rawValue, default: 0] += 1
        if selectCreated { selectedID = result }
        return result
    }
    @discardableResult
    func clearCapture(_ kind: TryKind) -> Bool {
        guard transact({ $0.captureDrafts?.removeValue(forKey: kind.rawValue) }) else { return false }
        captureGenerations[kind.rawValue, default: 0] += 1
        return true
    }
    func additionDraft(_ id: String) -> TryAdditionDraft { document.additionDrafts?[id] ?? TryAdditionDraft() }
    func additionGeneration(_ id: String) -> Int { additionGenerations[id] ?? 0 }

    @discardableResult
    func prepareAddition(_ id: String, editing additionID: String) -> Bool {
        guard let item = entry(id),
              let addition = item.additions?.first(where: { $0.id == additionID && $0.withdrawnAt == nil }) else { return false }
        let old = additionDraft(id)
        if !old.isEmpty {
            if old.editingID == additionID { return true }
            error = "还有未保存的追加草稿，请先保存或清空。"
            return false
        }
        saveAdditionDraft(id, draft: TryAdditionDraft(body: addition.body, editingID: additionID, expectedRevision: addition.revision))
        return true
    }
    func editAdditionDraft(_ id: String, body: String, generation: Int) {
        guard generation == additionGeneration(id), entry(id) != nil else { return }
        var draft = additionDraft(id); draft.body = body
        saveAdditionDraft(id, draft: draft)
    }
    func rememberAddition(_ id: String, bookmark: TryBookmark, generation: Int) {
        guard generation == additionGeneration(id), entry(id) != nil else { return }
        var draft = additionDraft(id)
        guard draft.bookmark != bookmark else { return }
        draft.bookmark = bookmark
        saveAdditionDraft(id, draft: draft)
    }
    private func saveAdditionDraft(_ id: String, draft: TryAdditionDraft) {
        pendingAdditionDrafts[id] = draft
        if document.additionDrafts == nil { document.additionDrafts = [:] }
        document.additionDrafts?[id] = draft
        saving = true; saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.flush() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    @discardableResult
    func clearAdditionDraft(_ id: String) -> Bool {
        guard transact({ $0.additionDrafts?.removeValue(forKey: id) }) else { return false }
        additionGenerations[id, default: 0] += 1
        return true
    }
    /// Saving an addition is the user's explicit instruction to continue a completed/shelved task.
    @discardableResult
    func submitAddition(_ id: String) -> String? {
        guard !additionDraft(id).isEmpty else { return nil }
        var result: String?
        guard transact({ document in
            guard let index = document.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
                  let draft = document.additionDrafts?[id], !draft.isEmpty else { throw TryDisk.Failure.missing }
            var additions = document.entries[index].additions ?? []
            let now = Date().timeIntervalSince1970
            if let editingID = draft.editingID {
                guard let row = additions.firstIndex(where: { $0.id == editingID && $0.withdrawnAt == nil }),
                      additions[row].revision == draft.expectedRevision else { throw TryDisk.Failure.changedAddition }
                additions[row].body = draft.body
                additions[row].revision += 1
                additions[row].completedAt = nil
                additions[row].completionSummary = nil
                result = editingID
            } else {
                let next = TryDisk.nextID(prefix: "A", ids: additions.map(\.id))
                additions.append(TryAddition(id: next, body: draft.body, createdAt: now))
                result = next
            }
            document.entries[index].additions = additions
            document.entries[index].status = .active
            document.entries[index].updatedAt = now
            document.entries[index].revision += 1
            document.additionDrafts?.removeValue(forKey: id)
        }) else { return nil }
        additionGenerations[id, default: 0] += 1
        return result
    }
    @discardableResult
    func markAddition(_ id: String, additionID: String, completed: Bool) -> Bool {
        update(id) { item in
            guard let row = item.additions?.firstIndex(where: { $0.id == additionID && $0.withdrawnAt == nil }) else { return }
            item.additions?[row].completedAt = completed ? Date().timeIntervalSince1970 : nil
            item.additions?[row].completionSummary = completed ? "用户确认已处理" : nil
            if !completed { item.status = .active }
        }
    }
    @discardableResult
    func withdrawAddition(_ id: String, additionID: String) -> Bool {
        update(id) { item in
            guard let row = item.additions?.firstIndex(where: { $0.id == additionID && $0.withdrawnAt == nil }) else { return }
            item.additions?[row].withdrawnAt = Date().timeIntervalSince1970
        }
    }

    @discardableResult
    func trash(_ id: String) -> Bool {
        guard update(id, { $0.deletedAt = Date().timeIntervalSince1970 }) else { return false }
        if selectedID == id { selectedID = nil }
        return true
    }
    @discardableResult
    func restore(_ id: String) -> Bool {
        transact { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { throw TryDisk.Failure.missing }
            document.entries[index].deletedAt = nil
            document.entries[index].revision += 1
            document.entries[index].updatedAt = Date().timeIntervalSince1970
        }
    }
    /// Only purge the rows the user reviewed; newly trashed or restored rows stay untouched.
    @discardableResult
    func emptyTrash(_ reviewedIDs: Set<String>) -> Int {
        var count = 0
        guard transact({ document in
            let removed = Set(document.entries.filter { $0.deletedAt != nil && reviewedIDs.contains($0.id) }.map(\.id))
            guard !removed.isEmpty else { return }
            TryDisk.reserveEntryNumbers(&document)
            document.entries.removeAll { removed.contains($0.id) }
            count = removed.count
            for id in removed {
                document.bookmarks.removeValue(forKey: id)
                document.additionDrafts?.removeValue(forKey: id)
            }
            for index in document.entries.indices {
                let old = document.entries[index].relatedIDs
                document.entries[index].relatedIDs.removeAll { removed.contains($0) }
                if old != document.entries[index].relatedIDs {
                    document.entries[index].revision += 1
                }
            }
            if let drafts = document.captureDrafts {
                for (kind, var draft) in drafts where draft.relatedID.map(removed.contains) == true {
                    draft.relatedID = nil
                    document.captureDrafts?[kind] = draft
                }
            }
            // Image files may also belong to other notes or Main demands; do not remove shared assets here.
        }) else { return 0 }
        if selectedID != nil && selected == nil { selectedID = nil }
        return count
    }
    @discardableResult
    func trashEmptyEntries() -> Int {
        var count = 0
        guard transact({ document in
            for index in document.entries.indices where document.entries[index].deletedAt == nil && document.entries[index].isEmpty {
                document.entries[index].deletedAt = Date().timeIntervalSince1970
                document.entries[index].revision += 1
                count += 1
            }
        }) else { return 0 }
        if selectedID != nil && selected == nil { selectedID = nil }
        return count
    }

    @discardableResult
    func update(_ id: String, _ action: (inout TryEntry) -> Void) -> Bool {
        transact { document in
            guard let index = document.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            action(&document.entries[index])
            document.entries[index].updatedAt = Date().timeIntervalSince1970
            document.entries[index].revision += 1
        }
    }
    func convert(_ id: String, to kind: TryKind) -> Bool {
        update(id) { entry in
            guard entry.kind != kind else { return }
            entry.conversions.append(TryConversion(from: entry.kind, to: kind, at: Date().timeIntervalSince1970))
            entry.kind = kind; entry.status = .active
        }
    }
    func status(_ id: String, _ status: TryStatus) -> Bool {
        transact { document in
            guard let row = document.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            if status == .done, document.entries[row].kind == .task, !document.entries[row].pendingAdditions.isEmpty {
                throw TryDisk.Failure.unfinished
            }
            document.entries[row].status = status
            document.entries[row].updatedAt = Date().timeIntervalSince1970
            document.entries[row].revision += 1
        }
    }
    func setProject(_ id: String, projectID: String?) -> Bool {
        guard projectID == nil || document.projects.contains(where: { $0.id == projectID }) else { return false }
        return update(id) { $0.projectID = projectID }
    }
    func adopt(_ id: String) -> Bool {
        update(id) { entry in
            guard !entry.aiResult.isEmpty else { return }
            entry.body += (entry.body.isEmpty ? "" : "\n\n") + entry.aiResult
        }
    }
    @discardableResult
    func project(name: String, context: String = "", id: String? = nil) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var result: String?
        guard transact({ document in
            if let id, let index = document.projects.firstIndex(where: { $0.id == id }) {
                document.projects[index].name = name; document.projects[index].context = context
                document.projects[index].revision += 1; result = id
            } else {
                let id = TryDisk.nextID(prefix: "TP", ids: document.projects.map(\.id))
                document.projects.append(TryProject(id: id, name: name, context: context, createdAt: Date().timeIntervalSince1970))
                result = id
            }
        }) else { return nil }
        return result
    }
    func remember(_ id: String, bookmark: TryBookmark) {
        guard document.bookmarks[id] != bookmark else { return }
        _ = transact { document in
            guard document.entries.contains(where: { $0.id == id }) || document.projects.contains(where: { $0.id == id }) else { return }
            document.bookmarks[id] = bookmark
        }
    }
    func learningGeneration(_ id: String) -> Int { learningGenerations[id] ?? 0 }
    func editLearningNote(_ id: String, noteID: String?, field: String, value: String, generation: Int) {
        guard let item = entry(id), item.kind == .digestion else { return }
        if noteID == nil, generation != learningGeneration(id) { return }
        if let noteID, !item.learningNotes.contains(where: { $0.id == noteID }) { return }
        edit(id, field: noteID.map { "note." + $0 + "." + field } ?? "noteDraft." + field, value: value)
    }
    func rememberLearningNote(_ id: String, noteID: String?, bookmark: TryBookmark, generation: Int) {
        let old = noteID.flatMap { key in entry(id)?.learningNotes.first { $0.id == key }?.bookmark } ?? (noteID == nil ? entry(id)?.learningDraft.bookmark : nil)
        guard old != bookmark, let data = try? JSONEncoder().encode(bookmark), let value = String(data: data, encoding: .utf8) else { return }
        editLearningNote(id, noteID: noteID, field: "bookmark", value: value, generation: generation)
    }
    @discardableResult
    func saveLearningNote(_ id: String) -> String? {
        guard let item = entry(id), !item.learningDraft.isEmpty else { return nil }
        var savedID: String?
        guard transact({ value in
            guard let row = value.entries.firstIndex(where: { $0.id == id && $0.kind == .digestion && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var item = value.entries[row]
            let draft = item.learningDraft
            guard !draft.isEmpty else { throw TryDisk.Failure.invalid }
            if item.notes == nil { item.notes = item.learningNotes }
            let next = TryDisk.nextID(prefix: "N", ids: (item.notes ?? []).map(\.id))
            let now = Date().timeIntervalSince1970
            item.notes?.append(TryLearningNote(id: next, title: draft.title, body: draft.body, createdAt: now, updatedAt: now, bookmark: draft.bookmark, learningStageID: draft.learningStageID, topicIDs: draft.topicIDs, unitIDs: draft.unitIDs))
            item.learningNoteDraft = nil; item.selectedLearningNoteID = next
            item.updatedAt = now; item.revision += 1
            value.entries[row] = item; savedID = next
        }) else { return nil }
        learningGenerations[id, default: 0] += 1
        return savedID
    }
    /// A page is a writing session, not a record. Blank pages never allocate an N number.
    func beginNotebookPage(_ id: String, fresh: Bool = false, suggestedTitle: String? = nil) -> TryNotebookPage? {
        guard flush(), let item = entry(id), item.kind == .digestion else { return nil }
        if fresh, !item.learningDraft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard saveLearningNote(id) != nil else { return nil }
        }
        let draft = entry(id)?.learningDraft ?? TryLearningNoteDraft()
        let resuming = !fresh && !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !resuming {
            let title = suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard update(id, {
                $0.learningNoteDraft = title.isEmpty ? nil : TryLearningNoteDraft(
                    topicIDs: item.currentLearningUnit?.topicIDs,
                    unitIDs: item.currentLearningUnit.map { [$0.id] }, title: title)
                $0.selectedLearningNoteID = "_draft"
            }) else { return nil }
            learningGenerations[id, default: 0] += 1
        }
        let page = TryNotebookPage(noteID: nil, generation: learningGeneration(id),
            stageID: resuming ? draft.learningStageID : entry(id)?.currentLearningStage?.id)
        if let stageID = page.stageID {
            editLearningNote(id, noteID: nil, field: "learningStageID", value: stageID, generation: page.generation)
        }
        selectLearningNote(id, noteID: nil)
        return page
    }
    /// The first committed text creates one note. Further keystrokes patch that same note.
    /// The page object and editor identity stay stable, including callbacks captured before autosave.
    func writeNotebookPage(_ id: String, page: TryNotebookPage, body: String) {
        guard let item = entry(id), item.kind == .digestion else { return }
        if let noteID = page.noteID {
            editLearningNote(id, noteID: noteID, field: "body", value: body, generation: page.generation)
            return
        }
        guard page.generation == learningGeneration(id) else { return }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            editLearningNote(id, noteID: nil, field: "body", value: body, generation: page.generation)
            return
        }
        var savedID: String?
        guard transact({ document in
            guard let row = document.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var current = document.entries[row]
            if current.notes == nil { current.notes = current.learningNotes }
            let next = TryDisk.nextID(prefix: "N", ids: (current.notes ?? []).map(\.id))
            let now = Date().timeIntervalSince1970
            let draft = current.learningDraft
            current.notes?.append(TryLearningNote(id: next, title: draft.title, body: body,
                createdAt: now, updatedAt: now, bookmark: draft.bookmark, learningStageID: page.stageID,
                topicIDs: draft.topicIDs, unitIDs: draft.unitIDs))
            current.learningNoteDraft = nil; current.selectedLearningNoteID = next
            current.updatedAt = now; current.revision += 1
            document.entries[row] = current; savedID = next
        }) else {
            // A temporary lock failure still keeps the typed text in the normal persistent draft.
            editLearningNote(id, noteID: nil, field: "body", value: body, generation: page.generation)
            return
        }
        page.noteID = savedID
        learningGenerations[id, default: 0] += 1
    }
    func discardLearningDraft(_ id: String) -> Bool {
        guard update(id, { $0.learningNoteDraft = nil; $0.selectedLearningNoteID = $0.learningNotes.last?.id }) else { return false }
        learningGenerations[id, default: 0] += 1
        return true
    }
    func selectLearningNote(_ id: String, noteID: String?) {
        guard noteID == nil || entry(id)?.learningNotes.contains(where: { $0.id == noteID }) == true else { return }
        edit(id, field: "selectedLearningNoteID", value: noteID ?? "_draft")
    }
    func removeLearningNote(_ id: String, noteID: String, restore: Bool = false) -> Bool {
        update(id) { item in
            if item.notes == nil { item.notes = item.learningNotes }
            guard let row = item.notes?.firstIndex(where: { $0.id == noteID }) else { return }
            item.notes?[row].deletedAt = restore ? nil : Date().timeIntervalSince1970
            if !restore, item.selectedLearningNoteID == noteID { item.selectedLearningNoteID = item.learningNotes.last?.id }
        }
    }
    func saveLearningOutcome(_ id: String, outcomeID: String? = nil, text: String, noteID: String?, reference: String = "") -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let item = entry(id), item.kind == .digestion,
              noteID == nil || item.learningNotes.contains(where: { $0.id == noteID }) else { return false }
        return update(id) { item in
            var outcomes = item.learningOutcomes
            if let outcomeID, let row = outcomes.firstIndex(where: { $0.id == outcomeID }) {
                outcomes[row].text = text; outcomes[row].noteID = noteID; outcomes[row].reference = reference
            } else {
                outcomes.append(TryLearningOutcome(id: UUID().uuidString, text: text, noteID: noteID, reference: reference))
            }
            item.outcomes = outcomes
        }
    }
    func removeLearningOutcome(_ id: String, outcomeID: String) -> Bool {
        update(id) { $0.outcomes?.removeAll { $0.id == outcomeID } }
    }
    func acceptLearningSuggestion(_ id: String) -> Bool {
        guard entry(id)?.learningSuggestionCurrent == true else { return false }
        return update(id) { item in
            guard item.learningSuggestionCurrent, let suggestion = item.learningSuggestion else { return }
            if let progress = suggestion.progress { item.progress = progress }
            if let next = suggestion.nextStep { item.nextStep = next }
            var outcomes = item.learningOutcomes
            for var outcome in suggestion.outcomes {
                if outcome.noteID != nil && !item.learningNotes.contains(where: { $0.id == outcome.noteID }) { outcome.noteID = nil }
                if !outcomes.contains(where: { $0.text == outcome.text && $0.noteID == outcome.noteID }) { outcomes.append(outcome) }
            }
            item.outcomes = outcomes; item.learningSuggestion = nil
        }
    }
    func adoptLearningExplanation(_ id: String, noteID: String?) -> Bool {
        guard let item = entry(id), let explanation = item.learningReadingBody else { return false }
        if let noteID, let note = item.learningNotes.first(where: { $0.id == noteID }) {
            editLearningNote(id, noteID: noteID, field: "body", value: note.body + "\n\n" + explanation, generation: learningGeneration(id))
        } else {
            editLearningNote(id, noteID: nil, field: "body", value: item.learningDraft.body + (item.learningDraft.body.isEmpty ? "" : "\n\n") + explanation, generation: learningGeneration(id))
        }
        return flush()
    }
    func beginLearning(from id: String) -> String? {
        guard let source = entry(id), source.kind == .idea else { return nil }
        var newID: String?
        guard transact({ value in
            let next = TryDisk.allocateEntryID(&value)
            let now = Date().timeIntervalSince1970
            var item = TryEntry(id: next, kind: .digestion, createdAt: now, updatedAt: now)
            item.title = source.displayTitle
            let learningSource = source.body + source.ideaSupplements.map { "\n\n## 补充想法\n" + $0.body }.joined()
            item.notes = [TryLearningNote(id: "N001", body: learningSource, createdAt: now, updatedAt: now)]
            item.selectedLearningNoteID = "N001"; item.relatedIDs = [id]
            value.entries.append(item)
            if let index = value.entries.firstIndex(where: { $0.id == id }) {
                value.entries[index].relatedIDs.append(next); value.entries[index].revision += 1
            }
            newID = next
        }) else { return nil }
        selectedID = newID
        return newID
    }

    func editLearningConfigDraft(_ id: String, config: TryLearningConfig) {
        guard let data = try? JSONEncoder().encode(config), let text = String(data: data, encoding: .utf8) else { return }
        edit(id, field: "learningConfigDraft", value: text)
    }
    func saveLearningConfig(_ id: String) -> Bool {
        guard let draft = entry(id)?.learningConfigDraft, draft.valid else { return false }
        return transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var item = value.entries[row]
            guard draft.revision == (item.learningConfig?.revision ?? 0) else { throw TryDisk.Failure.changedAddition }
            var config = draft
            config.revision = draft.revision + 1
            item.learningConfig = config; item.learningConfigDraft = nil
            item.learningFinishedAt = nil; item.learningGoalReached = nil; item.status = .active
            item.learningReview = nil
            item.updatedAt = Date().timeIntervalSince1970; item.revision += 1
            value.entries[row] = item
        }
    }
    func acceptLearningPlan(_ id: String) -> Bool {
        transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var item = value.entries[row]
            guard let config = item.learningConfig, let proposal = item.learningPlanProposal,
                  config.valid, !config.overdue, proposal.configRevision == config.revision,
                  !proposal.stages.isEmpty, proposal.totalMinutes <= config.availableMinutes else { throw TryDisk.Failure.invalid }
            let old = item.learningPlan
            var kept = item.learningStageChecks ?? []
            for index in kept.indices where kept[index].standards == nil {
                if kept[index].planID == old?.id,
                   kept[index].configRevision == old?.configRevision,
                   let stage = old?.stages.first(where: { $0.id == kept[index].stageID }) {
                    kept[index].standards = TryLearningStandards(stage)
                }
            }
            let previousCurrent = item.currentLearningStageID
            item.learningPlan = proposal; item.learningPlanProposal = nil; item.learningPlanFeedback = nil
            item.learningStageChecks = kept; item.learningLesson = nil; item.learningReview = nil
            item.currentLearningStageID = proposal.stages.contains { $0.id == previousCurrent } ? previousCurrent :
                proposal.stages.first { !item.verifiedLearningStages.contains($0.id) }?.id ?? proposal.stages.last?.id
            item.updatedAt = Date().timeIntervalSince1970; item.revision += 1
            value.entries[row] = item
        }
    }
    /// A study session opens the matching notebook, without losing another session's draft.
    func prepareLearningStageNote(_ id: String, stageID: String? = nil) -> Bool {
        transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var item = value.entries[row]
            guard item.learningPlanCurrent, item.learningConfig?.overdue == false, item.learningFinishedAt == nil,
                  let stage = item.learningPlan?.stages.first(where: { $0.id == (stageID ?? item.currentLearningStage?.id) }) else { throw TryDisk.Failure.invalid }
            var draft = item.learningDraft
            if !draft.isEmpty, draft.learningStageID != stage.id {
                // Preserve what the user was writing before entering another lesson.
                if item.notes == nil { item.notes = item.learningNotes }
                let noteID = TryDisk.nextID(prefix: "N", ids: (item.notes ?? []).map(\.id))
                let now = Date().timeIntervalSince1970
                item.notes?.append(TryLearningNote(id: noteID, title: draft.title, body: draft.body,
                    createdAt: now, updatedAt: now, bookmark: draft.bookmark, learningStageID: draft.learningStageID,
                    topicIDs: draft.topicIDs, unitIDs: draft.unitIDs))
                draft = TryLearningNoteDraft()
                item.learningNoteDraft = nil
            }
            item.currentLearningStageID = stage.id
            item.currentLearningUnitID = (item.learningUnits ?? []).last { $0.stageIDs.contains(stage.id) }?.id
            if let note = item.learningNotes.last(where: { $0.learningStageID == stage.id }) {
                item.selectedLearningNoteID = note.id
            } else {
                draft.learningStageID = stage.id
                if draft.title.isEmpty { draft.title = item.currentLearningNoteTitle }
                if draft.body.isEmpty {
                    draft.topicIDs = item.currentLearningUnit?.topicIDs
                    draft.unitIDs = item.currentLearningUnit.map { [$0.id] }
                }
                item.learningNoteDraft = draft; item.selectedLearningNoteID = "_draft"
            }
            item.updatedAt = Date().timeIntervalSince1970; item.revision += 1
            value.entries[row] = item
        }
    }
    func confirmLearningStage(_ id: String, stageID: String) -> Bool {
        transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var item = value.entries[row]
            guard let index = item.learningStageChecks?.firstIndex(where: { $0.stageID == stageID }),
                  let check = item.learningStageChecks?[index], item.learningCheckCurrent(check),
                  check.verdict == "ready" else { throw TryDisk.Failure.invalid }
            item.learningStageChecks?[index].confirmedAt = Date().timeIntervalSince1970
            item.learningReview = nil
            if !check.outcome.isEmpty {
                var outcomes = item.learningOutcomes
                if !outcomes.contains(where: { $0.text == check.outcome }) {
                    outcomes.append(TryLearningOutcome(id: UUID().uuidString, text: check.outcome,
                        noteID: check.evidenceVersions.keys.sorted().first))
                }
                item.outcomes = outcomes
            }
            item.currentLearningStageID = item.learningPlan?.stages.first { !item.verifiedLearningStages.contains($0.id) }?.id ?? stageID
            item.updatedAt = Date().timeIntervalSince1970; item.revision += 1
            value.entries[row] = item
        }
    }
    func finishLearning(_ id: String, reached: Bool) -> Bool {
        transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw TryDisk.Failure.missing }
            var item = value.entries[row]
            guard item.learningReviewCurrent else { throw TryDisk.Failure.invalid }
            if reached {
                guard item.learningPlanCurrent, !(item.learningPlan?.stages.isEmpty ?? true),
                      item.verifiedLearningStages.count == item.learningPlan?.stages.count else { throw TryDisk.Failure.invalid }
            }
            item.learningFinishedAt = Date().timeIntervalSince1970; item.learningGoalReached = reached; item.status = .done
            item.updatedAt = Date().timeIntervalSince1970; item.revision += 1
            value.entries[row] = item
        }
    }
    func switchLearningStage(_ id: String, stageID: String) -> Bool {
        // Uses the existing draft-preserving transition; never confirms mastery.
        prepareLearningStageNote(id, stageID: stageID)
    }
    func selectLearningUnit(_ id: String, unitID: String) -> Bool {
        update(id) { item in
            guard item.learningUnits?.contains(where: { $0.id == unitID && $0.stageIDs.contains(item.currentLearningStage?.id ?? "") }) == true else { return }
            item.currentLearningUnitID = unitID
        }
    }
    func recordLearningFeedback(_ id: String, text: String) -> Bool {
        update(id) { item in
            if item.learningFeedback == nil { item.learningFeedback = [] }
            let feedback = TryLearningFeedback(unitID: item.currentLearningUnit?.id,
                stageID: item.currentLearningStage?.id, text: text, at: Date().timeIntervalSince1970)
            item.learningFeedback?.append(feedback)
        }
    }
    func saveLearningPreferences(_ id: String, preferences: TryLearningPreferences) -> Bool {
        update(id) { $0.learningPreferences = preferences }
    }
    func collectLearningUnit(_ id: String) -> Bool {
        guard let item = entry(id), let unit = item.currentLearningUnit else { return false }
        let noteBody = unit.readingBody.components(separatedBy: "\n").dropFirst()
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if item.learningOrganizations?.contains(where: { $0.unitIDs == [unit.id] && ($0.body == noteBody || $0.body == unit.readingBody) }) == true { return true }
        return update(id) { item in
            guard let unit = item.currentLearningUnit else { return }
            let title = item.currentLearningNoteTitle
            let body = unit.readingBody.components(separatedBy: "\n").dropFirst()
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if item.learningOrganizations == nil { item.learningOrganizations = [] }
            item.learningOrganizations?.append(TryLearningOrganization(id: UUID().uuidString,
                title: title, body: body, topicIDs: unit.topicIDs, unitIDs: [unit.id],
                sourceNotes: [], explanation: "来自当前学习单元的AI讲解，待采纳；不代表独立作答。",
                createdAt: Date().timeIntervalSince1970))
        }
    }
    func adoptLearningOrganization(_ id: String, organizationID: String, expectedRevision: Int) -> Bool {
        transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id }),
                  value.entries[row].revision == expectedRevision else { throw TryDisk.Failure.changedAddition }
            try value.entries[row].adoptOrganization(organizationID)
            value.entries[row].updatedAt = Date().timeIntervalSince1970
            value.entries[row].revision += 1
        }
    }
    func undoLearningOrganization(_ id: String, organizationID: String, expectedRevision: Int) -> Bool {
        transact { value in
            guard let row = value.entries.firstIndex(where: { $0.id == id }),
                  value.entries[row].revision == expectedRevision,
                  let draft = value.entries[row].learningOrganizations?.first(where: { $0.id == organizationID }),
                  let noteID = draft.adoptedNoteID,
                  let index = value.entries[row].notes?.firstIndex(where: { $0.id == noteID }) else { throw TryDisk.Failure.changedAddition }
            value.entries[row].notes?[index].deletedAt = Date().timeIntervalSince1970
            if value.entries[row].selectedLearningNoteID == noteID { value.entries[row].selectedLearningNoteID = "_draft" }
            value.entries[row].updatedAt = Date().timeIntervalSince1970
            value.entries[row].revision += 1
        }
    }
    func learningHandoff(_ id: String, action: String? = nil) -> String? {
        guard flush(), let item = entry(id), item.kind == .digestion else { return nil }
        let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dboard-ai").path
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let storeArgument = url == TryDisk.defaultURL ? "" : " --store " + quote(url.path)
        let mode = action ?? item.learningAction
        guard ["plan", "lesson", "check", "practice", "review"].contains(mode) else { return nil }
        let instructions = mode == "practice"
            ? "按返回的 duePractice 出题，等我实际答完再点评并按反馈规则回写。"
            : "按返回的学习目标、基础、时间预算、截止日期、当前方案与本节笔记执行本阶段；遵守 learningPreferences，按当前单元先讲现象或结果，再讲指标、原因与判断。只在阶段末或我主动复习/复测时集中检查，不逐轮出题；把方案、讲解或实际自测结果按反馈规则回写。先澄清关键的不确定信息，不擅自扩大目标，不因讲解结束就认定我已掌握。"
        return "请作为我的学习教练，接手 D板「次 Try」学习 " + id + "「" + item.displayTitle + "」。\n执行 " + quote(cli) + " try" + storeArgument + " context " + quote(id) + " --learning-action " + mode + "。\n" + instructions
    }

    func handoff(_ id: String) -> String? {
        guard flush(), let entry = entry(id) else { return nil }
        let cli = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/dboard-ai").path
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let storeArgument = url == TryDisk.defaultURL ? "" : " --store " + quote(url.path)
        if entry.kind == .digestion { return learningHandoff(id) }
        if entry.kind == .idea {
            return "请帮我讨论这个想法：D板「次 Try」" + entry.id + "「" + entry.displayTitle + "」。\n执行 " + quote(cli) + " try" + storeArgument + " context " + quote(id) + "，先读最初的想法和所有��续补充，再按返回的反馈规则继续。\n保留我写的原���与补充；AI 解释单独记录。没有明确问题时直接��馈，不自行实施。"
        }
        let continuation = entry.pendingAdditions.isEmpty ? "" : "\n先处理未完成的追加���容，在已有成果上继续；已处理的部分只作参考，不重复实施。"
        return "请接手 D���「��� Try」的" + entry.kind.title + " " + entry.id + "「" + entry.displayTitle + "」。\n通过本机命令执行：\n" + quote(cli) + " try" + storeArgument + " context " + quote(id) + "\n按返回的最新内容、状��和反馈规则" + entry.kind.aiAction + "；每轮结束前记录一句话概括，按需补明细。没有待做事项时直接反馈，任务完成和是否消化完由我确认。" + continuation
    }
}
