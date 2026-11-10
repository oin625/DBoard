import Foundation

struct DemandReleaseChecklist: Codable, Equatable {
    enum Author: String, Codable { case user, ai }
    enum Category: Codable, CaseIterable, Identifiable, Hashable {
        case release, sql, configuration, permission, other
        case custom(String)
        static let allCases: [Self] = [.release, .sql, .configuration, .permission, .other]
        var id: String { rawValue }
        var rawValue: String {
            switch self {
            case .release: return "release"
            case .sql: return "sql"
            case .configuration: return "configuration"
            case .permission: return "permission"
            case .other: return "other"
            case .custom(let name): return "custom:" + name
            }
        }
        var title: String {
            switch self {
            case .release: return "发布"
            case .sql: return "SQL"
            case .configuration: return "配置"
            case .permission: return "权限"
            case .other: return "其他"
            case .custom(let name): return name
            }
        }
        init?(rawValue: String) {
            if let value = Self.allCases.first(where: { $0.rawValue == rawValue }) { self = value; return }
            guard rawValue.hasPrefix("custom:") else { return nil }
            let name = String(rawValue.dropFirst(7))
            guard !name.isEmpty, name == name.trimmed, name.count <= 20,
                  !Self.allCases.contains(where: { $0.title == name }),
                  !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
            self = .custom(name)
        }
        static func named(_ name: String) -> Self? {
            let name = name.trimmed
            return allCases.first(where: { $0.title == name || $0.rawValue == name }) ?? Self(rawValue: "custom:" + name)
        }
        static func ordered(_ categories: [Self]) -> [Self] {
            var result = allCases
            for category in categories where !result.contains(category) { result.append(category) }
            return result
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            guard let value = Self(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid release category")
            }
            self = value
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
        static func infer(_ text: String) -> Self {
            let text = text.lowercased()
            if ["sql", "建表", "索引", "ddl", "表结构"].contains(where: text.contains) || (text.hasPrefix("创建") && text.contains("表")) { return .sql }
            if text.hasPrefix("发布") || text.hasPrefix("部署") { return .release }
            if ["权限", "授权", "网关", "开通", "菜单"].contains(where: text.contains) { return .permission }
            if ["配置", "开关", "定时", "调度", "任务", "xxl"].contains(where: text.contains) { return .configuration }
            if ["发布", "部署"].contains(where: text.contains) { return .release }
            return .other
        }
    }
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        var text: String
        var done: Bool = false
        var updatedBy: Author
        var details: String = ""
        var evidence: String = ""
        var category: Category
        enum CodingKeys: String, CodingKey { case id, text, done, details, evidence, category, updatedBy = "updated_by" }

        init(id: String, text: String, done: Bool = false, updatedBy: Author, details: String = "", category: Category? = nil, evidence: String = "") {
            self.id = id; self.text = text; self.done = done; self.updatedBy = updatedBy; self.details = details
            self.evidence = evidence
            self.category = category ?? Category.infer(text)
        }
        func sameTask(as other: Self) -> Bool {
            id == other.id && text == other.text && done == other.done &&
                details == other.details && category == other.category
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            text = try values.decode(String.self, forKey: .text)
            done = try values.decode(Bool.self, forKey: .done)
            updatedBy = try values.decode(Author.self, forKey: .updatedBy)
            details = try values.decodeIfPresent(String.self, forKey: .details) ?? ""
            evidence = try values.decodeIfPresent(String.self, forKey: .evidence) ?? ""
            category = try values.decodeIfPresent(Category.self, forKey: .category) ?? Category.infer(text)
        }
    }

    var items: [Entry] = []
    var excludedByUser: [String] = []
    var nextID = 1
    var reviewedScope: String? = nil
    enum CodingKeys: String, CodingKey {
        case items, excludedByUser = "excluded_by_user", nextID = "next_id", reviewedScope = "reviewed_scope"
    }
    static let prefix = "<!-- dboard-release-checklist:v1:"
    static let suffix = " -->"
    var completedCount: Int { items.filter(\.done).count }

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "上线前事项无法读取，已保留原记录；请核对本地数据" }
    }

    static func clean(_ text: String) -> String { DemandReminder.singleLine(text).trimmed }
    static func key(_ text: String) -> String { clean(text).lowercased() }
    static func validText(_ text: String) -> Bool {
        !text.trimmed.isEmpty && !text.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func validDetails(_ text: String) -> Bool {
        text.count <= 12000 && !text.unicodeScalars.contains { ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 }
    }
    var isValid: Bool {
        let numbers = items.compactMap { entry -> Int? in
            guard entry.id.range(of: #"^L[0-9]{3,}$"#, options: .regularExpression) != nil else { return nil }
            return Int(entry.id.dropFirst())
        }
        return numbers.count == items.count && numbers.allSatisfy { $0 > 0 } &&
            Set(items.map(\.id)).count == items.count && items.allSatisfy { Self.validText($0.text) && Self.validDetails($0.details) && Self.validDetails($0.evidence) && Category(rawValue: $0.category.rawValue) != nil } &&
            Set(items.map { Self.key($0.text) }).count == items.count &&
            nextID > (numbers.max() ?? 0) && nextID < Int.max &&
            excludedByUser.allSatisfy(Self.validText) &&
            Set(excludedByUser.map(Self.key)).count == excludedByUser.count &&
            (reviewedScope == nil || reviewedScope!.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil)
    }

    static func read(_ block: [String]) throws -> Self {
        let records = block.filter { $0.hasPrefix(prefix) }
        guard records.count <= 1 else { throw ReadError.invalid }
        guard let record = records.first else { return .init() }
        guard record.hasSuffix(suffix),
              let bytes = Data(base64Encoded: String(record.dropFirst(prefix.count).dropLast(suffix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.isValid else { throw ReadError.invalid }
        return value
    }

    static func set(_ block: inout [String], checklist: Self) throws {
        guard checklist.isValid else { throw ReadError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let line = prefix + (try encoder.encode(checklist)).base64EncodedString() + suffix
        block.removeAll { $0.hasPrefix(prefix) }
        block.insert(line, at: 1)
    }

    @discardableResult
    mutating func add(_ text: String, author: Author, details: String = "", category: Category? = nil) -> Bool {
        let text = Self.clean(text), key = Self.key(text)
        guard Self.validText(text), Self.validDetails(details), nextID < Int.max - 1 else { return false }
        if items.contains(where: { Self.key($0.text) == key }) { return true }
        if author == .ai && excludedByUser.contains(where: { Self.key($0) == key }) { return true }
        if author == .user { excludedByUser.removeAll { Self.key($0) == key } }
        items.append(Entry(id: String(format: "L%03ld", nextID), text: text, updatedBy: author, details: details.trimmed, category: category))
        nextID += 1
        return true
    }

    mutating func edit(_ original: Entry, text: String, details: String? = nil, category: Category? = nil) -> Bool {
        let text = Self.clean(text), details = details?.trimmed ?? original.details
        guard Self.validText(text), Self.validDetails(details), let index = items.firstIndex(where: { $0.sameTask(as: original) }),
              !items.contains(where: { $0.id != original.id && Self.key($0.text) == Self.key(text) }) else { return false }
        if Self.key(text) != Self.key(original.text) { exclude(original.text) }
        excludedByUser.removeAll { Self.key($0) == Self.key(text) }
        items[index].text = text
        items[index].details = details
        items[index].category = category ?? original.category
        items[index].updatedBy = .user
        return true
    }

    /// Evidence has its own optimistic check, so saving it preserves concurrent text and check changes.
    mutating func setEvidence(_ id: String, text: String, expected: String) -> Bool {
        guard Self.validDetails(text), let index = items.firstIndex(where: { $0.id == id }),
              items[index].evidence == expected else { return false }
        items[index].evidence = text
        items[index].updatedBy = .user
        return true
    }

    mutating func toggle(_ original: Entry) -> Bool {
        guard let index = items.firstIndex(where: { $0.sameTask(as: original) }) else { return false }
        items[index].done.toggle()
        items[index].updatedBy = .user
        return true
    }

    mutating func remove(_ original: Entry) -> Bool {
        guard let index = items.firstIndex(of: original) else { return false }
        items.remove(at: index)
        exclude(original.text)
        return true
    }

    mutating func restore(_ entry: Entry) -> Bool {
        guard !items.contains(where: { $0.id == entry.id || Self.key($0.text) == Self.key(entry.text) }) else { return false }
        excludedByUser.removeAll { Self.key($0) == Self.key(entry.text) }
        var restored = entry
        restored.updatedBy = .user
        items.append(restored)
        return true
    }

    private mutating func exclude(_ text: String) {
        if !excludedByUser.contains(where: { Self.key($0) == Self.key(text) }) { excludedByUser.append(text) }
    }
}

extension DItem {
    var releaseChecklistNeedsReview: Bool { releaseChecklist.reviewedScope != executionScope }
}
