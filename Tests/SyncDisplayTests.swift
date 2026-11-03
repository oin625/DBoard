import XCTest
@testable import DBoard

final class SyncDisplayTests: XCTestCase {
    private let body = "## Tasks\n### D014 test\n"
    private let stamp = "2026-11-02T10:27:02"

    private func synced(_ content: String) -> String {
        "<!-- synced: \(stamp) -->\n<!-- synced-hash: \(ContentRevision.hash(content)) -->\n" + content
    }

    func testReceiptMustMatchCurrentBodyAndBeUnique() {
        let snapshot = synced(body)
        XCTAssertTrue(ContentRevision.matchesSyncReceipt(snapshot))
        XCTAssertFalse(ContentRevision.matchesSyncReceipt(snapshot + "new progress\n"))
        XCTAssertFalse(ContentRevision.matchesSyncReceipt("<!-- synced: \(stamp) -->\n" + body))
        XCTAssertFalse(ContentRevision.matchesSyncReceipt(
            "<!-- synced-hash: \(ContentRevision.hash(body)) -->\n" + snapshot))
    }

    @MainActor
    func testExternalSyncClearsOldFailureAndShowsLatestTime() {
        let vm = DBoardViewModel(loadCache: false)
        vm.syncKind = .fail
        vm.syncText = "同步失败，改动保留在本机"
        vm.syncTime = stamp
        vm.feedback = WorkspaceFeedback(message: vm.syncText, failed: true)

        vm.updateSyncDisplay(content: synced(body))

        XCTAssertEqual(vm.syncKind, .idle)
        XCTAssertEqual(vm.syncText, "最近同步 10:27")
        XCTAssertNil(vm.feedback)
    }

    @MainActor
    func testOldReceiptDoesNotClearFailureWithUnsyncedChanges() {
        let vm = DBoardViewModel(loadCache: false)
        vm.syncKind = .fail
        vm.syncText = "同步失败，改动保留在本机"
        vm.syncTime = stamp

        vm.updateSyncDisplay(content: synced(body) + "new progress\n")

        XCTAssertEqual(vm.syncKind, .fail)
        XCTAssertEqual(vm.syncText, "同步失败，改动保留在本机")
    }

    @MainActor
    func testTimestampAloneDoesNotClearFailure() {
        let vm = DBoardViewModel(loadCache: false)
        vm.syncKind = .fail
        vm.syncText = "同步失败，改动保留在本机"
        vm.syncTime = stamp

        vm.updateSyncDisplay(content: "<!-- synced: \(stamp) -->\n" + body)

        XCTAssertEqual(vm.syncKind, .fail)
    }

    @MainActor
    func testRefreshKeepsInFlightAndPendingSyncState() {
        let vm = DBoardViewModel(loadCache: false)
        vm.syncTime = stamp
        for state in [DBoardViewModel.SyncKind.syncing, .pending] {
            vm.syncKind = state
            vm.syncText = "working"
            vm.updateSyncDisplay(content: synced(body))
            XCTAssertEqual(vm.syncKind, state)
            XCTAssertEqual(vm.syncText, "working")
        }
    }

    @MainActor
    func testUnrelatedFailureStatusIsNotClearedBySyncReceipt() {
        let vm = DBoardViewModel(loadCache: false)
        vm.syncKind = .fail
        vm.syncText = "保存失败，请检查本地数据文件"
        vm.syncTime = stamp

        vm.updateSyncDisplay(content: synced(body))

        XCTAssertEqual(vm.syncKind, .fail)
        XCTAssertEqual(vm.syncText, "保存失败，请检查本地数据文件")
    }

    @MainActor
    func testSyncRecoveryKeepsUnrelatedFailureFeedback() {
        let vm = DBoardViewModel(loadCache: false)
        vm.syncKind = .fail
        vm.syncText = "同步失败，改动保留在本机"
        vm.syncTime = stamp
        vm.feedback = WorkspaceFeedback(message: "其他操作失败", failed: true)

        vm.updateSyncDisplay(content: synced(body))

        XCTAssertEqual(vm.syncKind, .idle)
        XCTAssertEqual(vm.feedback?.message, "其他操作失败")
    }
}
