import Foundation

/// A user's opt-out is separate from AI observations and does not erase existing pages or test evidence.
enum DemandDebugPagePolicy {
    static let prefix = "<!-- dboard-debug-page:v1:"
    static let notNeededLine = prefix + "not-needed -->"

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "调试页设置无法读取，请检查数据后重试" }
    }

    static func read(_ block: [String]) throws -> Bool {
        let records = block.filter { $0.hasPrefix(prefix) }
        guard records.count <= 1, records.allSatisfy({ $0 == notNeededLine }) else { throw ReadError.invalid }
        return !records.isEmpty
    }

    static func set(_ block: inout [String], notNeeded: Bool) throws {
        _ = try read(block)
        block.removeAll { $0.hasPrefix(prefix) }
        if notNeeded { block.insert(notNeededLine, at: min(1, block.count)) }
    }
}
