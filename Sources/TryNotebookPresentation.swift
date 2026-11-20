import Foundation

/// A reading projection only. Full bodies, source snapshots and evidence are never rewritten.
struct TryNotebookPresentation {
    let title: String
    let body: String
    let annotations: [String]

    init(_ note: TryLearningNote) {
        title = note.displayTitle
        var lines = note.body.components(separatedBy: .newlines)
        if let first = lines.first, Self.normalizedTitle(first) == Self.normalizedTitle(title),
           first.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            lines.removeFirst()
        }
        let source = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.origin == "ai_organized" || note.origin == "ai_supplement" else {
            body = source; annotations = []; return
        }
        var reading: [String] = []
        var notes: [String] = []
        for paragraph in source.components(separatedBy: "\n\n") {
            let text = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            let workflow = #"^(这里结合N\d+|以上结合N\d+|这是已讲内容的AI整理补充|用户S\d+(真实作答|实际回答))"#
            if text.range(of: workflow, options: .regularExpression) != nil {
                notes.append(text)
            } else {
                reading.append(paragraph)
            }
        }
        body = reading.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        annotations = notes
    }
    static func normalizedTitle(_ value: String) -> String {
        value.replacingOccurrences(of: #"^\s*#+\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func hasBodyTitle(_ note: TryLearningNote) -> Bool {
        guard let first = note.body.split(whereSeparator: \.isNewline).first,
              first.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return false }
        return normalizedTitle(String(first)) == normalizedTitle(note.displayTitle)
    }
}

/// Prefer a supplied concept heading or an existing category; do not guess concepts by trimming a question.
enum TryLearningNoteNaming {
    static func knowledgeHeading(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = TryNoteMarkup.plainLabel(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !value.contains("\n"), !title.hasSuffix("?"), !title.hasSuffix("？"),
              title.range(of: #"^(为什么|怎么|如何|是否|能否)"#, options: .regularExpression) == nil else { return nil }
        return title
    }
}

/// One content directory for every active note. Reading or editing never changes its order.
struct TryNotebookCatalog {
    let notes: [TryLearningNote]
    init(_ item: TryEntry) {
        notes = item.learningNotes.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }
}
