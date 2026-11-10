import Foundation

struct IncidentExperienceReview: Codable {
    let decision: String
    let reason: String
    let checked_at: String
    let record_count: Int
    let scope_hash: String

    static func read(_ block: [String]) throws -> Self? {
        let prefix = "<!-- dboard-ai-feedback:v1:"
        guard let row = block.first(where: { $0.hasPrefix(prefix) }),
              let data = Data(base64Encoded: String(row.dropFirst(prefix.count).dropLast(4))),
              let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let review = metadata["experience_review"] else { return nil }
        let result = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: review))
        guard ["create", "update", "skip"].contains(result.decision), !result.reason.trimmed.isEmpty,
              result.record_count >= 0 else { throw IncidentError.invalid }
        return result
    }
}

struct DemandKnowledge: Codable {
    struct Source: Codable, Equatable {
        let id: String
        let record_count: Int
        let scope_hash: String
    }
    struct Entry: Codable, Identifiable, Equatable {
        var id: String
        var title: String
        var mechanism: String
        var symptoms: [String]
        var scopes: [String]
        var procedure: String
        var finding: String
        var confidence: String
        var boundaries: String
        var evidence: [String]
        var related_ids: [String]
        var sources: [Source]
        var active: Bool
        var updated_by: String
        var updated_at: String

        var revision: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return ContentRevision.hash(String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? "")
        }
        var cleaned: Self {
            var result = self
            result.title = title.trimmed; result.mechanism = mechanism.trimmed
            result.procedure = procedure.trimmed; result.finding = finding.trimmed; result.boundaries = boundaries.trimmed
            result.symptoms = symptoms.map(\.trimmed).filter { !$0.isEmpty }
            result.scopes = scopes.map(\.trimmed).filter { !$0.isEmpty }
            result.evidence = evidence.map(\.trimmed).filter { !$0.isEmpty }
            return result
        }
        var isValid: Bool {
            let texts = [title, procedure, boundaries] + symptoms + evidence
            guard id.range(of: #"^K[0-9]{3,}$"#, options: .regularExpression) != nil,
                  !symptoms.isEmpty, !evidence.isEmpty,
                  texts.allSatisfy({ !$0.trimmed.isEmpty }),
                  (texts + [mechanism, finding] + scopes).allSatisfy(Self.plain),
                  ["confirmed", "method"].contains(confidence),
                  confidence != "confirmed" || !finding.trimmed.isEmpty,
                  ["ai", "user"].contains(updated_by), !updated_at.isEmpty, !sources.isEmpty else { return false }
            return sources.allSatisfy {
                $0.id.range(of: #"^[DP][0-9]{3,}$"#, options: .regularExpression) != nil &&
                $0.record_count >= 0 && $0.scope_hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
            }
        }
        private static func plain(_ value: String) -> Bool {
            !value.unicodeScalars.contains { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }
        }
    }
    var version = 1
    var next_id = 1
    var entries: [Entry] = []
    static let prefix = "<!-- dboard-knowledge:v1:"
    static let keys: Set<String> = ["id", "title", "mechanism", "symptoms", "scopes", "procedure", "finding",
        "confidence", "boundaries", "evidence", "related_ids", "sources", "active", "updated_by", "updated_at"]

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "排查经验库无法读取，原数据保留；请核对后重试。" }
    }

    static func read(_ lines: [String]) throws -> Self {
        let rows = lines.filter { $0.hasPrefix(prefix) }
        guard !rows.isEmpty else { return Self() }
        guard rows.count == 1, let row = rows.first, row.hasSuffix(" -->"),
              let data = Data(base64Encoded: String(row.dropFirst(prefix.count).dropLast(4))),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "next_id", "entries"],
              let entries = object["entries"] as? [[String: Any]], entries.allSatisfy({ Set($0.keys) == keys }),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              value.entries.allSatisfy(\.isValid), Set(value.entries.map(\.id)).count == value.entries.count,
              value.next_id > (value.entries.compactMap { Int($0.id.dropFirst()) }.max() ?? 0) else { throw ReadError.invalid }
        let ids = Set(value.entries.map(\.id))
        guard value.entries.allSatisfy({ entry in
            entry.related_ids.allSatisfy { ids.contains($0) && $0 != entry.id }
        }) else { throw ReadError.invalid }
        return value
    }

    func write(_ lines: inout [String]) throws {
        let encoded = try JSONEncoder().encode(self)
        lines.removeAll { $0.hasPrefix(Self.prefix) }
        lines.insert(Self.prefix + encoded.base64EncodedString() + " -->", at: 0)
    }
}

extension DItemStore {
    static func saveKnowledge(_ value: DemandKnowledge.Entry, expected: String, at url: URL? = nil) -> Bool {
        mutate(at: url) { lines in
            do {
                var catalog = try DemandKnowledge.read(lines)
                guard let index = catalog.entries.firstIndex(where: { $0.id == value.id }),
                      catalog.entries[index].revision == expected, value.sources == catalog.entries[index].sources,
                      value.cleaned.isValid,
                      value.related_ids.allSatisfy({ ref in ref != value.id && catalog.entries.contains(where: { $0.id == ref }) }) else { return false }
                var updated = value.cleaned
                updated.updated_by = "user"
                updated.updated_at = ISO8601DateFormatter().string(from: Date())
                catalog.entries[index] = updated
                try catalog.write(&lines)
                return true
            } catch { return false }
        }
    }
}

struct DemandKnowledgeDraft: Codable {
    var value: DemandKnowledge.Entry
    let expected: String
    static func load(_ id: String) -> Self? {
        guard let data = UserDefaults.standard.data(forKey: "dboard.knowledgeDraft." + id) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "dboard.knowledgeDraft." + value.id) }
    static func clear(_ id: String) { UserDefaults.standard.removeObject(forKey: "dboard.knowledgeDraft." + id) }
}
