import Foundation

struct DemandChat: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    var isValid: Bool {
        !id.isEmpty && id == id.trimmed &&
        id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil && !name.trimmed.isEmpty
    }
}

struct DemandChatLinks: Codable, Equatable {
    var primary: DemandChat? = nil
    var secondary: [DemandChat] = []

    var all: [DemandChat] { (primary.map { [$0] } ?? []) + secondary }
    var isEmpty: Bool { all.isEmpty }
    var isValid: Bool { all.allSatisfy(\.isValid) && Set(all.map(\.id)).count == all.count }
    var optional: DemandChatLinks? { isEmpty ? nil : self }

    mutating func setPrimary(_ chat: DemandChat?) {
        primary = chat
        if let chat { secondary.removeAll { $0.id == chat.id } }
    }

    mutating func setSecondary(_ chats: [DemandChat]) {
        var seen = Set(primary.map { [$0.id] } ?? [])
        secondary = chats.filter { seen.insert($0.id).inserted }
    }

    var summary: String {
        if let primary {
            return primary.name + (secondary.isEmpty ? "" : " · 次要 " + String(secondary.count) + " 个")
        }
        return "次要群聊 " + String(secondary.count) + " 个"
    }

    var assembled: String {
        var lines: [String] = []
        if let primary { lines.append("主要群聊：" + primary.name + "；群 ID：" + primary.id) }
        lines += secondary.map { "次要群聊：" + $0.name + "；群 ID：" + $0.id }
        return lines.joined(separator: "\n")
    }
}

enum DemandChatLinksCodec {
    static let field = "- **关联群聊**"

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "关联群聊无法读取，原记录已保留；请检查需求数据。" }
    }

    static func read(_ block: [String]) throws -> DemandChatLinks? {
        let matches = block.indices.filter { block[$0].hasPrefix(field) }
        guard matches.count <= 1 else { throw ReadError.invalid }
        guard let index = matches.first else { return nil }
        guard index + 1 >= block.count || !block[index + 1].hasPrefix("    ") else { throw ReadError.invalid }
        var value = String(block[index].dropFirst(field.count))
        if value.first == "：" || value.first == ":" { value.removeFirst() }
        guard let data = value.data(using: .utf8),
              let links = try? JSONDecoder().decode(DemandChatLinks.self, from: data),
              links.isValid else { throw ReadError.invalid }
        return links.optional
    }

    static func set(_ block: inout [String], links: DemandChatLinks?) throws {
        _ = try read(block) // Never replace an unreadable existing association.
        guard links?.isValid != false else { throw ReadError.invalid }
        let index = block.firstIndex { $0.hasPrefix(field) }
        guard let links, !links.isEmpty else {
            if let index { block.remove(at: index) }
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let line = field + "：" + String(decoding: try encoder.encode(links), as: UTF8.self)
        if let index { block[index] = line }
        else { block.insert(line, at: min(1, block.count)) }
    }
}
