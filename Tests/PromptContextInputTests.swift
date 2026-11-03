import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class PromptContextInputTests: XCTestCase {
    private final class Draft: ObservableObject { @Published var text = "" }
    private struct Input: View {
        @ObservedObject var draft: Draft
        var body: some View {
            PromptContextInput(text: $draft.text, title: "可能有用的资料")
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private struct SpellSheet: View {
        let item: DItem
        let vm: DBoardViewModel
        @State private var presented = false
        var body: some View {
            Color.clear.frame(width: 520, height: 500)
                .sheet(isPresented: $presented) { DemandPromptEditor(item: item, draftStore: vm.promptDraftStore, cancel: {}).environmentObject(vm) }
                .onAppear { presented = true }
        }
    }

    @MainActor
    func testPastedLongURLWrapsGrowsAndResizesWithoutLosingText() throws {
        _ = NSApplication.shared
        let draft = Draft()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 320, height: 250),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: Input(draft: draft))
        window.setContentSize(NSSize(width: 320, height: 250))
        window.orderBack(nil)
        defer { window.close() }
        settle(window)
        let content = try XCTUnwrap(window.contentView)
        let editor = try XCTUnwrap(findEditor(content))
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let emptyHeight = scroll.frame.height
        editor.insertText("方案文档", replacementRange: NSRange(location: 0, length: 0))
        settle(window)
        let singleContainer = try XCTUnwrap(editor.textContainer)
        let singleLayout = try XCTUnwrap(editor.layoutManager)
        singleLayout.ensureLayout(for: singleContainer)
        let singleTextBottom = max(singleLayout.usedRect(for: singleContainer).maxY,
                                   singleLayout.extraLineFragmentRect.maxY)
        XCTAssertEqual(scroll.contentSize.height,
                       ceil(singleTextBottom + editor.textContainerInset.height * 2), accuracy: 1,
                       "A single line should not leave another empty line below it")

        let url = "https://alidocs.dingtalk.com/i/nodes/ExampleDocument?corpId=dingfixture&iframeQuery=" +
            String(repeating: "abcdefghij", count: 20) + "&utm_source=im"
        // Exercise native text insertion, including the binding callback and automatic remeasurement.
        editor.insertText(url, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        settle(window)
        XCTAssertEqual(editor.string, url)
        XCTAssertGreaterThan(scroll.frame.height, emptyHeight + 20)
        XCTAssertFalse(scroll.hasHorizontalScroller)
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        layout.ensureLayout(for: container)
        XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxY + editor.textContainerInset.height * 2,
                                 scroll.contentSize.height + 1, "Full URL visibility: scroll=\(scroll.frame), editor=\(editor.frame), container=\(container.containerSize), used=\(layout.usedRect(for: container))")
        let textBottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        XCTAssertEqual(scroll.contentSize.height, ceil(textBottom + editor.textContainerInset.height * 2),
                       accuracy: 1, "Wrapped text should not leave an extra empty line below it")
        let narrowHeight = scroll.frame.height
        window.setContentSize(NSSize(width: 640, height: 250))
        settle(window)
        XCTAssertLessThan(scroll.frame.height, narrowHeight)
        XCTAssertEqual(editor.string, url)

        editor.setSelectedRange(NSRange(location: (url as NSString).length, length: 0))
        editor.insertText("\n补充方案说明", replacementRange: editor.selectedRange())
        settle(window)
        XCTAssertEqual(draft.text, url + "\n补充方案说明")
    }

    @MainActor
    func testFullSpellFormKeepsTextContainerAndVisibleFrameAligned() throws {
        _ = NSApplication.shared
        var url = "https://alidocs.dingtalk.com/i/nodes/ExampleDocument?corpId=dingfixture&iframeQuery=" +
            String(repeating: "abcdefghij", count: 12) + "&utm_source=im"
        var codeEntry = "ultra 里三渠的车点点链路"
        if let path = ProcessInfo.processInfo.environment["DBOARD_CONTEXT_FIXTURE"] {
            let fixture = try JSONDecoder().decode(DemandPromptSections.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            codeEntry = fixture.codeEntry
            url = fixture.materials
        }
        let item = DItem(id: "D014", project: "工作台", title: "", headerTitle: "车点点锁券链路改造",
            status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [],
            prompt: DemandPromptSections(codeEntry: codeEntry, materials: url,
                                         intent: "将锁券从验券中拆出。").stored)
        let vm = DBoardViewModel(loadCache: false)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 640, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView:
            SpellSheet(item: item, vm: vm))
        window.setContentSize(NSSize(width: 640, height: 560))
        window.orderBack(nil)
        defer { window.close() }
        settle(window)
        let form = try XCTUnwrap(window.attachedSheet)
        defer { window.endSheet(form); form.orderOut(nil) }
        for width: CGFloat in [640, 480, 800, 520] {
            form.setContentSize(NSSize(width: width, height: 560))
            settle(form)
            let content = try XCTUnwrap(form.contentView)
            let editor = try XCTUnwrap(findMaterialEditor(content))
            // Check restored content before typing: insertion can silently fix paragraph attributes.
            form.makeFirstResponder(editor)
            settle(form)
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            let container = try XCTUnwrap(editor.textContainer)
            let layout = try XCTUnwrap(editor.layoutManager)
            // Simulate a document retaining the width from an earlier sheet animation frame.
            editor.setFrameSize(NSSize(width: scroll.contentSize.width + 180, height: editor.frame.height))
            scroll.needsLayout = true
            scroll.layoutSubtreeIfNeeded()
            layout.ensureLayout(for: container)
            XCTAssertEqual(editor.string, url)
            XCTAssertLessThanOrEqual(layout.usedRect(for: container).maxX, container.containerSize.width + 1,
                                     "Long links must stay inside the visible input")
            if width == 480, let path = ProcessInfo.processInfo.environment["DBOARD_CONTEXT_SNAPSHOT"],
               let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            XCTAssertEqual(editor.frame.width, scroll.contentSize.width, accuracy: 1,
                           "Document width must follow the actual form input width")
            XCTAssertEqual(container.containerSize.width,
                           scroll.contentSize.width - editor.textContainerInset.width * 2, accuracy: 1,
                           "Text wrapping must match the visible field")
            let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            XCTAssertEqual(scroll.contentSize.height, ceil(bottom + editor.textContainerInset.height * 2),
                           accuracy: 1, "Filled form input should fit its actual visible text at width \(width)")
        }
    }

    @MainActor
    private func findMaterialEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.accessibilityLabel() == "可能有用的资料" { return editor }
        for child in view.subviews { if let editor = findMaterialEditor(child) { return editor } }
        return nil
    }

    @MainActor
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func findEditor(_ view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        for child in view.subviews { if let editor = findEditor(child) { return editor } }
        return nil
    }
}
