import Foundation
import AppKit
import SwiftUI

enum DemandKind: String, Codable, CaseIterable {
    case development = "开发需求"
    case incident = "线上排查"

    var idPrefix: String { self == .incident ? "P" : "D" }
    var counterKey: String { self == .incident ? "dboard.lastPID" : "dboard.lastDID" }
}

struct IncidentClosure: Codable, Equatable {
    enum Outcome: String, Codable, CaseIterable {
        case resolved = "已处理"
        case handedOff = "已定位并交接"
        case stopped = "结束本次排查，原因未定"
    }
    let outcome: Outcome
    let summary: String
    let closed_at: String
    static let prefix = "<!-- dboard-incident-closure:v1:"
    var isValid: Bool { !summary.trimmed.isEmpty && !closed_at.isEmpty && !summary.contains("\0") }

    static func read(_ block: [String]) throws -> Self? {
        let rows = block.filter { $0.hasPrefix(prefix) }
        guard rows.count <= 1 else { throw IncidentError.invalid }
        guard let row = rows.first else { return nil }
        guard row.hasSuffix(" -->"),
              let data = Data(base64Encoded: String(row.dropFirst(prefix.count).dropLast(4))),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { throw IncidentError.invalid }
        return value
    }
}

enum IncidentError: LocalizedError {
    case invalid
    var errorDescription: String? { "排查类型或完结信息无法读取，原数据保留；请核对后重试。" }
}

enum DemandIncident {
    static func kind(_ block: [String]) throws -> DemandKind {
        let rows = block.filter { $0.hasPrefix("- **类型**") }
        guard rows.count <= 1 else { throw IncidentError.invalid }
        guard let row = rows.first else { return .development }
        let raw = row.replacingOccurrences(of: #"^- \*\*类型\*\*\s*[：:]?\s*"#, with: "", options: .regularExpression)
        guard let value = DemandKind(rawValue: raw.trimmed) else { throw IncidentError.invalid }
        return value
    }
}

extension DItem {
    var isIncident: Bool { kind == .incident }
}

struct DemandKindBadge: View {
    let item: DItem
    var body: some View {
        if item.isIncident {
            Label("线上排查", systemImage: "magnifyingglass")
                .dboardFont(size: 10, weight: .medium).foregroundStyle(.orange)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

extension DItemStore {
    /// Closure remains in the local board, so the full case is available to any AI and offline search.
    static func closeIncident(id: String, expected: [String], outcome: IncidentClosure.Outcome,
                              summary: String, at url: URL? = nil) -> Bool {
        let closure = IncidentClosure(outcome: outcome, summary: summary.trimmed,
                                      closed_at: ISO8601DateFormatter().string(from: Date()))
        guard closure.isValid else { return false }
        return mutate(at: url) { lines in
            guard let range = blockRange(lines, id: id), Array(lines[range]) == expected,
                  let item = CacheParser.parse(content: lines.joined(separator: "\n")).items.first(where: { $0.id == id }),
                  item.isIncident, item.status != .completed, DemandCompletionGate.localIssue(item) == nil else { return false }
            var block = Array(lines[range])
            do {
                _ = try IncidentClosure.read(block)
                let bytes = try JSONEncoder().encode(closure)
                block.removeAll { $0.hasPrefix(IncidentClosure.prefix) }
                block.append(IncidentClosure.prefix + bytes.base64EncodedString() + " -->")
                for state in [ItemStatus.pending, .inProgress, .suspended] {
                    block[0] = block[0].replacingOccurrences(of: state.rawValue, with: ItemStatus.completed.rawValue)
                }
                guard let entry = DemandProgress.entry(date: today(), summary: "本次排查已完结：\(outcome.rawValue)。",
                                                       details: closure.summary) else { return false }
                if let index = block.firstIndex(where: { $0.hasPrefix("- **进度**") }) {
                    var end = index + 1
                    while end < block.count && block[end].hasPrefix("    ") { end += 1 }
                    block.insert(contentsOf: entry, at: end)
                } else { block.append(contentsOf: ["- **进度**："] + entry) }
                lines.replaceSubrange(range, with: block)
                return true
            } catch { return false }
        }
    }

    static func reopenIncident(id: String, expected: [String], at url: URL? = nil) -> Bool {
        mutate(at: url) { lines in
            guard let range = blockRange(lines, id: id), Array(lines[range]) == expected,
                  let item = CacheParser.parse(content: lines.joined(separator: "\n")).items.first(where: { $0.id == id }),
                  item.isIncident, item.status == .completed, item.incidentReadError == nil else { return false }
            lines[range.lowerBound] = lines[range.lowerBound].replacingOccurrences(of: ItemStatus.completed.rawValue,
                                                                                 with: ItemStatus.inProgress.rawValue)
            return true
        }
    }
}

extension DBoardViewModel {
    func beginNewIncidentDraft() {
        if let current = newItemDraft, current.hasUserInput {
            beginNewItemDraft()
            if current.effectiveKind != .incident { showFeedback("已打开已有草稿；可在类型中切换为线上排查。") }
            return
        }
        beginNewItemDraft(kind: .incident)
    }

    func finishIncident(_ item: DItem, original: [String]) {
        let alert = NSAlert()
        alert.messageText = "完结 \(item.id)「\(item.displayTitle)」？"
        alert.informativeText = "选择本次结果，留一句完结说明。完整记录保留在「已完成」，可恢复继续排查。"
        alert.addButton(withTitle: "完结排查"); alert.addButton(withTitle: "取消")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 105))
        let outcome = NSPopUpButton(frame: NSRect(x: 0, y: 74, width: 380, height: 26))
        outcome.addItems(withTitles: IncidentClosure.Outcome.allCases.map(\.rawValue))
        let note = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 64))
        note.placeholderString = "已处理什么、交给谁，或为什么结束本次排查"
        note.maximumNumberOfLines = 3; note.lineBreakMode = .byWordWrapping
        accessory.addSubview(outcome); accessory.addSubview(note); alert.accessoryView = accessory
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            guard !note.stringValue.trimmed.isEmpty else {
                alert.informativeText = "请留一句完结说明，再确认结束；输入内容会保留。"
                continue
            }
            guard let value = IncidentClosure.Outcome(rawValue: outcome.titleOfSelectedItem ?? "") else { return }
            markSelfWrite()
            guard afterWrite(DItemStore.closeIncident(id: item.id, expected: original, outcome: value, summary: note.stringValue),
                             fail: "排查或清单已变化，未完结；请重新核对。",
                             success: "排查已完结，完整记录保留在「已完成」。") else { return }
            showDemands(.completed); selectedID = item.id; expandedIDs.insert(item.id)
            return
        }
    }

    func reopenIncident(_ item: DItem) {
        guard let original = DItemStore.blockText(id: item.id) else { flash("排查记录无法读取"); return }
        if afterWrite(DItemStore.reopenIncident(id: item.id, expected: original), fail: "记录已变化，未恢复排查",
                      success: "已恢复排查，原结论和历史仍保留。") { focusItem(item.id) }
    }
}

struct IncidentResultView: View {
    let item: DItem
    var body: some View {
        if let closure = item.incidentClosure, item.status == .completed {
            VStack(alignment: .leading, spacing: 5) {
                Label(closure.outcome.rawValue, systemImage: "checkmark.circle")
                    .dboardFont(size: 12, weight: .medium).foregroundStyle(.green)
                Text(closure.summary).dboardFont(size: 12).textSelection(.enabled)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.green.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        }
        if let error = item.incidentReadError { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
    }
}
