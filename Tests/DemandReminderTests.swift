import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandReminderTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!
    private let source = """
    ## 🟡 重要
    ### D501【ultra】提醒测试 #进行中
    - **描述**：锁券接口改造
        需要保留的补充描述
    - **提示词**：
        ## 要做什么
        - **进展提醒**：这只是咒言里的文字
    - **分支**：ultra:feature/cdd
    - **进度**：
        - 11.4: 开发完成，待联调

    ### D502【audi】其他需求 #待开始
    - **描述**：不要修改
    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardReminder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("cache.md")
        try source.write(to: cache, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testReminderSurvivesAIReportingWithoutChangingScopeOrCloudOverview() throws {
        let original = try DItemStore.currentItem(id: "D501", at: cache)
        XCTAssertTrue(original.reminder.isEmpty, "Indented spell text is not a personal reminder")
        let overview = try DemandOverview.hash(source)
        XCTAssertTrue(DItemStore.saveReminder(id: original.id, text: "正在联调，等上游提供券码", expected: "", at: cache))
        let saved = try DItemStore.currentItem(id: original.id, at: cache)
        XCTAssertEqual(saved.reminder, "正在联调，等上游提供券码")
        XCTAssertEqual(saved.executionScope, original.executionScope)
        XCTAssertEqual(saved.title, original.title)
        XCTAssertEqual(saved.prompt, original.prompt)
        XCTAssertEqual(try DemandOverview.hash(String(contentsOf: cache, encoding: .utf8)), overview)

        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/dboard_ai.py").path
        let show = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "show", "D501"])
        XCTAssertEqual(show.exitCode, 0)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: show.stdout) as? [String: Any])
        let item = try XCTUnwrap(json["item"] as? [String: Any])
        let revision = try XCTUnwrap(item["revision"] as? String)
        let title = try XCTUnwrap(item["title"] as? String)
        let report = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path,
            "report", "D501", "--no-sync", "--expect-title", title, "--expect-revision", revision,
            "--summary", "接口试调通过，待外部联调。", "--event-id", "reminder-test-report"])
        XCTAssertEqual(report.exitCode, 0, String(data: report.stdout, encoding: .utf8) ?? "")
        XCTAssertEqual(try DItemStore.currentItem(id: "D501", at: cache).reminder, saved.reminder)
        XCTAssertTrue(DItemStore.saveReminder(id: "D501", text: "等上游验收", expected: saved.reminder, at: cache))
        let latest = try DItemStore.currentItem(id: "D501", at: cache)
        XCTAssertEqual(latest.milestones.last?.content, "接口试调通过，待外部联调。")
        XCTAssertEqual(latest.reminder, "等上游验收")
        XCTAssertEqual(try DItemStore.currentItem(id: "D502", at: cache).title, "不要修改")
    }

    func testSingleLinePasteClearAndOtherEditsKeepExistingContext() throws {
        let original = try DItemStore.currentItem(id: "D501", at: cache)
        XCTAssertTrue(DItemStore.saveReminder(id: "D501", text: "联调中\n等待券码\t明天再看", expected: "", at: cache))
        let saved = try DItemStore.currentItem(id: "D501", at: cache)
        XCTAssertEqual(saved.reminder, "联调中 等待券码 明天再看")
        var draft = DItemDraft(from: saved)
        draft.name = "修改后的需求名"
        draft.priority = .p2
        XCTAssertTrue(DItemStore.save(draft, original: saved, at: cache))
        let edited = try DItemStore.currentItem(id: "D501", at: cache)
        XCTAssertEqual(edited.reminder, saved.reminder)
        XCTAssertTrue(DItemStore.saveReminder(id: "D501", text: " ", expected: edited.reminder, at: cache))
        let cleared = try DItemStore.currentItem(id: "D501", at: cache)
        XCTAssertEqual(cleared.reminder, "")
        XCTAssertEqual(cleared.prompt, original.prompt)
        XCTAssertEqual(cleared.title, original.title)
        XCTAssertEqual(cleared.milestones.map(\.content), original.milestones.map(\.content))
    }

    @MainActor
    func testAutosaveAndFailedSavePreserveUserInput() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        let item = try XCTUnwrap(vm.items.first)
        vm.editReminder(item, text: "正在等外部环境", at: cache)
        vm.workspacePage = .todos
        RunLoop.main.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(try DItemStore.currentItem(id: "D501", at: cache).reminder, "正在等外部环境")
        XCTAssertNil(vm.reminderDrafts[item.id])

        let latest = try XCTUnwrap(vm.items.first)
        vm.editReminder(latest, text: "我的未保存输入", at: cache)
        XCTAssertTrue(DItemStore.saveReminder(id: latest.id, text: "另一处已更新", expected: latest.reminder, at: cache))
        XCTAssertFalse(vm.saveReminder(latest.id))
        XCTAssertEqual(vm.reminderDrafts[latest.id]?.text, "我的未保存输入")
        XCTAssertEqual(try DItemStore.currentItem(id: latest.id, at: cache).reminder, "另一处已更新")
    }

    func testCompletedSnapshotAndRestoreRetainReminder() throws {
        let block = ["### D503【ultra】已完成需求 #已完成 ✅2026-11-04", "- **进展提醒**：等最终验收确认",
            "- **描述**：保留背景", "- **进度**：", "    - 11.4: 开发已完成"]
        let archive = try XCTUnwrap(DemandArchive.parse(block.joined(separator: "\n")).first)
        XCTAssertEqual(archive.item.reminder, "等最终验收确认")
        XCTAssertTrue(DItemStore.reopenArchive(archive, at: cache))
        XCTAssertEqual(try DItemStore.currentItem(id: "D503", at: cache).reminder, archive.item.reminder)
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.saveReminder(id: "D999", text: "不存在", expected: "", at: cache))
        XCTAssertEqual(try Data(contentsOf: cache), before)
    }

    @MainActor
    func testCollapsedReminderAppearance() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_REMINDER_SMOKE"] else {
            throw XCTSkip("Enable isolated reminder screenshot explicitly")
        }
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        let fixtures = source.replacingOccurrences(of: "- **描述**：锁券接口改造", with: "- **进展提醒**：正在联调，等上游提供券码\n- **描述**：锁券接口改造")
            .replacingOccurrences(of: "- **描述**：不要修改", with: "- **进展提醒**：等待测试环境，周五再跟进\n- **描述**：不要修改")
        vm.items = CacheParser.parse(content: fixtures).items
        let view = NSHostingView(rootView: VStack(spacing: 10) {
            ForEach(vm.items, id: \.id) { item in ItemCardView(item: item) }
        }.environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
            .frame(width: 660, height: 340).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        XCTAssertTrue(vm.expandedIDs.isEmpty)
        XCTAssertTrue(vm.reminderDrafts.isEmpty, "Displaying cards must not start editing or save placeholder text")
    }
}
