import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandReleaseChecklistTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!
    private let source = "## 🟡 重要\n### D601【ultra】上线清单测试 #进行中\n- **描述**：锁券改造\n    保留补充描述\n- **提示词**：\n    根据现有接口拆出锁券\n- **进度**：\n    - 11.4: 开发已完成，待联调\n\n### D602【audi】其他需求 #待开始\n- **描述**：保持原样\n"
    private let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardRelease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("cache.md")
        try source.write(to: cache, atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func call(_ arguments: [String], expectedCode: Int32 = 0) throws -> [String: Any] {
        let result = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path] + arguments)
        XCTAssertEqual(result.exitCode, expectedCode, String(data: result.stdout, encoding: .utf8) ?? "")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }
    private func report(_ arguments: [String]) throws -> [String: Any] {
        let response = try call(["show", "D601"])
        let item = try XCTUnwrap(response["item"] as? [String: Any])
        return try call(["report", "D601", "--expect-title", item["title"] as! String,
            "--expect-revision", item["revision"] as! String, "--no-sync"] + arguments)
    }

    func testAIAndUserRoundtripPreservesEditsChecksExclusionsAndOtherContext() throws {
        let old = try DItemStore.currentItem(id: "D601", at: cache)
        let digest = try DemandOverview.hash(source)
        try report(["--release-add", "发布 ultra 服务", "--release-add", "执行旧 SQL", "--release-reviewed"])
        let ai = try DItemStore.currentItem(id: "D601", at: cache)
        XCTAssertEqual(ai.releaseChecklist.items.map(\.id), ["L001", "L002"])
        XCTAssertFalse(ai.releaseChecklistNeedsReview)
        XCTAssertEqual(ai.title, old.title)
        XCTAssertEqual(ai.prompt, old.prompt)
        XCTAssertEqual(ai.executionScope, old.executionScope)
        let first = ai.releaseChecklist.items[0], second = ai.releaseChecklist.items[1]
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { list in
            guard list.edit(first, text: "先执行新 SQL，再发布 ultra 服务"), list.remove(second),
                  list.add("创建 lock_record 表", author: .user) else { return false }
            return list.toggle(list.items[0])
        })
        let user = try DItemStore.currentItem(id: "D601", at: cache)
        XCTAssertEqual(user.releaseChecklist.completedCount, 1)
        XCTAssertEqual(user.releaseChecklist.items.map(\.updatedBy), [.user, .user])
        let context = try call(["context", "D601"])
        let text = try XCTUnwrap(context["context"] as? String)
        XCTAssertTrue(text.contains("先执行新 SQL，再发布 ultra 服务"))
        XCTAssertTrue(text.contains("用户删除或修正过"))
        XCTAssertTrue(text.contains("[x] L001"))
        try report(["--release-add", "执行旧 SQL", "--release-add", "发布 ultra 服务", "--release-add", "配置开关"])
        let next = try DItemStore.currentItem(id: "D601", at: cache)
        XCTAssertEqual(next.releaseChecklist.items.map(\.id), ["L001", "L003", "L004"])
        XCTAssertTrue(next.releaseChecklist.items[0].done)
        XCTAssertEqual(next.releaseChecklist.items[0].text, user.releaseChecklist.items[0].text)
        XCTAssertEqual(try DemandOverview.hash(String(contentsOf: cache, encoding: .utf8)), digest)
        XCTAssertEqual(try DItemStore.currentItem(id: "D602", at: cache).title, "保持原样")
    }

    func testStaleRowDoesNotOverwriteConcurrentAIEditAndUserCanRestoreRemoval() throws {
        try report(["--release-add", "发布 ultra"])
        let original = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        try report(["--release-edit", "L001=发布 ultra 后端"])
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.toggle(original) })
        XCTAssertEqual(try Data(contentsOf: cache), before)
        let current = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.remove(current) })
        XCTAssertTrue(try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.excludedByUser.contains(current.text))
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.restore(current) })
        let restored = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertEqual(restored.id, current.id)
        XCTAssertEqual(restored.text, current.text)
        XCTAssertEqual(restored.done, current.done)
        XCTAssertEqual(restored.updatedBy, .user)
    }

    func testCompletionRestoreRetainsChecklistAndCorruptDataIsNotEmpty() throws {
        var list = DemandReleaseChecklist()
        XCTAssertTrue(list.add("发布 ultra", author: .user))
        XCTAssertTrue(list.toggle(list.items[0]))
        var block = ["### D603【ultra】已完成的需求 #已完成 ✅2026-11-04", "- **描述**：完整历史"]
        try DemandReleaseChecklist.set(&block, checklist: list)
        let record = try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
        XCTAssertEqual(record.item.releaseChecklist, list)
        XCTAssertTrue(DItemStore.reopenArchive(record, at: cache))
        XCTAssertEqual(try DItemStore.currentItem(id: "D603", at: cache).releaseChecklist, list)
        let broken = source.replacingOccurrences(of: "- **描述**：锁券改造", with: DemandReleaseChecklist.prefix + "broken -->\n- **描述**：锁券改造")
        try broken.write(to: cache, atomically: true, encoding: .utf8)
        XCTAssertNotNil(try DItemStore.currentItem(id: "D601", at: cache).releaseChecklistReadError)
        XCTAssertFalse(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.add("不能覆盖", author: .user) })
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), broken)
    }

    func testLegacyEntryAndStructuredDetailsRemainReadableAndPreserveChecks() throws {
        let legacy = "{\"items\":[{\"id\":\"L001\",\"text\":\"旧格式事项\",\"done\":true,\"updated_by\":\"user\"}],\"excluded_by_user\":[],\"next_id\":2}"
        let line = DemandReleaseChecklist.prefix + Data(legacy.utf8).base64EncodedString() + DemandReleaseChecklist.suffix
        try source.replacingOccurrences(of: "- **描述**：锁券改造", with: line + "\n- **描述**：锁券改造").write(to: cache, atomically: true, encoding: .utf8)
        let old = try DItemStore.currentItem(id: "D601", at: cache)
        XCTAssertEqual(old.releaseChecklist.items[0].details, "")
        XCTAssertTrue(old.releaseChecklist.items[0].done)
        let details = "开发分支：feature/gaode。\nSQL：doc/sql/create.sql。\n### D999 只是明细，不是另一条需求"
        let json = try JSONSerialization.data(withJSONObject: ["summary": "发布 Ultra 服务", "details": details])
        try report(["--release-item", String(decoding: json, as: UTF8.self)])
        var current = try DItemStore.currentItem(id: "D601", at: cache)
        let entry = current.releaseChecklist.items[1]
        XCTAssertEqual(entry.text, "发布 Ultra 服务")
        XCTAssertEqual(entry.details, details)
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.edit(entry, text: entry.text, details: details + "\n用户补充的顺序") })
        current = try DItemStore.currentItem(id: "D601", at: cache)
        XCTAssertEqual(current.releaseChecklist.items[1].updatedBy, .user)
        let context = try call(["context", "D601"])
        XCTAssertTrue((context["context"] as? String)?.contains("用户补充的顺序") == true)
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.toggle(current.releaseChecklist.items[1]) })
        XCTAssertEqual(try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[1].details, details + "\n用户补充的顺序")
        XCTAssertEqual(CacheParser.parse(content: try String(contentsOf: cache, encoding: .utf8)).items.map(\.id), ["D601", "D602"])
    }


    func testCategoryCompatibilityAndUserChangesSurviveCLIAndUndo() throws {
        let cases: [(String, DemandReleaseChecklist.Category)] = [
            ("创建归因结果表", .sql), ("补齐查询索引", .sql), ("发布 Ultra 服务", .release),
            ("配置 Ultra ES 连接", .configuration), ("启用归因定时任务", .configuration),
            ("开通生产查询接口", .permission), ("配置菜单权限", .permission), ("备份附件", .other)
        ]
        for (text, expected) in cases {
            let bytes = try JSONSerialization.data(withJSONObject: ["id": "L001", "text": text, "done": false, "updated_by": "ai"])
            let entry = try JSONDecoder().decode(DemandReleaseChecklist.Entry.self, from: bytes)
            XCTAssertEqual(entry.category, expected)
        }
        let payload = try JSONSerialization.data(withJSONObject: ["summary": "执行预发检查", "category": "permission", "details": "保留原有明细"])
        try report(["--release-item", String(decoding: payload, as: UTF8.self)])
        let entry = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertEqual(entry.category, .permission)
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.edit(entry, text: entry.text, category: .configuration) })
        let current = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertEqual(current.details, entry.details)
        XCTAssertEqual(current.updatedBy, .user)
        let response = try call(["context", "D601"])
        let item = try XCTUnwrap(response["item"] as? [String: Any])
        let list = try XCTUnwrap(item["release_checklist"] as? [String: Any])
        let entries = try XCTUnwrap(list["items"] as? [[String: Any]])
        XCTAssertEqual(entries[0]["category"] as? String, "configuration")
        XCTAssertTrue((response["context"] as? String)?.contains("### 配置") == true)
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.toggle(current) })
        let checked = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.remove(checked) })
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) { $0.restore(checked) })
        let restored = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertEqual(restored.category, .configuration)
        XCTAssertEqual(restored.details, "保留原有明细")
        XCTAssertTrue(restored.done)
        let invalid = #"{"id":"L001","text":"坏分类","done":false,"updated_by":"ai","category":"unknown"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(DemandReleaseChecklist.Entry.self, from: Data(invalid.utf8)))
    }


    func testCustomCategoriesRoundtripWithCLIAndRetainUserOwnership() throws {
        XCTAssertEqual(DemandReleaseChecklist.Category.named("SQL"), .sql)
        XCTAssertEqual(DemandReleaseChecklist.Category.named(" 数据迁移 "), .custom("数据迁移"))
        XCTAssertNil(DemandReleaseChecklist.Category.named(String(repeating: "长", count: 21)))
        XCTAssertNil(DemandReleaseChecklist.Category(rawValue: "custom:SQL"))
        let payload = try JSONSerialization.data(withJSONObject: [
            "summary": "申请 ES 存储资源", "category": "custom:资源准备", "details": "确认生产容量后再启用任务"])
        try report(["--release-item", String(decoding: payload, as: UTF8.self)])
        let entry = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertEqual(entry.category, .custom("资源准备"))
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D601", at: cache) {
            $0.edit(entry, text: entry.text, category: .custom("容量规划"))
        })
        let latest = try DItemStore.currentItem(id: "D601", at: cache).releaseChecklist.items[0]
        XCTAssertEqual(latest.details, entry.details)
        XCTAssertEqual(latest.updatedBy, .user)
        let context = try call(["context", "D601"])
        XCTAssertTrue((context["context"] as? String)?.contains("### 容量规划") == true)
        var list = DemandReleaseChecklist()
        XCTAssertTrue(list.add("无效分类", author: .user, category: .custom("")))
        XCTAssertFalse(list.isValid)
    }

    @MainActor
    func testRealD013ShortSummariesRenderWithoutChangingUserData() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_D013_RELEASE_SMOKE"] else {
            throw XCTSkip("Enable read-only D013 checklist screenshot explicitly")
        }
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: CacheFile.path)
        let before = try Data(contentsOf: url)
        let item = try DItemStore.currentItem(id: "D013")
        XCTAssertEqual(item.releaseChecklist.items.count, 8)
        for category in DemandReleaseChecklist.Category.allCases where category != .other {
            XCTAssertEqual(item.releaseChecklist.items.filter { $0.category == category }.count, 2)
        }
        XCTAssertTrue(item.releaseChecklist.items.allSatisfy { $0.text.count <= 40 && !$0.details.isEmpty })
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [item]
        let view = NSHostingView(rootView: DemandReleaseChecklistView(item: item).padding(20)
            .environmentObject(vm).frame(width: 650, height: 560).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        XCTAssertTrue(vm.releaseDrafts.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    @MainActor
    func testChecklistAppearanceWithoutStartingEditors() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_RELEASE_SMOKE"] else {
            throw XCTSkip("Enable isolated checklist screenshot explicitly")
        }
        _ = NSApplication.shared
        var item = try DItemStore.currentItem(id: "D601", at: cache)
        item.releaseChecklist.add("上线前执行 V20261104__create_lock_record.sql，创建 lock_record 表", author: .ai)
        item.releaseChecklist.add("确认门店锁券功能开关已配置", author: .user)
        item.releaseChecklist.add("发布 ultra 服务（SQL 执行完成后）", author: .ai)
        item.releaseChecklist.toggle(item.releaseChecklist.items[0])
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [item]
        let view = NSHostingView(rootView: DemandReleaseChecklistView(item: item).padding(20)
            .environmentObject(vm).frame(width: 650, height: 300).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        XCTAssertTrue(vm.releaseDrafts.isEmpty)
    }
}
