import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class TryLearningInterfaceTests: XCTestCase {
    func testReadingSeparatesWorkflowCommentsAndDuplicateTitleWithoutChangingSourceOrBoundaries() {
        let source = "# 参数量与资源\n\n基础权重约3.5GB。\n\n不能把它当作总运行内存。\n\n这里结合N003整理，原文保留。"
        let note = TryLearningNote(id: "N005", title: "参数量与资源", body: source,
                                   createdAt: 1, updatedAt: 2, origin: "ai_organized")
        let display = TryNotebookPresentation(note)
        XCTAssertEqual(display.title, "参数量与资源")
        XCTAssertFalse(display.body.contains("# 参数量与资源"))
        XCTAssertFalse(display.body.contains("这里结合N003"))
        XCTAssertTrue(display.body.contains("不能把它当作总运行内存"))
        XCTAssertEqual(display.annotations, ["这里结合N003整理，原文保留。"])
        XCTAssertEqual(note.body, source)
        var personal = note
        personal.origin = nil
        XCTAssertTrue(TryNotebookPresentation(personal).body.contains("这里结合N003"),
                      "Only known AI workflow comments may be separated; personal writing stays intact.")
    }

    func testUnifiedCatalogDoesNotReorderAfterReadingOrUpdatingAPageAndKeepsEmptyNotes() {
        var item = sample()
        let before = TryNotebookCatalog(item)
        item.notes?.reverse()
        item.notes?[0].updatedAt = 5000
        item.selectedLearningNoteID = "N006"
        let after = TryNotebookCatalog(item)
        XCTAssertEqual(before.notes.map(\.id), after.notes.map(\.id))
        XCTAssertEqual(after.notes.map(\.id), ["N001", "N005", "N006"])
    }

    @MainActor
    func testReadOnlyProjectionCannotOverwriteFullSourceAndReturnRestoresItBeforeEditing() throws {
        _ = NSApplication.shared
        let source = "# 运行资源\n\n权重之外还有缓存。\n\n这里结合N003整理，原文保留。"
        let state = EditorState(source)
        let controller = TryNoteController()
        let note = TryLearningNote(id: "N005", title: "运行资源", body: source,
                                   createdAt: 1, updatedAt: 1, origin: "ai_organized")
        let window = host(TryNoteEditor(text: Binding(get: { state.text }, set: { state.text = $0 }),
            editing: Binding(get: { state.editing }, set: { state.editing = $0 }),
            minimumHeight: 250, maximumHeight: 350, autofocus: false, allowsClickToEdit: false,
            allowsReadingToEdit: true, richFormatting: true,
            readingPresentation: TryNotebookPresentation(note).body, controller: controller)
            .frame(width: 550, height: 350).padding(24))
        defer { window.close() }
        let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
        XCTAssertFalse(editor.isEditable)
        XCTAssertEqual(editor.string, "权重之外还有缓存。")
        editor.didChangeText(); controller.end(); settle()
        XCTAssertEqual(state.text, source, "A read-only projection must never be serialized back as the source.")
        window.makeFirstResponder(editor)
        editor.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        XCTAssertTrue(editor.isEditable)
        XCTAssertTrue(editor.string.contains("这里结合N003"), "Restore the full body synchronously before the first key.")
        XCTAssertTrue(editor.string.contains("运行资源"))
        editor.insertText("\n自己的新理解。", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        settle()
        XCTAssertTrue(state.text.contains("自己的新理解"))
        XCTAssertTrue(state.text.contains("这里结合N003"))
        XCTAssertTrue(state.text.contains("# 运行资源"))
    }

    @MainActor
    func testExplicitEditRestoresFullSourceBeforeImmediateFormatting() throws {
        _ = NSApplication.shared
        let source = "# 运行资源\n\n权重之外还有缓存。\n\n这里结合N003整理，原文保留。"
        let state = EditorState(source)
        let controller = TryNoteController()
        let note = TryLearningNote(id: "N005", title: "运行资源", body: source,
                                   createdAt: 1, updatedAt: 1, origin: "ai_organized")
        let window = host(TryNoteEditor(text: Binding(get: { state.text }, set: { state.text = $0 }),
            editing: Binding(get: { state.editing }, set: { state.editing = $0 }),
            minimumHeight: 250, maximumHeight: 350, autofocus: false, allowsClickToEdit: false,
            allowsReadingToEdit: true, richFormatting: true,
            readingPresentation: TryNotebookPresentation(note).body, controller: controller)
            .frame(width: 550, height: 350).padding(24))
        defer { window.close() }
        let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
        // The explicit Edit button changes its binding before SwiftUI updates the native view.
        state.editing = true
        controller.format(.bold)
        editor.insertText("补充", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        settle()
        XCTAssertTrue(state.text.contains("这里结合N003"))
        XCTAssertTrue(state.text.contains("# 运行资源"))
        XCTAssertTrue(state.text.contains("补充"))
    }

    @MainActor
    func testAllNotesChangesOnlyTheRightPaneAndBrowsingAllocatesNoDraft() throws {
        _ = NSApplication.shared
        let visibilityKey = "tryNotebookShowsDirectory"
        let savedVisibility = UserDefaults.standard.object(forKey: visibilityKey)
        UserDefaults.standard.set(true, forKey: visibilityKey)
        defer {
            if let savedVisibility { UserDefaults.standard.set(savedVisibility, forKey: visibilityKey) }
            else { UserDefaults.standard.removeObject(forKey: visibilityKey) }
        }
        try isolated { store in
            let id = sample().id
            XCTAssertTrue(store.update(id) { item in
                if let index = item.notes?.firstIndex(where: { $0.id == "N006" }) {
                    item.notes?[index].body = "# 缓存\n\n> " + String(repeating: "引用中的较长内容，", count: 24)
                }
            })
            let window = host(TryLearningNotebook(store: store, entryID: id, initialNoteID: "N005",
                close: {}, copyAction: { _ in }, notify: { _ in }))
            defer { window.close() }
            @MainActor func directoryIDs() -> [String] {
                descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                    .map { $0.keyboardIdentifier }.filter { $0.hasPrefix("try-select-note-") }
            }
            let before = directoryIDs()
            XCTAssertEqual(before, ["try-select-note-N006", "try-select-note-N005", "try-select-note-N001"])
            try action("try-notebook-all", window)
            XCTAssertEqual(directoryIDs(), before)
            XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.isEmpty)
            let overviewIDs = descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .map { $0.keyboardIdentifier }.filter { $0.hasPrefix("try-note-overview-") }.sorted()
            XCTAssertEqual(overviewIDs, ["try-note-overview-N001", "try-note-overview-N005", "try-note-overview-N006"])
            try action("try-note-overview-N001", window)
            XCTAssertEqual(directoryIDs(), before)
            XCTAssertFalse(try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first).isEditable)
            try action("try-select-note-N006", window)
            XCTAssertEqual(directoryIDs(), before)
            let reader = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            let content = reader.serializedNote
            let expandedWidth = reader.bounds.width
            let expandedRail = try XCTUnwrap(reader.noteQuoteRailRects().first)
            try action("try-notebook-toggle-directory", window)
            XCTAssertTrue(directoryIDs().isEmpty)
            XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first === reader)
            XCTAssertGreaterThan(reader.bounds.width, expandedWidth)
            let collapsedWidth = reader.bounds.width
            XCTAssertEqual(reader.serializedNote, content)
            XCTAssertLessThan(try XCTUnwrap(reader.noteQuoteRailRects().first).height, expandedRail.height)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: visibilityKey))

            let reopened = host(TryLearningNotebook(store: store, entryID: id, initialNoteID: "N006",
                close: {}, copyAction: { _ in }, notify: { _ in }))
            defer { reopened.close() }
            XCTAssertFalse(descendants(reopened.contentView!).compactMap { $0 as? DemandKeyboardActionView }
                .contains { $0.keyboardIdentifier.hasPrefix("try-select-note-") })
            try action("try-notebook-toggle-directory", reopened)
            XCTAssertTrue(UserDefaults.standard.bool(forKey: visibilityKey))
            XCTAssertEqual(directoryIDs(), before)

            // Route real mouse events through the window, including a move while the divider shifts.
            @MainActor func mouse(_ type: NSEvent.EventType, at point: NSPoint) {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
            }
            let divider = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNotebookDividerView }.first)
            XCTAssertFalse(divider.mouseDownCanMoveWindow)
            let start = divider.convert(NSPoint(x: divider.bounds.midX, y: divider.bounds.midY), to: nil)
            let destination = NSPoint(x: start.x - 85, y: start.y)
            mouse(.leftMouseDown, at: start)
            mouse(.leftMouseDragged, at: destination)
            settle()
            XCTAssertFalse(directoryIDs().isEmpty)
            XCTAssertGreaterThan(reader.bounds.width, expandedWidth + 35)
            XCTAssertLessThan(reader.bounds.width, collapsedWidth)
            mouse(.leftMouseUp, at: destination)
            settle()
            XCTAssertTrue(directoryIDs().isEmpty)
            XCTAssertFalse(UserDefaults.standard.bool(forKey: visibilityKey))
            XCTAssertTrue(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first === reader)

            try action("try-notebook-toggle-directory", window)
            let restoredDivider = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNotebookDividerView }.first)
            let click = restoredDivider.convert(NSPoint(x: restoredDivider.bounds.midX, y: restoredDivider.bounds.midY), to: nil)
            mouse(.leftMouseDown, at: click)
            mouse(.leftMouseUp, at: click)
            settle()
            XCTAssertTrue(directoryIDs().isEmpty)
            XCTAssertEqual(reader.serializedNote, content)
            XCTAssertEqual(store.entry(id)?.learningNotes.count, 3)
            XCTAssertTrue(store.entry(id)?.learningDraft.isEmpty == true)
            XCTAssertFalse(reader.isEditable)
        }
    }

    func testRepeatedCollectReusesTheUnchangedStudyDraft() throws {
        try isolated { store in
            XCTAssertTrue(store.collectLearningUnit("T007"))
            let first = store.entry("T007")?.learningOrganizations?.first?.id
            XCTAssertTrue(store.collectLearningUnit("T007"))
            XCTAssertEqual(store.entry("T007")?.learningOrganizations?.count, 1)
            XCTAssertEqual(store.entry("T007")?.learningOrganizations?.first?.id, first)
            XCTAssertTrue(store.entry("T007")?.verifiedLearningStages.isEmpty == true)
        }
    }

    @MainActor
    func testNativePreviewWithRealT007DataWhenRequested() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_LEARNING_INTERFACE_SNAPSHOTS"],
              let path = ProcessInfo.processInfo.environment["DBOARD_LEARNING_INTERFACE_STORE"] else { return }
        _ = NSApplication.shared
        let visibilityKey = "tryNotebookShowsDirectory"
        let savedVisibility = UserDefaults.standard.object(forKey: visibilityKey)
        UserDefaults.standard.set(true, forKey: visibilityKey)
        defer {
            if let savedVisibility { UserDefaults.standard.set(savedVisibility, forKey: visibilityKey) }
            else { UserDefaults.standard.removeObject(forKey: visibilityKey) }
        }
        let real = try XCTUnwrap(TryDisk.read(URL(fileURLWithPath: path)).entries.first { $0.id == "T007" })
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LearningPreview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.json")
        try TryDisk.change(url) { $0.entries = [real] }
        let store = TryStore(url: url, watching: false)
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let home = host(TryLearningHome(entries: [real], searching: false, open: { _ in }, notebook: { _ in }, create: {}).padding(28))
        try snapshot(home, path: output + "/home.png"); home.close()
        let study = host(TryJournalDetail(store: store, id: real.id, back: {}, open: { _ in }, notify: { _ in }))
        try snapshot(study, path: output + "/study.png"); study.close()
        let book = host(TryLearningNotebook(store: store, entryID: real.id, initialNoteID: "N006",
            close: {}, copyAction: { _ in }, notify: { _ in }))
        try snapshot(book, path: output + "/note.png")
        try action("try-notebook-toggle-directory", book)
        try snapshot(book, path: output + "/note-collapsed.png")
        try action("try-notebook-toggle-directory", book)
        try action("try-notebook-all", book)
        try snapshot(book, path: output + "/all-notes.png"); book.close()
    }

    @MainActor
    func testPlusOpensCurrentKnowledgePointNoteAndKeepsPlusInputInTheEditor() throws {
        _ = NSApplication.shared
        try isolated { store in
            let detail = TryDetailWindowController(store: store, activates: false)
            detail.show("T007"); settle()
            defer { detail.close() }
            let window = try XCTUnwrap(detail.window)
            let shortcut = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryLearningNoteShortcutView }.first)
            let plus = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "+",
                charactersIgnoringModifiers: "=", isARepeat: false, keyCode: 24))
            XCTAssertNil(shortcut.handleKey(plus))
            settle()
            let editor = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryNoteTextView }.first)
            XCTAssertTrue(editor.isEditable)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertTrue(editor.string.isEmpty)
            XCTAssertEqual(store.entry("T007")?.learningDraft.title, "权重、缓存与运行内存")
            XCTAssertEqual(store.entry("T007")?.learningNotes.count, 3, "A suggested title alone does not allocate a note.")
            XCTAssertNotNil(shortcut.handleKey(plus), "The plus shortcut must be inactive inside the notebook.")
            editor.insertText("权重 + 缓存。", replacementRange: editor.selectedRange())
            settle()
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.title, "权重、缓存与运行内存")
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.unitIDs, ["U001"])
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.topicIDs, ["K001"])
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.learningStageID, "S001")
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.body, "权重 + 缓存。")
        }
    }

    @MainActor
    func testShortcutDoesNotInterceptTextFieldsModifiersRepeatsOrOtherWindows() throws {
        _ = NSApplication.shared
        let window = host(TextField("输入", text: .constant("")).padding(24)
            .background(TryLearningNoteShortcut(enabled: true, action: {})))
        defer { window.close() }
        let shortcut = try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? TryLearningNoteShortcutView }.first)
        var activations = 0
        shortcut.action = { activations += 1 }
        @MainActor func key(_ modifiers: NSEvent.ModifierFlags = .shift, repeatKey: Bool = false, number: Int? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: number ?? window.windowNumber, context: nil, characters: "+",
                charactersIgnoringModifiers: "=", isARepeat: repeatKey, keyCode: 24)!
        }
        window.makeFirstResponder(nil)
        XCTAssertNotNil(shortcut.handleKey(key(.command)))
        XCTAssertNotNil(shortcut.handleKey(key(repeatKey: true)))
        let other = host(Text("其他窗口")); defer { other.close() }
        XCTAssertNotNil(shortcut.handleKey(key(number: other.windowNumber)))
        let text = NSTextView()
        text.isEditable = true
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text)
        XCTAssertNotNil(shortcut.handleKey(key()))
        XCTAssertEqual(activations, 0)
        window.makeFirstResponder(nil)
        XCTAssertNil(shortcut.handleKey(key()))
        XCTAssertEqual(activations, 1)
    }

    func testCurrentNoteTitleFallsBackToStageAndNeverRenamesAnOlderDraft() throws {
        try isolated { store in
            XCTAssertTrue(store.update("T007") { $0.learningUnits = [] })
            store.editLearningNote("T007", noteID: nil, field: "title", value: "先前的疑问", generation: 0)
            store.editLearningNote("T007", noteID: nil, field: "body", value: "尚未写完的原文。", generation: 0)
            let page = try XCTUnwrap(store.beginNotebookPage("T007", fresh: true,
                suggestedTitle: store.entry("T007")?.currentLearningStage?.title))
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.title, "先前的疑问")
            XCTAssertEqual(store.entry("T007")?.learningNotes.last?.body, "尚未写完的原文。")
            XCTAssertEqual(store.entry("T007")?.learningDraft.title, "运行资源")
            store.writeNotebookPage("T007", page: page, body: "这一节的新理解。")
            XCTAssertTrue(store.flush())
            let reloaded = TryStore(url: store.url, watching: false)
            XCTAssertEqual(reloaded.entry("T007")?.learningNotes.last?.title, "运行资源")
            XCTAssertEqual(reloaded.entry("T007")?.learningNotes.last?.body, "这一节的新理解。")
        }
    }

    func testLegacyLessonQuestionUsesExistingKnowledgeTopicAndCollectionUsesTheSameHeading() throws {
        try isolated { store in
            XCTAssertTrue(store.update("T007") { $0.learningUnits?[0].noteTitle = nil })
            XCTAssertEqual(store.entry("T007")?.currentLearningNoteTitle, "运行资源")
            XCTAssertTrue(store.update("T007") { $0.learningUnits?[0].noteTitle = "为什么这么慢？" })
            XCTAssertEqual(store.entry("T007")?.currentLearningNoteTitle, "运行资源")
            XCTAssertTrue(store.update("T007") { $0.learningUnits?[0].noteTitle = "权重、缓存与运行内存" })
            XCTAssertTrue(store.collectLearningUnit("T007"))
            XCTAssertEqual(store.entry("T007")?.learningOrganizations?.last?.title, "权重、缓存与运行内存")
            XCTAssertFalse(store.entry("T007")?.learningOrganizations?.last?.body.hasPrefix("# 为什么") == true)
            XCTAssertTrue(store.entry("T007")?.learningOrganizations?.last?.body.contains("权重外还有缓存") == true)
        }
    }

    private func sample() -> TryEntry {
        var item = TryEntry(id: "T007", kind: .digestion, title: "模型学习", createdAt: 1, updatedAt: 1)
        var config = TryLearningConfig.empty
        config.goal = "理解运行资源"; config.revision = 1
        item.learningConfig = config
        item.learningPlan = TryLearningPlan(id: "plan", configRevision: 1, target: "理解运行资源",
            startingPoint: "初学", rationale: "先讲后练", stages: [
                TryLearningStage(id: "S001", title: "运行资源", objective: "理解缓存", resources: "",
                    practice: "估算资源", check: "说明边界", estimatedMinutes: 30)])
        item.currentLearningStageID = "S001"
        item.learningTopics = [TryLearningTopic(id: "K001", title: "运行资源")]
        item.learningUnits = [TryLearningUnit(id: "U001", title: "为什么模型运行需要额外内存？", stageIDs: ["S001"], topicIDs: ["K001"],
            question: "为什么运行还有额外占用", materialKind: "hypothetical", material: "一个假设例子",
            conditions: "", metrics: "", reasoning: "权重外还有缓存", limits: "不能作为实际占用", judgment: "留出空间", sources: [], noteTitle: "权重、缓存与运行内存")]
        item.currentLearningUnitID = "U001"
        item.notes = [
            TryLearningNote(id: "N001", title: "空白原记录", body: "", createdAt: 1, updatedAt: 1),
            TryLearningNote(id: "N005", title: "权重", body: "# 权重\n\n权重需要空间。",
                createdAt: 2, updatedAt: 2, origin: "ai_organized"),
            TryLearningNote(id: "N006", title: "缓存", body: "# 缓存\n\n缓存需要空间。",
                createdAt: 3, updatedAt: 3, origin: "ai_supplement")]
        return item
    }
    private final class EditorState: ObservableObject {
        @Published var text: String
        @Published var editing = false
        init(_ text: String) { self.text = text }
    }
    private func isolated(_ action: (TryStore) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LearningInterface-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("personal.json")
        try TryDisk.change(url) { $0.entries = [sample()] }
        try action(TryStore(url: url, watching: false))
    }
    @MainActor private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 920, height: 780),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view.demandFloatingCanvas()
            .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
        window.orderBack(nil); settle()
        return window
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
    @MainActor private func action(_ id: String, _ window: NSWindow) throws {
        try XCTUnwrap(descendants(window.contentView!).compactMap { $0 as? DemandKeyboardActionView }
            .first { $0.keyboardIdentifier == id }, id).activate()
        settle()
    }
    @MainActor private func snapshot(_ window: NSWindow, path: String) throws {
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
