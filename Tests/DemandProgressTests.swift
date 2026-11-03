import XCTest
@testable import DBoard

final class DemandProgressTests: XCTestCase {
    func testSummaryDetailsRoundTripPreservesNestedMarkdownAndOtherFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cache.md")
        try """
        ## 🟡 重要
        ### D014【fixture】接口 #进行中
        - **描述**：原描述
        - **进度**：
            - 10.30: 旧记录
        ### D015【fixture】另一张 #待开始
        - **描述**：不要修改
        """.write(to: file, atomically: true, encoding: .utf8)
        let detail = "验证：回归通过。\n\n### D999 嵌套标题\n- **描述**：明细字段\n    - 11.2: 明细代码日期"
        XCTAssertTrue(DItemStore.appendProgress(id: "D014", text: "接口完成，待验收。", details: detail, at: file))
        let item = try DItemStore.currentItem(id: "D014", at: file)
        XCTAssertEqual(item.title, "原描述")
        XCTAssertEqual(item.milestones.count, 2)
        XCTAssertEqual(item.milestones.last?.summary, "接口完成，待验收。")
        XCTAssertEqual(item.milestones.last?.detailText, detail)
        XCTAssertTrue(item.milestones.last?.fullContent.contains(detail) == true)
        XCTAssertEqual(try DItemStore.currentItem(id: "D015", at: file).title, "不要修改")
        var draft = DItemDraft(from: item)
        draft.desc = "新描述"
        XCTAssertTrue(DItemStore.save(draft, original: item, at: file))
        XCTAssertEqual(try DItemStore.currentItem(id: "D014", at: file).milestones.last?.detailText, detail)
        let block = try XCTUnwrap(DItemStore.blockRange(try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n"), id: "D014"))
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertTrue(try DemandVersion.baseline(item: item, block: Array(lines[block])).contains(detail))
    }

    func testLegacySummaryDoesNotLoseFullText() {
        let text = "功能已完成；" + String(repeating: "详细排查过程", count: 50)
        let record = Milestone(date: "11.2", content: text)
        XCTAssertEqual(record.summary, "功能已完成。")
        XCTAssertEqual(record.detailText, text)
        XCTAssertEqual(record.fullContent, text)
        XCTAssertEqual(Milestone(date: "11.2", content: "待联调").detailText, "")
    }

    func testOverlongAndMultilineSummaryCannotBecomeCacheStructure() {
        XCTAssertNil(DemandProgress.entry(date: "11.2", summary: String(repeating: "长", count: 121)))
        XCTAssertNil(DemandProgress.entry(date: "11.2", summary: "第一行\n### D999 注入"))
    }

    func testRemoteProjectionKeepsOverviewAndProgressButNotPrivateContext() throws {
        let lines = ["### D014【fixture】接口 #进行中",
                     "- **提示词**：", "    ## 资料", "    保留咒言",
                     "- **进度**：", "    - 11.2: 接口完成，待验收。",
                     "        明细：", "        私有数据", "        ",
                     "        - 11.2: 嵌套日期", "        ### D999 嵌套标题",
                     DemandVersion.prefix + "encoded-history -->", "- **分支**：feature/a"]
        let remote = try DemandProgress.remoteLines(lines).joined(separator: "\n")
        XCTAssertTrue(remote.contains("接口完成，待验收。"))
        XCTAssertFalse(remote.contains("- **提示词**"))
        XCTAssertFalse(remote.contains("私有数据"))
        XCTAssertFalse(remote.contains("feature/a"))
        XCTAssertFalse(remote.contains("D999"))
    }

    func testLocalArchiveKeepsDetailsWhenMergedWithSummaryOnlyRemote() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = ArchiveJournal(url: directory.appendingPathComponent("journal.json"))
        let block = ["### D014【fixture】接口 #已完成 ✅2026-11-02",
                     "- **进度**：", "    - 11.2: 已验收。",
                     "        明细：", "        完整验收记录"]
        XCTAssertTrue(journal.save(.init(id: "D014", original: block, archived: block,
                                         state: .removed, createdAt: Date())))
        let remote = try DemandArchive.parse(try DemandProgress.remoteLines(block).joined(separator: "\n"))
        let merged = DemandArchive.merged(remote, journal: journal)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.item.milestones.first?.detailText, "完整验收记录")
    }
}
