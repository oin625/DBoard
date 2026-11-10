import Foundation
import Combine

struct ArchivedDemand: Identifiable {
    let block: [String]
    let original: [String]?
    let priority: ItemPriority
    var id: String { ContentRevision.hash(block.joined(separator: "\n")) }
    let item: DItem
    var completedDate: String? {
        guard let range = block[0].range(of: #"✅[0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) else { return nil }
        return String(block[0][range].dropFirst())
    }

    func newDraft(id: String) throws -> DItemDraft {
        let previous = item
        let number = (previous.version?.number ?? 1) + 1
        let version = DemandVersion(number: number, parentID: previous.id,
            rootID: previous.version?.rootID ?? previous.id, parentTitle: previous.displayTitle,
            sourceRevision: self.id, background: try DemandVersion.baseline(item: previous, block: block),
            repositories: try DemandVersion.repositoryHints(block, item: previous))
        guard version.isValid else { throw DemandVersion.ReadError.invalid }
        var draft = DItemDraft(newID: id, priority: priority)
        draft.kind = previous.kind
        let title = previous.displayTitle.replacingOccurrences(of: #"\s+[0-9]+\.0$"#, with: "", options: .regularExpression)
        draft.name = title + " " + version.label
        draft.project = previous.project
        draft.branch = previous.branch == "待定" ? "" : (previous.branch ?? "")
        let spell = DemandPromptSections(stored: previous.prompt)
        draft.promptSections = DemandPromptSections(codeEntry: spell.codeEntry, materials: spell.materials)
        draft.version = version
        draft.chatLinks = previous.chatLinks
        return draft
    }
}

enum DemandArchive {
    enum ReadError: LocalizedError {
        case invalid, missingNode, remote
        var errorDescription: String? {
            switch self {
            case .invalid: return "归档内容无法读取，已保留上次记录"
            case .missingNode: return "尚未配置归档文档，可先查看本机保留的归档"
            case .remote: return "读取钉钉归档失败，当前保留上次记录；可重试或打开归档文档"
            }
        }
    }

    static func parse(_ markdown: String) throws -> [ArchivedDemand] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var records: [ArchivedDemand] = []
        var priority: ItemPriority = .p1
        var index = 0
        while index < lines.count {
            for value in ItemPriority.allCases where lines[index].hasPrefix(value.sectionPrefix) { priority = value }
            guard lines[index].range(of: #"^### [DP][0-9]{3,}(?=【|\s|$)"#, options: .regularExpression) != nil else {
                index += 1; continue
            }
            let start = index
            index += 1
            while index < lines.count && !lines[index].hasPrefix("### ") &&
                !lines[index].hasPrefix("## ") && lines[index] != "---" { index += 1 }
            var block = Array(lines[start..<index])
            while block.count > 1 && block.last == "" { block.removeLast() }
            // The completion stamp belongs to the archive, not the requirement's title.
            block[0] = block[0].replacingOccurrences(of: #"\s*✅[0-9]{4}-[0-9]{2}-[0-9]{2}"#,
                with: "", options: .regularExpression)
            let parsed = CacheParser.parse(content: priority.sectionPrefix + "\n" + block.joined(separator: "\n")).items
            guard parsed.count == 1 else { throw ReadError.invalid }
            guard parsed[0].status == .completed else { continue }
            // Keep the exact archive snapshot (including completion stamp) as identity.
            var rawBlock = Array(lines[start..<index])
            while rawBlock.count > 1 && rawBlock.last == "" { rawBlock.removeLast() }
            records.append(ArchivedDemand(block: rawBlock, original: nil, priority: priority, item: parsed[0]))
        }
        var seen = Set<String>()
        return records.reversed().filter { seen.insert($0.id).inserted }
    }

    static func decodeResponse(_ data: Data) throws -> String {
        guard BusinessResponse.succeeded(data),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let markdown = object["markdown"] as? String else { throw ReadError.remote }
        return markdown
    }

    static func readRemote() throws -> String {
        guard let node = DItemStore.archiveNodeID else { throw ReadError.missingNode }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = NSHomeDirectory() + "/.qoderwork/bin:" + NSHomeDirectory() +
            "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["dws", "doc", "read", "--node", node],
                                       environment: environment, timeout: 45)
        guard result.succeeded else { throw ReadError.remote }
        return try decodeResponse(result.stdout)
    }

    static func merged(_ remote: [ArchivedDemand], journal: ArchiveJournal) -> [ArchivedDemand] {
        var records = remote
        for entry in journal.entries.values.sorted(by: { $0.createdAt < $1.createdAt }) where entry.state != .submitted {
            guard let parsed = try? parse(entry.archived.joined(separator: "\n")), let archived = parsed.first else { continue }
            if let index = records.firstIndex(where: { $0.id == archived.id }) ??
                records.firstIndex(where: { $0.item.id == archived.item.id && $0.completedDate == archived.completedDate }) {
                records[index] = ArchivedDemand(block: archived.block, original: entry.original, priority: archived.priority, item: archived.item)
            } else {
                records.insert(ArchivedDemand(block: archived.block, original: entry.original, priority: archived.priority, item: archived.item), at: 0)
            }
        }
        return records
    }
}

struct ArchivedCodeReview: Codable, Identifiable {
    let itemID: String
    let sourceRevision: String
    let summary: String
    let details: String
    let eventID: String
    var id: String { itemID + "-" + eventID }

    enum CodingKeys: String, CodingKey {
        case itemID = "id", sourceRevision = "source_revision", summary, details, eventID = "event_id"
    }

    struct File: Decodable { let version: Int; let records: [ArchivedCodeReview] }
}

final class DemandArchiveStore: ObservableObject {
    @Published private(set) var records: [ArchivedDemand] = []
    @Published private(set) var reviewNotes: [ArchivedCodeReview] = []
    var cacheURL: URL { cache }
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var readAt: Date?
    private let cache: URL
    private let journalURL: URL
    private let allowsRemote: Bool

    init(cache: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/dboard-archive-cache.md"),
         journalURL: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/dboard-archive-journal.json"),
         allowsRemote: Bool = true) {
        self.cache = cache; self.journalURL = journalURL; self.allowsRemote = allowsRemote
        reloadLocal()
    }

    func reloadLocal() {
        let reviewURL = cache.deletingLastPathComponent().appendingPathComponent("dboard-archive-code-reviews.json")
        if let data = try? Data(contentsOf: reviewURL),
           let file = try? JSONDecoder().decode(ArchivedCodeReview.File.self, from: data), file.version == 1 {
            reviewNotes = file.records
        } else { reviewNotes = [] }
        let journal = ArchiveJournal(url: journalURL)
        var remote = records
        var readError: String?
        do {
            remote = FileManager.default.fileExists(atPath: cache.path)
                ? try DemandArchive.parse(String(contentsOf: cache, encoding: .utf8)) : []
        } catch { readError = error.localizedDescription }
        records = DemandArchive.merged(remote, journal: journal)
        error = !journal.readable ? "本机归档恢复记录无法读取；当前仅显示可读取的归档" : readError
        readAt = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func refresh() {
        reloadLocal()
        guard allowsRemote, !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try DemandArchive.readRemote() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loading = false
                do {
                    let content = try result.get()
                    let parsed = try DemandArchive.parse(content)
                    let journal = ArchiveJournal(url: self.journalURL)
                    try FileManager.default.createDirectory(at: self.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try content.write(to: self.cache, atomically: true, encoding: .utf8)
                    self.records = DemandArchive.merged(parsed, journal: journal)
                    self.readAt = Date()
                    self.error = journal.readable ? nil : "本机归档恢复记录无法读取；当前显示钉钉归档"
                    for kind in DemandKind.allCases {
                        let maximum = self.records.filter { $0.item.id.hasPrefix(kind.idPrefix) }
                            .compactMap { DemandNumbering.number($0.item.id) }.max() ?? 0
                        if maximum > UserDefaults.standard.integer(forKey: kind.counterKey) {
                            UserDefaults.standard.set(maximum, forKey: kind.counterKey)
                        }
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
