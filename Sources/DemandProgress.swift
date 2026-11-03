import Foundation

/// Local progress keeps the full handoff; remote documents receive only short summaries.
enum DemandProgress {
    static let summaryLimit = 120

    static func summary(_ content: String) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > summaryLimit else { return text }
        let sentence = text.prefix { !"。！？；;\n".contains($0) }
        let short = String(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty && short.count <= 80 { return short + "。" }
        return String(text.prefix(79)) + "…"
    }

    static func entry(date: String, summary: String, details: String = "") -> [String]? {
        let text = summary.trimmed
        guard !text.isEmpty, text.count <= summaryLimit,
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        var lines = ["    - " + date + ": " + text]
        if !details.trimmed.isEmpty {
            lines.append("        明细：")
            lines.append(contentsOf: details.trimmingCharacters(in: .newlines)
                .components(separatedBy: "\n").map { "        " + $0 })
        }
        return lines
    }

    static func remoteLines(_ lines: [String]) throws -> [String] {
        try DemandOverview.archiveBlock(lines)
    }

}

extension Milestone {
    var summary: String { details.isEmpty ? DemandProgress.summary(content) : content }
    var detailText: String { details.isEmpty && summary != content ? content : details }
    var fullContent: String { details.isEmpty ? content : content + "\n明细：\n" + details }
}
