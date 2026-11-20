import XCTest
import AppKit
@testable import DBoard

final class TryIdeaJournalTests: XCTestCase {
    @MainActor
    func testIdeaOpensAsReadingAndOriginalChangesOnlyAfterExplicitEdit() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try makeIdea(store)
            let original = try XCTUnwrap(store.entry(id)?.body)
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            XCTAssertTrue(editors(window).isEmpty, "Reading an idea must not create a writing editor.")
            XCTAssertEqual(store.entry(id)?.body, original)
            try snapshot(window, "reading")
            try click("try-idea-edit-original", window)
            let editor = try XCTUnwrap(editors(window).first)
            XCTAssertTrue(editor.isEditable)
            XCTAssertTrue(window.firstResponder === editor)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("\n先试着整理一周，再决定怎么继续。", replacementRange: editor.selectedRange())
            settle()
            try click("try-idea-edit-original", window)
            XCTAssertTrue(editors(window).isEmpty)
            XCTAssertTrue(store.entry(id)?.body.hasSuffix("再决定怎么继续。") == true)
            XCTAssertTrue(store.entry(id)?.ideaSupplements.isEmpty == true)
            detail.close(); settle()
            detail.show(id); settle()
            XCTAssertTrue(editors(try XCTUnwrap(detail.window)).isEmpty, "Reopening must return to reading.")
            XCTAssertEqual(TryStore(url: store.url, watching: false).entry(id)?.body, store.entry(id)?.body)
        }
    }

    @MainActor
    func testSupplementDraftImagesAndSavedHistoryDoNotReplaceOriginal() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try makeIdea(store)
            let original = try XCTUnwrap(store.entry(id)?.body)
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            var window = try XCTUnwrap(detail.window)
            try click("try-idea-add-supplement", window)
            let editor = try XCTUnwrap(editors(window).first)
            XCTAssertTrue(window.firstResponder === editor)
            editor.insertText("刚想到：可以先用学习笔记验证这个想法。\n", replacementRange: editor.selectedRange())
            let board = NSPasteboard(name: .init("TryIdeaImages-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 3,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 12, bitsPerPixel: 32))
            board.setData(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), forType: .png)
            editor.imageStore = DemandImageStore(directory: store.url.deletingLastPathComponent().appendingPathComponent("images"))
            editor.pasteboard = board; editor.paste(nil); settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.additionDraft(id).body).count, 1)
            try click("try-idea-supplement-later", window)
            XCTAssertTrue(editors(window).isEmpty)
            XCTAssertEqual(store.entry(id)?.body, original)
            detail.close(); settle()
            detail.show(id); settle()
            window = try XCTUnwrap(detail.window)
            XCTAssertTrue(editors(window).isEmpty, "A stored draft should offer resume, never open automatically.")
            try click("try-idea-add-supplement", window)
            XCTAssertTrue(store.additionDraft(id).body.contains("学习笔记"))
            XCTAssertEqual(DemandImageMarkdown.references(in: store.additionDraft(id).body).count, 1)
            try click("try-idea-supplement-save", window)
            XCTAssertTrue(editors(window).isEmpty)
            XCTAssertEqual(store.entry(id)?.body, original)
            XCTAssertEqual(store.entry(id)?.ideaSupplements.count, 1)
            XCTAssertTrue(store.additionDraft(id).isEmpty)
            try snapshot(window, "with-supplement")

            try click("try-idea-edit-supplement-A001", window)
            let rewriting = try XCTUnwrap(editors(window).first)
            rewriting.setSelectedRange(NSRange(location: rewriting.string.utf16.count, length: 0))
            rewriting.insertText("\n补充：每周回看一次。", replacementRange: rewriting.selectedRange())
            try click("try-idea-supplement-save", window)
            XCTAssertEqual(store.entry(id)?.ideaSupplements.count, 1)
            XCTAssertTrue(store.entry(id)?.ideaSupplements.first?.body.contains("每周回看") == true)
            XCTAssertEqual(store.entry(id)?.body, original)
            let reloaded = TryStore(url: store.url, watching: false)
            XCTAssertEqual(reloaded.entry(id)?.ideaSupplements, store.entry(id)?.ideaSupplements)
        }
    }

    @MainActor
    func testEachOfThreeSupplementsEditsInlineAndKeepsOtherBlocksUnchanged() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try makeIdea(store)
            let original = (1...35).map { "最初想法的第\($0)行，补充的编辑器应留在各自内容块。" }.joined(separator: "\n")
            store.edit(id, field: "body", value: original)
            XCTAssertTrue(store.flush())
            for index in 1...3 {
                store.editAdditionDraft(id, body: "第\(index)条补充\n这一条独立记录新的角度。",
                    generation: store.additionGeneration(id))
                XCTAssertEqual(store.submitAddition(id), String(format: "A%03d", index))
            }
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            window.setContentSize(NSSize(width: 700, height: 650)); settle()
            for target in ["A002", "A001", "A003"] {
                let before = try XCTUnwrap(store.entry(id))
                try click("try-idea-edit-supplement-" + target, window)
                let editor = try XCTUnwrap(editors(window).first)
                XCTAssertEqual(editors(window).count, 1)
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(store.additionDraft(id).editingID, target)
                XCTAssertTrue(editor.string.contains(before.ideaSupplements.first { $0.id == target }!.body))
                assertVisible(try XCTUnwrap(editor.enclosingScrollView), in: window)
                if target == "A002" { try snapshot(window, "editing-middle-block") }
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.insertText("\n仅修改" + target, replacementRange: editor.selectedRange())
                try click("try-idea-supplement-save", window)
                let after = try XCTUnwrap(store.entry(id))
                XCTAssertEqual(after.body, original)
                XCTAssertEqual(after.ideaSupplements.map(\.id), ["A001", "A002", "A003"])
                for untouched in before.ideaSupplements where untouched.id != target {
                    XCTAssertEqual(after.ideaSupplements.first { $0.id == untouched.id }, untouched)
                }
                XCTAssertTrue(after.ideaSupplements.first { $0.id == target }!.body.hasSuffix("仅修改" + target))
                XCTAssertTrue(editors(window).isEmpty)
            }
            try click("try-idea-edit-supplement-A001", window)
            let editor = try XCTUnwrap(editors(window).first)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("\n切换时保留这次编辑", replacementRange: editor.selectedRange())
            try click("try-idea-edit-supplement-A003", window)
            XCTAssertEqual(store.additionDraft(id).editingID, "A003")
            XCTAssertTrue(store.entry(id)?.ideaSupplements.first { $0.id == "A001" }?.body.contains("切换时保留") == true)
            try click("try-idea-supplement-save", window)
            XCTAssertEqual(store.entry(id)?.body, original)
            XCTAssertEqual(store.entry(id)?.ideaSupplements.count, 3)
            detail.close(); settle()
            detail.show(id); settle()
            XCTAssertTrue(editors(try XCTUnwrap(detail.window)).isEmpty)
        }
    }

    @MainActor
    func testIdeaCanFinishAndResumeWithoutLosingOriginalSupplementsOrDraft() throws {
        _ = NSApplication.shared
        try isolated { store in
            let id = try makeIdea(store)
            store.editAdditionDraft(id, body: "已记录的后续想法", generation: store.additionGeneration(id))
            _ = try XCTUnwrap(store.submitAddition(id))
            let supplements = try XCTUnwrap(store.entry(id)?.ideaSupplements)
            store.editAdditionDraft(id, body: "还没有收好的草稿", generation: store.additionGeneration(id))
            XCTAssertTrue(store.flush())
            let draft = store.additionDraft(id)
            let quick = TryQuickOpenWindowController(store: store, activates: false)
            quick.show(); quick.model.scope = .idea; settle()
            defer { quick.close() }
            XCTAssertEqual(quick.model.entries.map(\.id), [id])

            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show(id); settle()
            defer { detail.close() }
            var window = try XCTUnwrap(detail.window)
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance); settle()
                try snapshot(window, appearance == .aqua ? "finish-button-light" : "finish-button-dark")
            }
            try click("try-idea-edit-original", window)
            let editor = try XCTUnwrap(editors(window).first)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("\n这一轮先到这里。", replacementRange: editor.selectedRange())
            try click("try-idea-finish", window)

            let finished = try XCTUnwrap(store.entry(id))
            XCTAssertEqual(finished.status, .done)
            XCTAssertEqual(finished.statusTitle, "已告一段落")
            XCTAssertTrue(quick.model.entries.isEmpty)
            XCTAssertNil(quick.model.selectedID)
            XCTAssertTrue(TryEntrySearch.results(in: store.document.entries, kind: .idea, query: finished.title).isEmpty)
            XCTAssertEqual(TryEntrySearch.results(in: store.document.entries, kind: .idea,
                query: finished.title, finishedIdeas: true).map(\.id), [id])
            XCTAssertTrue(finished.body.hasSuffix("这一轮先到这里。"))
            XCTAssertEqual(finished.ideaSupplements, supplements)
            XCTAssertEqual(store.additionDraft(id), draft)
            XCTAssertTrue(editors(window).isEmpty)
            let reloaded = TryStore(url: store.url, watching: false)
            XCTAssertEqual(reloaded.entry(id)?.status, .done)
            XCTAssertEqual(reloaded.entry(id)?.body, finished.body)
            XCTAssertEqual(reloaded.additionDraft(id), draft)

            detail.close(); settle()
            detail.show(id); settle()
            window = try XCTUnwrap(detail.window)
            try click("try-idea-resume", window)
            XCTAssertEqual(store.entry(id)?.status, .active)
            XCTAssertEqual(quick.model.entries.map(\.id), [id])
            XCTAssertEqual(TryEntrySearch.results(in: store.document.entries, kind: .idea, query: finished.title).map(\.id), [id])
            XCTAssertTrue(TryEntrySearch.results(in: store.document.entries, kind: .idea, finishedIdeas: true).isEmpty)
            XCTAssertEqual(store.entry(id)?.body, finished.body)
            XCTAssertEqual(store.entry(id)?.ideaSupplements, supplements)
            XCTAssertEqual(store.additionDraft(id), draft)
            XCTAssertEqual(TryStore(url: store.url, watching: false).entry(id)?.status, .active)
        }
    }

    func testFinishedIdeasAreExcludedFromDefaultSearchAndKeptInArchive() {
        var active = TryEntry(id: "T001", kind: .idea, title: "同一关键词：进行中", createdAt: 1, updatedAt: 1)
        var finished = TryEntry(id: "T002", kind: .idea, title: "同一关键词：已结束", createdAt: 1, updatedAt: 5)
        finished.status = .done
        var shelved = TryEntry(id: "T003", kind: .idea, title: "同一关键词：已搁置", createdAt: 1, updatedAt: 3)
        shelved.status = .shelved
        var deleted = finished
        deleted.id = "T004"; deleted.deletedAt = 10
        let empty = TryEntry(id: "T005", kind: .idea, createdAt: 1, updatedAt: 8)
        var learning = TryEntry(id: "T006", kind: .digestion, title: "同一关键词：学习", createdAt: 1, updatedAt: 7)
        learning.status = .done
        active.additions = [TryAddition(id: "A001", body: "原有补充", createdAt: 1)]
        let entries = [active, finished, shelved, deleted, empty, learning]

        XCTAssertEqual(TryEntrySearch.results(in: entries, kind: .idea).map(\.id), ["T003", "T001"])
        XCTAssertEqual(TryEntrySearch.results(in: entries, kind: .idea, query: "同一关键词").map(\.id), ["T003", "T001"])
        XCTAssertTrue(TryEntrySearch.results(in: entries, kind: .idea, query: "已结束").isEmpty)
        XCTAssertEqual(TryEntrySearch.results(in: entries, kind: .idea, query: "已结束", finishedIdeas: true).map(\.id), ["T002"])
        XCTAssertTrue(TryEntrySearch.results(in: entries, kind: .idea, query: "不存在", finishedIdeas: true).isEmpty)
        XCTAssertEqual(TryEntrySearch.results(in: entries, kind: .digestion).map(\.id), ["T006"])
    }

    func testAIReadsOriginalAndAllEffectiveSupplementsIncludingPreviouslyDiscussedOnes() throws {
        try isolated { store in
            let id = try makeIdea(store)
            store.editAdditionDraft(id, body: "第一段补充\n重要的第二行\n![图](</tmp/idea-example.png>)", generation: store.additionGeneration(id))
            let first = try XCTUnwrap(store.submitAddition(id))
            XCTAssertTrue(store.markAddition(id, additionID: first, completed: true))
            store.editAdditionDraft(id, body: "后来又想到的角度", generation: store.additionGeneration(id))
            _ = try XCTUnwrap(store.submitAddition(id))
            store.editAdditionDraft(id, body: "已经撤回的内容", generation: store.additionGeneration(id))
            let withdrawn = try XCTUnwrap(store.submitAddition(id))
            XCTAssertTrue(store.withdrawAddition(id, additionID: withdrawn))
            let output = try cli(store, ["context", id])
            let item = try XCTUnwrap(output["item"] as? [String: Any])
            let supplements = try XCTUnwrap(item["ideaSupplements"] as? [[String: Any]])
            XCTAssertEqual(supplements.count, 2)
            XCTAssertTrue((supplements.first?["body"] as? String)?.contains("重要的第二行") == true)
            XCTAssertTrue((item["pendingAdditions"] as? [[String: Any]])?.isEmpty == true)
            XCTAssertEqual(item["body"] as? String, store.entry(id)?.body)
            XCTAssertEqual((output["images"] as? [[String: Any]])?.first?["path"] as? String, "/tmp/idea-example.png")
            XCTAssertTrue((output["feedback_instructions"] as? String)?.contains("全部有效补充") == true)
            XCTAssertTrue(store.handoff(id)?.contains("所有后续补充") == true)
            let learning = try XCTUnwrap(store.beginLearning(from: id))
            let seed = try XCTUnwrap(store.entry(learning)?.learningNotes.first?.body)
            XCTAssertTrue(seed.contains("重要的第二行"))
            XCTAssertTrue(seed.contains("后来又想到"))
            XCTAssertFalse(seed.contains("已经撤回"))
        }
    }

    private func makeIdea(_ store: TryStore) throws -> String {
        let id = try XCTUnwrap(store.create(.idea))
        store.edit(id, field: "title", value: "把学过的东西留下来")
        store.edit(id, field: "body", value: "我想把每天读过的资料整理成自己的知识。\n先从一个主题开始，不急着做成复杂的系统。")
        XCTAssertTrue(store.flush())
        return id
    }
    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TryIdea-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try action(TryStore(url: folder.appendingPathComponent("personal.json"), watching: false))
    }
    private func cli(_ store: TryStore, _ args: [String]) throws -> [String: Any] {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, "try", "--store", store.url.path] + args
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func editors(_ window: NSWindow) -> [TryNoteTextView] {
        descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }
    }
    @MainActor private func assertVisible(_ target: NSView, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        var ancestor = target.superview
        while let view = ancestor {
            if let clip = view as? NSClipView {
                XCTAssertTrue(clip.bounds.insetBy(dx: -1, dy: -1).contains(target.convert(target.bounds, to: clip)),
                    "The selected block's editor should be visible in its own location.", file: file, line: line)
            }
            ancestor = view.superview
        }
        XCTAssertTrue(window.contentView!.bounds.contains(target.convert(target.bounds, to: window.contentView!)), file: file, line: line)
    }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor private func click(_ id: String, _ window: NSWindow) throws {
        let target = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
            .first { $0.keyboardIdentifier == id }, id)
        var ancestor = target.superview
        while let view = ancestor {
            if let scroll = view as? NSScrollView, let document = scroll.documentView {
                document.scrollToVisible(target.convert(target.bounds, to: document).insetBy(dx: 0, dy: -8))
            }
            ancestor = view.superview
        }
        settle()
        let point = target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
    }
    @MainActor private func snapshot(_ window: NSWindow, _ name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["DBOARD_IDEA_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/" + name + ".png"))
    }
}
