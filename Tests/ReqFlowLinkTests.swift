import XCTest
import Combine
@testable import DBoard

final class ReqFlowLinkTests: XCTestCase {
    private func temporaryFile(_ content: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardLinkTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cache.md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return (file, directory)
    }
    private let emptyCache = "## 🔴 紧急\n\n## 🟡 重要\n\n## 🟠 紧急不重要\n\n## 🟢 其他\n"

    func testOldCacheAndAdjacentItemKeepIndependentAssociations() {
        let parsed = CacheParser.parse(content: """
        ## 🟡 重要
        ### D001【手工项目】个人标题 #待开始
        - **需求流**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/42)
        - **进度**：
            - 10.28: 已核对
        ### D002【手工项目】其他需求 #进行中
        - **描述**：未关联
        """)
        XCTAssertEqual(parsed.items.count, 2)
        XCTAssertEqual(parsed.items[0].reqFlow, ReqFlowLink(id: 42, no: "R1001"))
        XCTAssertEqual(parsed.items[0].milestones.map(\.content), ["已核对"])
        XCTAssertNil(parsed.items[1].reqFlow)
    }

    func testMalformedLinkNeverEstablishesAssociation() {
        for field in [
            "- **需求流**：[R1001](https://example.com/prd/index.html#detail/42)",
            "- **需求流**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/0)",
            "- **需求流**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/99999999999999999999999)",
            "- **需求流**：可能涉及 R1001",
            "- **描述**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/42)"
        ] { XCTAssertNil(ReqFlowLink.parseField(field)) }
        let link = ReqFlowLink(id: 42, no: "R1001")
        XCTAssertEqual(ReqFlowLink.parseField("- **需求流**：\(link.markdown)"), link)
    }

    func testCreateEditMoveAndUnlinkPreserveUnrelatedFields() throws {
        let (file, directory) = try temporaryFile(emptyCache)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousWatermark = UserDefaults.standard.object(forKey: "dboard.lastDID") as? Int
        var draft = DItemDraft(newID: "D001", priority: .p1)
        draft.name = "个人安排"
        draft.project = "自主填写"
        draft.reqFlow = ReqFlowLink(id: 42, no: "R1001")
        XCTAssertTrue(DItemStore.create(draft, at: file))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "dboard.lastDID") as? Int, previousWatermark)
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "- **描述**：（待补充）",
            with: "- **描述**：手工描述\n- **业务备注**：必须保留\n- **进度**：\n    - 10.28: 今日记录")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let original = try XCTUnwrap(CacheParser.parse(content: text).items.first)
        var edit = DItemDraft(from: original)
        edit.name = "重新命名"
        edit.priority = .p0
        edit.status = .inProgress
        XCTAssertTrue(DItemStore.save(edit, original: original, at: file))
        let editedText = try String(contentsOf: file, encoding: .utf8)
        let edited = try XCTUnwrap(CacheParser.parse(content: editedText).items.first)
        XCTAssertEqual(edited.reqFlow, draft.reqFlow)
        XCTAssertEqual(edited.status, .inProgress)
        XCTAssertEqual(edited.priority, .p0)
        XCTAssertEqual(edited.milestones.map(\.content), ["今日记录"])
        XCTAssertTrue(editedText.contains("- **业务备注**：必须保留"))
        edit = DItemDraft(from: edited)
        edit.reqFlow = nil
        XCTAssertTrue(DItemStore.save(edit, original: edited, at: file))
        let unlinked = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNil(CacheParser.parse(content: unlinked).items.first?.reqFlow)
        XCTAssertTrue(unlinked.contains("今日记录"))
        XCTAssertTrue(unlinked.contains("必须保留"))
    }

    func testDuplicateIdentityIsRejectedFromDiskAndSameTitlesRemainDistinct() throws {
        let (file, directory) = try temporaryFile(emptyCache)
        defer { try? FileManager.default.removeItem(at: directory) }
        var first = DItemDraft(newID: "D001", priority: .p1)
        first.name = "同名需求"
        first.reqFlow = ReqFlowLink(id: 42, no: "R1001")
        XCTAssertTrue(DItemStore.create(first, at: file))
        let before = try String(contentsOf: file, encoding: .utf8)
        var second = first
        second.id = "D002"
        second.reqFlow = ReqFlowLink(id: 42, no: "R9999") // Different displayed number, same system identity.
        XCTAssertFalse(DItemStore.create(second, at: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
        second.reqFlow = ReqFlowLink(id: 43, no: "R1002")
        XCTAssertTrue(DItemStore.create(second, at: file))
        XCTAssertFalse(DItemStore.create(first, at: file))
        XCTAssertEqual(CacheParser.parse(content: try String(contentsOf: file, encoding: .utf8)).items.count, 2)
    }

    func testEditingCannotStealAnotherItemsAssociation() throws {
        let (file, directory) = try temporaryFile(emptyCache)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (id, requirementID) in [("D001", 42), ("D002", 43)] {
            var draft = DItemDraft(newID: id, priority: .p1)
            draft.name = id
            draft.reqFlow = ReqFlowLink(id: requirementID, no: "R\(requirementID)")
            XCTAssertTrue(DItemStore.create(draft, at: file))
        }
        let before = try String(contentsOf: file, encoding: .utf8)
        let original = CacheParser.parse(content: before).items[1]
        var draft = DItemDraft(from: original)
        draft.reqFlow = ReqFlowLink(id: 42, no: "R42")
        XCTAssertFalse(DItemStore.save(draft, original: original, at: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), before)
    }

    func testSelectionOnlyFillsTitleAndKeepsPersonalFields() throws {
        let requirement = try makeRequirement(id: 42, no: "R1001", name: "正式标题")
        var draft = DItemDraft(newID: "D001", priority: .p1)
        draft.project = "我选的工程"
        draft.branch = "feature/personal"
        draft.status = .suspended
        draft.associate(with: requirement)
        XCTAssertEqual(draft.name, "正式标题")
        XCTAssertEqual(draft.reqFlow, ReqFlowLink(requirement))
        XCTAssertEqual(draft.project, "我选的工程")
        XCTAssertEqual(draft.branch, "feature/personal")
        XCTAssertEqual(draft.status, .suspended)
        XCTAssertEqual(draft.priority, .p1)
        let next = try makeRequirement(id: 43, no: "R1002", name: "另一正式标题")
        draft.associate(with: next, previous: requirement)
        XCTAssertEqual(draft.name, next.name)
        draft.name = "自定义个人标题"
        draft.associate(with: requirement, previous: next)
        XCTAssertEqual(draft.name, "自定义个人标题")
    }

    func testPickerIncludesPendingAndMineWithSearchAndIdentityDeduplication() throws {
        let pending = try makeRequirement(id: 42, no: "R1001", name: "同名", scopes: ["pending", "dept"])
        let mine = try makeRequirement(id: 43, no: "R1002", name: "同名", scopes: ["mine"])
        let group = try makeRequirement(id: 44, no: "R1003", name: "组内事项", scopes: ["dept"])
        let items = [mine, group, pending, pending]
        XCTAssertEqual(ReqFlowLinkQueries.candidates(items, scope: .mine, query: "").map(\.id), [42, 43])
        XCTAssertEqual(ReqFlowLinkQueries.candidates(items, scope: .mine, query: " r1002 ").map(\.id), [43])
        XCTAssertEqual(Set(ReqFlowLinkQueries.candidates(items, scope: .department, query: "").map(\.id)), [42, 44])
        XCTAssertEqual(ReqFlowLinkQueries.candidates(items, scope: .mine, query: "组内").count, 0)
    }

    @MainActor
    func testNavigationUsesStableIDAndDoesNotGuessMissingRequirement() throws {
        let flow = BizMapViewModel(loadBackgroundData: false)
        flow.cache = try makeCache([
            makeRequirement(id: 42, no: "R1001", name: "同名"),
            makeRequirement(id: 43, no: "R1002", name: "同名")
        ])
        XCTAssertTrue(flow.focusRequirement(ReqFlowLink(id: 43, no: "Rold")))
        XCTAssertEqual(flow.query, "R1002")
        XCTAssertEqual(flow.expandedPRD, [43])
        XCTAssertEqual(flow.perspective, .requirements)
        XCTAssertFalse(flow.focusRequirement(ReqFlowLink(id: 99, no: "R1001")))
        XCTAssertEqual(flow.expandedPRD, [43])
        XCTAssertEqual(flow.query, "R1002")
    }

    @MainActor
    func testOfficialStatusRefreshUpdatesObservationWithoutChangingPersonalStatus() throws {
        let flow = BizMapViewModel(loadBackgroundData: false)
        let vm = DBoardViewModel(loadCache: false, reqFlow: flow)
        vm.items = CacheParser.parse(content: """
        ## 🟡 重要
        ### D001【个人项目】个人标题 #挂起
        - **需求流**：[R1001](https://ai.tmallyc.com/prd/index.html#detail/42)
        """).items
        var observations = 0
        let token = vm.objectWillChange.sink { observations += 1 }
        flow.cache = try makeCache([makeRequirement(id: 42, no: "R1001", name: "正式标题", status: "开发中")])
        XCTAssertGreaterThan(observations, 0)
        XCTAssertEqual(vm.items.first?.status, .suspended)
        XCTAssertEqual(vm.reqFlow.prdItems.first?.status, "开发中")
        XCTAssertEqual(ReqFlowLinkQueries.linkedItem(for: ReqFlowLink(id: 42, no: "R1001"), in: vm.items)?.id, "D001")
        XCTAssertNil(ReqFlowLinkQueries.linkedItem(for: ReqFlowLink(id: 42, no: "R1001"), in: vm.items, excludingID: "D001"))
        vm.focusItem("D001")
        XCTAssertEqual(vm.workspacePage, .demands)
        XCTAssertEqual(vm.selectedID, "D001")
        withExtendedLifetime(token) {}
    }

    private func makeRequirement(id: Int, no: String, name: String, scopes: [String] = ["mine"],
                                 status: String = "待开始") throws -> BizPRDItem {
        let object: [String: Any] = [
            "id": id, "no": no, "name": name, "code": "KFZ", "status": status,
            "scopes": scopes, "services": [], "docs": [],
            "url": "https://ai.tmallyc.com/prd/index.html#detail/\(id)"
        ]
        return try JSONDecoder().decode(BizPRDItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func makeCache(_ items: [BizPRDItem]) throws -> BizMapCache {
        let data = try JSONEncoder().encode(items)
        let itemObjects = try JSONSerialization.jsonObject(with: data)
        let object: [String: Any] = [
            "generated": "2026-10-28 10:00", "prdGenerated": "2026-10-28 10:00",
            "phase": ["done": [], "current": "", "rest": []],
            "groups": [], "services": [], "routes": [], "dItemsAll": [], "prdItemsAll": itemObjects
        ]
        return try JSONDecoder().decode(BizMapCache.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
