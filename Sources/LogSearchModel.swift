import SwiftUI
import Cocoa

// MARK: - 日志面板数据模型（LogSearchViewModel 重构拆分自 LogSearch.swift, 逻辑零改动）

/// 日志内嵌 JSON 块: 解析日志时一次性识别并预格式化。
/// nsRange 是相对 LogEntry.detail 的 UTF-16 偏移, 详情视图据此做芯片, 点击弹出查看窗口。
struct LogJSONBlock: Identifiable, Hashable {
    let id = UUID()
    let raw: String
    let formatted: String
    let nsRange: NSRange

    static func == (l: LogJSONBlock, r: LogJSONBlock) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// 从混杂日志中提取完整 JSON 对象/数组。括号扫描会避开字符串内的括号和转义字符，
    /// 最终仍以 JSONSerialization 校验，避免把普通堆栈或占位符当成 JSON。
    static func extract(from raw: String) -> [LogJSONBlock] {
        var results: [LogJSONBlock] = []
        // 失败路径最坏 O(n²)(截断大 JSON、密集开括号的堆栈行)。提取跑在搜索请求
        // 回调线程上, 给总步数设预算, 超预算带着已提取的块提前返回, 只损失可点击性。
        let stepBudget = min(max(raw.utf16.count * 20, 200_000), 4_000_000)
        var steps = 0
        var index = raw.startIndex
        while index < raw.endIndex {
            let opening = raw[index]
            guard opening == "{" || opening == "[" else {
                index = raw.index(after: index)
                continue
            }
            steps += 1
            if steps > stepBudget { return results }
            var stack: [Character] = [opening == "{" ? "}" : "]"]
            var cursor = raw.index(after: index)
            var insideString = false
            var escaped = false
            while cursor < raw.endIndex, !stack.isEmpty {
                steps += 1
                if steps > stepBudget { return results }
                let character = raw[cursor]
                if insideString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        insideString = false
                    }
                } else {
                    if character == "\"" {
                        insideString = true
                    } else if character == "{" {
                        stack.append("}")
                    } else if character == "[" {
                        stack.append("]")
                    } else if character == stack.last {
                        stack.removeLast()
                    } else if character == "}" || character == "]" {
                        break
                    }
                }
                cursor = raw.index(after: cursor)
            }
            guard stack.isEmpty else {
                index = raw.index(after: index)
                continue
            }
            let candidate = String(raw[index..<cursor])
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(object),
               let prettyData = try? JSONSerialization.data(
                   withJSONObject: object,
                   options: [.prettyPrinted, .sortedKeys]
               ),
               let pretty = String(data: prettyData, encoding: .utf8) {
                results.append(LogJSONBlock(raw: candidate, formatted: pretty,
                                            nsRange: NSRange(index..<cursor, in: raw)))
                index = cursor
            } else {
                index = raw.index(after: index)
            }
        }
        return results
    }
}

struct LogEntry: Identifiable, Hashable {
    let id = UUID()
    let app: String
    let timestamp: String
    let level: String
    /// 原始日志行(详情全文展示的就是它)
    let detail: String
    /// 解析时预计算(避免滚动/悬停触发的 body 重算每帧做 O(n) 字符串替换+正则):
    /// 折行压扁后的正文 + "巨型行"判定(超长/大JSON/异常栈 → 默认折叠3行)
    var flatText: String = ""
    var isHuge: Bool = false
    let traceId: String?
    let jsonBlocks: [LogJSONBlock]

    /// 级别语义色(DESIGN.md: 只用系统语义色, 不写死 hex)
    var levelColor: Color {
        switch levelKind {
        case .err:  return .red
        case .warn: return .orange
        case .info: return .green          // INFO/DEBUG/未知统一归它
        }
    }
    /// 级别三分类: ERROR / WARN / INFO 三档
    enum LogKind { case err, warn, info }
    var levelKind: LogKind {
        switch level {
        case "ERROR", "FATAL": return .err
        case "WARN":           return .warn
        default:               return .info
        }
    }
    var levelLabel: String {
        switch levelKind {
        case .err:  return "ERROR"
        case .warn: return "WARN"
        case .info: return "INFO"
        }
    }

    static func == (l: LogEntry, r: LogEntry) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// "巨型行"判定, 解析时算一次: 超长文本 / 含超大 JSON 块 / 异常栈。
    /// 只做 O(1)~O(n) 的原生查找, 不用正则(正则在滚动热路径上被验证会卡)。
    static func judgeHuge(_ flat: String, blocks: [LogJSONBlock]) -> Bool {
        let ns = flat as NSString
        if ns.length > 700 { return true }
        for b in blocks where (b.raw as NSString).length > 400 { return true }
        if ns.length > 300,
           ns.range(of: ".java:").location != NSNotFound,
           ns.range(of: " at ").location != NSNotFound { return true }
        return false
    }
}

/// 关键词 tag(对齐 audi kwTags: 可点击禁用、可删除)
struct KWTag: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var disabled = false
}

/// 结果中发现的应用及其在当前页的条数(侧栏应用列表数据源)
struct AppCount: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let count: Int
}

/// 历史查询: 应用 + 关键词组合, 一键重跑(对齐 audi {app, tags})
struct LogHistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var app: String
    var tags: [String]
    var ts = Date()

    init(id: UUID = UUID(), app: String, tags: [String], ts: Date = Date()) {
        self.id = id
        self.app = app
        self.tags = tags
        self.ts = ts
    }

    var dedupKey: String { app + "\u{1F}" + tags.sorted().joined(separator: "|") }
    var tagsLabel: String { tags.isEmpty ? "(无关键词)" : tags.joined(separator: " · ") }
}

// KWTag 启禁切换的函数式帮手(避免 map 里手写可变拷贝)
func KWTagEnable(_ t: KWTag) -> KWTag { var c = t; c.disabled = false; return c }
func KWTagToggle(_ t: KWTag) -> KWTag { var c = t; c.disabled.toggle(); return c }

// MARK: - 可钻取词扫描 (对齐 audi tokens.js 的 word 规则)

/// 扫描文本中「可点击钻取」的 word 区间:
///   - 按空白与括号分块(Java 堆栈的 `Bar(Baz.java:12)` 要能拆成可钻的段);
///     `key:value` 只有 value 段可点
///   - 排除已有 link 区间(JSON 芯片), 避免嵌套点击
///   - 值两端剥常见标点, 防止把 "abc," 原样带进短语查询
///   - 长度限 [2, 100]: 更短是噪音, 更长多是堆栈/URL 段, 点中查询必零命中
enum LogWordTokenizer {
    private static let keyPrefixRegex = try! NSRegularExpression(
        pattern: #"^([A-Za-z_][A-Za-z0-9_.\-]*[:=])(.+)$"#)
    private static let trimSet = CharacterSet(charactersIn:
        ".,;:!?()[]{}<>\"'`|=、。，：；！？（）《》「」")
    private static let whitespaceSet = CharacterSet.whitespacesAndNewlines
    private static let skipValues: Set<String> = ["AND", "OR", "NOT"]

    static func drillRanges(in text: String, excluded: [NSRange]) -> [(range: NSRange, value: String)] {
        let ns = text as NSString
        var results: [(range: NSRange, value: String)] = []
        func overlapsExcluded(_ r: NSRange) -> Bool {
            excluded.contains { NSIntersectionRange($0, r).length > 0 }
        }
        // 代理对半字返回 nil: 视为非边界/非标点, 不切断 chunk(emoji 等)
        func isBoundary(_ c: unichar) -> Bool {
            if c == 0x28 || c == 0x29 { return true }   // '(' ')' 作为分块边界
            guard let scalar = UnicodeScalar(c) else { return false }
            return whitespaceSet.contains(scalar)
        }
        func isTrim(_ c: unichar) -> Bool {
            guard let scalar = UnicodeScalar(c) else { return false }
            return trimSet.contains(scalar)
        }
        var pos = 0
        while pos < ns.length {
            if isBoundary(ns.character(at: pos)) { pos += 1; continue }
            var end = pos
            while end < ns.length, !isBoundary(ns.character(at: end)) { end += 1 }
            var range = NSRange(location: pos, length: end - pos)
            pos = end
            // key:value / key=value → 只取 value 段
            let chunk = ns.substring(with: range)
            let chunkNS = chunk as NSString
            if let m = keyPrefixRegex.firstMatch(
                in: chunk, range: NSRange(location: 0, length: chunkNS.length)),
               m.range(at: 1).location != NSNotFound {
                range.location += m.range(at: 1).length
                range.length -= m.range(at: 1).length
            }
            // 两端剥标点
            while range.length > 0, isTrim(ns.character(at: range.location)) {
                range.location += 1; range.length -= 1
            }
            while range.length > 0, isTrim(ns.character(at: NSMaxRange(range) - 1)) {
                range.length -= 1
            }
            guard range.length >= 2, range.length <= 100 else { continue }
            let value = ns.substring(with: range)
            guard !skipValues.contains(value), !overlapsExcluded(range) else { continue }
            results.append((range, value))
        }
        return results
    }
}
