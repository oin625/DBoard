import XCTest
import AppKit
@testable import DBoard

final class TryNoteFormattingTests: XCTestCase {
    @MainActor
    func testMarkupSurvivesFontChangesAndRetainsListsLinksCodeAndImages() throws {
        _ = NSApplication.shared
        let body = """
        ## 我理解了什么
        **重点**和*疑问*，还有`sample_value`。
        - 第一条 **重点**
        - 第二条
        1. 一个步骤
        > 我自己的理解
        [参考](https://example.com/guide)
        ![证据](</tmp/note-format.png>)
        ```swift
        let value = "**literal**"
        ```
        """
        let text = NSMutableAttributedString(attributedString: TryNoteMarkup.attributed(body, font: .systemFont(ofSize: 16)))
        XCTAssertFalse(text.string.contains("## "))
        XCTAssertTrue(text.string.contains("• 第一条"))
        XCTAssertTrue(text.string.contains("sample_value"))
        XCTAssertTrue(text.string.contains("**literal**"), "Fenced code must not be interpreted as prose")
        let before = TryNoteMarkup.markdown(text)
        TryNoteMarkup.style(text, font: .monospacedSystemFont(ofSize: 18, weight: .regular))
        XCTAssertEqual(TryNoteMarkup.markdown(text), before)
        XCTAssertTrue(before.contains("- 第一条 **重点**"))
        XCTAssertTrue(before.contains("[参考](https://example.com/guide)"))
        XCTAssertTrue(before.contains("![证据](</tmp/note-format.png>)"))
        XCTAssertTrue(before.contains("```swift\nlet value = \"**literal**\"\n```"))
        XCTAssertEqual(TryNoteMarkup.markdown(TryNoteMarkup.attributed(before, font: .systemFont(ofSize: 16))), before)
        let code = "`**原样保留**`"
        XCTAssertEqual(TryNoteMarkup.attributed(code, font: .systemFont(ofSize: 16)).string, "**原样保留**")
        XCTAssertEqual(TryNoteMarkup.markdown(TryNoteMarkup.attributed(code, font: .systemFont(ofSize: 16))), code)
    }

    @MainActor
    func testBulletAndNumberedInputContinueExitAndUndoWithoutChangingMidSentenceStars() throws {
        let (window, editor) = editorWindow()
        defer { window.close() }
        editor.insertText("*", replacementRange: editor.selectedRange())
        settle()
        editor.insertText(" ", replacementRange: editor.selectedRange())
        settle()
        XCTAssertEqual(editor.string, "• ")
        editor.breakUndoCoalescing(); editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "*", "Undo automatic formatting back to the typed marker")
        editor.undoManager?.redo()
        XCTAssertEqual(editor.string, "• ")
        editor.insertText("第一条", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "• 第一条\n• ")
        editor.insertText("第二条", replacementRange: editor.selectedRange())
        editor.insertNewline(nil); editor.insertNewline(nil)
        XCTAssertEqual(editor.string, "• 第一条\n• 第二条\n")
        editor.insertText("普通段落* ", replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.string.hasSuffix("普通段落* "))
        editor.insertNewline(nil)
        editor.insertText("1.", replacementRange: editor.selectedRange())
        editor.insertText(" ", replacementRange: editor.selectedRange())
        editor.insertText("步骤一", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        XCTAssertTrue(editor.string.hasSuffix("1. 步骤一\n2. "))
        editor.deleteBackward(nil)
        XCTAssertTrue(editor.string.hasSuffix("1. 步骤一\n"))
        XCTAssertTrue(editor.serializedNote.contains("- 第一条\n- 第二条"))
    }

    @MainActor
    func testShortcutFormatsSelectionAndFutureTypingAndCanBeUndone() throws {
        let (window, editor) = editorWindow()
        defer { window.close() }
        editor.insertText("重点与疑问", replacementRange: editor.selectedRange())
        settle()
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        XCTAssertTrue(editor.performKeyEquivalent(with: key("b", window)))
        XCTAssertEqual(editor.serializedNote, "**重点**与疑问")
        settle()
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        editor.undoManager?.undo()
        XCTAssertEqual(editor.serializedNote, "重点与疑问")
        editor.undoManager?.redo()
        XCTAssertEqual(editor.serializedNote, "**重点**与疑问")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.typingAttributes.removeValue(forKey: .tryNoteBold)
        XCTAssertTrue(editor.performKeyEquivalent(with: key("i", window)))
        editor.insertText("补充", replacementRange: editor.selectedRange())
        XCTAssertTrue(editor.serializedNote.hasSuffix("*补充*"))
        editor.isEditable = false
        XCTAssertFalse(editor.handleNoteShortcut(key("b", window)), "Reading mode must not modify notes")
    }

    @MainActor
    func testHeadingInputDoesNotForceFollowingParagraphToRemainAHeading() {
        let (window, editor) = editorWindow()
        defer { window.close() }
        editor.insertText("##", replacementRange: editor.selectedRange())
        editor.insertText(" ", replacementRange: editor.selectedRange())
        editor.insertText("小标题", replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        editor.insertText("正文", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.serializedNote, "## 小标题\n正文")
    }


    @MainActor
    func testChineseItalicActuallyChangesRenderedGlyphsAndSurvivesReload() throws {
        let (window, editor) = editorWindow()
        defer { window.close() }
        let font = try XCTUnwrap(NSFont(name: "Hannotate SC", size: 22))
        XCTAssertFalse(NSFontManager.shared.traits(of: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)).contains(.italicFontMask))
        editor.noteBaseFont = font
        editor.textStorage?.setAttributedString(TryNoteMarkup.attributed("中文学习笔记与 English", font: font))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.isEditable = false
        let before = try raster(editor)
        editor.isEditable = true
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.applyNoteFormat(.italic)
        XCTAssertEqual(editor.serializedNote, "*中文学习笔记与 English*")
        XCTAssertEqual((editor.textStorage?.attribute(.obliqueness, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0.18, accuracy: 0.001)
        let saved = editor.serializedNote
        editor.textStorage?.setAttributedString(TryNoteMarkup.attributed(saved, font: font))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.isEditable = false
        let after = try raster(editor)
        XCTAssertNotEqual(before, after, "The selected Chinese font must visibly tilt, not merely store an italic flag")
        editor.isEditable = true
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
        editor.applyNoteFormat(.italic)
        XCTAssertEqual(editor.serializedNote, "中文学习笔记与 English")
        XCTAssertEqual((editor.textStorage?.attribute(.obliqueness, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0, 0, accuracy: 0.001)
        if let directory = ProcessInfo.processInfo.environment["DBOARD_NOTE_FORMAT_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try before.write(to: URL(fileURLWithPath: directory + "/upright-chinese.png"))
            try after.write(to: URL(fileURLWithPath: directory + "/italic-chinese.png"))
        }
    }

    @MainActor
    func testBothQuoteMarkersContinueExitAndStayQuotedAfterReload() throws {
        for marker in [">", "》"] {
            let (window, editor) = editorWindow()
            defer { window.close() }
            editor.insertText(marker, replacementRange: editor.selectedRange())
            editor.insertText(" ", replacementRange: editor.selectedRange())
            XCTAssertTrue(editor.string.isEmpty)
            XCTAssertEqual(editor.typingAttributes[.tryNoteQuote] as? Bool, true)
            editor.insertText("引用原话", replacementRange: editor.selectedRange())
            editor.insertNewline(nil)
            editor.insertText("继续引用", replacementRange: editor.selectedRange())
            editor.insertNewline(nil); editor.insertNewline(nil)
            editor.insertText("普通段落", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.serializedNote, "> 引用原话\n> 继续引用\n普通段落")
            let reloaded = TryNoteMarkup.attributed(editor.serializedNote, font: editor.noteBaseFont)
            XCTAssertEqual(reloaded.attribute(.tryNoteQuote, at: 0, effectiveRange: nil) as? Bool, true)
            XCTAssertNil(reloaded.attribute(.tryNoteQuote, at: reloaded.length - 1, effectiveRange: nil))
            editor.textStorage?.setAttributedString(reloaded)
            editor.isEditable = false; editor.setSelectedRange(NSRange(location: 0, length: 0))
            if let directory = ProcessInfo.processInfo.environment["DBOARD_NOTE_FORMAT_SNAPSHOTS"] {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try raster(editor).write(to: URL(fileURLWithPath: directory + "/quote.png"))
            }
        }
        let alias = TryNoteMarkup.attributed("》 引用文字", font: .systemFont(ofSize: 16))
        XCTAssertEqual(TryNoteMarkup.markdown(alias), "> 引用文字")
    }

    @MainActor
    private func raster(_ editor: NSView) throws -> Data {
        editor.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: editor.bounds))
        editor.cacheDisplay(in: editor.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.06)) }
    @MainActor
    private func editorWindow() -> (NSWindow, TryNoteTextView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = TryNoteTextView(frame: window.contentView!.bounds)
        editor.usesNoteFormatting = true; editor.isRichText = true; editor.isEditable = true; editor.allowsUndo = true
        editor.noteBaseFont = .systemFont(ofSize: 16)
        editor.typingAttributes = [.font: editor.noteBaseFont, .paragraphStyle: TryNoteMarkup.paragraph([:])]
        window.contentView = editor; window.makeFirstResponder(editor)
        return (window, editor)
    }
    @MainActor
    private func key(_ letter: String, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: letter,
            charactersIgnoringModifiers: letter, isARepeat: false, keyCode: letter == "b" ? 11 : 34)!
    }
}
