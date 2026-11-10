import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandReleaseEvidenceTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!
    private let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py").path

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardReleaseEvidence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("cache.md")
        var list = DemandReleaseChecklist()
        XCTAssertTrue(list.add("发布 Ultra 服务", author: .ai))
        var block = ["### D777【ultra】证据测试 #进行中", "- **描述**：保留背景"]
        try DemandReleaseChecklist.set(&block, checklist: list)
        try ("## 🟡 重要\n" + block.joined(separator: "\n")).write(to: cache, atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func item() throws -> DItem { try DItemStore.currentItem(id: "D777", at: cache) }
    private func call(_ args: [String]) throws -> [String: Any] {
        let result = HandoffCLIFixture.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path] + args)
        XCTAssertEqual(result.exitCode, 0, String(decoding: result.stdout, as: UTF8.self))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<64 { for y in 0..<40 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.7, blue: 0.4, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testEvidenceSurvivesCheckUndoEditMoveAndCLIFeedbackAndIsReadableByNextAI() throws {
        let original = try item().releaseChecklist.items[0]
        let store = DemandImageStore(directory: directory.appendingPathComponent("images"))
        let markdown = try store.importData(png(), label: "发布成功")
        let evidence = "发布平台确认成功\n" + markdown
        let overview = try DemandOverview.hash(String(contentsOf: cache, encoding: .utf8))
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.setEvidence(original.id, text: evidence, expected: "") })
        XCTAssertFalse(try item().releaseChecklist.items[0].done)
        // A check based on the visible row remains valid after independently adding evidence.
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.toggle(original) })
        var current = try item()
        XCTAssertTrue(current.releaseChecklist.items[0].done)
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.toggle(current.releaseChecklist.items[0]) })
        current = try item()
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) {
            $0.edit(current.releaseChecklist.items[0], text: "发布 Ultra 后端服务", details: "保留分支说明")
        })
        XCTAssertTrue(DItemStore.setPriority(id: "D777", .p0, at: cache, expectedPriority: .p1))
        current = try item()
        let latest = try XCTUnwrap(try call(["show", "D777"])["item"] as? [String: Any])
        _ = try call(["report", "D777", "--expect-title", latest["title"] as! String,
            "--expect-revision", latest["revision"] as! String, "--release-add", "执行 SQL", "--no-sync"])
        let context = try call(["context", "D777"])
        let text = try XCTUnwrap(context["context"] as? String)
        XCTAssertTrue(text.contains("发布平台确认成功"))
        XCTAssertTrue(text.contains(markdown))
        let images = try XCTUnwrap(context["images"] as? [[String: Any]])
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0]["exists"] as? Bool, true)
        let shown = try call(["show", "D777"])
        let shownImages = try XCTUnwrap((shown["item"] as? [String: Any])?["images"] as? [[String: Any]])
        XCTAssertEqual(shownImages.first?["path"] as? String, images.first?["path"] as? String)
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, evidence)
        // Proof and local checklist updates do not trigger remote overview uploads.
        XCTAssertEqual(try DemandOverview.hash(String(contentsOf: cache, encoding: .utf8)), overview)
    }

    func testEvidenceUpdatePreservesIndependentChangesAndRejectsStaleProof() throws {
        let original = try item().releaseChecklist.items[0]
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.edit(original, text: "发布已核对的 Ultra 服务") })
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.setEvidence("L001", text: "第一份证据", expected: "") })
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.setEvidence("L001", text: "过期草稿", expected: "") })
        XCTAssertEqual(try Data(contentsOf: cache), before)
        XCTAssertEqual(try item().releaseChecklist.items[0].text, "发布已核对的 Ultra 服务")
        XCTAssertTrue(DItemStore.updateReleaseChecklist(id: "D777", at: cache) { $0.setEvidence("L001", text: "", expected: "第一份证据") })
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, "")
    }

    @MainActor
    func testPendingEvidenceIsFlushedAndRetainedInCompletionRecord() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [try item()]
        let original = vm.items[0].releaseChecklist.items[0]
        vm.updateReleaseEvidence("D777", entry: original, text: "待保存的发布成功截图说明", at: cache)
        XCTAssertTrue(vm.saveReleaseEvidenceDrafts("D777", at: cache))
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, "待保存的发布成功截图说明")
        let completed = try String(contentsOf: cache, encoding: .utf8).replacingOccurrences(of: "#进行中", with: "#已完成")
        let archive = try XCTUnwrap(DemandArchive.parse(completed).first)
        XCTAssertEqual(archive.item.releaseChecklist.items[0].evidence, "待保存的发布成功截图说明")
        XCTAssertFalse(archive.item.releaseChecklist.items[0].done)
    }

    @MainActor
    func testTypingAndChineseCompositionStayStableUntilEditingEnds() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [try item()]
        let original = vm.items[0].releaseChecklist.items[0]
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 480, height: 380),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DemandReleaseEvidenceEditor(itemID: "D777",
            entry: original, close: {}, cacheURL: cache).environmentObject(vm)
            .padding(14).frame(width: 480, height: 380, alignment: .topLeading))
        defer { window.contentView = nil; window.close() }
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func findEditor(_ view: NSView) -> DemandSpellTextView? {
            if let editor = view as? DemandSpellTextView { return editor }
            return view.subviews.compactMap(findEditor).first
        }
        let editor = try XCTUnwrap(window.contentView.flatMap(findEditor))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("已发布 ", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.65))
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, "", "Typing pauses must not write and refresh the panel")
        editor.setMarkedText("chenggong", selectedRange: NSRange(location: 9, length: 0),
            replacementRange: editor.selectedRange())
        editor.didChangeText()
        let selection = editor.selectedRange()
        vm.releaseEvidenceErrors["another-entry"] = "刷新其他事项"
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertTrue(editor.hasMarkedText(), "An unrelated SwiftUI update must not replace the input method composition")
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertEqual(vm.releaseEvidenceDrafts["D777:L001"]?.text, "已发布 ")
        editor.insertText("成功", replacementRange: editor.markedRange())
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(vm.releaseEvidenceDrafts["D777:L001"]?.text, "已发布 成功")
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, "")
        XCTAssertTrue(window.makeFirstResponder(nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, "已发布 成功")
        XCTAssertFalse(try item().releaseChecklist.items[0].done)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.insertText("，待核对", replacementRange: editor.selectedRange())
        window.contentView = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(try item().releaseChecklist.items[0].evidence, "已发布 成功，待核对")
    }

    @MainActor
    func testNativeImagePasteAutosavesOnCloseWithoutChangingCheckOrUserClipboard() throws {
        _ = NSApplication.shared
        let before = try Data(contentsOf: URL(fileURLWithPath: CacheFile.path))
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [try item()]
        let store = DemandImageStore(directory: directory.appendingPathComponent("images"))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 480, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DemandReleaseEvidenceEditor(itemID: "D777",
            entry: vm.items[0].releaseChecklist.items[0], close: {}, imageStore: store, cacheURL: cache)
            .environmentObject(vm).padding(14).frame(width: 480, height: 380, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        defer { window.close() }
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        func findEditor(_ view: NSView) -> DemandSpellTextView? {
            if let editor = view as? DemandSpellTextView { return editor }
            for child in view.subviews { if let editor = findEditor(child) { return editor } }
            return nil
        }
        let editor = try XCTUnwrap(window.contentView.flatMap(findEditor))
        XCTAssertTrue(window.makeFirstResponder(editor))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(try png(), forType: .png)
        editor.pasteboard = pasteboard
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        XCTAssertTrue(editor.performKeyEquivalent(with: event))
        if let output = ProcessInfo.processInfo.environment["DBOARD_EVIDENCE_UI_SNAPSHOTS"] {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let view = try XCTUnwrap(window.contentView)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output + "/evidence-editor.png"))
        }
        window.contentView = nil // Closing/switching away flushes the pending automatic save.
        window.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let saved = try item().releaseChecklist.items[0]
        XCTAssertFalse(saved.done)
        XCTAssertEqual(DemandImageMarkdown.references(in: saved.evidence).count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: CacheFile.path)), before)
    }
}
