import XCTest
import AppKit
import SwiftUI
import Carbon.HIToolbox
@testable import DBoard

final class DemandImagesTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardImages-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<4 { for y in 0..<3 { bitmap.setColor(.red, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testInlineImageCopiesSurviveOriginalRemovalAndPreserveUnicodeAndWhitespace() throws {
        try withDirectory { directory in
            let original = directory.appendingPathComponent("中文 截图(1).png")
            try png().write(to: original)
            let store = DemandImageStore(directory: directory.appendingPathComponent("图片 库"))
            let link = try store.importFile(original)
            let reference = try XCTUnwrap(DemandImageMarkdown.references(in: link).first)
            XCTAssertNotEqual(reference.path, original.path)
            try FileManager.default.removeItem(at: original)
            XCTAssertNotNil(NSImage(contentsOfFile: reference.path))
            XCTAssertEqual(try store.importData(png(), label: "同一张截图").contains(reference.path), true)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count, 1)
            let markdown = "开头中文🙂  \n\n" + link + "\n    后面的说明\n\n"
            let rendered = DemandSpellText.attributed(markdown)
            XCTAssertTrue(rendered.string.contains("\u{fffc}"))
            XCTAssertFalse(rendered.string.contains(reference.path))
            XCTAssertEqual(DemandSpellText.markdown(rendered), markdown)
            let attributes = try FileManager.default.attributesOfItem(atPath: reference.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    @MainActor
    func testPromptAndChangeEditorPasteImagesThenRecoverWithFreshStores() throws {
        _ = NSApplication.shared
        try withDirectory { directory in
            let promptFile = directory.appendingPathComponent("prompt-drafts.json")
            let changesFile = directory.appendingPathComponent("change-drafts.json")
            let images = DemandImageStore(directory: directory.appendingPathComponent("images"))
            let item = DItem(id: "D014", project: "ultra", title: "", headerTitle: "图文编辑恢复",
                status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil,
                milestones: [], prompt: DemandPromptSections(intent: "原始文字").stored)
            let vm = DBoardViewModel(loadCache: false, promptDraftStore: DemandPromptDraftStore(url: promptFile),
                changeDraftStore: DemandChangeDraftStore(url: changesFile))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 640, height: 700),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: AnyView(
                DemandPromptEditor(item: item, draftStore: vm.promptDraftStore, cancel: {}, imageStore: images).environmentObject(vm)))
            window.contentViewController = host
            window.orderBack(nil)
            defer { window.close() }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setData(try png(), forType: .png)
            settle(window)
            let promptEditor = try XCTUnwrap(findEditor(try XCTUnwrap(window.contentView)))
            promptEditor.setSelectedRange(NSRange(location: promptEditor.string.utf16.count, length: 0))
            XCTAssertTrue(promptEditor.pasteImages(from: pasteboard))
            promptEditor.insertText("图片之后的说明", replacementRange: promptEditor.selectedRange())
            settle(window)
            let prompt = try XCTUnwrap(DemandPromptDraftStore(url: promptFile).drafts[item.id]?.sections.intent)
            XCTAssertEqual(DemandImageMarkdown.references(in: prompt).count, 1)
            XCTAssertTrue(prompt.hasSuffix("图片之后的说明"))
            XCTAssertFalse(promptEditor.string.contains(images.directory.path))
            host.rootView = AnyView(Color.clear)
            settle(window)
            let reopened = DBoardViewModel(loadCache: false, promptDraftStore: DemandPromptDraftStore(url: promptFile),
                changeDraftStore: DemandChangeDraftStore(url: changesFile))
            host.rootView = AnyView(
                DemandPromptEditor(item: item, draftStore: reopened.promptDraftStore, cancel: {}, imageStore: images).environmentObject(reopened))
            settle(window)
            XCTAssertEqual(DemandSpellText.markdown(try XCTUnwrap(findEditor(try XCTUnwrap(window.contentView))).attributedString()), prompt)
            host.rootView = AnyView(Color.clear)
            settle(window)
            host.rootView = AnyView(
                DemandChangesEditor(item: item, draftStore: reopened.changeDraftStore, cancel: {}, refreshOnAppear: false, imageStore: images)
                    .environmentObject(reopened))
            settle(window)
            let changeEditor = try XCTUnwrap(findEditor(try XCTUnwrap(window.contentView)))
            changeEditor.insertText("新的图文变更", replacementRange: changeEditor.selectedRange())
            XCTAssertTrue(changeEditor.pasteImages(from: pasteboard))
            settle(window)
            let change = try XCTUnwrap(DemandChangeDraftStore(url: changesFile).drafts[item.id]?.intent)
            XCTAssertTrue(change.hasPrefix("新的图文变更"))
            XCTAssertEqual(DemandImageMarkdown.references(in: change).count, 1)
            host.rootView = AnyView(Color.clear)
            settle(window)
            let latest = DBoardViewModel(loadCache: false, changeDraftStore: DemandChangeDraftStore(url: changesFile))
            host.rootView = AnyView(
                DemandChangesEditor(item: item, draftStore: latest.changeDraftStore, cancel: {}, refreshOnAppear: false, imageStore: images)
                    .environmentObject(latest))
            settle(window)
            XCTAssertEqual(DemandSpellText.markdown(try XCTUnwrap(findEditor(try XCTUnwrap(window.contentView))).attributedString()), change)
            XCTAssertTrue(item.changes.isEmpty)
            XCTAssertEqual(item.prompt, DemandPromptSections(intent: "原始文字").stored)
        }
    }

    @MainActor
    func testCommandVPasteDispatchesFromFirstResponderAndSavesDraft() throws {
        _ = NSApplication.shared
        try withDirectory { directory in
            let draftFile = directory.appendingPathComponent("drafts.json")
            let store = DemandChangeDraftStore(url: draftFile)
            let session = DemandChangeDraftSession(id: "D014", changes: [], store: store)
            let controller = DemandSpellInputController()
            let binding = Binding(get: { session.intent },
                set: { session.updateIntent($0, generation: session.generation) })
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 500, height: 320),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView:
                DemandSpellInput(text: binding, title: "真实粘贴入口", controller: controller,
                    imageStore: DemandImageStore(directory: directory.appendingPathComponent("images"))))
            window.orderBack(nil)
            defer { window.close() }
            settle(window)
            let editor = try XCTUnwrap(controller.editor)
            window.makeFirstResponder(editor)
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let imageData: Data
            if let fixture = ProcessInfo.processInfo.environment["DBOARD_PASTE_IMAGE"] {
                imageData = try Data(contentsOf: URL(fileURLWithPath: fixture))
            } else { imageData = try png() }
            pasteboard.setData(imageData, forType: .png)
            editor.pasteboard = pasteboard
            let pasteMenu = NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            XCTAssertTrue(editor.validateUserInterfaceItem(pasteMenu))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [.command], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            XCTAssertTrue(window.performKeyEquivalent(with: event), "⌘V 必须通过窗口传到实际输入框")
            settle(window)
            XCTAssertTrue(editor.string.contains("\u{fffc}"))
            let draft = try XCTUnwrap(DemandChangeDraftStore(url: draftFile).drafts["D014"])
            let reference = try XCTUnwrap(DemandImageMarkdown.references(in: draft.intent).first)
            XCTAssertNotNil(NSImage(contentsOfFile: reference.path))
            XCTAssertEqual(DemandSpellText.markdown(editor.attributedString()), draft.intent)
            pasteboard.clearContents()
            pasteboard.setString("图片后的文字", forType: .string)
            XCTAssertTrue(editor.performKeyEquivalent(with: event))
            settle(window)
            XCTAssertTrue(session.intent.hasSuffix("图片后的文字"))
            XCTAssertEqual(DemandImageMarkdown.references(in: session.intent).count, 1)
        }
    }

    @MainActor
    func testImageTypesAreAdvertisedForNativePasteValidation() {
        let editor = DemandSpellTextView(frame: .zero)
        editor.isRichText = true
        editor.importsGraphics = false
        XCTAssertTrue(editor.readablePasteboardTypes.contains(.png))
        XCTAssertTrue(editor.readablePasteboardTypes.contains(.tiff))
    }

    @MainActor
    func testFilePasteAndImageDeletionKeepSharedAttachmentReadable() throws {
        _ = NSApplication.shared
        try withDirectory { directory in
            let source = directory.appendingPathComponent("Finder粘贴.png")
            try png().write(to: source)
            let store = DemandImageStore(directory: directory.appendingPathComponent("images"))
            let editor = DemandSpellTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
            editor.isRichText = true
            editor.isEditable = true
            editor.imageStore = store
            editor.insertText("前面的文字", replacementRange: NSRange(location: 0, length: 0))
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL]))
            XCTAssertTrue(editor.pasteImages(from: pasteboard))
            let markdown = DemandSpellText.markdown(editor.attributedString())
            let image = try XCTUnwrap(DemandImageMarkdown.references(in: markdown).first)
            let index = try XCTUnwrap((editor.string as NSString).range(of: "\u{fffc}").location as Int?)
            XCTAssertLessThan(index, editor.attributedString().length)
            editor.setSelectedRange(NSRange(location: index, length: 1))
            editor.insertText("", replacementRange: editor.selectedRange())
            XCTAssertEqual(DemandImageMarkdown.references(in: DemandSpellText.markdown(editor.attributedString())).count, 0)
            XCTAssertTrue(editor.string.contains("前面的文字"))
            XCTAssertNotNil(NSImage(contentsOfFile: image.path))
            XCTAssertEqual(DemandImageMarkdown.references(in: markdown).count, 1)
        }
    }

    @MainActor
    func testInvalidImageOrDiskFailureLeavesExistingTextUntouched() throws {
        try withDirectory { directory in
            let blocked = directory.appendingPathComponent("file")
            try Data().write(to: blocked)
            let editor = DemandSpellTextView(frame: .zero)
            editor.isRichText = true
            editor.imageStore = DemandImageStore(directory: blocked.appendingPathComponent("images"))
            editor.insertText("必须保留的文字", replacementRange: NSRange(location: 0, length: 0))
            var error: String?
            editor.onError = { error = $0 }
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            pasteboard.setData(try png(), forType: .png)
            XCTAssertTrue(editor.pasteImages(from: pasteboard))
            XCTAssertNotNil(error)
            XCTAssertEqual(editor.string, "必须保留的文字")
            editor.imageStore = DemandImageStore(directory: directory.appendingPathComponent("valid"))
            pasteboard.clearContents()
            pasteboard.setData(Data("不是图片".utf8), forType: .png)
            XCTAssertTrue(editor.pasteImages(from: pasteboard))
            XCTAssertNotNil(error)
            XCTAssertEqual(editor.string, "必须保留的文字")
        }
    }

    @MainActor
    func testSavedPromptChangesAndCLIExposePicturesWhileDraftIsExcluded() throws {
        try withDirectory { directory in
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            let images = DemandImageStore(directory: directory.appendingPathComponent("images"))
            let link = try images.importData(png(), label: "原咒言图片")
            var demand = DItemDraft(newID: "D014", priority: .p1)
            demand.name = "图文交接"
            demand.promptSections.intent = "先按这张图实现\n" + link
            XCTAssertTrue(DItemStore.create(demand, at: cache))
            let changeLink = try images.importData(png(), label: "变更截图")
            let change = try XCTUnwrap(DItemStore.appendChange(id: demand.id, intent: "在原来基础上改成\n" + changeLink, at: cache))
            let item = try DItemStore.currentItem(id: demand.id, at: cache)
            XCTAssertEqual(item.prompt, demand.prompt)
            XCTAssertEqual(item.changes.first?.intent, change.intent)
            let session = DemandChangeDraftSession(id: demand.id, changes: item.changes,
                store: DemandChangeDraftStore(url: directory.appendingPathComponent("drafts.json")))
            session.updateIntent("未提交的图片\n![未发布](</tmp/not-submitted.png>)", generation: session.generation)
            let cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tools/dboard_ai.py").path
            let result = ProcessRunner.run("/usr/bin/env", arguments: ["python3", cli, "--cache", cache.path, "context", demand.id, "--change", change.id])
            XCTAssertEqual(result.exitCode, 0)
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
            let context = try XCTUnwrap(json["context"] as? String)
            XCTAssertTrue(context.contains(link))
            XCTAssertTrue(context.contains(changeLink))
            XCTAssertTrue(context.contains("逐张打开"))
            XCTAssertFalse(context.contains("not-submitted.png"))
            let attachments = try XCTUnwrap(json["images"] as? [[String: Any]])
            XCTAssertEqual(attachments.count, 1) // identical bytes share one immutable file.
            XCTAssertEqual(attachments.first?["exists"] as? Bool, true)
        }
    }

    @MainActor
    func testMissingImagesKeepTheirReferenceWhenEditorRestores() {
        let markdown = "文字\n![缺失图片](</tmp/dboard-image-that-does-not-exist.png>)\n后文"
        let rendered = DemandSpellText.attributed(markdown)
        XCTAssertEqual(DemandSpellText.markdown(rendered), markdown)
        XCTAssertTrue(rendered.string.contains("\u{fffc}"))
    }

    func testHomeShortcutDefaultCanBeChangedAndPreservesOtherBindings() throws {
        let suite = "DBoardHomeShortcut-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = ShortcutPreferences(defaults: defaults)
        XCTAssertEqual(prefs.binding(for: "dboard")?.title, "⌃⇧D")
        let reqFlow = prefs.binding(for: "reqflow")
        let replacement = GlobalShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey), keyLabel: "B")
        XCTAssertTrue(prefs.set(replacement, for: "dboard"))
        XCTAssertEqual(ShortcutPreferences(defaults: defaults).binding(for: "dboard"), replacement)
        XCTAssertEqual(prefs.binding(for: "reqflow"), reqFlow)
        XCTAssertFalse(prefs.set(try XCTUnwrap(reqFlow), for: "dboard"))
        XCTAssertEqual(prefs.binding(for: "dboard"), replacement)
    }

    @MainActor
    private func findEditor(_ view: NSView) -> DemandSpellTextView? {
        if let editor = view as? DemandSpellTextView { return editor }
        for child in view.subviews { if let editor = findEditor(child) { return editor } }
        return nil
    }

    @MainActor
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.contentView?.layoutSubtreeIfNeeded()
    }
}
