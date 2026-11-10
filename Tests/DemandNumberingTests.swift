import XCTest
import Foundation
@testable import DBoard

final class DemandNumberingTests: XCTestCase {
    func testBusinessTraceAndNestedHistoryDoNotAllocateDemandNumbers() {
        let current = """
        ## 🔴 重要且紧急
        ### D019【ultra】当前需求 #进行中
        - **描述**：流水号2611052016395B0C07D548EFC8DBBEC2
        - **提示词**：
            ### D999【示例】不是实际需求 #已完成
        - **进度**：
            - 11.6: 等待反馈。
                明细：
                旧排查提到 D900，日志返回 D888
        <!-- metadata:D777 -->
        """
        let archive = """
        ### D018【tesla】归档需求 #已完成
        - **描述**：日志中的 D594 不属于需求编号
        """
        XCTAssertEqual(DemandNumbering.nextID(contents: [current, archive], reserving: [], lastAssigned: 19), "D020")
        XCTAssertEqual(DemandNumbering.reservedIDs(in: current), ["D019"])
        XCTAssertNil(DemandNumbering.number("order-D999"))
        XCTAssertNil(DemandNumbering.number("D548EFC8"))
        XCTAssertEqual(DemandNumbering.nextID(contents: [current], reserving: ["D085"], lastAssigned: 19), "D086")
        XCTAssertEqual(DemandNumbering.nextID(contents: [current], reserving: [], lastAssigned: 120), "D121",
                       "Previously allocated numbers remain reserved after deletion.")
    }

    func testIncidentAndDevelopmentCountersAreIndependent() {
        let content = "## 🔴\n### D019【】开发 #进行中\n### P001【】排查 #进行中\n- **类型**：线上排查\n- **描述**：流水 D548EFC P900ABC\n"
        XCTAssertEqual(DemandNumbering.nextID(contents: [content], reserving: [], lastAssigned: 19), "D020")
        XCTAssertEqual(DemandNumbering.nextID(contents: [content], reserving: [], lastAssigned: 1, kind: .incident), "P002")
        XCTAssertEqual(DemandNumbering.nextID(contents: [content], reserving: ["D080"], lastAssigned: 1, kind: .incident), "P002")
        XCTAssertEqual(DemandNumbering.nextID(contents: [], reserving: [], lastAssigned: 0, kind: .incident), "P001")
    }

    func testStructuredTodoAndPreviousVersionsReserveRealIdentities() throws {
        let version = DemandVersion(number: 2, parentID: "D050", rootID: "D040", parentTitle: "上一版",
            sourceRevision: String(repeating: "a", count: 64), background: "历史流水 D999 不是编号",
            repositories: [])
        let content = """
        ## 🟡 重要不紧急
        ### D020【ultra】第二版 #进行中
        \(try version.stored)
        ## 📝 今日零碎
        ### 2020-01-01
        - [ ] 跟进上线 → D065
        - [ ] 补充排查线索 → P007
        """
        XCTAssertEqual(DemandNumbering.reservedIDs(in: content), ["D020", "D050", "D040", "D065", "P007"])
        XCTAssertEqual(DemandNumbering.nextID(contents: [content], reserving: [], lastAssigned: 20), "D066")
        XCTAssertEqual(DemandNumbering.nextID(contents: [content], reserving: [], lastAssigned: 0, kind: .incident), "P008")
    }

    func testDefaultAllocatorUsesPendingArchiveAndDoesNotReserveAPreview() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardNumbering-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = directory.appendingPathComponent("cache.md")
        let archive = directory.appendingPathComponent("archive.md")
        let journalURL = directory.appendingPathComponent("journal.json")
        try "## 🟡\n### D019【】现有需求 #进行中\n- **描述**：订单D548EFC\n".write(to: cache, atomically: true, encoding: .utf8)
        try "### D018【】已完成需求 #已完成\n".write(to: archive, atomically: true, encoding: .utf8)
        let suite = "DBoardNumberingTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(19, forKey: "dboard.lastDID")
        func next() -> String {
            DItemStore.nextID(at: cache, archiveURL: archive, journalURL: journalURL, defaults: defaults)
        }
        XCTAssertEqual(next(), "D020")
        XCTAssertEqual(next(), "D020")
        XCTAssertEqual(defaults.integer(forKey: "dboard.lastDID"), 19)
        let journal = ArchiveJournal(url: journalURL)
        let block = ["### D030【】归档提交中 #已完成"]
        XCTAssertTrue(journal.save(.init(id: "D030", original: block, archived: block,
                                       state: .submitted, createdAt: Date())))
        XCTAssertEqual(next(), "D031")
    }
}
