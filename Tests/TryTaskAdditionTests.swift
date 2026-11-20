import XCTest
import AppKit
@testable import DBoard

final class TryTaskAdditionTests: XCTestCase {
    func testDraftSaveReopensCompletedTaskWithoutReplacingOriginalOrDuplicating() throws {
        try isolated { store in
            let id = try XCTUnwrap(store.create(.task))
            store.edit(id, field: "body", value: "原目标")
            XCTAssertTrue(store.update(id) { $0.status = .done; $0.aiSummary = "已经完成"; $0.aiResult = "上轮成果" })
            store.editAdditionDraft(id, body: "增加导出\n![图](</tmp/addition.png>)", generation: 0)
            XCTAssertTrue(store.flush())
            let fresh = TryStore(url: store.url, watching: false)
            XCTAssertEqual(fresh.entry(id)?.status, .done)
            XCTAssertTrue(fresh.entry(id)?.pendingAdditions.isEmpty == true)
            XCTAssertEqual(fresh.submitAddition(id), "A001")
            XCTAssertEqual(fresh.entry(id)?.status, .active)
            XCTAssertEqual(fresh.entry(id)?.body, "原目标")
            XCTAssertEqual(fresh.entry(id)?.aiResult, "上轮成果")
            fresh.editAdditionDraft(id, body: "延迟回写", generation: 0)
            XCTAssertTrue(fresh.additionDraft(id).isEmpty)
            XCTAssertNil(fresh.submitAddition(id))
            XCTAssertEqual(fresh.document.entries.count, 1)
            XCTAssertTrue(fresh.handoff(id)?.contains("未完成的追加内容") == true)
            let context = try cli(fresh, ["context", id]).1
            let item = try XCTUnwrap(context["item"] as? [String: Any])
            XCTAssertEqual((item["pendingAdditions"] as? [[String: Any]])?.first?["body"] as? String, "增加导出\n![图](</tmp/addition.png>)")
            XCTAssertEqual((context["images"] as? [[String: Any]])?.first?["path"] as? String, "/tmp/addition.png")
            XCTAssertTrue((context["feedback_instructions"] as? String)?.contains("不得因旧摘要写着完成而跳过") == true)
        }
    }

    func testConditionalCLICompletionRejectsChangedVersionsAndDoesNotCompleteWholeTask() throws {
        try isolated { store in
            let id = try XCTUnwrap(store.create(.task))
            store.edit(id, field: "body", value: "原功能")
            store.editAdditionDraft(id, body: "第一项", generation: 0)
            let first = try XCTUnwrap(store.submitAddition(id))
            store.editAdditionDraft(id, body: "第二项", generation: store.additionGeneration(id))
            let second = try XCTUnwrap(store.submitAddition(id))
            XCTAssertTrue(store.prepareAddition(id, editing: first))
            store.editAdditionDraft(id, body: "第一项又修改了", generation: store.additionGeneration(id))
            XCTAssertEqual(store.submitAddition(id), first)
            let revision = try XCTUnwrap(store.entry(id)?.revision)
            let before = try Data(contentsOf: store.url)
            XCTAssertNotEqual(try cli(store, ["report", id, "--expected-revision", String(revision), "--summary", "旧结论",
                "--complete-addition", first + "@1"]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
            XCTAssertNotEqual(try cli(store, ["report", id, "--expected-revision", String(revision), "--summary", "不能部分生效",
                "--complete-addition", first + "@2", "--complete-addition", "A999@1"]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
            store.editAdditionDraft(id, body: "未提交的草稿", generation: store.additionGeneration(id))
            XCTAssertTrue(store.flush())
            let args = ["report", id, "--expected-revision", String(revision), "--summary", "第一项已处理",
                        "--complete-addition", first + "@2", "--event-id", "round1"]
            XCTAssertEqual(try cli(store, args).0, 0)
            XCTAssertEqual(try cli(store, args).1["duplicate"] as? Bool, true)
            store.reload()
            XCTAssertEqual(store.entry(id)?.pendingAdditions.map(\.id), [second])
            XCTAssertEqual(store.additionDraft(id).body, "未提交的草稿")
            XCTAssertEqual(store.entry(id)?.body, "原功能")
            XCTAssertEqual(store.entry(id)?.status, .active)
            XCTAssertFalse(store.status(id, .done))
            XCTAssertTrue(store.markAddition(id, additionID: second, completed: true), "Warning must not block the next correction")
            XCTAssertTrue(store.status(id, .done))
            let item = try XCTUnwrap(try cli(store, ["context", id]).1["item"] as? [String: Any])
            XCTAssertTrue((item["pendingAdditions"] as? [[String: Any]])?.isEmpty == true)
            XCTAssertEqual((item["processedAdditions"] as? [[String: Any]])?.first?["summary"] as? String, "第一项又修改了")
        }
    }

    func testEditResetsCompletionAndWithdrawalRetainsHistoryAndUniqueIDs() throws {
        try isolated { store in
            let id = try XCTUnwrap(store.create(.task))
            store.editAdditionDraft(id, body: "导出", generation: 0)
            let first = try XCTUnwrap(store.submitAddition(id))
            XCTAssertTrue(store.markAddition(id, additionID: first, completed: true))
            XCTAssertTrue(store.status(id, .done))
            XCTAssertTrue(store.prepareAddition(id, editing: first))
            store.editAdditionDraft(id, body: "导出也要有图片", generation: store.additionGeneration(id))
            XCTAssertEqual(store.submitAddition(id), first)
            XCTAssertEqual(store.entry(id)?.pendingAdditions.first?.revision, 2)
            XCTAssertEqual(store.entry(id)?.status, .active)
            XCTAssertTrue(store.withdrawAddition(id, additionID: first))
            XCTAssertTrue(store.entry(id)?.pendingAdditions.isEmpty == true)
            store.editAdditionDraft(id, body: "改为打印", generation: store.additionGeneration(id))
            XCTAssertEqual(store.submitAddition(id), "A002")
            XCTAssertEqual((try cli(store, ["history", id]).1["additions"] as? [[String: Any]])?.count, 2)
        }
    }

    @MainActor
    func testActualEditorKeepsImagesAndDraftAcrossClosingAndSavesOneAddition() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try XCTUnwrap(store.create(.task))
            store.edit(id, field: "title", value: "个人工具")
            store.edit(id, field: "body", value: "原目标，基础功能已完成")
            XCTAssertTrue(store.flush())
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            let window = try XCTUnwrap(detail.window)
            try click("try-add-content", window)
            let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.last)
            XCTAssertTrue(window.firstResponder === editor)
            editor.insertText("加一个图片导出功能", replacementRange: editor.selectedRange())
            let board = NSPasteboard(name: .init("TryAddition-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 3,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 12, bitsPerPixel: 32))
            board.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
            editor.imageStore = DemandImageStore(directory: store.url.deletingLastPathComponent().appendingPathComponent("images"))
            editor.pasteboard = board; editor.paste(nil); settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.additionDraft(id).body).count, 1)
            try click("try-addition-close", window)
            XCTAssertTrue(store.entry(id)?.pendingAdditions.isEmpty == true)
            detail.close(); settle()
            detail.show(id); settle()
            defer { detail.close() }
            let reopened = try XCTUnwrap(detail.window)
            try click("try-add-content", reopened)
            XCTAssertTrue(store.additionDraft(id).body.contains("图片导出"))
            try click("try-addition-save", reopened); settle()
            XCTAssertEqual(store.entry(id)?.pendingAdditions.count, 1)
            XCTAssertEqual(store.entry(id)?.body, "原目标，基础功能已完成")
            XCTAssertTrue(store.additionDraft(id).isEmpty)
            XCTAssertEqual(store.document.entries.count, 1)
            if let output = ProcessInfo.processInfo.environment["DBOARD_TRY_ADDITION_SNAPSHOT"] {
                let view = try XCTUnwrap(reopened.contentView)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
            }
        }
    }

    @MainActor
    func testOpeningAdditionRevealsAndFocusesEditorWithoutManualScrolling() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try XCTUnwrap(store.create(.task))
            let original = (1...70).map { "原目标第\($0)行，正文很长，追加入口仍应直接打开可见的输入区。" }.joined(separator: "\n")
            store.edit(id, field: "body", value: original)
            XCTAssertTrue(store.flush())
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            window.setContentSize(NSSize(width: 700, height: 560)); settle()

            try click("try-add-content", window, reveal: false)
            let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.last)
            let viewport = try XCTUnwrap(editor.enclosingScrollView)
            assertVisible(viewport, in: window)
            XCTAssertTrue(window.firstResponder === editor, "Opening must focus the visible addition editor automatically.")
            editor.insertText("新增导出功能", replacementRange: editor.selectedRange())
            settle()
            XCTAssertEqual(store.additionDraft(id).body, "新增导出功能")

            // Even when composing is already true, clicking the fixed toolbar must bring it back.
            let originalEditor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            var ancestor = originalEditor.enclosingScrollView?.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView, let document = scroll.documentView {
                    document.scroll(NSPoint(x: 0, y: 0))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                ancestor = view.superview
            }
            settle()
            try click("try-add-content", window, reveal: false)
            assertVisible(viewport, in: window)
            XCTAssertTrue(window.firstResponder === editor)

            try click("try-addition-close", window, reveal: false)
            try click("try-add-content", window, reveal: false)
            let resumed = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.last)
            assertVisible(try XCTUnwrap(resumed.enclosingScrollView), in: window)
            XCTAssertTrue(window.firstResponder === resumed)
            XCTAssertEqual(store.additionDraft(id).body, "新增导出功能")
            try click("try-addition-save", window, reveal: false)
            let row = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .first { $0.keyboardIdentifier == "try-addition-A001" })
            assertVisible(row, in: window)
            XCTAssertEqual(store.entry(id)?.body, original)
            XCTAssertEqual(store.entry(id)?.pendingAdditions.count, 1)
        }
    }

    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TryAddition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(TryStore(url: folder.appendingPathComponent("personal.json"), watching: false))
    }
    private func cli(_ store: TryStore, _ args: [String]) throws -> (Int32, [String: Any]) {
        let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [cli.path, "try", "--store", store.url.path] + args
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any]))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    @MainActor private func assertVisible(_ target: NSView, in window: NSWindow, requiresScroll: Bool = true,
        file: StaticString = #filePath, line: UInt = #line) {
        var ancestor = target.superview
        var checkedClip = false
        while let view = ancestor {
            if let clip = view as? NSClipView {
                checkedClip = true
                let rect = target.convert(target.bounds, to: clip)
                XCTAssertTrue(clip.bounds.insetBy(dx: -1, dy: -1).contains(rect),
                    "Target \(rect) must be inside viewport \(clip.bounds), without manually scrolling.",
                    file: file, line: line)
            }
            ancestor = view.superview
        }
        XCTAssertTrue(!requiresScroll || checkedClip, "Verify the actual enclosing scroll viewport.", file: file, line: line)
        if let root = window.contentView {
            XCTAssertTrue(root.bounds.contains(target.convert(target.bounds, to: root)), file: file, line: line)
        }
    }
    @MainActor private func click(_ id: String, _ window: NSWindow, reveal: Bool = true) throws {
        let target = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
            .first { $0.keyboardIdentifier == id })
        if reveal {
            var ancestor = target.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView, let document = scroll.documentView {
                    document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
                }
                ancestor = view.superview
            }
            settle()
        } else {
            assertVisible(target, in: window, requiresScroll: id != "try-add-content")
        }
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
    }
}
