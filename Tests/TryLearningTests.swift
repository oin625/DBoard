import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class TryLearningTests: XCTestCase {
    func testLegacyLearningBecomesEditableNotesAndTasksStayOutsideWorkspace() throws {
        try isolated { store in
            let learning = try XCTUnwrap(store.create(.digestion))
            let task = try XCTUnwrap(store.create(.task))
            store.edit(learning, field: "body", value: "旧学习笔记\n我的理解")
            store.edit(task, field: "body", value: "旧个人项目")
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(learning)?.learningNotes.first?.id, "N001")
            store.editLearningNote(learning, noteID: "N001", field: "body", value: "更新后的理解", generation: 0)
            XCTAssertTrue(store.flush())
            let fresh = TryStore(url: store.url, watching: false)
            XCTAssertEqual(fresh.entry(learning)?.learningNotes.first?.body, "更新后的理解")
            XCTAssertEqual(fresh.entry(learning)?.body, "旧学习笔记\n我的理解")
            XCTAssertEqual(fresh.entry(task)?.body, "旧个人项目")
            XCTAssertEqual(TryKind.workspaceKinds, [.digestion, .idea])
            let quick = TryQuickOpenModel()
            quick.begin(fresh.document.entries)
            XCTAssertEqual(quick.scope, .health)
            quick.moveScope(1)
            XCTAssertEqual(quick.scope, .digestion)
            XCTAssertEqual(quick.entries.map(\.id), [learning])
            quick.moveScope(1)
            XCTAssertEqual(quick.scope, .idea)
            quick.moveScope(1)
            XCTAssertEqual(quick.scope, .idea)
        }
    }
    func testNoteDraftSurvivesReloadAndLateEditorCannotReviveSavedDraft() throws {
        try isolated { store in
            let id = try topic(store)
            store.editLearningNote(id, noteID: nil, field: "body", value: "第二篇\n![证据](</tmp/learning.png>)", generation: 0)
            store.rememberLearningNote(id, noteID: nil, bookmark: TryBookmark(location: 3, length: 0, scrollY: 12), generation: 0)
            store.selectLearningNote(id, noteID: nil)
            XCTAssertTrue(store.flush())
            let fresh = TryStore(url: store.url, watching: false)
            XCTAssertEqual(fresh.entry(id)?.learningDraft.bookmark?.location, 3)
            XCTAssertEqual(fresh.entry(id)?.selectedLearningNoteID, "_draft")
            XCTAssertEqual(fresh.saveLearningNote(id), "N002")
            fresh.editLearningNote(id, noteID: nil, field: "body", value: "过期回写", generation: 0)
            XCTAssertTrue(fresh.entry(id)?.learningDraft.isEmpty == true)
            XCTAssertNil(fresh.saveLearningNote(id))
            XCTAssertEqual(fresh.entry(id)?.learningNotes.count, 2)
            XCTAssertEqual(fresh.document.entries.count, 1)
            XCTAssertTrue(fresh.removeLearningNote(id, noteID: "N002"))
            fresh.editLearningNote(id, noteID: nil, field: "body", value: "第三篇", generation: fresh.learningGeneration(id))
            XCTAssertEqual(fresh.saveLearningNote(id), "N003")
            XCTAssertTrue(fresh.removeLearningNote(id, noteID: "N002", restore: true))
            XCTAssertEqual(fresh.entry(id)?.learningNotes.count, 3)
        }
    }
    func testAISuggestionsRequireAcceptanceAndConcurrentNoteEditsKeepFeedback() throws {
        try isolated { store in
            let id = try topic(store)
            store.edit(id, field: "progress", value: "正在看RDB")
            XCTAssertTrue(store.flush())
            let revision = try XCTUnwrap(store.entry(id)?.revision)
            store.editLearningNote(id, noteID: "N001", field: "body", value: "我的新理解", generation: 0)
            let report = try cli(store, ["report", id, "--expected-revision", String(revision),
                "--summary", "解释了持久化差异", "--progress", "可以继续看AOF", "--learning-outcome", "能解释RDB的适用场景",
                "--learning-note", "N001", "--event-id", "study-round1"])
            XCTAssertEqual(report.0, 0)
            store.reload()
            XCTAssertEqual(store.entry(id)?.learningNotes.first?.body, "我的新理解")
            XCTAssertEqual(store.entry(id)?.progress, "正在看RDB")
            XCTAssertTrue(store.entry(id)?.learningOutcomes.isEmpty == true)
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(id)?.learningSuggestion?.outcomes.count, 1)
            XCTAssertEqual(store.entry(id)?.reports.count, 1)
            XCTAssertTrue(store.acceptLearningSuggestion(id))
            XCTAssertEqual(store.entry(id)?.progress, "可以继续看AOF")
            XCTAssertEqual(store.entry(id)?.learningOutcomes.first?.noteID, "N001")
            XCTAssertNil(store.entry(id)?.learningSuggestion)
            let before = try Data(contentsOf: store.url)
            XCTAssertNotEqual(try cli(store, ["report", id, "--expected-revision", String(revision),
                "--summary", "过期反馈", "--learning-outcome", "错误结论"]).0, 0)
            XCTAssertEqual(try Data(contentsOf: store.url), before)
        }
    }
    func testAIContextContainsCurrentNoteDirectoryOutcomesAndImagesWithoutEveryNoteBody() throws {
        try isolated { store in
            let id = try topic(store)
            store.editLearningNote(id, noteID: nil, field: "body", value: "AOF实验\n![截图](</tmp/learning.png>)", generation: 0)
            XCTAssertEqual(store.saveLearningNote(id), "N002")
            XCTAssertTrue(store.saveLearningOutcome(id, text: "完成恢复实验", noteID: "N002", reference: "https://example.com/result"))
            let result = try cli(store, ["context", id])
            XCTAssertEqual(result.0, 0)
            let item = try XCTUnwrap(result.1["item"] as? [String: Any])
            XCTAssertNil(item["notes"])
            XCTAssertEqual((item["noteDirectory"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual((item["currentNote"] as? [String: Any])?["id"] as? String, "N002")
            XCTAssertEqual((item["confirmedOutcomes"] as? [[String: Any]])?.first?["noteID"] as? String, "N002")
            XCTAssertEqual((result.1["images"] as? [[String: Any]])?.first?["path"] as? String, "/tmp/learning.png")
            XCTAssertTrue((result.1["feedback_instructions"] as? String)?.contains("由用户确认后采纳") == true)
            XCTAssertEqual((try cli(store, ["note", id, "N001"]).1["note"] as? [String: Any])?["body"] as? String, "第一篇笔记")
            XCTAssertTrue(store.removeLearningNote(id, noteID: "N002"))
            XCTAssertNotEqual(try cli(store, ["note", id, "N002"]).0, 0)
            XCTAssertEqual(store.entry(id)?.learningOutcomes.count, 1)
        }
    }

    func testNotebookBlankPagesAllocateNothingAndContinuousWritingKeepsOneStageLinkedNote() throws {
        try isolated { store in
            let id = try topic(store)
            let page = try XCTUnwrap(store.beginNotebookPage(id))
            page.stageID = "S001"
            store.writeNotebookPage(id, page: page, body: " \n ")
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 1)
            XCTAssertNil(page.noteID)
            store.writeNotebookPage(id, page: page, body: "我的理解")
            XCTAssertEqual(page.noteID, "N002")
            store.writeNotebookPage(id, page: page, body: "我的理解\n继续记录")
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 2)
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.learningStageID, "S001")
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.body, "我的理解\n继续记录")
            let next = try XCTUnwrap(store.beginNotebookPage(id, fresh: true))
            XCTAssertNil(next.noteID)
            store.writeNotebookPage(id, page: page, body: "旧页回调只更新旧页")
            XCTAssertTrue(store.flush())
            XCTAssertTrue(store.entry(id)?.learningDraft.body.isEmpty == true)
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.body, "旧页回调只更新旧页")
            let fresh = TryStore(url: store.url, watching: false)
            XCTAssertEqual(fresh.entry(id)?.learningNotes.count, 2)
        }
    }
    func testNotebookResumesLegacyDraftWithoutDroppingOriginalTextOrStage() throws {
        try isolated { store in
            let id = try topic(store)
            store.editLearningNote(id, noteID: nil, field: "body", value: "上次写了一半", generation: 0)
            store.editLearningNote(id, noteID: nil, field: "learningStageID", value: "S001", generation: 0)
            XCTAssertTrue(store.flush())
            let page = try XCTUnwrap(store.beginNotebookPage(id))
            XCTAssertEqual(page.stageID, "S001")
            XCTAssertEqual(store.entry(id)?.learningDraft.body, "上次写了一半")
            store.writeNotebookPage(id, page: page, body: "上次写了一半，今天继续")
            XCTAssertEqual(page.noteID, "N002")
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.body, "上次写了一半，今天继续")
            XCTAssertTrue(store.entry(id)?.learningDraft.body.isEmpty == true)
            store.editLearningNote(id, noteID: page.noteID, field: "learningStageID", value: "S002", generation: 0)
            XCTAssertTrue(store.flush())
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.learningStageID, "S002")
        }
    }

    @MainActor
    func testActualNotebookAutosavesWithoutBreakingTypingImagesOrHistory() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try topic(store)
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            let window = try XCTUnwrap(detail.window)
            XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.isEmpty,
                "The overview must not repeat an editable copy of the last note")
            try click("try-open-notebook", window, reveal: false)
            let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(editor.string.isEmpty)
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 1)
            assertVisible(try XCTUnwrap(editor.enclosingScrollView), window)
            editor.setMarkedText("恢复", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
            editor.didChangeText(); store.reload(); settle()
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 1)
            editor.unmarkText(); editor.didChangeText()
            editor.insertText("实验\n记录操作步骤与观察结果。", replacementRange: editor.selectedRange()); settle()
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 2)
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.id, "N002")
            XCTAssertTrue(store.flush()); settle()
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first === editor,
                "Autosave must retain the native editor, selection and undo stack")
            editor.insertText("\n再补一句。", replacementRange: editor.selectedRange())
            XCTAssertTrue(store.flush()); store.reload(); settle()
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 2)
            XCTAssertTrue(editor.string.contains("再补一句"))
            let board = NSPasteboard(name: .init("TryLearning-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 3,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 12, bitsPerPixel: 32))
            board.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
            editor.imageStore = DemandImageStore(directory: store.url.deletingLastPathComponent().appendingPathComponent("images"))
            editor.pasteboard = board; editor.paste(nil); settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.entry(id)!.learningNotes.last!.body).count, 1)
            editor.undoManager?.undo(); settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.entry(id)!.learningNotes.last!.body).count, 0)
            editor.undoManager?.redo(); settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.entry(id)!.learningNotes.last!.body).count, 1)
            window.setContentSize(NSSize(width: 620, height: 560)); settle()
            assertVisible(try XCTUnwrap(editor.enclosingScrollView), window)
            if let output = ProcessInfo.processInfo.environment["DBOARD_LEARNING_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                try snapshot(window, path: output + "/notebook-narrow.png")
                window.setContentSize(NSSize(width: 920, height: 780)); settle()
                try snapshot(window, path: output + "/notebook-writing.png")
            }
            try click("try-new-note", window, reveal: false)
            let blank = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(blank.string.isEmpty)
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 2)
            try click("try-select-note-N002", window)
            let reader = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertFalse(reader.isEditable)
            XCTAssertTrue(reader.string.contains("恢复实验"))
            try click("try-note-edit", window, reveal: false)
            reader.insertText("\n更新原笔记。", replacementRange: NSRange(location: reader.string.utf16.count, length: 0))
            detail.close(); settle()
            XCTAssertTrue(TryStore(url: store.url, watching: false).entry(id)?.learningNotes.last?.body.contains("更新原笔记") == true)
            detail.show(id); settle()
            defer { detail.close() }
            let reopened = try XCTUnwrap(detail.window)
            try click("try-open-knowledge", reopened)
            try click("try-select-note-N002", reopened)
            let restored = try XCTUnwrap(descendants(reopened.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertFalse(restored.isEditable)
            XCTAssertTrue(restored.string.contains("更新原笔记"))
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 2)
            if let output = ProcessInfo.processInfo.environment["DBOARD_LEARNING_SNAPSHOTS"] {
                try snapshot(reopened, path: output + "/notebook-reading.png")
            }
        }
    }

    @MainActor
    func testNotebookFormattingAutosavesAndReopensWithTheSameStyle() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try topic(store)
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            let window = try XCTUnwrap(detail.window)
            try click("try-open-notebook", window, reveal: false)
            let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            editor.insertText("模型运行需要空间。", replacementRange: editor.selectedRange())
            editor.setSelectedRange(NSRange(location: 2, length: 2))
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "b",
                charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11)!
            window.sendEvent(event); settle()
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.body, "模型**运行**需要空间。")
            XCTAssertEqual(editor.string, "模型运行需要空间。", "Formatting markers should not clutter the writing surface")
            XCTAssertEqual(store.entry(id)?.learningNotes.last?.displayTitle, "Redis持久化")
            let selected = editor.selectedRange()
            XCTAssertTrue(store.flush()); store.reload(); settle()
            XCTAssertEqual(editor.selectedRange(), selected)
            XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first === editor)
            editor.applyNoteFont(.monospacedSystemFont(ofSize: 18, weight: .regular))
            XCTAssertTrue(editor.serializedNote.contains("**运行**"))
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertNewline(nil)
            editor.insertText("*", replacementRange: editor.selectedRange())
            editor.insertText(" ", replacementRange: editor.selectedRange())
            editor.insertText("给缓存留出空间。", replacementRange: editor.selectedRange())
            XCTAssertTrue(store.flush()); settle()
            XCTAssertTrue(store.entry(id)?.learningNotes.last?.body.contains("- 给缓存留出空间。") == true)
            detail.close(); settle()
            detail.show(id); settle()
            defer { detail.close() }
            let reopened = try XCTUnwrap(detail.window)
            try click("try-open-knowledge", reopened)
            try click("try-select-note-N002", reopened)
            let reader = try XCTUnwrap(descendants(reopened.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertFalse(reader.isEditable)
            XCTAssertTrue(reader.string.contains("• 给缓存留出空间。"))
            let font = try XCTUnwrap(reader.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            if let output = ProcessInfo.processInfo.environment["DBOARD_NOTE_FORMAT_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                try snapshot(reopened, path: output + "/formatted-notebook.png")
            }
        }
    }
    @MainActor
    func testReadingNoteEntersEditingOnReturnOrDoubleClickAndKeepsAutosave() throws {
        let previousTabNavigation = WorkspacePreferences.shared.tabNavigationEnabled
        WorkspacePreferences.shared.tabNavigationEnabled = true
        defer { WorkspacePreferences.shared.tabNavigationEnabled = previousTabNavigation }
        _ = NSApplication.shared
        try isolated { store in
            let id = try topic(store)
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            try click("try-open-knowledge", window)
            try click("try-select-note-N001", window)
            let reader = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertFalse(reader.isEditable)
            XCTAssertTrue(window.firstResponder === reader)
            let before = store.entry(id)!.learningNotes[0].body
            let navigation = DemandWindowKeyboardNavigation(window: window)
            XCTAssertTrue(navigation.focusableControls().contains { $0 === reader })
            let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            window.sendEvent(enter); settle()
            XCTAssertTrue(reader.isEditable)
            XCTAssertTrue(window.firstResponder === reader)
            XCTAssertEqual(store.entry(id)?.learningNotes[0].body, before, "Entering editing must not insert a newline")
            reader.insertText("\n回车后补充。", replacementRange: NSRange(location: reader.string.utf16.count, length: 0))
            try click("try-note-edit-done", window, reveal: false)
            XCTAssertFalse(reader.isEditable)
            XCTAssertTrue(store.flush())
            let saved = store.entry(id)!.learningNotes[0].body
            let point = reader.convert(NSPoint(x: reader.textContainerOrigin.x + 10, y: reader.textContainerOrigin.y + 10), to: nil)
            for count in [1, 2] {
                // NSTextView tracks selection until mouse-up, so queue it before dispatching mouse-down.
                let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 0))
                NSApp.postEvent(up, atStart: true)
                window.sendEvent(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!)
                settle()
                XCTAssertEqual(reader.isEditable, count == 2, "Only a double click starts writing")
            }
            XCTAssertTrue(window.firstResponder === reader)
            XCTAssertEqual(store.entry(id)?.learningNotes[0].body, saved)
            reader.insertText("\n双击后补充。", replacementRange: NSRange(location: reader.string.utf16.count, length: 0))
            XCTAssertTrue(store.flush())
            XCTAssertEqual(TryStore(url: store.url, watching: false).entry(id)?.learningNotes.count, 1)
            XCTAssertTrue(TryStore(url: store.url, watching: false).entry(id)?.learningNotes[0].body.contains("双击后补充") == true)
        }
    }

    private func topic(_ store: TryStore) throws -> String {
        store.editCapture(.digestion, field: "title", value: "Redis持久化", generation: store.captureGeneration(.digestion))
        store.editCapture(.digestion, field: "body", value: "第一篇笔记", generation: store.captureGeneration(.digestion))
        return try XCTUnwrap(store.submitCapture(.digestion))
    }
    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TryLearning-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(TryStore(url: folder.appendingPathComponent("personal.json"), watching: false))
    }
    private func cli(_ store: TryStore, _ args: [String]) throws -> (Int32, [String: Any]) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [path.path, "try", "--store", store.url.path] + args
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any]))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor private func assertVisible(_ target: NSView, _ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        var ancestor = target.superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                XCTAssertTrue(clip.bounds.insetBy(dx: -1, dy: -1).contains(target.convert(target.bounds, to: clip)), "\(target) outside clip \(clip.bounds)", file: file, line: line)
            }
            ancestor = view.superview
        }
        XCTAssertTrue(window.contentView!.bounds.contains(target.convert(target.bounds, to: window.contentView!)), file: file, line: line)
    }
    @MainActor private func click(_ id: String, _ window: NSWindow, reveal: Bool = true) throws {
        let target = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }.first { $0.keyboardIdentifier == id }, id)
        if reveal {
            var ancestor = target.superview
            while let view = ancestor {
                if let scroll = view as? NSScrollView, let document = scroll.documentView {
                    document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
                }
                ancestor = view.superview
            }
            settle()
        } else { assertVisible(target, window) }
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
    }
    @MainActor private func snapshot(_ window: NSWindow, path: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
