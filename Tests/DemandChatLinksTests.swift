import XCTest
import Foundation
@testable import DBoard

final class DemandChatLinksTests: XCTestCase {
    private let primary = DemandChat(id: "cid-primary", name: "主要群【车点点】🙂")
    private let first = DemandChat(id: "cid-secondary-1", name: "联调群")
    private let second = DemandChat(id: "cid-secondary-2", name: "SAAS 群")

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardChats-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func fixture(_ directory: URL) throws -> (URL, DItem) {
        let cache = directory.appendingPathComponent("cache.md")
        try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
        var draft = DItemDraft(newID: "D014", priority: .p1)
        draft.name = "车点点图文和群聊上下文"
        draft.project = "ultra"
        draft.promptSections.intent = "原始要求\n![图片](</tmp/fixture-image.png>)"
        draft.chatLinks = DemandChatLinks(primary: primary, secondary: [first, second])
        XCTAssertTrue(DItemStore.create(draft, at: cache))
        return (cache, try DItemStore.currentItem(id: draft.id, at: cache))
    }

    func testCreateEditAndRemoveAssociationsPreserveExistingPromptAndProgress() throws {
        try withDirectory { directory in
            let (cache, item) = try fixture(directory)
            XCTAssertEqual(item.chatLinks, DemandChatLinks(primary: primary, secondary: [first, second]))
            XCTAssertTrue(DItemStore.appendProgress(id: item.id, text: "接口开发完成，待联调。", at: cache))
            var edit = DItemDraft(from: item)
            edit.chatLinks?.setPrimary(first)
            edit.chatLinks?.setSecondary([primary, primary, second, first])
            XCTAssertTrue(DItemStore.save(edit, original: item, at: cache))
            let updated = try DItemStore.currentItem(id: item.id, at: cache)
            XCTAssertEqual(updated.chatLinks?.primary, first)
            XCTAssertEqual(updated.chatLinks?.secondary, [primary, second])
            XCTAssertEqual(updated.prompt, item.prompt)
            XCTAssertEqual(updated.milestones.first?.content, "接口开发完成，待联调。")
            var cleared = DItemDraft(from: updated)
            cleared.chatLinks = nil
            XCTAssertTrue(DItemStore.save(cleared, original: updated, at: cache))
            let result = try DItemStore.currentItem(id: item.id, at: cache)
            XCTAssertNil(result.chatLinks)
            XCTAssertEqual(result.prompt, item.prompt)
            XCTAssertFalse(try String(contentsOf: cache, encoding: .utf8).contains(DemandChatLinksCodec.field))
        }
    }

    func testOnlySecondaryGroupsAndSpecialNamesRoundTripWithoutBecomingCacheHeadings() throws {
        let chat = DemandChat(id: "cid-valid", name: "群名\n### D999【误解析】\n- **进度**：引用内容")
        var block = ["### D014【ultra】需求 #进行中"]
        try DemandChatLinksCodec.set(&block, links: DemandChatLinks(secondary: [chat]))
        XCTAssertEqual(block.count, 2)
        XCTAssertFalse(block[1].contains("\n"))
        XCTAssertEqual(try DemandChatLinksCodec.read(block)?.secondary, [chat])
        let items = CacheParser.parse(content: "## 🟡 重要\n" + block.joined(separator: "\n")).items
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.chatLinks?.secondary, [chat])
        XCTAssertNil(items.first?.chatLinks?.primary)
    }

    func testNewDemandDraftWithOnlyChatSelectionPersistsAndOldDraftsDecodeWithoutAssociations() throws {
        try withDirectory { directory in
            let file = directory.appendingPathComponent("draft.json")
            var draft = DItemDraft(newID: "D014", priority: .p1)
            draft.chatLinks = DemandChatLinks(primary: primary)
            XCTAssertTrue(draft.hasUserInput)
            XCTAssertTrue(NewDemandDraftStore(url: file).save(draft))
            XCTAssertEqual(NewDemandDraftStore(url: file).draft?.chatLinks, draft.chatLinks)
            var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as? [String: Any])
            json.removeValue(forKey: "chatLinks")
            let legacy = try JSONDecoder().decode(DItemDraft.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertNil(legacy.chatLinks)
            XCTAssertEqual(legacy.id, draft.id)
        }
    }

    func testConcurrentGroupEditIsRejectedButUnrelatedEditKeepsNewestGroups() throws {
        try withDirectory { directory in
            let (cache, original) = try fixture(directory)
            var newer = DItemDraft(from: original)
            newer.chatLinks = DemandChatLinks(primary: second)
            XCTAssertTrue(DItemStore.save(newer, original: original, at: cache))
            var stale = DItemDraft(from: original)
            stale.chatLinks = DemandChatLinks(primary: first)
            XCTAssertFalse(DItemStore.save(stale, original: original, at: cache))
            XCTAssertEqual(try DItemStore.currentItem(id: original.id, at: cache).chatLinks, newer.chatLinks)
            var branchOnly = DItemDraft(from: original)
            branchOnly.branch = "feature/cdd-lock"
            XCTAssertTrue(DItemStore.save(branchOnly, original: original, at: cache))
            let result = try DItemStore.currentItem(id: original.id, at: cache)
            XCTAssertEqual(result.chatLinks, newer.chatLinks)
            XCTAssertEqual(result.branch, branchOnly.branch)
        }
    }

    func testCorruptOrDuplicateAssociationsBlockSnapshotAndCannotBeOverwritten() throws {
        try withDirectory { directory in
            let (cache, original) = try fixture(directory)
            let before = try String(contentsOf: cache, encoding: .utf8)
            let line = try XCTUnwrap(before.components(separatedBy: "\n").first { $0.hasPrefix(DemandChatLinksCodec.field) })
            for bad in [line + "\n" + line, DemandChatLinksCodec.field + "：{}", line + "\n    非法续行"] {
                let corrupt = before.replacingOccurrences(of: line, with: bad)
                try corrupt.write(to: cache, atomically: true, encoding: .utf8)
                let parsed = try XCTUnwrap(CacheParser.parse(content: corrupt).items.first)
                XCTAssertNotNil(parsed.chatReadError)
                XCTAssertThrowsError(try DItemStore.currentItem(id: original.id, at: cache))
                var edit = DItemDraft(from: original)
                edit.chatLinks = nil
                XCTAssertFalse(DItemStore.save(edit, original: original, at: cache))
                XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), corrupt)
            }
        }
    }

    func testArchiveAndNextVersionKeepGroupContext() throws {
        try withDirectory { directory in
            let (cache, original) = try fixture(directory)
            let block = try String(contentsOf: cache, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.hasPrefix("## ") && !$0.isEmpty }
            let archived = ArchivedDemand(block: block, original: nil, priority: .p1, item: original)
            let next = try archived.newDraft(id: "D015")
            XCTAssertEqual(next.chatLinks, original.chatLinks)
            XCTAssertTrue(next.version?.background.contains(primary.id) == true)
            XCTAssertTrue(next.version?.background.contains(first.name) == true)
        }
    }

    func testGroupListPageDecodesNumericCursorsAndRejectsInvalidResponse() throws {
        let first = Data(#"{"success":true,"result":{"groups":[{"openConversationId":"cid-A","title":"开发群"}],"hasMore":true,"nextCursor":1787190533356}}"#.utf8)
        let page = try DemandChatPage.decode(first)
        XCTAssertEqual(page.nextCursor, "1787190533356")
        XCTAssertEqual(page.groups.first?.id, "cid-A")
        for raw in [
            #"{"success":false,"result":{"groups":[],"hasMore":false}}"#,
            #"{"success":true,"result":{"groups":[],"hasMore":"true","nextCursor":"x"}}"#,
            #"{"success":true,"result":{"groups":[{"openConversationId":"","title":"无ID"}],"hasMore":false}}"#,
            #"{"success":true,"result":{"groups":[],"hasMore":true}}"#
        ] { XCTAssertThrowsError(try DemandChatPage.decode(Data(raw.utf8))) }
    }

    @MainActor
    func testDirectoryLoadsAllPagesAndUpdatesRenamedGroupsByID() async {
        var cursors: [String?] = []
        let directory = DemandChatDirectory(knownURL: nil, fetch: { cursor in
            cursors.append(cursor)
            if cursor == nil { return DemandChatPage(groups: [self.primary, self.first], nextCursor: "next") }
            return DemandChatPage(groups: [DemandChat(id: self.first.id, name: "联调群新名字"), self.second], nextCursor: nil)
        })
        await directory.load()
        XCTAssertEqual(cursors.count, 2)
        XCTAssertEqual(cursors[1], "next")
        XCTAssertEqual(directory.groups.count, 3)
        XCTAssertEqual(directory.groups.first { $0.id == first.id }?.name, "联调群新名字")
        XCTAssertFalse(directory.isLoading)
        XCTAssertNil(directory.error)
    }

    @MainActor
    func testDirectoryKeepsPartialResultsOnFailureAndStopsRepeatedPagination() async {
        var calls = 0
        let directory = DemandChatDirectory(knownURL: nil, fetch: { _ in
            calls += 1
            if calls == 1 { return DemandChatPage(groups: [self.primary], nextCursor: "next") }
            throw DemandChatDirectoryError.unavailable
        })
        await directory.load()
        XCTAssertEqual(directory.groups, [primary])
        XCTAssertNotNil(directory.error)
        let repeated = DemandChatDirectory(knownURL: nil, fetch: { _ in
            DemandChatPage(groups: [self.primary], nextCursor: "same")
        })
        await repeated.load()
        XCTAssertNotNil(repeated.error)
        XCTAssertEqual(repeated.groups, [primary])
    }
}
