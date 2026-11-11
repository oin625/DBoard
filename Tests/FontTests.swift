import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class FontTests: XCTestCase {
    func testFontChoicePersistsWithoutChangingSkin() throws {
        try withDefaults { defaults in
            defaults.set("sand", forKey: "dboard_theme_id")
            let fonts = FontManager(defaults: defaults)
            fonts.current = .muyao
            XCTAssertEqual(FontManager(defaults: defaults).current, .muyao)
            XCTAssertEqual(defaults.string(forKey: "dboard_theme_id"), "sand")
            fonts.current = .system
            XCTAssertEqual(FontManager(defaults: defaults).current, .system)
        }
    }

    @MainActor
    func testOpenHomeQuickCardAndEditorsChangeFontsWithoutLosingTextImagesOrFocus() throws {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try withDefaults { defaults in
            let fonts = FontManager(defaults: defaults)
            let theme = ThemeManager(defaults: defaults)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardFonts-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let archive = DemandArchiveStore(cache: directory.appendingPathComponent("archive.md"),
                journalURL: directory.appendingPathComponent("journal.json"), allowsRemote: false)
            let vm = DBoardViewModel(loadCache: false,
                newItemDraftStore: NewDemandDraftStore(url: directory.appendingPathComponent("draft.json")),
                archiveStore: archive)
            var item = DItem(id: "D014", project: "ultra", title: "验券只查券，工单创建后再调用独立锁券接口。",
                headerTitle: "车点点锁券链路改造", status: .inProgress, priority: .p1,
                deadline: nil, branch: "feature/cdd-lock", startDate: nil,
                milestones: [Milestone(date: "11.10", content: "独立锁券接口与调试页就绪，等待调用方联调。")])
            item.reminder = "等待调用方联调"
            vm.items = [item]
            let quick = DemandQuickOpenModel()
            quick.begin(items: vm.items, archives: [], recentIDs: [])
            let native = Draft()
            native.rich = "改造说明\n" + DemandImageMarkdown.link(label: "联调截图",
                path: directory.appendingPathComponent("missing-image.png").path) + "\n保留图片引用"
            let controller = DemandSpellInputController()
            let homeWindow = host(FontScope(fonts: fonts, content: DBoardRootView(popoverMode: true)
                .environmentObject(vm).environmentObject(theme).environmentObject(fonts)), size: NSSize(width: 660, height: 740))
            let quickWindow = host(FontScope(fonts: fonts, content: DemandQuickOpenView(model: quick, open: { _ in }, close: {})
                .environmentObject(theme)), size: NSSize(width: 452, height: 370))
            let nativeWindow = host(FontScope(fonts: fonts, content: NativeFields(draft: native, controller: controller)
                .environmentObject(theme)), size: NSSize(width: 500, height: 420))
            let codeWindow = host(FontScope(fonts: fonts, content: Text("feature/cdd-lock · /Users/zz/code")
                .font(.system(size: 13, design: .monospaced)).padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white)),
                size: NSSize(width: 420, height: 70))
            defer { homeWindow.close(); quickWindow.close(); nativeWindow.close(); codeWindow.close() }
            settle()
            let rich = try XCTUnwrap(controller.editor)
            let plain = try XCTUnwrap(descendants(try XCTUnwrap(nativeWindow.contentView))
                .compactMap { $0 as? NSTextView }.first { !($0 is DemandSpellTextView) && $0.isEditable })
            let originalPlain = native.plain
            let originalRich = native.rich
            var attachmentRange = NSRange()
            let attachmentIndex = (rich.string as NSString).range(of: "\u{FFFC}").location
            let attachment = rich.textStorage?.attribute(.attachment, at: attachmentIndex, effectiveRange: &attachmentRange)
            XCTAssertNotNil(attachment)
            plain.setSelectedRange(NSRange(location: 2, length: 2))
            rich.setSelectedRange(NSRange(location: 1, length: 1))
            nativeWindow.makeFirstResponder(plain)
            let plainSelection = plain.selectedRange(), richSelection = rich.selectedRange()
            let output = ProcessInfo.processInfo.environment["DBOARD_FONT_SNAPSHOTS"]
            if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
            var previous: [String: Data] = [:]
            let codeBefore = try bitmap(codeWindow)
            for preset in [DBoardFont.system, .yuanti, .muyao, .kaiti] {
                fonts.current = preset
                settle()
                XCTAssertEqual(plain.font?.fontName, preset.appKitFont(13).fontName)
                XCTAssertEqual(rich.font?.fontName, preset.appKitFont(13).fontName)
                XCTAssertEqual((plain.typingAttributes[.font] as? NSFont)?.fontName, preset.appKitFont(13).fontName)
                XCTAssertEqual((rich.typingAttributes[.font] as? NSFont)?.fontName, preset.appKitFont(13).fontName)
                XCTAssertEqual(plain.selectedRange(), plainSelection)
                XCTAssertEqual(rich.selectedRange(), richSelection)
                XCTAssertTrue(nativeWindow.firstResponder === plain)
                XCTAssertEqual(native.plain, originalPlain)
                XCTAssertEqual(native.rich, originalRich)
                XCTAssertEqual(DemandSpellText.markdown(rich.attributedString()), originalRich)
                let after = rich.textStorage?.attribute(.attachment, at: attachmentIndex, effectiveRange: nil)
                XCTAssertTrue((after as AnyObject?) === (attachment as AnyObject?))
                XCTAssertEqual(quick.selectedID, item.id)
                XCTAssertEqual(try bitmap(codeWindow), codeBefore, "Technical monospaced text stays unchanged")
                for (name, window) in [("home", homeWindow), ("quick", quickWindow), ("editors", nativeWindow)] {
                    let png = try bitmap(window)
                    if let previous = previous[name] { XCTAssertNotEqual(png, previous, "\(name) should follow font selection immediately") }
                    previous[name] = png
                    if let output {
                        try png.write(to: URL(fileURLWithPath: output + "/\(preset.id)-\(name).png"))
                    }
                }
            }
            rich.setSelectedRange(NSRange(location: rich.string.utf16.count, length: 0))
            rich.insertText("，继续填写", replacementRange: rich.selectedRange())
            settle()
            XCTAssertEqual(native.rich, originalRich + "，继续填写")
            XCTAssertEqual(DemandImageMarkdown.references(in: native.rich).count, 1)
        }
    }

    @MainActor
    func testChangingFontDuringChineseCompositionPreservesMarkedText() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let fonts = FontManager(defaults: defaults)
            let draft = Draft()
            let controller = DemandSpellInputController()
            let window = host(FontScope(fonts: fonts, content:
                DemandSpellInput(text: Binding(get: { draft.rich }, set: { draft.rich = $0 }),
                    title: "中文输入", controller: controller)), size: NSSize(width: 500, height: 220))
            defer { window.close() }
            settle()
            let editor = try XCTUnwrap(controller.editor)
            window.makeFirstResponder(editor)
            editor.setMarkedText("联调", selectedRange: NSRange(location: 2, length: 0),
                                 replacementRange: NSRange(location: 0, length: 0))
            XCTAssertTrue(editor.hasMarkedText())
            let marked = editor.markedRange(), selection = editor.selectedRange(), text = editor.string
            fonts.current = .muyao
            settle()
            XCTAssertTrue(editor.hasMarkedText())
            XCTAssertEqual(editor.markedRange(), marked)
            XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertEqual(editor.string, text)
            XCTAssertEqual(draft.rich, "")
            editor.unmarkText()
            editor.didChangeText()
            settle()
            XCTAssertEqual(draft.rich, text)
            XCTAssertEqual(editor.font?.fontName, DBoardFont.muyao.appKitFont(13).fontName)
        }
    }

    @MainActor
    func testStatusMenuStillChangesStatusWithCustomFont() throws {
        _ = NSApplication.shared
        try withDefaults { defaults in
            let fonts = FontManager(defaults: defaults)
            fonts.current = .muyao
            let theme = ThemeManager(defaults: defaults)
            let state = StatusState()
            let window = DemandWorkspaceWindow(contentRect: NSRect(x: -10000, y: 0, width: 320, height: 180))
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: FontScope(fonts: fonts,
                content: StatusControl(state: state).padding(24).demandFloatingCanvas().environmentObject(theme)))
            let navigation = DemandWindowKeyboardNavigation(window: window)
            window.orderBack(nil)
            defer { window.close() }
            settle()
            XCTAssertTrue(navigation.focusControl(identifier: "font-status"))
            let action = try XCTUnwrap(window.firstResponder as? DemandKeyboardActionView)
            let probe = MenuProbe()
            let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                object: nil, queue: .main) { notification in
                    guard let menu = notification.object as? NSMenu else { return }
                    probe.opened = true
                    probe.menu = menu
                    DispatchQueue.main.async {
                        guard let menu = probe.menu else { return }
                        if let index = menu.items.firstIndex(where: { $0.title == ItemStatus.suspended.label }) {
                            menu.performActionForItem(at: index)
                        }
                        menu.cancelTracking()
                    }
                }
            defer { NotificationCenter.default.removeObserver(token) }
            action.activate()
            settle()
            XCTAssertTrue(probe.opened)
            XCTAssertEqual(state.status, .suspended)
        }
    }

    // The notification and deferred menu action both run on the main thread.
    private final class MenuProbe: @unchecked Sendable {
        var opened = false
        var menu: NSMenu?
    }
    private final class StatusState: ObservableObject { @Published var status = ItemStatus.inProgress }
    private struct StatusControl: View {
        @ObservedObject var state: StatusState
        var body: some View {
            StatusPill(status: state.status, onTap: {}, onSelect: { state.status = $0 })
                .demandKeyboardID("font-status")
        }
    }

    private final class Draft: ObservableObject {
        @Published var plain = "ultra 里三渠的车点点链路"
        @Published var rich = ""
    }
    private struct FontScope<Content: View>: View {
        @ObservedObject var fonts: FontManager
        let content: Content
        var body: some View { content.environment(\.dboardFontOverride, fonts.current) }
    }
    private struct NativeFields: View {
        @ObservedObject var draft: Draft
        let controller: DemandSpellInputController
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("代码入口").dboardFont(size: 15, weight: .semibold)
                PromptContextInput(text: $draft.plain, title: "代码入口").frame(maxHeight: 100)
                Text("要做什么").dboardFont(size: 15, weight: .semibold)
                DemandSpellInput(text: $draft.rich, title: "要做什么", controller: controller).frame(height: 220)
            }.padding(20).background { DemandCanvasBackground() }
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "DBoardFontTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
    @MainActor
    private func host<V: View>(_ root: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderBack(nil)
        return window
    }
    @MainActor
    private func bitmap(_ window: NSWindow) throws -> Data {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.45)) }
}
