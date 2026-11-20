import SwiftUI

/// A stage is one evolving study sheet. Sections group knowledge, never conversation turns.
struct TryStudyDocument {
    struct Section: Identifiable {
        let id: Int
        let title: String
        let body: String
        var isOverview: Bool { ["本节要点", "本阶段要点", "核心要点", "要点", "学习要点"].contains(title) }
        var preview: String {
            for block in TryStudyBlock.parse(body) {
                switch block {
                case .paragraph(let text), .quote(let text), .bullet(_, let text): return text
                default: continue
                }
            }
            return ""
        }
    }
    let title: String?
    let introduction: String
    let sections: [Section]

    init(_ body: String) {
        let lines = body.components(separatedBy: .newlines)
        var fenced = false
        let headings = lines.enumerated().compactMap { index, line -> (Int, Int, String)? in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); return nil }
            guard !fenced, let heading = Self.heading(line) else { return nil }
            return (index, heading.level, heading.title)
        }
        let titleHeading = headings.first.flatMap { $0.1 == 1 ? $0 : nil }
        title = titleHeading?.2
        let level = headings.filter { $0.0 != titleHeading?.0 }.map { $0.1 }.min()
        let topics = headings.filter { $0.1 == level && $0.0 != titleHeading?.0 }
        let start = titleHeading.map { $0.0 + 1 } ?? 0
        let end = topics.first?.0 ?? lines.count
        introduction = lines[start..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        sections = topics.enumerated().map { index, heading in
            let end = index + 1 < topics.count ? topics[index + 1].0 : lines.count
            return Section(id: index, title: heading.2,
                body: lines[(heading.0 + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func heading(_ line: String) -> (level: Int, title: String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let level = text.prefix { $0 == "#" }.count
        guard (1...6).contains(level), text.dropFirst(level).first == " " else { return nil }
        return (level, text.dropFirst(level).trimmingCharacters(in: .whitespaces))
    }
}

enum TryStudyBlock: Equatable {
    case paragraph(String)
    case heading(String, Int)
    case bullet(String, String)
    case table([[String]])
    case code(String)
    case quote(String)
    case rule

    static func parse(_ body: String) -> [TryStudyBlock] {
        let lines = body.components(separatedBy: .newlines)
        var blocks: [TryStudyBlock] = []
        var index = 0
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        func cells(_ line: String) -> [String] {
            var text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("|") { text.removeFirst() }
            if text.hasSuffix("|") { text.removeLast() }
            return text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        func separator(_ line: String) -> Bool {
            let row = cells(line)
            return line.contains("|") && row.count > 1 && row.allSatisfy {
                $0.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces).count >= 3 &&
                    $0.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
            }
        }
        while index < lines.count {
            let line = lines[index]
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { flush(); index += 1; continue }
            if text.hasPrefix("```") {
                flush(); index += 1
                var code: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                blocks.append(.code(code.joined(separator: "\n")))
                if index < lines.count { index += 1 }
                continue
            }
            if index + 1 < lines.count, text.contains("|"), separator(lines[index + 1]) {
                flush()
                var rows = [cells(line)]
                let columns = rows[0].count
                index += 2
                while index < lines.count, lines[index].contains("|"), !lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[index])
                    guard row.count == columns else { break }
                    rows.append(row); index += 1
                }
                blocks.append(.table(rows)); continue
            }
            if let heading = TryStudyDocument.heading(line) {
                flush(); blocks.append(.heading(heading.title, heading.level))
            } else if ["---", "***", "___"].contains(text) {
                flush(); blocks.append(.rule)
            } else if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
                flush(); blocks.append(.bullet("•", String(text.dropFirst(2))))
            } else if let match = text.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush(); blocks.append(.bullet(String(text[match]).trimmingCharacters(in: .whitespaces), String(text[match.upperBound...])))
            } else if text.hasPrefix("> ") {
                flush(); blocks.append(.quote(String(text.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
            index += 1
        }
        flush()
        return blocks
    }
}

struct TryLearningStudySheet: View {
    let text: String
    @State private var expanded: Set<Int> = []
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let document = TryStudyDocument(text)
        VStack(alignment: .leading, spacing: 14) {
            if let title = document.title {
                Text(title).dboardFont(size: 18, weight: .semibold).textSelection(.enabled)
            }
            if !document.introduction.isEmpty { TryStudyMarkdown(text: document.introduction) }
            ForEach(document.sections) { section in
                if section.isOverview {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).dboardFont(size: 12, weight: .medium).foregroundStyle(theme.current.accentPrimary)
                        TryStudyMarkdown(text: section.body)
                    }.padding(16).workspaceSurface(radius: 12)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.title).dboardFont(size: 14, weight: .medium).textSelection(.enabled)
                        TryStudyMarkdown(text: section.body)
                    }.padding(.vertical, 8)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: document.title) { _, _ in expanded = [] }
    }

    private func topic(_ section: TryStudyDocument.Section) -> some View {
        let open = expanded.contains(section.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(TryMotion.animation(reduceMotion)) {
                    if open { expanded.remove(section.id) } else { expanded.insert(section.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 10) {
                        Text(section.title).dboardFont(size: 14, weight: .medium)
                            .foregroundStyle(theme.current.textPrimary).multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").dboardFont(size: 10, weight: .medium)
                            .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(theme.current.textSecondary)
                    }
                    if !open, !section.preview.isEmpty {
                        Text(TryStudyMarkdown.inline(section.preview)).dboardFont(size: 12)
                            .foregroundStyle(theme.current.textSecondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.demandButtonStyle(.plain).demandKeyboardID("try-study-topic-" + String(section.id))
                .accessibilityValue(open ? "已展开" : "已收起")
            if open {
                TryStudyMarkdown(text: section.body).padding(.horizontal, 14).padding(.bottom, 16)
                    .transition(TryMotion.transition(reduceMotion))
            }
        }.workspaceSurface(radius: 12)
    }
}

/// Render learning Markdown with actual heading, list, code and table layout.
struct TryStudyMarkdown: View {
    let text: String
    @EnvironmentObject private var theme: ThemeManager
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(TryStudyBlock.parse(text).enumerated()), id: \.offset) { _, block in
                content(block)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            .dboardDrawingLinks()
    }
    @ViewBuilder private func content(_ block: TryStudyBlock) -> some View {
        switch block {
        case .paragraph(let text):
            if !DemandImageMarkdown.references(in: text).isEmpty {
                DemandSpellContentView(text: text)
            } else {
                Text(Self.inline(text)).dboardFont(size: 14).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .heading(let text, let level):
            Text(Self.inline(text)).dboardFont(size: level <= 2 ? 17 : 15, weight: .semibold).padding(.top, 5)
        case .bullet(let marker, let text):
            HStack(alignment: .top, spacing: 9) {
                Text(marker).dboardFont(size: 13).foregroundStyle(theme.current.accentPrimary).frame(minWidth: 12)
                Text(Self.inline(text)).dboardFont(size: 14).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(Self.inline(cell)).dboardFont(size: 12, weight: index == 0 ? .medium : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.background(theme.current.accentPrimary.opacity(index == 0 ? 0.09 : (index % 2 == 0 ? 0.035 : 0)))
                }
            }.frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 9))
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text).dboardFont(size: 12, design: .monospaced).padding(12)
            }.background(theme.current.textPrimary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(theme.current.accentPrimary.opacity(0.45)).frame(width: 3)
                Text(Self.inline(text)).dboardFont(size: 13).foregroundStyle(theme.current.textSecondary).lineSpacing(4)
            }.fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().opacity(0.3)
        }
    }
}

struct TryLearningResourceCards: View {
    let resources: [TryLearningResource]
    @State private var showAll = false
    @EnvironmentObject private var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(showAll ? resources : Array(resources.prefix(6))) { resource in
                    Link(destination: resource.url) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(resource.title).dboardFont(size: 12, weight: .medium).lineLimit(2)
                                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 6) {
                                Text(resource.url.host ?? "资料").lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                            }.dboardFont(size: 10).foregroundStyle(theme.current.textSecondary)
                        }.padding(12).frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                            .workspaceSurface(radius: 10).contentShape(RoundedRectangle(cornerRadius: 10))
                    }.demandButtonStyle(.plain).demandKeyboardID("try-resource-" + resource.id)
                        .accessibilityLabel(resource.title + "，" + resource.source)
                }
            }
            if resources.count > 6 {
                Button(showAll ? "收起" : "全部 \(resources.count) 项资料") {
                    withAnimation(TryMotion.animation(reduceMotion)) { showAll.toggle() }
                }.demandButtonStyle(TryControlStyle()).dboardFont(size: 11).demandKeyboardID(showAll ? "try-resources-collapse" : "try-resources-all")
            }
        }
    }
}
