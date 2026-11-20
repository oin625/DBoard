import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class TryWorkspaceTests: XCTestCase {
    func testDraftProjectAndConversionsKeepIdentityAndOriginalMaterial() throws {
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let project = try XCTUnwrap(store.project(name: "D板", context: "代码入口 /repo/DBoard"))
            let id = try XCTUnwrap(store.create(.idea, projectID: project))
            let body = "想做一个快捷入口\n" + DemandImageMarkdown.link(label: "示意图", path: "/tmp/reference.png")
            store.edit(id, field: "body", value: body)
            store.edit(id, field: "title", value: "快捷入口")
            XCTAssertTrue(store.flush())
            XCTAssertTrue(store.convert(id, to: .task))
            XCTAssertTrue(store.convert(id, to: .digestion))
            let reopened = TryStore(url: url, watching: false)
            let entry = try XCTUnwrap(reopened.entry(id))
            XCTAssertEqual(entry.id, "T001")
            XCTAssertEqual(entry.body, body)
            XCTAssertEqual(entry.kind, .digestion)
            XCTAssertEqual(entry.projectID, project)
            XCTAssertEqual(entry.conversions.map(\.from), [.idea, .task])
            XCTAssertEqual(entry.conversions.map(\.to), [.task, .digestion])
            XCTAssertEqual(reopened.document.projects.first?.context, "代码入口 /repo/DBoard")
            XCTAssertTrue(reopened.status(id, .done))
            XCTAssertEqual(TryStore(url: url, watching: false).entry(id)?.status, .done)
            XCTAssertTrue(reopened.status(id, .active))
            XCTAssertEqual(reopened.entry(id)?.status, .active)
            let related = try XCTUnwrap(reopened.create(.task, relatedID: id))
            XCTAssertEqual(reopened.entry(id)?.relatedIDs, [related])
            XCTAssertEqual(reopened.entry(related)?.relatedIDs, [id])
        }
    }

    func testPendingTypingMergesWithExternalAIFeedbackAndPreservesBookmarks() throws {
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let id = try XCTUnwrap(store.create(.digestion))
            store.edit(id, field: "body", value: "我正在输入的理解")
            try TryDisk.change(url) { document in
                document.entries[0].aiSummary = "AI 已澄清图片导入"
                document.entries[0].aiResult = "图片先保存到本机"
                document.entries[0].reports.append(TryReport(id: "round1", at: 1, summary: "解释图片导入", details: "按需明细"))
                document.entries[0].revision += 1
            }
            store.reload()
            XCTAssertEqual(store.entry(id)?.body, "我正在输入的理解")
            XCTAssertEqual(store.entry(id)?.aiSummary, "AI 已澄清图片导入")
            XCTAssertTrue(store.flush())
            store.remember(id, bookmark: TryBookmark(location: 3, length: 2, scrollY: 120))
            let fresh = try TryDisk.read(url)
            XCTAssertEqual(fresh.entries[0].body, "我正在输入的理解")
            XCTAssertEqual(fresh.entries[0].aiResult, "图片先保存到本机")
            XCTAssertEqual(fresh.entries[0].reports.count, 1)
            XCTAssertEqual(fresh.bookmarks[id]?.scrollY, 120)
            XCTAssertTrue(store.adopt(id))
            XCTAssertEqual(store.entry(id)?.body, "我正在输入的理解\n\n图片先保存到本机")
        }
    }

    func testMalformedDataNeverOverwritesAndPendingDraftCanRetry() throws {
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let id = try XCTUnwrap(store.create(.idea))
            let good = try Data(contentsOf: url)
            store.edit(id, field: "body", value: "不能丢的草稿")
            try Data("{".utf8).write(to: url)
            XCTAssertFalse(store.flush())
            XCTAssertNotNil(store.error)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{")
            XCTAssertEqual(store.entry(id)?.body, "不能丢的草稿")
            XCTAssertNil(store.create(.task))
            try good.write(to: url, options: .atomic)
            XCTAssertTrue(store.flush())
            XCTAssertEqual(try TryDisk.read(url).entries[0].body, "不能丢的草稿")
        }
    }

    func testCopiedCommandUsesLatestKindAndCorrectStoreWithoutFullHistory() throws {
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let id = try XCTUnwrap(store.create(.idea))
            store.edit(id, field: "title", value: "个人任务")
            store.edit(id, field: "body", value: "准备讨论")
            XCTAssertTrue(store.convert(id, to: .task))
            let command = try XCTUnwrap(store.handoff(id))
            XCTAssertTrue(command.contains(" try --store "))
            XCTAssertTrue(command.contains("context '" + id + "'"))
            XCTAssertTrue(command.contains("继续执行"))
            XCTAssertTrue(command.contains("由我确认"))
            XCTAssertFalse(command.contains("准备讨论"))
            XCTAssertEqual(try TryDisk.read(url).entries[0].body, "准备讨论")
        }
    }

    func testSwiftAndCLIShareSchemaAndConditionalFeedback() throws {
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let projectID = try XCTUnwrap(store.project(name: "D板", context: "主 Main 保持现状"))
            let id = try XCTUnwrap(store.create(.task, projectID: projectID))
            store.edit(id, field: "body", value: "用户自己的目标")
            XCTAssertTrue(store.flush())
            let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tools/dboard_ai.py")
            func call(_ arguments: [String]) throws -> [String: Any] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [cli.path, "try", "--store", url.path] + arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0, String(decoding: output, as: UTF8.self))
                return try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? [String: Any])
            }
            let context = try call(["context", id])
            let item = try XCTUnwrap(context["item"] as? [String: Any])
            let revision = try XCTUnwrap(item["revision"] as? Int)
            let result = url.deletingLastPathComponent().appendingPathComponent("result.md")
            try "可供采纳的成果说明".write(to: result, atomically: true, encoding: .utf8)
            _ = try call(["report", id, "--expected-revision", String(revision), "--summary", "完成了第一步",
                "--result-file", result.path, "--event-id", "interop-round"])
            store.reload()
            XCTAssertEqual(store.entry(id)?.body, "用户自己的目标")
            XCTAssertEqual(store.entry(id)?.aiResult, "可供采纳的成果说明")
            store.edit(id, field: "progress", value: "用户补充：待验证")
            XCTAssertTrue(store.flush())
            XCTAssertNotNil(try TryDisk.read(url).entries[0].reports[0].fingerprint)
            let duplicate = try call(["report", id, "--expected-revision", String(revision), "--summary", "完成了第一步",
                "--result-file", result.path, "--event-id", "interop-round"])
            XCTAssertEqual(duplicate["duplicate"] as? Bool, true)
            let related = try call(["create", "--kind", "digestion", "--title", "理解这段代码", "--project", projectID, "--related", id])
            let created = try XCTUnwrap(related["item"] as? [String: Any])
            store.reload()
            XCTAssertEqual(store.document.entries.count, 2)
            XCTAssertEqual(store.entry(id)?.relatedIDs, [try XCTUnwrap(created["id"] as? String)])
        }
    }

    @MainActor
    func testTryKeyboardKeepsTextArrowsAndCommitsBeforeEscapeBack() throws {
        _ = NSApplication.shared
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let id = try XCTUnwrap(store.create(.idea))
            store.edit(id, field: "title", value: "键盘交互")
            store.edit(id, field: "body", value: "自己的想法")
            XCTAssertTrue(store.flush())
            store.selectedID = id
            let window = host(TryWorkspaceView(store: store, keyboardEnabled: true).environmentObject(ThemeManager.shared),
                size: NSSize(width: 720, height: 660))
            defer { window.close() }
            settle()
            @MainActor func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            let root = try XCTUnwrap(window.contentView)
            let bridge = try XCTUnwrap(descendants(root).compactMap { $0 as? TryKeyboardHostView }.first)
            let navigation = try XCTUnwrap(bridge.navigation)
            let editor = try XCTUnwrap(descendants(root).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(editor.isEditable, "打开详情就能直接写，不再需要切换书写模式")
            editor.beginWriting()
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            editor.insertText("，继续写", replacementRange: editor.selectedRange())
            @MainActor func key(_ code: UInt16) throws -> NSEvent {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)
                return try XCTUnwrap(event)
            }
            XCTAssertNotNil(navigation.handleKey(try key(125)), "正文保留上下移动光标")
            XCTAssertNil(navigation.handleKey(try key(53)))
            settle()
            XCTAssertFalse(editor.isEditable)
            XCTAssertEqual(store.selectedID, id)
            XCTAssertEqual(try TryDisk.read(url).entries[0].body, "自己的想法，继续写")
            XCTAssertNil(navigation.handleKey(try key(53)))
            settle()
            XCTAssertNil(store.selectedID)
        }
    }

    @MainActor
    func testNativeEditorKeepsCaretImagesUndoAndUserTypingDuringFeedback() throws {
        _ = NSApplication.shared
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let id = try XCTUnwrap(store.create(.digestion))
            store.edit(id, field: "body", value: "我的理解\n还想知道")
            XCTAssertTrue(store.flush())
            let state = EditorState()
            let controller = TryNoteController()
            let window = host(EditorFixture(store: store, id: id, state: state, controller: controller),
                              size: NSSize(width: 580, height: 430))
            defer { window.close() }
            settle()
            let editor = try XCTUnwrap(controller.editor)
            window.makeFirstResponder(editor)
            editor.setSelectedRange(NSRange(location: 2, length: 1))
            let selection = editor.selectedRange()
            editor.setMarkedText("正在输入", selectedRange: NSRange(location: 4, length: 0), replacementRange: selection)
            XCTAssertTrue(editor.hasMarkedText())
            let before = editor.string
            try TryDisk.change(url) { document in document.entries[0].aiSummary = "AI 的新反馈"; document.entries[0].revision += 1 }
            store.reload()
            settle()
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.string, before)
            XCTAssertTrue(window.firstResponder === editor)
            editor.insertText("写", replacementRange: editor.markedRange())
            settle()
            XCTAssertFalse(editor.hasMarkedText())
            XCTAssertTrue(store.entry(id)?.body.contains("写") == true)
            let board = NSPasteboard(name: .init("DBoardTryTest-" + UUID().uuidString))
            defer { board.releaseGlobally() }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 16, bitsPerPixel: 32))
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            board.setData(png, forType: .png)
            editor.imageStore = DemandImageStore(directory: url.deletingLastPathComponent().appendingPathComponent("images"))
            editor.pasteboard = board
            state.editing = false
            editor.isEditable = false
            editor.setSelectedRange(NSRange(location: editor.attributedString().length, length: 0))
            editor.paste(nil)
            XCTAssertTrue(editor.isEditable, "阅读时直接粘贴，也能进入书写")
            XCTAssertTrue(state.editing)
            settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.entry(id)?.body ?? "").count, 1)
            let imageIndex = (editor.string as NSString).range(of: "\u{FFFC}").location
            XCTAssertNotEqual(imageIndex, NSNotFound)
            editor.setSelectedRange(NSRange(location: imageIndex, length: 1))
            editor.delete(nil)
            settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.entry(id)?.body ?? "").count, 0)
            XCTAssertNotNil(editor.undoManager)
            editor.undoManager?.undo()
            settle()
            XCTAssertEqual(DemandImageMarkdown.references(in: store.entry(id)?.body ?? "").count, 1)
            let final = try XCTUnwrap(store.entry(id)?.body)
            controller.end()
            XCTAssertEqual(TryStore(url: url, watching: false).entry(id)?.body, final)
            XCTAssertNotNil(store.bookmarks[id])
        }
    }

    @MainActor
    func testNativeEditorResumesSelectionAndScrollAfterReopening() throws {
        _ = NSApplication.shared
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let id = try XCTUnwrap(store.create(.digestion))
            store.edit(id, field: "body", value: (1...80).map { "第\($0)行：消化资料与我的理解" }.joined(separator: "\n"))
            XCTAssertTrue(store.flush())
            let state = EditorState()
            let firstController = TryNoteController()
            let first = host(EditorFixture(store: store, id: id, state: state, controller: firstController),
                             size: NSSize(width: 560, height: 430))
            settle()
            let editor = try XCTUnwrap(firstController.editor)
            editor.setSelectedRange(NSRange(location: 12, length: 3))
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
            scroll.reflectScrolledClipView(scroll.contentView)
            firstController.end()
            let bookmark = try XCTUnwrap(store.bookmarks[id])
            first.close()
            XCTAssertEqual(bookmark.location, 12)
            XCTAssertEqual(bookmark.length, 3)
            XCTAssertGreaterThan(bookmark.scrollY, 0)
            let secondController = TryNoteController()
            state.editing = false
            let second = host(EditorFixture(store: store, id: id, state: state, controller: secondController),
                              size: NSSize(width: 560, height: 430))
            defer { second.close() }
            settle()
            let reopened = try XCTUnwrap(secondController.editor)
            XCTAssertEqual(reopened.selectedRange(), NSRange(location: 12, length: 3))
            XCTAssertEqual(reopened.enclosingScrollView?.contentView.bounds.origin.y ?? 0, bookmark.scrollY, accuracy: 2)
            XCTAssertFalse(reopened.isEditable)
        }
    }

    @MainActor
    func testPersonalHomeDetailsAndMainSwitchRenderInBothAppearances() throws {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try isolated { url in
            let store = TryStore(url: url, watching: false)
            let project = try XCTUnwrap(store.project(name: "D板", context: "代码入口：/Users/zz/work/code/other/DBoard\n主 Main 保持现状；个人空间以书写和轻量闭环为主。"))
            let fixtures: [(TryKind, String, String, String)] = [
                (.task, "次 Try 个人空间", "想法、任务和消化互相关联，让每次投入都有记录。", "正在核验编辑与 AI 接手"),
                (.idea, "把旅行的碎片留下来", "沿途想到的事情，拍下的图，还有想去的小地方。", ""),
                (.digestion, "弄懂 SwiftUI 焦点管理", "## 我的理解\n焦点属于当前窗口，切换页面时应保存编辑位置。\n\n## 还有疑问\nTab 与输入法如何配合？", "已经理解焦点顺序"),
                (.task, "做一个自己的小工具", "先做出最小可用的版本，再根据实际使用调整。", "等一个空闲的周末")]
            var ids: [String] = []
            for (kind, title, body, progress) in fixtures {
                let id = try XCTUnwrap(store.create(kind, projectID: kind == .task || kind == .digestion ? project : nil))
                ids.append(id)
                store.edit(id, field: "title", value: title); store.edit(id, field: "body", value: body)
                store.edit(id, field: "progress", value: progress)
            }
            XCTAssertTrue(store.flush())
            store.selectedID = nil
            let vm = DBoardViewModel(loadCache: false)
            vm.space = .personal
            let root = DBoardRootView(personalStore: store, popoverMode: true)
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
            let window = host(root, size: NSSize(width: 820, height: 780))
            defer { window.close() }
            let output = ProcessInfo.processInfo.environment["DBOARD_TRY_SNAPSHOTS"]
            if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                store.selectedID = nil
                settle()
                try snapshot(window, output: output, name: appearance == .aqua ? "home-light" : "home-dark")
                store.selectedID = ids[2]
                settle()
                try snapshot(window, output: output, name: appearance == .aqua ? "digestion-light" : "digestion-dark")
                store.selectedID = nil
            }
            vm.space = .main
            settle()
            try snapshot(window, output: output, name: "main-preserved")
            XCTAssertEqual(store.document.entries.count, 4)
        }
    }

    private func isolated(_ action: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardTry-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try action(directory.appendingPathComponent("personal.json"))
    }
    @MainActor
    private final class EditorState: ObservableObject { @Published var editing = true }
    @MainActor
    private struct EditorFixture: View {
        @ObservedObject var store: TryStore
        let id: String
        @ObservedObject var state: EditorState
        let controller: TryNoteController
        var body: some View {
            TryNoteEditor(text: Binding(get: { store.entry(id)?.body ?? "" }, set: { store.edit(id, field: "body", value: $0) }),
                editing: $state.editing, bookmark: store.bookmarks[id], controller: controller,
                onBookmark: { store.remember(id, bookmark: $0) }, onEnd: { _ = store.flush() })
                .padding(20)
        }
    }
    @MainActor
    private func host<V: View>(_ root: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.makeKeyAndOrderFront(nil)
        return window
    }
    @MainActor
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.3)) }
    @MainActor
    private func snapshot(_ window: NSWindow, output: String?, name: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2000)
        if let output { try png.write(to: URL(fileURLWithPath: output + "/" + name + ".png")) }
    }
}
