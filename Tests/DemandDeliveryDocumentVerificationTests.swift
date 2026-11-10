import XCTest
@testable import DBoard

final class DemandDeliveryDocumentVerificationTests: XCTestCase {
    private let expected = """
    # 锁券技术说明

    需求：[R42](https://ai.tmallyc.com/prd/index.html#detail/42) · D014

    ```java
    Result<CddCouponLockRO> lockCode(String voucherSerial, String couponCode);
    ```

    | extData.failureType | 处理 |
    | --- | --- |
    | LOCK_FAILED | 停止后续调用。 |
    | LOCK_RESULT_UNKNOWN | 先核实，勿重试。 |

    失败 `code=-110`，`data=null`；`msg` **完整等于文案**时带过期标记。
    工程 `ultra:merge/pre_1013`；路径 `C:\\work\\ultra`。
    """

    private var exported: String {
        expected.replacingOccurrences(of: "| --- | --- |", with: "|-------------------|---------------|")
            .replacingOccurrences(of: "LOCK_FAILED", with: #"LOCK\_FAILED"#)
            .replacingOccurrences(of: "LOCK_RESULT_UNKNOWN", with: #"LOCK\_RESULT\_UNKNOWN"#)
            .replacingOccurrences(of: "**完整等于文案**", with: #"\*\*完整等于文案\*\*"#)
            .replacingOccurrences(of: "\n\n", with: "\n")
    }

    func testDingtalkEscapingTableRulersAndParagraphSpacingKeepTheSameContent() {
        XCTAssertTrue(DemandDeliveryDocumentVerification.matches(actual: exported, expected: expected))
        XCTAssertTrue(DemandDeliveryDocumentVerification.matches(
            actual: exported.replacingOccurrences(of: "\n", with: "\r\n"), expected: expected))
    }

    func testActualChangesInErrorCodeBranchSignatureAndStatusAreRejected() {
        for text in [
            exported.replacingOccurrences(of: "-110", with: "110"),
            exported.replacingOccurrences(of: "merge/pre_1013", with: "merge/pre1013"),
            exported.replacingOccurrences(of: "String couponCode", with: "String orderNo"),
            exported.replacingOccurrences(of: #"LOCK\_FAILED"#, with: "LOCKFAILED"),
            exported.replacingOccurrences(of: "停止后续调用。", with: ""),
            exported + "\n已验收上线。",
            ""
        ] {
            XCTAssertFalse(DemandDeliveryDocumentVerification.matches(actual: text, expected: expected))
        }
        XCTAssertFalse(DemandDeliveryDocumentVerification.matches(actual: "", expected: " \n "))
    }

    func testInlineAndFencedCodeDoNotLoseLiteralEscapesOrOperators() {
        let source = """
        参数 `LOCK_FAILED`；路径 `C:\\work\\ultra`；返回 `code=-110`。
        ```java
        String value = "\\\\n"; int price = 2 * 3;
        ```
        """
        for text in [
            source.replacingOccurrences(of: "LOCK_FAILED", with: #"LOCK\_FAILED"#),
            source.replacingOccurrences(of: #"C:\work"#, with: "C:work"),
            source.replacingOccurrences(of: #"\\n"#, with: #"\n"#),
            source.replacingOccurrences(of: "2 * 3", with: "23")
        ] {
            XCTAssertFalse(DemandDeliveryDocumentVerification.matches(actual: text, expected: source))
        }
    }

    func testFormattingRepairReusesTheSavedLinkAndOnlyThenSubmits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardVerify-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var item = DItem(id: "D900", project: "ultra", title: "锁券改造", headerTitle: "锁券改造",
            status: .inProgress, priority: .p1, deadline: nil, branch: "feature/cdd",
            startDate: nil, milestones: [], reqFlow: ReqFlowLink(id: 42, no: "R42"))
        item.executionScope = String(repeating: "a", count: 64)
        item.technicalPlan = DemandTechnicalPlan(title: "技术方案", markdown: expected,
            projects: [.init(name: "ultra", branch: "feature/cdd")], scopeHash: item.executionScope,
            codeRevision: String(repeating: "b", count: 64), updatedAt: "2026-11-09T09:00:00Z", updatedBy: "ai")
        let plan = try DemandDeliveryPlan.make(item: item)
        let url = "https://alidocs.dingtalk.com/i/nodes/fixture"
        var actual = exported.replacingOccurrences(of: "-110", with: "110")
        var created = 0, submitted = 0, present = false
        let services = DemandDeliveryServices(generate: { _ in self.expected }, validate: { _ in },
            findDocument: { _ in nil }, createDocument: { _, _ in created += 1; return url },
            verifyDocument: { _, expected in
                guard DemandDeliveryDocumentVerification.matches(actual: actual, expected: expected) else {
                    throw DemandDeliveryError.message("正文核对未通过")
                }
            }, listDeliverables: { _ in
                let rows: [[String: Any]] = present ? [["deliverableContent": url, "deliverableDevProject": "ultra:feature/cdd"]] : []
                return try DevelopmentDeliverables.decode(JSONSerialization.data(withJSONObject:
                    ["success": true, "data": ["3": rows]]))
            }, submit: { _, _ in submitted += 1; present = true })
        let store = DemandDeliveryStore(url: directory.appendingPathComponent("receipts.json"))
        let workflow = DemandDeliveryWorkflow(store: store, services: services)
        XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { true }))
        XCTAssertEqual(created, 1)
        XCTAssertEqual(submitted, 0)
        XCTAssertEqual(try store.read()[plan.key]?.documentURL, url)
        XCTAssertEqual(try store.read()[plan.key]?.confirmed, false)
        actual = exported
        XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
        XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
        XCTAssertEqual(created, 1)
        XCTAssertEqual(submitted, 1)
    }

    func testExistingD014DocumentVerifiesReadOnly() throws {
        guard ProcessInfo.processInfo.environment["DBOARD_DELIVERY_SMOKE"] == "D014" else {
            throw XCTSkip("Enable read-only D014 document verification explicitly")
        }
        let store = DemandDeliveryStore()
        let before = try Data(contentsOf: store.url)
        let receipts = try store.read().values.filter { $0.itemID == "D014" }
        XCTAssertFalse(receipts.isEmpty)
        for receipt in receipts {
            let url = try XCTUnwrap(receipt.documentURL)
            try DemandDeliveryServices.live.verifyDocument(url, receipt.markdown)
        }
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }
}
