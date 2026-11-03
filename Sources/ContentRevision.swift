import Foundation
import CryptoKit

/// 时间戳只用于展示；同步一致性看正文 hash，忽略同步元数据行。
enum ContentRevision {
    static func matchesSyncReceipt(_ content: String) -> Bool {
        if content.components(separatedBy: "\n").contains(where: { $0.hasPrefix(DemandOverview.receiptPrefix) }) {
            return DemandOverview.matchesReceipt(content)
        }
        let prefix = "<!-- synced-hash: "
        let suffix = " -->"
        let receipts = content.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
        guard receipts.count == 1, let receipt = receipts.first, receipt.hasSuffix(suffix) else { return false }
        let syncedHash = String(receipt.dropFirst(prefix.count).dropLast(suffix.count))
        return syncedHash == hash(content)
    }

    static func hash(_ content: String) -> String {
        let body = content.components(separatedBy: "\n").filter {
            !$0.hasPrefix("<!-- synced:") && !$0.hasPrefix("<!-- synced-hash:") &&
                !$0.hasPrefix(DemandOverview.receiptPrefix) && !$0.hasPrefix(DemandOverview.nodePrefix)
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
