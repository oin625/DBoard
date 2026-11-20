import XCTest
@testable import DBoard

final class DemandDeliveryCLIResponseTests: XCTestCase {
    private func result(_ stdout: String, stderr: String = "", exit: Int32 = 0,
                        timedOut: Bool = false, complete: Bool = true) -> CommandResult {
        CommandResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
                      timedOut: timedOut, outputComplete: complete)
    }

    func testLongDocumentProgressDoesNotHideSuccessfulJSON() throws {
        let output = """
        [INFO] [INFO] 内容较长 (10511 字符)，自动分片写入...
        [INFO] [INFO] 写入分片 (1/2)，9777 字符 (create)...
        [INFO] [INFO] 写入分片 (2/2)，734 字符 (append)...
        {"success":true,"nodeId":"existing-document","docUrl":"https://alidocs.dingtalk.com/i/nodes/existing-document"}
        """
        let response = try DemandDeliveryRemote.decodeDWS(result(output), arguments: ["doc", "create"])
        XCTAssertEqual(response["nodeId"] as? String, "existing-document")
    }

    func testProgressCannotConcealPartialFailedOrAmbiguousResponses() {
        for output in [
            "[INFO] 写入分片...\n{\"success\":true",
            "[INFO] 创建成功但追加失败\n{\"success\":false,\"message\":\"追加失败\"}",
            "{\"success\":true}\n{\"success\":false}",
            "{\"success\":1}",
            "unknown prefix\n{\"success\":true}"
        ] {
            XCTAssertThrowsError(try DemandDeliveryRemote.decodeDWS(result(output), arguments: ["doc", "create"]))
        }
        XCTAssertThrowsError(try DemandDeliveryRemote.decodeDWS(result(#"{"success":true}"#, exit: 5), arguments: ["doc", "create"]))
        XCTAssertThrowsError(try DemandDeliveryRemote.decodeDWS(result(#"{"success":true}"#, timedOut: true), arguments: ["doc", "create"]))
    }

    func testErrorNamesActualActionAndReasonWithoutDiscardingCreatedDocument() {
        let command = result("[INFO] 写入分片...", stderr: #"{"error":{"category":"internal","message":"创建成功但无法提取 nodeId"}}"#, exit: 5)
        XCTAssertThrowsError(try DemandDeliveryRemote.decodeDWS(command, arguments: ["doc", "create"])) { error in
            XCTAssertFalse(error is DemandDeliveryDocumentRejected)
            XCTAssertTrue(error.localizedDescription.contains("doc create"))
            XCTAssertTrue(error.localizedDescription.contains("无法提取 nodeId"))
        }
    }

    func testDefinitiveCreateRejectionAllowsRetryButTimeoutDoesNot() {
        let command = result("", stderr: #"{"error":{"category":"auth","message":"会话已过期"}}"#, exit: 2)
        XCTAssertThrowsError(try DemandDeliveryRemote.decodeDWS(command, arguments: ["doc", "create"])) { error in
            XCTAssertTrue(error is DemandDeliveryDocumentRejected)
        }
        XCTAssertThrowsError(try DemandDeliveryRemote.decodeDWS(result("", timedOut: true), arguments: ["doc", "create"])) { error in
            XCTAssertFalse(error is DemandDeliveryDocumentRejected)
        }
    }

    func testD016CreatedDocumentCanBeRecoveredAndVerifiedReadOnlyWithChatsDisabled() throws {
        guard ProcessInfo.processInfo.environment["DBOARD_DELIVERY_SMOKE"] == "D016" else {
            throw XCTSkip("Enable read-only D016 verification explicitly")
        }
        XCTAssertFalse(DemandChatPrivacy.isEnabled)
        let store = DemandDeliveryStore()
        let before = try Data(contentsOf: store.url)
        let receipt = try XCTUnwrap(store.read().values.first { $0.itemID == "D016" && $0.creating })
        let url = try XCTUnwrap(DemandDeliveryServices.live.findDocument(receipt.title))
        try DemandDeliveryServices.live.verifyDocument(url, receipt.markdown)
        XCTAssertEqual(try Data(contentsOf: store.url), before)
    }
}
