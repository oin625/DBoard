import XCTest
import Foundation
@testable import DBoard

final class DemandChatDiscoveryTests: XCTestCase {
    private let target = DemandChat(id: "cid-external", name: "高德-天猫深度合作")
    private func result(stdout: String = "", stderr: String = "", exit: Int32 = 0) -> CommandResult {
        CommandResult(exitCode: exit, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8),
                      timedOut: false, outputComplete: true)
    }

    func testContentSearchUsesConversationMetadataAndDeduplicatesMatchingNames() throws {
        let raw = #"{"success":true,"result":[{"sourceType":"im","openConversationId":"cid-external","meta":{"conversation_title":"高德-天猫深度合作","chat_type":"direct"}},{"sourceType":"im","openConversationId":"cid-external","meta":{"conversation_title":"高德-天猫深度合作"}},{"sourceType":"im","openConversationId":"cid-other","meta":{"conversation_title":"其他群"}},{"sourceType":"document","title":"高德-天猫深度合作"},{"sourceType":"im","title":"高德-天猫深度合作 | 某条消息"}]}"#
        XCTAssertEqual(try DemandChatDiscoveryService.candidates(Data(raw.utf8), query: "高德 天猫"), [target])
        XCTAssertThrowsError(try DemandChatDiscoveryService.candidates(Data(#"{"success":false,"result":[]}"#.utf8), query: "高德"))
    }

    func testConversationProbeExcludesDirectMessagesAndAcceptsOnlyMatchingGroupID() {
        let group = #"{"success":true,"result":{"conversationInfo":{"singleChat":false,"openConversationId":"cid-external","title":"高德-天猫深度合作"}}}"#
        let verified = DemandChatDiscoveryService.verified(result(stdout: group), candidate: target)
        XCTAssertEqual(verified?.groups, [target])
        XCTAssertTrue(verified?.restrictedIDs.isEmpty == true)
        XCTAssertNil(DemandChatDiscoveryService.verified(result(stdout: group.replacingOccurrences(of: "false", with: "true")), candidate: target))
        XCTAssertNil(DemandChatDiscoveryService.verified(result(stdout: group.replacingOccurrences(of: "cid-external", with: "cid-unrelated")), candidate: target))
    }

    func testExplicitInternalGroupDenialCanExposeItsNameWithoutGrantingMessageAccess() {
        let denied = #"{"error":{"server_error_code":"FORBIDDEN","message":"无权访问该内部群 (operation: chat/get_conversation_info)"}}"#
        let verified = DemandChatDiscoveryService.verified(result(stderr: denied, exit: 1), candidate: target)
        XCTAssertEqual(verified?.groups, [target])
        XCTAssertEqual(verified?.restrictedIDs, [target.id])
        for failure in [
            #"{"error":{"server_error_code":"FORBIDDEN","message":"无权访问"}}"#,
            #"{"error":{"server_error_code":"UNAUTHORIZED","message":"无权访问该内部群"}}"#,
            #"{"success":true,"result":{"conversationInfo":{"singleChat":0,"title":"同事","openConversationId":"cid-external"}}}"#
        ] {
            XCTAssertNil(DemandChatDiscoveryService.verified(result(stderr: failure, exit: 1), candidate: target))
        }
    }

    func testSuccessfulMessageReadClearsRestrictionEvenWhenGroupDetailsRemainForbidden() {
        let denied = DemandChatDiscovery(groups: [target], restrictedIDs: [target.id])
        for messages in ["[]", "[{}]"] {
            let read = result(stdout: "{\"success\":true,\"result\":{\"messages\":\(messages),\"hasMore\":false}}")
            let confirmed = DemandChatDiscoveryService.confirmingMessageAccess(denied, for: target.id, result: read)
            XCTAssertEqual(confirmed.groups, [target])
            XCTAssertTrue(confirmed.restrictedIDs.isEmpty)
        }
    }

    func testFailedOrUnreadableMessageProbeKeepsRestrictionAndCannotClearOtherGroups() {
        let denied = DemandChatDiscovery(groups: [target], restrictedIDs: [target.id])
        for raw in [
            #"{"success":false,"result":{"messages":[],"hasMore":false}}"#,
            #"{"success":true,"result":{"messages":[],"hasMore":0}}"#,
            #"{"success":true,"result":{"hasMore":false}}"#
        ] {
            XCTAssertEqual(DemandChatDiscoveryService.confirmingMessageAccess(denied, for: target.id,
                result: result(stdout: raw)).restrictedIDs, [target.id])
        }
        let good = result(stdout: #"{"success":true,"result":{"messages":[],"hasMore":false}}"#)
        XCTAssertEqual(DemandChatDiscoveryService.confirmingMessageAccess(denied, for: "cid-other",
            result: good).restrictedIDs, [target.id])
    }

    @MainActor
    func testDiscoveryFallbackFindsMissingInternalGroupAndPersistsItsAccessNotice() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardChatDiscovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("groups.json")
        var restricted = true
        var discoveries = 0
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [], nextCursor: nil)
        }, search: { _, _ in DemandChatPage(groups: [], nextCursor: nil) }, discover: { _ in
            discoveries += 1
            return DemandChatDiscovery(groups: [self.target], restrictedIDs: restricted ? [self.target.id] : [])
        }, cacheURL: cache)
        await directory.search("高德")
        XCTAssertEqual(directory.groups, [target])
        XCTAssertTrue(directory.restrictedGroupIDs.contains(target.id))
        let restored = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [], nextCursor: nil)
        }, cacheURL: cache)
        XCTAssertEqual(restored.groups, [target])
        XCTAssertTrue(restored.restrictedGroupIDs.contains(target.id))
        restricted = false
        await directory.search("高德")
        XCTAssertEqual(discoveries, 2)
        XCTAssertTrue(directory.restrictedGroupIDs.isEmpty, "A successful metadata probe removes the old restriction notice")
    }

    @MainActor
    func testLiveDiscoveryOfGaodeInternalGroup() async throws {
        guard ProcessInfo.processInfo.environment["DBOARD_LIVE_CHAT_DISCOVERY"] == "1" else {
            throw XCTSkip("Enable read-only live DingTalk lookup explicitly")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardLiveChat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = DemandChatDirectory(knownURL: nil, cacheURL: folder.appendingPathComponent("groups.json"))
        await directory.search("高德")
        XCTAssertTrue(directory.groups.contains {
            $0.id == "cidNP75diuTEndXS9jqB0Iu/A==" && $0.name == "高德-天猫深度合作"
        })
        XCTAssertNil(directory.searchError)
        XCTAssertFalse(directory.isSearching)
        if ProcessInfo.processInfo.environment["DBOARD_EXPECT_CHAT_MESSAGE_ACCESS"] == "1" {
            XCTAssertFalse(directory.restrictedGroupIDs.contains("cidNP75diuTEndXS9jqB0Iu/A=="),
                           "A successful message read must clear the notice even when group details stay forbidden")
        }
    }
}
