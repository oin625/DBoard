// LogTemplate.swift — 日志搜索模板: 固定关键词 + {动态槽位} 一键带入
import Foundation

struct LogSearchTemplate: Codable, Identifiable {
    let name: String
    var icon: String? = nil
    var app: String? = nil          // 可空 = 沿用面板当前选择
    var env: String? = nil          // "prod" / "pre"; 可空 = 沿用当前
    var query: String               // 关键词以空格分隔; {名称} 或 {名称:输入提示} 为动态槽位
    var id: String { name }

    /// 解析出的动态槽位: (名称, 输入提示)
    var slots: [(name: String, prompt: String)] {
        var out: [(String, String)] = []
        let re = try? NSRegularExpression(pattern: "\\{([^}:]+)(?::([^}]*))?\\}")
        guard let re else { return out }
        let ns = query as NSString
        re.enumerateMatches(in: query, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges >= 2 else { return }
            let name = ns.substring(with: m.range(at: 1))
            let prompt = m.numberOfRanges >= 3 && m.range(at: 2).location != NSNotFound
                ? ns.substring(with: m.range(at: 2)) : "输入\(name)"
            out.append((name, prompt))
        }
        return out
    }

    /// 用输入值填槽 → 拆成关键词数组(空格分词)
    func expand(values: [String]) -> [String] {
        var text = query
        var idx = values.startIndex
        let re = try? NSRegularExpression(pattern: "\\{[^}]+\\}")
        if let re {
            let ns = NSMutableString(string: text)
            var offset = 0
            let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length - offset))
            for m in matches {
                let len = m.range.length
                let val = idx < values.count ? values[idx].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                idx += 1
                ns.replaceCharacters(in: NSRange(location: m.range.location - offset, length: len), with: " \(val) ")
                offset += len - (val.count + 2)
            }
            text = ns as String
        }
        return text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init).filter { !$0.isEmpty }
    }
}

enum LogTemplateStore {
    static let path = NSString(string: "~/.config/dboard/log-templates.json").expandingTildeInPath

    /// 内置模板兜底; 文件里的同名模板优先
    static let builtin: [LogSearchTemplate] = [
        LogSearchTemplate(name: "车点点查券", icon: "qrcode.viewfinder",
                          query: "API 车点点 {券码:粘贴券码}"),
    ]

    static func load() -> [LogSearchTemplate] {
        var file: [LogSearchTemplate] = []
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let list = try? JSONDecoder().decode([LogSearchTemplate].self, from: data) {
            file = list
        }
        let names = Set(file.map(\.name))
        return file + builtin.filter { !names.contains($0.name) }
    }

    static func save(_ template: LogSearchTemplate) -> String? {
        var list = load().filter { $0.name != template.name }
        list.append(template)
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(list).write(to: URL(fileURLWithPath: path))
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
