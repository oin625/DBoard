import XCTest
@testable import DBoard

final class DemandCompletionGateTests: XCTestCase {
    private func item() -> DItem {
        DItem(id: "D881", project: "ultra", title: "", headerTitle: "归档门槛",
              status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
    }

    func testPendingActionsBlockCompletionAndAllCompletedActionsAllowIt() {
        var value = item()
        value.releaseChecklist.items = [
            .init(id: "L001", text: "发布 Ultra 服务", done: true, updatedBy: .user),
            .init(id: "L002", text: "执行建表 SQL", updatedBy: .ai)
        ]
        XCTAssertTrue(DemandCompletionGate.localIssue(value)?.contains("执行建表 SQL") == true)
        XCTAssertFalse(DemandCompletionGate.needsEmptyChecklistConfirmation(value))
        value.releaseChecklist.items[1].done = true
        XCTAssertNil(DemandCompletionGate.localIssue(value))
        value.releaseChecklist.items[0].done = false
        XCTAssertNotNil(DemandCompletionGate.localIssue(value))
    }

    func testEmptyChecklistRequiresExtraConfirmationButCorruptChecklistCannotBeBypassed() {
        var value = item()
        XCTAssertNil(DemandCompletionGate.localIssue(value))
        XCTAssertTrue(DemandCompletionGate.needsEmptyChecklistConfirmation(value))
        value.releaseChecklistReadError = "清单无法读取"
        XCTAssertNotNil(DemandCompletionGate.localIssue(value))
        XCTAssertFalse(DemandCompletionGate.needsEmptyChecklistConfirmation(value))
    }

    func testOnlyConfirmedFormalAcceptanceForExactLinkedDemandAllowsCompletion() throws {
        let link = ReqFlowLink(id: 881, no: "R260881")
        func response(_ status: String, id: Int = 881, no: String = "R260881", success: Bool = true) -> [String: Any] {
            ["success": success, "data": ["id": id, "reqNo": no, "currentStatus": status]]
        }
        for status in ["CPYSWC", "XQWC"] {
            XCTAssertNoThrow(try DemandCompletionGate.validateAcceptance(response(status), link: link))
        }
        for status in ["KFZ", "CSZ", "CSWC", "CPYSZ", "待核实", ""] {
            XCTAssertThrowsError(try DemandCompletionGate.validateAcceptance(response(status), link: link))
        }
        XCTAssertThrowsError(try DemandCompletionGate.validateAcceptance(response("CPYSWC", id: 882), link: link))
        XCTAssertThrowsError(try DemandCompletionGate.validateAcceptance(response("CPYSWC", no: "R260882"), link: link))
        XCTAssertThrowsError(try DemandCompletionGate.validateAcceptance(response("CPYSWC", success: false), link: link))
    }
}
