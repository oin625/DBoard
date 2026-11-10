import Foundation
import CryptoKit

/// Execution milestones are AI observations, separate from the user's completion/archival state.
struct DemandExecution: Codable, Equatable {
    enum Stage: String, Codable, CaseIterable {
        case developing
        case developmentComplete = "development-complete"
        case debugPageReady = "debug-page-ready"
        case testingPassed = "testing-passed"

        var label: String {
            switch self {
            case .developing: return "开发待补齐"
            case .developmentComplete: return "开发已核验 · 待建调试页"
            case .debugPageReady: return "调试页已就绪 · 待联调"
            case .testingPassed: return "AI试调已完成 · 待人工联调"
            }
        }
    }
    let stage: Stage
    let scopeHash: String
    let debugPage: String?
    let debugURL: String?
    let updatedAt: String
    var code: [DemandCodeSnapshot]? = nil
    static let prefix = "<!-- dboard-execution:v1:"
    static let suffix = " -->"

    enum CodingKeys: String, CodingKey {
        case stage, scopeHash = "scope_hash", debugPage = "debug_page", debugURL = "debug_url", updatedAt = "updated_at", code
    }
    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "调试进度无法读取，请检查数据后重试" }
    }

    static func validPage(_ value: String) -> Bool {
        value.range(of: #"^/[A-Za-z0-9][A-Za-z0-9/_-]*$"#, options: .regularExpression) != nil &&
            !value.contains("//")
    }
    static func validURL(_ value: String, page: String) -> Bool {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 }),
              let parts = URLComponents(string: value), ["https", "http"].contains(parts.scheme ?? ""),
              !(parts.host ?? "").isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil || (1...65535).contains(parts.port!) else { return false }
        return parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            page.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    var isValid: Bool {
        guard scopeHash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              !updatedAt.isEmpty, !updatedAt.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        if let code, code.isEmpty || !code.allSatisfy(\.isValid) || Set(code.map(\.path)).count != code.count { return false }
        if let page = debugPage, !Self.validPage(page) { return false }
        if stage == .debugPageReady || stage == .testingPassed, debugPage == nil { return false }
        if let url = debugURL {
            guard let page = debugPage, Self.validURL(url, page: page) else { return false }
        }
        return true
    }
    static func read(_ block: [String]) throws -> Self? {
        let records = block.filter { $0.hasPrefix(prefix) }
        guard records.count <= 1 else { throw ReadError.invalid }
        guard let record = records.first else { return nil }
        guard record.hasSuffix(suffix),
              let bytes = Data(base64Encoded: String(record.dropFirst(prefix.count).dropLast(suffix.count))),
              let value = try? JSONDecoder().decode(Self.self, from: bytes), value.isValid else { throw ReadError.invalid }
        return value
    }

    /// Hash requirements only: execution notes, Git bookkeeping, dates and personal state do not invalidate results.
    static func scopeHash(_ block: [String]) -> String {
        var header = block.first ?? ""
        for status in [ItemStatus.pending, .inProgress, .completed, .suspended] { header = header.replacingOccurrences(of: status.rawValue, with: "") }
        header = header.replacingOccurrences(of: #"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})"#,
            with: "", options: .regularExpression)
        header = header.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
        var fields: [String: String] = [:]
        var i = 1
        while i < block.count {
            let line = block[i]
            if let keyEnd = line.range(of: "**", range: line.index(line.startIndex, offsetBy: min(4, line.count))..<line.endIndex),
               line.hasPrefix("- **") {
                let key = String(line[line.index(line.startIndex, offsetBy: 4)..<keyEnd.lowerBound])
                let inline = String(line[keyEnd.upperBound...])
                    .replacingOccurrences(of: #"^\s*[：:]?\s*"#, with: "", options: .regularExpression)
                var values = inline.isEmpty ? [] : [inline]
                i += 1
                while i < block.count && block[i].hasPrefix("    ") {
                    values.append(String(block[i].dropFirst(4))); i += 1
                }
                fields[key] = values.joined(separator: "\n")
            } else { i += 1 }
        }
        let keys = ["项目", "描述", "提示词", "变更咒言", "需求流", "关联群聊"]
        var values = [header] + keys.map { fields[$0] ?? "" } +
            block.filter { $0.hasPrefix(DemandVersion.prefix) }
        if let kind = fields["类型"], kind != DemandKind.development.rawValue { values.append("kind=" + kind) }
        return SHA256.hash(data: Data(values.joined(separator: "\0").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

extension DItem {
    var executionScopeNeedsReview: Bool {
        guard let execution else { return false }
        return execution.scopeHash != executionScope
    }
    var executionReviewReason: String? {
        guard let execution else { return nil }
        if executionScopeNeedsReview { return "需求已变更 · 需重新核验" }
        if execution.stage == .developing { return nil }
        if execution.code == nil { return "旧结论未绑定代码 · 需重新核验" }
        guard let review = executionCodeReview else { return "代码版本待核对" }
        return review.needsReview ? review.reason ?? "代码已变更 · 需重新核验" : nil
    }
    var executionNeedsReview: Bool { executionReviewReason != nil }
    var executionLabel: String {
        if debugPageReadError != nil { return "调试页设置无法读取" }
        if executionReadError != nil { return "调试记录无法读取" }
        if let reason = executionReviewReason { return reason }
        if debugPageNotNeeded { return "无需调试页" }
        if execution?.stage == .developmentComplete, execution?.debugPage != nil { return "开发已核验 · 调试页待同步" }
        return execution?.stage.label ?? "尚未核验开发完成情况"
    }
}
