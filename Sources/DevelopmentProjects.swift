import Foundation
import SwiftUI

/// Only the dedicated project field of PRD development deliverables is used.
struct DeclaredDevelopmentProject: Codable, Equatable, Identifiable {
    let project: String
    let branch: String?
    var id: String { project + "\u{0}" + (branch ?? "") }

    static func parse(_ declarations: [String]) -> [Self] {
        var seen = Set<String>()
        var result: [Self] = []
        let separators = CharacterSet(charactersIn: ",;，；\n\r")
        for declaration in declarations {
            for entry in declaration.components(separatedBy: separators) {
                let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                let parts = value.replacingOccurrences(of: "：", with: ":")
                    .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let project = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !project.isEmpty else { continue }
                let branch = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let item = Self(project: project, branch: branch.isEmpty ? nil : branch)
                if seen.insert(item.id).inserted { result.append(item) }
            }
        }
        return result
    }
}

struct DevelopmentProjectSnapshot: Codable, Equatable {
    let source: String
    let fetchedAt: Date
    let projects: [DeclaredDevelopmentProject]
    static let officialSource = "prd-development-deliverable"

    init(projects: [DeclaredDevelopmentProject], fetchedAt: Date = Date()) {
        source = Self.officialSource
        self.fetchedAt = fetchedAt
        self.projects = projects
    }
}

final class DevelopmentProjectStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/prd-development-projects.json")
    private let url: URL
    private(set) var records: [Int: DevelopmentProjectSnapshot] = [:]
    private struct File: Codable {
        let version: Int
        let records: [Int: DevelopmentProjectSnapshot]
    }

    init(url: URL = DevelopmentProjectStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
           let file = try? decoder.decode(File.self, from: data), file.version == 1 {
            records = file.records.filter { $0.value.source == DevelopmentProjectSnapshot.officialSource }
        }
    }

    @discardableResult
    func save(_ snapshot: DevelopmentProjectSnapshot, for reqID: Int) -> Bool {
        records[reqID] = snapshot
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(version: 1, records: records)).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

enum DevelopmentDeliverables {
    struct Response {
        let tags: Set<String>
        let items: [[String: Any]]
        let projects: [DeclaredDevelopmentProject]
    }
    enum ReadError: Error { case invalidResponse }

    static func decode(_ data: Data) throws -> Response {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["success"] as? Bool == true,
              let groups = response["data"] as? [String: Any],
              groups.keys.allSatisfy({ Int($0) != nil }) else { throw ReadError.invalidResponse }
        let typeMap = ["1": "solution", "2": "ui", "3": "dev", "4": "test"]
        var tags = Set<String>()
        var all: [[String: Any]] = []
        var declarations: [String] = []
        for (key, tag) in typeMap {
            guard let value = groups[key], !(value is NSNull) else { continue }
            guard let items = value as? [[String: Any]] else { throw ReadError.invalidResponse }
            if !items.isEmpty { tags.insert(tag) }
            for item in items {
                var tagged = item
                tagged["_tag"] = tag
                all.append(tagged)
                if key == "3", let raw = item["deliverableDevProject"], !(raw is NSNull) {
                    guard raw is String else { throw ReadError.invalidResponse }
                }
            }
        }
        all.sort { ($0["createTime"] as? String ?? "") > ($1["createTime"] as? String ?? "") }
        var currentDocuments = Set<String>()
        for item in all where item["_tag"] as? String == "dev" {
            // A correction by the same author for the same document replaces its old
            // project declaration; all original deliverables remain visible in history.
            if let author = item["authorId"] as? String, !author.isEmpty,
               let content = item["deliverableContent"] as? String, !content.trimmed.isEmpty,
               let date = item["createTime"] as? String, !date.isEmpty {
                let key = author + "\u{0}" + content.trimmed
                if !currentDocuments.insert(key).inserted { continue }
            }
            if let text = item["deliverableDevProject"] as? String { declarations.append(text) }
        }
        return Response(tags: tags, items: all, projects: DeclaredDevelopmentProject.parse(declarations))
    }
}

struct DevelopmentProjectsView: View {
    let snapshot: DevelopmentProjectSnapshot?
    let loading: Bool
    let error: String?
    let refresh: () -> Void
    private static let dateFormat: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "zh_CN")
        format.dateFormat = "M月d日 HH:mm"
        return format
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("涉及工程").font(.system(size: 13, weight: .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .demandButtonStyle(.plain).disabled(loading)
            }
            if let snapshot {
                if snapshot.projects.isEmpty {
                    Text("—").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("工程").foregroundStyle(.secondary)
                            Text("分支").foregroundStyle(.secondary)
                        }
                        ForEach(snapshot.projects) { item in
                            GridRow {
                                Text(item.project).textSelection(.enabled)
                                Text(item.branch ?? "—").textSelection(.enabled).foregroundStyle(.secondary)
                            }
                        }
                    }.font(.system(size: 12, design: .monospaced))
                }
                Text("来源：开发交付 · 读取于 " + Self.dateFormat.string(from: snapshot.fetchedAt))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !loading && error == nil {
                Text("尚未读取开发交付").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
