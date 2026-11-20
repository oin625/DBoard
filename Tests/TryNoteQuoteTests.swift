import XCTest
import AppKit
@testable import DBoard

final class TryNoteQuoteTests: XCTestCase {
    @MainActor
    func testReadingPlainEmptyLineDoesNotUseStaleQuoteTypingAttributes() {
        let (window, editor, _) = editorWindow("\n普通正文")
        defer { window.close() }
        editor.isEditable = false
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.typingAttributes[.tryNoteQuote] = true
        XCTAssertTrue(editor.noteQuoteRailRects().isEmpty, "Reading must show stored paragraph formatting only.")
    }

    @MainActor
    func testRailStopsBeforeTheFollowingPlainParagraph() throws {
        let (window, editor, _) = editorWindow("> 引用原话\n普通正文")
        defer { window.close() }
        editor.isEditable = false
        let rail = try XCTUnwrap(editor.noteQuoteRailRects().first)
        let plain = (editor.string as NSString).range(of: "普通正文").location
        let fragment = lineFragment(editor, at: plain)
        XCTAssertLessThanOrEqual(rail.maxY, editor.textContainerOrigin.y + fragment.minY)
        XCTAssertEqual(editor.noteQuoteRailRects().count, 1)
    }

    @MainActor
    func testRailMovesWithParagraphAndReflowsWhenWidthChanges() throws {
        let text = "> " + String(repeating: "引用里的一段较长文字，", count: 12) + "\n普通正文"
        let (window, editor, scroll) = editorWindow(text)
        defer { window.close() }
        editor.isEditable = false
        let before = try XCTUnwrap(editor.noteQuoteRailRects().first)
        let prefix = "插入在引用前面的段落\n再插入一段\n"
        editor.textStorage?.insert(TryNoteMarkup.attributed(prefix, font: editor.noteBaseFont), at: 0)
        editor.didChangeText()
        let moved = try XCTUnwrap(editor.noteQuoteRailRects().first)
        XCTAssertGreaterThan(moved.minY, before.minY + editor.noteBaseFont.pointSize)
        let quoteStart = prefix.utf16.count
        XCTAssertEqual(moved.minY, editor.textContainerOrigin.y + lineFragment(editor, at: quoteStart).minY + 2, accuracy: 0.5)
        scroll.setFrameSize(NSSize(width: 240, height: 240))
        editor.setFrameSize(NSSize(width: 240, height: editor.frame.height))
        editor.textContainer?.containerSize.width = 236
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        let narrowed = try XCTUnwrap(editor.noteQuoteRailRects().first)
        XCTAssertGreaterThan(narrowed.height, moved.height)
        try snapshot(scroll, name: "quote-narrow")
    }

    @MainActor
    func testPastingInlineTextAtQuoteStartKeepsWholeParagraphQuoted() throws {
        let (window, editor, _) = editorWindow("> 原话")
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(TryNoteMarkup.attributed("补充 ", font: editor.noteBaseFont), replacementRange: editor.selectedRange())
        editor.applyNoteFont(editor.noteBaseFont)
        XCTAssertEqual(editor.serializedNote, "> 补充 原话")
        XCTAssertEqual(editor.noteQuoteRailRects().count, 1)
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        XCTAssertEqual(editor.serializedNote, "> 原话")
    }

    @MainActor
    func testMixedInlineStylesKeepOneContinuousQuoteRail() throws {
        let (window, editor, _) = editorWindow("> 普通 **加粗** 和 *斜体*\n> 第二段引用\n\n普通正文")
        defer { window.close() }
        let before = editor.serializedNote
        editor.applyNoteFont(.monospacedSystemFont(ofSize: 20, weight: .regular))
        XCTAssertEqual(editor.serializedNote, before)
        XCTAssertEqual(editor.noteQuoteRailRects().count, 1)
        editor.isEditable = false
        try snapshot(editor.enclosingScrollView!, name: "quote-mixed-styles")
    }

    @MainActor
    func testBackspaceAtQuoteStartExitsQuoteWithoutJoiningPreviousParagraph() {
        let (window, editor, _) = editorWindow("普通正文\n> 引用原话")
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: "普通正文\n".utf16.count, length: 0))
        editor.deleteBackward(nil)
        XCTAssertEqual(editor.string, "普通正文\n引用原话")
        XCTAssertEqual(editor.serializedNote, "普通正文\n引用原话")
        XCTAssertTrue(editor.noteQuoteRailRects().isEmpty)
    }

    @MainActor
    func testQuoteContinuationExitAndUndoRedoKeepCorrectRails() throws {
        let (window, editor, _) = editorWindow("")
        defer { window.close() }
        editor.insertText("》", replacementRange: editor.selectedRange())
        editor.insertText(" ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.noteQuoteRailRects().count, 1)
        editor.insertText("第一段引用", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        editor.insertText("第二段引用", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        editor.insertNewline(nil)
        editor.insertText("普通正文", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.serializedNote, "> 第一段引用\n> 第二段引用\n普通正文")
        XCTAssertEqual(editor.noteQuoteRailRects().count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        editor.setSelectedRange(NSRange(location: 0, length: "第一段引用\n第二段引用".utf16.count))
        editor.applyNoteFormat(.quote)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertTrue(editor.noteQuoteRailRects().isEmpty)
        editor.undoManager?.undo()
        XCTAssertEqual(editor.noteQuoteRailRects().count, 1)
        editor.undoManager?.redo()
        XCTAssertTrue(editor.noteQuoteRailRects().isEmpty)
    }

    @MainActor
    func testScrollingDoesNotCreateRailOnUnquotedLines() throws {
        let body = (0..<30).map { "普通段落" + String($0) }.joined(separator: "\n") +
            "\n> 引用原话\n" + (30..<60).map { "普通段落" + String($0) }.joined(separator: "\n")
        let (window, editor, scroll) = editorWindow(body)
        defer { window.close() }
        editor.isEditable = false
        let rails = editor.noteQuoteRailRects()
        XCTAssertEqual(rails.count, 1)
        let rail = try XCTUnwrap(rails.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rail.minY - 80)))
        scroll.reflectScrolledClipView(scroll.contentView)
        try snapshot(scroll, name: "quote-scroll")
        XCTAssertEqual(editor.noteQuoteRailRects(), rails)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.typingAttributes[.tryNoteQuote] = true
        XCTAssertEqual(editor.noteQuoteRailRects(), rails)
    }

    @MainActor
    func testSwitchingEmptyQuoteAndHeadingClearsOldParagraphFormat() {
        for (first, second, expected, count) in [(">", "##", "## 新内容", 0), ("##", ">", "> 新内容", 1)] {
            let (window, editor, _) = editorWindow("")
            defer { window.close() }
            editor.insertText(first, replacementRange: editor.selectedRange())
            editor.insertText(" ", replacementRange: editor.selectedRange())
            editor.insertText(second, replacementRange: editor.selectedRange())
            editor.insertText(" ", replacementRange: editor.selectedRange())
            editor.insertText("新内容", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.serializedNote, expected)
            XCTAssertEqual(editor.noteQuoteRailRects().count, count)
        }
    }

    @MainActor
    func testDeletingNewlineBetweenPlainAndQuoteRemovesStaleQuoteMetadata() {
        let (window, editor, _) = editorWindow("普通正文\n> 引用原话")
        defer { window.close() }
        editor.setSelectedRange(NSRange(location: "普通正文".utf16.count, length: 0))
        editor.deleteForward(nil)
        XCTAssertEqual(editor.serializedNote, "普通正文引用原话")
        XCTAssertTrue(editor.noteQuoteRailRects().isEmpty)
        XCTAssertNil(editor.textStorage?.attribute(.tryNoteQuote, at: editor.string.utf16.count - 1, effectiveRange: nil))
        let style = editor.textStorage?.attribute(.paragraphStyle, at: editor.string.utf16.count - 1, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.headIndent, 0)
    }

    @MainActor
    func testEnteringQuoteOnAnExistingEmptyLinePersistsAtThatLineOnly() throws {
        let (window, editor, _) = editorWindow("前一段\n\n后一段")
        defer { window.close() }
        let position = "前一段\n".utf16.count
        editor.setSelectedRange(NSRange(location: position, length: 0))
        editor.insertText(">", replacementRange: editor.selectedRange())
        editor.insertText(" ", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.serializedNote, "前一段\n> \n后一段")
        editor.isEditable = false
        let rails = editor.noteQuoteRailRects()
        XCTAssertEqual(rails.count, 1)
        XCTAssertEqual(try XCTUnwrap(rails.first).minY,
            editor.textContainerOrigin.y + lineFragment(editor, at: position).minY + 2, accuracy: 0.5)
    }

    @MainActor
    private func editorWindow(_ body: String) -> (NSWindow, TryNoteTextView, NSScrollView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 480, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        scroll.drawsBackground = true; scroll.backgroundColor = .white
        scroll.hasVerticalScroller = true
        let editor = TryNoteTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 2000))
        editor.usesNoteFormatting = true; editor.isRichText = true
        editor.isEditable = true; editor.allowsUndo = true
        editor.noteBaseFont = .systemFont(ofSize: 16); editor.noteQuoteColor = .systemGreen
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 2, height: 8)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textStorage?.setAttributedString(TryNoteMarkup.attributed(body, font: editor.noteBaseFont))
        editor.typingAttributes = [.font: editor.noteBaseFont, .paragraphStyle: TryNoteMarkup.paragraph([:])]
        scroll.documentView = editor; window.contentView = scroll
        window.orderBack(nil)
        window.makeFirstResponder(editor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        return (window, editor, scroll)
    }

    @MainActor
    private func lineFragment(_ editor: TryNoteTextView, at character: Int) -> NSRect {
        let layout = editor.layoutManager!
        layout.ensureLayout(for: editor.textContainer!)
        return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: character), effectiveRange: nil)
    }

    @MainActor
    private func snapshot(_ view: NSView, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_QUOTE_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
    }
}
