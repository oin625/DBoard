import XCTest
@testable import DBoard

final class DemandOverviewTests: XCTestCase {
    private let base = "## 🟡\n### D014【ultra】锁券改造 #进行中\n- **概括**：拆出锁券接口。\n- **进度**：\n    - 11.3: 接口完成，待验收。\n"

    func testSharedSwiftAndPythonProjectionFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Fixtures/dboard-overview.json"))
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        for fixture in fixtures {
            XCTAssertEqual(try DemandOverview.render(try XCTUnwrap(fixture["source"])), fixture["expected"], fixture["name"] ?? "")
        }
    }

    func testLocalOnlyEditsDoNotInvalidateCloudReceiptButVisibleChangesDo() throws {
        let receipt = DemandOverview.receiptPrefix + (try DemandOverview.hash(base)) + " -->\n" + base
        for hidden in ["- **分支**：feature/another\n", "- **关联群聊**：{}\n",
                       "- **提示词**：\n    新咒言\n", "## 📝\n### 2026-11-03\n- [ ] 本地事项\n"] {
            XCTAssertTrue(DemandOverview.matchesReceipt(receipt + hidden))
            XCTAssertTrue(ContentRevision.matchesSyncReceipt(receipt + hidden))
        }
        XCTAssertFalse(ContentRevision.matchesSyncReceipt(receipt.replacingOccurrences(of: "待验收", with: "已验收")))
        XCTAssertFalse(ContentRevision.matchesSyncReceipt(receipt.replacingOccurrences(of: "#进行中", with: "#挂起")))
    }

    func testNewChangeShowsPendingWorkWithoutPublishingTheSpell() throws {
        let change = DemandChange(id: "C001", createdAt: Date(timeIntervalSince1970: 1793692800),
            intent: "不可上传的变更原文与图片")
        var block = Array(base.components(separatedBy: "\n").dropFirst())
        try DemandChanges.set(&block, changes: [change])
        let source = "## 🟡\n" + block.joined(separator: "\n")
        let text = try DemandOverview.render(source)
        XCTAssertTrue(text.contains("新增 1 项变更待处理"))
        XCTAssertFalse(text.contains(change.intent))
        XCTAssertNotEqual(try DemandOverview.hash(source), try DemandOverview.hash(base))
        let recorded = source.replacingOccurrences(of: "接口完成，待验收。", with: "[C001] 新要求已实现，待验收。")
        XCTAssertFalse(try DemandOverview.render(recorded).contains("变更待处理"))
    }

    func testDuplicateOrMalformedDemandCannotOverwriteCloudWithAnEmptyOverview() {
        XCTAssertThrowsError(try DemandOverview.render(base + base))
        XCTAssertThrowsError(try DemandOverview.render(base.replacingOccurrences(of: "#进行中", with: "#未知")))
        XCTAssertThrowsError(try DemandOverview.render(base + "- **概括**：重复字段\n"))
    }
}
