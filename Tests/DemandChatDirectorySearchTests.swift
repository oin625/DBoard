import XCTest
import Foundation
@testable import DBoard

final class DemandChatDirectorySearchTests: XCTestCase {
    private let listed = DemandChat(id: "cid-listed", name: "已在群列表的群")
    private let target = DemandChat(id: "cid-target", name: "高德－天猫 深度合作")

    func testConversationDecoderExcludesDirectMessagesAndChecksPagination() throws {
        let raw = #"{"success":true,"result":{"conversations":[{"singleChat":true,"title":"同事"},{"singleChat":false,"openConversationId":"cid-target","title":"群聊"}],"hasMore":true,"nextCursor":"next"}}"#
        let page = try DemandChatPage.decodeConversations(Data(raw.utf8))
        XCTAssertEqual(page.groups, [DemandChat(id: "cid-target", name: "群聊")])
        XCTAssertEqual(page.nextCursor, "next")
        for raw in [
            #"{"success":false,"result":{"conversations":[],"hasMore":false}}"#,
            #"{"success":true,"result":{"conversations":[],"hasMore":1}}"#,
            #"{"success":true,"result":{"conversations":[],"hasMore":true}}"#,
            #"{"success":true,"result":{"conversations":[{"singleChat":0,"openConversationId":"cid-a","title":"群聊"}],"hasMore":false}}"#,
            #"{"success":true,"result":{"conversations":[{"singleChat":false,"openConversationId":"","title":"群聊"}],"hasMore":false}}"#
        ] { XCTAssertThrowsError(try DemandChatPage.decodeConversations(Data(raw.utf8))) }
    }

    func testNameSearchIgnoresSpacingPunctuationAndWidthAndSupportsMultipleTerms() {
        for query in ["高德-天猫深度合作", "高德 天猫", " 深度合作 ", "cid-target", ""] {
            XCTAssertTrue(DemandChatSearch.matches(target, query: query), query)
        }
        XCTAssertFalse(DemandChatSearch.matches(target, query: "高德 SAAS"))
        XCTAssertFalse(DemandChatSearch.matches(target, query: "其他群"))
        XCTAssertTrue(DemandChatSearch.matches(DemandChat(id: "cid-a", name: "ＡＩ Café"), query: "ai cafe"))
    }

    @MainActor
    func testConversationAndRemoteSearchRecoverGroupsAbsentFromGroupList() async {
        let remoteOnly = DemandChat(id: "cid-remote", name: "远端搜索才能找到的群")
        var conversationCursors: [String?] = []
        var queries: [String] = []
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [self.listed], nextCursor: nil)
        }, conversations: { cursor in
            conversationCursors.append(cursor)
            return DemandChatPage(groups: cursor == nil ? [self.target] : [], nextCursor: cursor == nil ? "next" : nil)
        }, search: { query, cursor in
            queries.append(query)
            return DemandChatPage(groups: [remoteOnly], nextCursor: cursor == nil ? "next" : nil)
        })
        await directory.load()
        XCTAssertEqual(Set(directory.groups.map(\.id)), Set([listed.id, target.id]))
        XCTAssertEqual(conversationCursors.count, 2)
        XCTAssertEqual(conversationCursors[1], "next")
        await directory.search("远端")
        XCTAssertEqual(queries, ["远端", "远端"])
        XCTAssertTrue(directory.groups.contains(remoteOnly))
        XCTAssertNil(directory.searchError)
        XCTAssertFalse(directory.isSearching)
    }

    @MainActor
    func testConversationSourceStillLoadsWhenGroupListFailsAndSearchFailureKeepsChoices() async {
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            throw DemandChatDirectoryError.unavailable
        }, conversations: { _ in
            DemandChatPage(groups: [self.target], nextCursor: nil)
        }, search: { _, _ in throw DemandChatDirectoryError.unavailable })
        await directory.load()
        XCTAssertEqual(directory.groups, [target])
        XCTAssertNotNil(directory.error)
        await directory.search("高德")
        XCTAssertEqual(directory.groups, [target])
        XCTAssertNotNil(directory.searchError)
        XCTAssertFalse(directory.isSearching)
        await directory.search("")
        XCTAssertNil(directory.searchError)
    }

    @MainActor
    func testRemoteResultsPersistAcrossOpeningAndRefreshDoesNotDiscardThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardChatSearch-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = folder.appendingPathComponent("groups.json")
        let known = folder.appendingPathComponent("known.json")
        let directory = DemandChatDirectory(knownURL: known, fetch: { _ in
            DemandChatPage(groups: [self.listed], nextCursor: nil)
        }, search: { _, _ in DemandChatPage(groups: [self.target], nextCursor: nil) }, cacheURL: cache)
        await directory.search("高德")
        await directory.load()
        let restored = DemandChatDirectory(knownURL: known, fetch: { _ in
            DemandChatPage(groups: [], nextCursor: nil)
        }, cacheURL: cache)
        XCTAssertEqual(Set(restored.groups.map(\.id)), Set([listed.id, target.id]))
        try JSONEncoder().encode(["cid-new": "启动后新加入的群"]).write(to: known)
        await restored.load()
        XCTAssertTrue(restored.groups.contains { $0.id == "cid-new" })
        XCTAssertTrue(restored.groups.contains(target))
    }

    @MainActor
    func testLateSearchResponseCannotReplaceLatestQueryOrClearItsLoadingState() async {
        var pending: [String: CheckedContinuation<DemandChatPage, Error>] = [:]
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [], nextCursor: nil)
        }, search: { query, _ in
            try await withCheckedThrowingContinuation { pending[query] = $0 }
        })
        let first = Task { await directory.search("旧查询") }
        while pending["旧查询"] == nil { await Task.yield() }
        let second = Task { await directory.search("新查询") }
        while pending["新查询"] == nil { await Task.yield() }
        pending.removeValue(forKey: "旧查询")?.resume(returning: DemandChatPage(groups: [listed], nextCursor: nil))
        await first.value
        XCTAssertTrue(directory.isSearching)
        XCTAssertFalse(directory.groups.contains(listed))
        pending.removeValue(forKey: "新查询")?.resume(returning: DemandChatPage(groups: [target], nextCursor: nil))
        await second.value
        XCTAssertEqual(directory.groups, [target])
        XCTAssertFalse(directory.isSearching)
    }
}
