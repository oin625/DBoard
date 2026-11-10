import Foundation
import CryptoKit

struct TodoOrigin: Equatable {
    let date: String
    var lines: [String]
    let occurrence: Int
    var persistentID: String? {
        guard let line = lines.first,
              let range = line.range(of: #"<!-- todo:[0-9A-Fa-f-]{36} -->"#, options: .regularExpression) else { return nil }
        let value = String(line[range]).replacingOccurrences(of: "<!-- todo:", with: "").replacingOccurrences(of: " -->", with: "")
        return UUID(uuidString: value)?.uuidString
    }
    var id: String {
        persistentID ?? "legacy:\(date):\(SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()):\(occurrence)"
    }
}

/// 旧记录必须按原日期 + 完整行快照唯一命中；不猜相似文本，不覆盖刷新前的旧草稿。
enum TodoStore {
    enum Change { case toggle, edit(String), note(String), delete }
    struct Removal {
        let origin: TodoOrigin
        let lines: [String]
    }
    private struct Record { let date: String; let range: Range<Int> }
    private static func records(_ lines: [String]) -> [Record] {
        var inside = false, date = "", result: [Record] = [], i = 0
        while i < lines.count {
            let t = lines[i].trimmed
            if t.hasPrefix("## ") { inside = t.hasPrefix("## 📝"); date = "" }
            if inside && t.hasPrefix("### ") { date = String(t.dropFirst(4)).trimmed }
            if inside && !date.isEmpty && ["- [ ]", "- [x]", "- [X]"].contains(where: t.hasPrefix) {
                var end = i + 1
                while end < lines.count && lines[end].trimmed.hasPrefix("> 💬") { end += 1 }
                result.append(Record(date: date, range: i..<end)); i = end
            } else { i += 1 }
        }
        return result
    }

    static func parse(_ row: String, date: String, occurrence: Int) -> TodoItem {
        let completed = row.trimmed.hasPrefix("- [x]") || row.trimmed.hasPrefix("- [X]")
        var body = String(row.trimmed.dropFirst(5)).trimmed
        body = body.replacingOccurrences(of: #"\s*<!-- todo:[0-9A-Fa-f-]{36} -->"#, with: "", options: .regularExpression)
        var time: String?
        if let r = body.range(of: #"✅\s*(?:[0-9]{1,2}\.[0-9]{1,2}\s+)?[0-9]{1,2}:[0-9]{2}"#, options: .regularExpression) {
            time = String(body[r]).replacingOccurrences(of: "✅", with: "").trimmed
            body.removeSubrange(r)
        }
        var note: String?
        if let r = body.range(of: "💬") {
            note = String(body[r.upperBound...]).trimmed
            body = String(body[..<r.lowerBound])
        }
        var link: String?
        if let r = body.range(of: #"`?→\s*[DP][0-9]{3,}`?"#, options: .regularExpression) {
            link = String(body[r]).replacingOccurrences(of: #"[^DP0-9]"#, with: "", options: .regularExpression)
            body.removeSubrange(r)
        }
        return TodoItem(text: body.trimmed, isCompleted: completed, linkedDItem: link,
            note: note?.isEmpty == false ? note : nil,
            origin: TodoOrigin(date: date, lines: [row], occurrence: occurrence), completedAt: time)
    }

    private static func read(_ url: URL?) -> String? {
        if let url { return try? String(contentsOf: url, encoding: .utf8) }
        return CacheFile.read()
    }
    private static func write(_ lines: [String], at url: URL?) -> Bool {
        let content = lines.joined(separator: "\n")
        if let url {
            do { try content.write(to: url, atomically: true, encoding: .utf8); return true }
            catch { return false }
        }
        return CacheFile.write(content)
    }

    static func change(_ item: TodoItem, _ change: Change, at url: URL? = nil) -> (ok: Bool, removal: Removal?) {
        CacheFile.withLock(at: url) { changeLocked(item, change, at: url) } ?? (false, nil)
    }

    private static func changeLocked(_ item: TodoItem, _ change: Change, at url: URL?) -> (ok: Bool, removal: Removal?) {
        guard let origin = item.origin, let content = read(url) else { return (false, nil) }
        var lines = content.components(separatedBy: "\n")
        let matches = records(lines).filter { record in
            let candidate = TodoOrigin(date: record.date, lines: Array(lines[record.range]), occurrence: 0)
            if let id = origin.persistentID { return candidate.persistentID == id }
            return candidate.date == origin.date && candidate.lines == origin.lines
        }
        guard matches.count == 1, let record = matches.first,
              record.date == origin.date, Array(lines[record.range]) == origin.lines else { return (false, nil) }
        var updated = item
        switch change {
        case .delete:
            lines.removeSubrange(record.range)
            return (write(lines, at: url), Removal(origin: origin, lines: origin.lines))
        case .toggle:
            updated.isCompleted.toggle()
            let f = DateFormatter(); f.dateFormat = origin.date == DemandDates.today() ? "HH:mm" : "M.d HH:mm"
            updated.completedAt = updated.isCompleted ? f.string(from: Date()) : nil
        case .edit(let text):
            guard !text.trimmed.isEmpty, !text.contains("\n"), !text.contains("\r") else { return (false, nil) }
            updated.text = text.trimmed
        case .note(let note):
            guard !note.contains("\n"), !note.contains("\r") else { return (false, nil) }
            updated.note = note.trimmed.isEmpty ? nil : note.trimmed
        }
        var row = "- [\(updated.isCompleted ? "x" : " ")] \(updated.text)"
        if let link = updated.linkedDItem { row += " `→ \(link)`" }
        if let time = updated.completedAt { row += " ✅\(time)" }
        if let note = updated.note { row += " 💬\(note)" }
        row += " <!-- todo:\(origin.persistentID ?? UUID().uuidString) -->"
        lines.replaceSubrange(record.range, with: [row])
        return (write(lines, at: url), nil)
    }

    static func add(_ text: String, at url: URL? = nil, date: String = DemandDates.today()) -> Bool {
        CacheFile.withLock(at: url) { addLocked(text, at: url, date: date) } ?? false
    }

    private static func addLocked(_ text: String, at url: URL?, date: String) -> Bool {
        guard !text.trimmed.isEmpty, !text.contains("\n"), !text.contains("\r"), let content = read(url) else { return false }
        var lines = content.components(separatedBy: "\n")
        let row = "- [ ] \(text.trimmed) <!-- todo:\(UUID().uuidString) -->"
        if let section = lines.firstIndex(where: { $0.trimmed.hasPrefix("## 📝") }) {
            let end = lines.indices.first { $0 > section && lines[$0].trimmed.hasPrefix("## ") } ?? lines.count
            let dates = (section..<end).filter { lines[$0].trimmed == "### \(date)" }
            guard dates.count <= 1 else { return false }
            if let header = dates.first {
                let next = ((header + 1)..<end).first { lines[$0].trimmed.hasPrefix("### ") } ?? end
                lines.insert(row, at: next)
            } else { lines.insert(contentsOf: ["", "### \(date)", row, ""], at: end) }
        } else { lines.append(contentsOf: ["", "## 📝 零碎事项（日清日结）", "", "### \(date)", row]) }
        return write(lines, at: url)
    }

    static func restore(_ removal: Removal, at url: URL? = nil) -> Bool {
        CacheFile.withLock(at: url) { restoreLocked(removal, at: url) } ?? false
    }

    private static func restoreLocked(_ removal: Removal, at url: URL?) -> Bool {
        guard let content = read(url) else { return false }
        var lines = content.components(separatedBy: "\n")
        let existing = records(lines)
        guard !existing.contains(where: {
            let origin = TodoOrigin(date: $0.date, lines: Array(lines[$0.range]), occurrence: 0)
            if let id = removal.origin.persistentID { return origin.persistentID == id }
            return origin.date == removal.origin.date && origin.lines == removal.lines
        }) else { return false }
        guard let section = lines.firstIndex(where: { $0.trimmed.hasPrefix("## 📝") }) else { return false }
        let end = lines.indices.first { $0 > section && lines[$0].trimmed.hasPrefix("## ") } ?? lines.count
        let headers = (section..<end).filter { lines[$0].trimmed == "### \(removal.origin.date)" }
        guard headers.count <= 1 else { return false }
        if let header = headers.first { lines.insert(contentsOf: removal.lines, at: header + 1) }
        else { lines.insert(contentsOf: ["", "### \(removal.origin.date)"] + removal.lines, at: end) }
        return write(lines, at: url)
    }
}
