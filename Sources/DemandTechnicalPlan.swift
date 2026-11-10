import Foundation

/// AI-authored document, independent from progress summaries and verification milestones.
struct DemandTechnicalPlan: Codable, Equatable {
    var title: String
    var markdown: String
    var projects: [DemandDeliveryProject]
    var scopeHash: String
    var codeRevision: String?
    var updatedAt: String
    var updatedBy: String
    enum CodingKeys: String, CodingKey {
        case title, markdown, projects
        case scopeHash = "scope_hash", codeRevision = "code_revision", updatedAt = "updated_at", updatedBy = "updated_by"
    }
    static let prefix = "<!-- dboard-technical-plan:v1:"
    var revision: String {
        let parts = [title, markdown] + projects.sorted { $0.name < $1.name }.map(\.declaration)
            + [scopeHash, codeRevision ?? "", updatedAt, updatedBy]
        return ContentRevision.hash(parts.joined(separator: "\0"))
    }
    var isValid: Bool {
        !title.trimmed.isEmpty && !title.contains("\n") && title.count <= 200 &&
        !markdown.trimmed.isEmpty && markdown.count <= 60000 &&
        scopeHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil &&
        (codeRevision == nil || codeRevision?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil) &&
        ["ai", "user"].contains(updatedBy) && !updatedAt.isEmpty &&
        Set(projects.map(\.name)).count == projects.count &&
        projects.allSatisfy { DemandDeliveryProject.validName($0.name) && DemandDeliveryProject.validBranch($0.branch)
            && !DemandDeliveryProject.isIntegrationBranch($0.branch) }
    }
    static func read(_ block: [String]) throws -> Self? {
        let lines = block.filter { $0.hasPrefix(prefix) }
        guard lines.count <= 1 else { throw DemandDeliveryError.message("技术方案记录重复，请核对后重试。") }
        guard let line = lines.first else { return nil }
        guard line.hasSuffix(" -->"), let bytes = Data(base64Encoded: String(line.dropFirst(prefix.count).dropLast(4))),
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.isValid else {
            throw DemandDeliveryError.message("技术方案无法读取，原记录已保留。")
        }
        return value
    }
    static func set(_ block: inout [String], value: Self) throws {
        guard value.isValid else { throw DemandDeliveryError.message("技术方案不完整，未保存。") }
        let bytes = try JSONEncoder().encode(value)
        block.removeAll { $0.hasPrefix(prefix) }
        block.insert(prefix + bytes.base64EncodedString() + " -->", at: 1)
    }
    func reviewReason(item: DItem, codeRevision: String?) -> String? {
        if scopeHash != item.executionScope { return "需求已变化，请让 AI 核对技术方案" }
        if codeRevision == nil || self.codeRevision != codeRevision { return "代码已变化或无法核实，请让 AI 核对技术方案" }
        return nil
    }
    static func currentCodeRevision(repositories: [DemandVersion.Repository]) -> String? {
        struct Response: Decodable {
            struct Row: Decodable { let code_revision: String? }
            let success: Bool
            let reviews: [Row]
        }
        guard !repositories.isEmpty, let bytes = try? JSONEncoder().encode(repositories) else { return nil }
        let request = "[{\"id\":\"plan\",\"repositories\":" + String(decoding: bytes, as: UTF8.self) + "}]"
        let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", DemandCodeReviews.helperURL.path, request], timeout: 30)
        guard result.succeeded, let value = try? JSONDecoder().decode(Response.self, from: result.stdout), value.success else { return nil }
        return value.reviews.first?.code_revision
    }
}

extension DItemStore {
    static func saveTechnicalPlan(id: String, markdown: String, expectedRevision: String, at url: URL? = nil) -> Bool {
        mutate(at: url) { lines in
            guard let range = blockRange(lines, id: id) else { return false }
            var block = Array(lines[range])
            do {
                guard var value = try DemandTechnicalPlan.read(block), value.revision == expectedRevision,
                      CacheParser.parse(content: lines.joined(separator: "\n")).items.first(where: { $0.id == id })?.status != .completed else { return false }
                if value.markdown == markdown { return true }
                value.markdown = markdown
                value.updatedBy = "user"
                value.updatedAt = ISO8601DateFormatter().string(from: Date())
                try DemandTechnicalPlan.set(&block, value: value)
                lines.replaceSubrange(range, with: block)
                return true
            } catch { return false }
        }
    }
}
