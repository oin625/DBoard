import SwiftUI
import AppKit

final class TryNoteController: ObservableObject {
    weak var editor: TryNoteTextView?
    @Published var error: String?
    func focus() {
        guard let editor else { return }
        editor.beginWriting(force: true)
        editor.window?.makeFirstResponder(editor)
    }
    func images() { focus(); editor?.chooseImages() }
    func insert(_ text: String) {
        focus()
        guard let editor else { return }
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    func format(_ format: TryNoteFormat) { focus(); editor?.applyNoteFormat(format) }
    func end() {
        guard let editor else { return }
        if editor.hasMarkedText() { editor.unmarkText() }
        editor.didChangeText()
        editor.window?.makeFirstResponder(nil)
        editor.endWriting?()
    }
}

/// Transparent, growing document editor. Its identity stays stable through autosave and AI feedback.
struct TryNoteEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    var bookmark: TryBookmark?
    var minimumHeight: CGFloat = 280
    var maximumHeight: CGFloat = 560
    var autofocus = true
    var allowsClickToEdit = true
    var allowsReadingToEdit = false
    var richFormatting = false
    var readingPresentation: String? = nil
    let controller: TryNoteController
    var imageStore: DemandImageStore = .shared
    var onBookmark: (TryBookmark) -> Void = { _ in }
    var onEnd: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dboardFocusColor) private var accentColor
    @Environment(\.dboardFontOverride) private var fontOverride
    @ObservedObject private var fonts = FontManager.shared
    private var font: NSFont { (fontOverride ?? fonts.current).appKitFont(16) }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, editing: $editing, font: font, readingPresentation: readingPresentation,
                    onBookmark: onBookmark, onEnd: onEnd)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TryNoteScrollView()
        scroll.borderType = .noBorder; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay
        let editor = TryNoteTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 280))
        editor.imageStore = imageStore
        editor.usesNoteFormatting = richFormatting
        editor.noteBaseFont = font
        editor.noteQuoteColor = accentColor
        editor.onError = { [weak controller] in controller?.error = $0 }
        editor.isRichText = true; editor.importsGraphics = false; editor.allowsUndo = true
        editor.drawsBackground = false
        editor.isEditable = editing; editor.isSelectable = true
        editor.allowsEditingFromInteraction = allowsClickToEdit
        editor.allowsReadingToEdit = allowsReadingToEdit
        editor.font = font
        editor.textContainerInset = NSSize(width: 2, height: 8)
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6; paragraph.paragraphSpacing = 5; paragraph.lineBreakMode = .byCharWrapping
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.lineBreakMode = .byCharWrapping
        let displayedText = editing ? text : readingPresentation ?? text
        editor.textStorage?.setAttributedString(editor.renderedNote(displayedText))
        context.coordinator.loadedSource = displayedText
        context.coordinator.isShowingReadingPresentation = !editing && readingPresentation != nil
        if !richFormatting {
            editor.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: editor.attributedString().length))
        }
        editor.setAccessibilityLabel("正文")
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        editor.delegate = context.coordinator
        editor.beginWritingAction = { [weak editor] in
            let coordinator = context.coordinator
            if let editor, coordinator.isShowingReadingPresentation {
                // Restore the complete source synchronously before the first edit or formatting action.
                let raw = coordinator.text.wrappedValue
                let selection = editor.selectedRange()
                editor.textStorage?.setAttributedString(editor.renderedNote(raw))
                coordinator.loadedSource = raw
                coordinator.isShowingReadingPresentation = false
                let length = editor.attributedString().length
                editor.setSelectedRange(NSRange(location: min(selection.location, length),
                    length: min(selection.length, max(0, length - selection.location))))
            }
            coordinator.editing.wrappedValue = true
        }
        editor.endWriting = { [weak editor] in
            if let editor { context.coordinator.publish(editor); context.coordinator.remember(editor) }
            context.coordinator.editing.wrappedValue = false
            context.coordinator.onEnd()
        }
        scroll.documentView = editor
        controller.editor = editor
        context.coordinator.editor = editor
        context.coordinator.observeUndo(editor)
        applyColors(editor)
        if let bookmark {
            let length = editor.attributedString().length
            editor.setSelectedRange(NSRange(location: min(bookmark.location, length),
                length: min(bookmark.length, max(0, length - bookmark.location))))
            scroll.restorePoint = NSPoint(x: 0, y: bookmark.scrollY)
            scroll.scheduleRestoration()
        } else {
            // A new topic page starts at its beginning; saved reading positions still win.
            scroll.restorePoint = .zero
            scroll.scheduleRestoration()
        }
        if autofocus && (editing || allowsReadingToEdit) {
            DispatchQueue.main.async { [weak editor] in editor?.window?.makeFirstResponder(editor) }
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text; coordinator.editing = $editing
        coordinator.font = font; coordinator.onBookmark = onBookmark; coordinator.onEnd = onEnd
        coordinator.readingPresentation = readingPresentation
        guard let editor = scroll.documentView as? TryNoteTextView else { return }
        controller.editor = editor
        guard !editor.hasMarkedText() else { return }
        editor.usesNoteFormatting = richFormatting
        editor.noteBaseFont = font
        editor.noteQuoteColor = accentColor
        let displayedText = editing ? text : readingPresentation ?? text
        if richFormatting ? coordinator.loadedSource != displayedText : editor.serializedNote != displayedText {
            let selection = editor.selectedRange()
            let origin = scroll.contentView.bounds.origin
            editor.textStorage?.setAttributedString(editor.renderedNote(displayedText))
            coordinator.loadedSource = displayedText
            if !richFormatting, let paragraph = editor.defaultParagraphStyle {
                editor.textStorage?.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: editor.attributedString().length))
            }
            let length = editor.attributedString().length
            editor.setSelectedRange(NSRange(location: min(selection.location, length),
                length: min(selection.length, max(0, length - selection.location))))
            scroll.contentView.scroll(to: origin)
        }
        coordinator.isShowingReadingPresentation = !editing && readingPresentation != nil
        editor.isEditable = editing
        editor.allowsEditingFromInteraction = allowsClickToEdit
        editor.allowsReadingToEdit = allowsReadingToEdit
        applyColors(editor)
    }
    private func applyColors(_ editor: TryNoteTextView) {
        editor.applyNoteFont(font)
        var color = NSColor.labelColor
        NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        }
        editor.textColor = color; editor.insertionPointColor = color
        editor.typingAttributes[.foregroundColor] = color
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let editor = scroll.documentView as? NSTextView else { return nil }
        let width = max(100, proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480)
        let storage = NSTextStorage(attributedString: editor.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - 4), height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; container.lineBreakMode = .byCharWrapping
        storage.addLayoutManager(layout); layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let height = ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + 16)
        return CGSize(width: width, height: min(maximumHeight, max(minimumHeight, height)))
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? TryNoteTextView else { return }
        if editor.hasMarkedText() { editor.unmarkText() }
        let value = editor.serializedNote
        let canWrite = !coordinator.isShowingReadingPresentation &&
            (coordinator.editing.wrappedValue || coordinator.readingPresentation == nil)
        let range = editor.selectedRange()
        let bookmark = TryBookmark(location: range.location, length: range.length,
            scrollY: Double(editor.enclosingScrollView?.contentView.bounds.origin.y ?? 0))
        // Dismantling happens inside a SwiftUI update; commit the captured values afterwards.
        DispatchQueue.main.async {
            if canWrite, coordinator.text.wrappedValue != value { coordinator.text.wrappedValue = value }
            coordinator.onBookmark(bookmark)
            coordinator.onEnd()
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var editing: Binding<Bool>
        var font: NSFont
        var loadedSource: String
        var readingPresentation: String?
        var isShowingReadingPresentation = false
        var onBookmark: (TryBookmark) -> Void
        var onEnd: () -> Void
        weak var editor: TryNoteTextView?
        private var undoTokens: [NSObjectProtocol] = []
        func observeUndo(_ editor: TryNoteTextView) {
            for name in [Notification.Name.NSUndoManagerDidUndoChange, Notification.Name.NSUndoManagerDidRedoChange] {
                undoTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak editor] event in
                    guard let self, let editor, let manager = event.object as? UndoManager,
                          manager === editor.undoManager else { return }
                    // Attachment undo changes native storage without a textDidChange callback.
                    // Publish before a queued autosave redraw can restore the older binding.
                    self.publish(editor)
                })
            }
        }
        deinit { undoTokens.forEach(NotificationCenter.default.removeObserver) }
        init(text: Binding<String>, editing: Binding<Bool>, font: NSFont, readingPresentation: String?,
             onBookmark: @escaping (TryBookmark) -> Void, onEnd: @escaping () -> Void) {
            self.text = text; self.editing = editing; self.font = font
            self.loadedSource = text.wrappedValue
            self.readingPresentation = readingPresentation
            self.onBookmark = onBookmark; self.onEnd = onEnd
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, ExcalidrawDocument.handles(url) else { return false }
            ExcalidrawWindowManager.shared.open(url)
            return true
        }
        func publish(_ editor: NSTextView) {
            guard let editor = editor as? TryNoteTextView, !editor.hasMarkedText(), !isShowingReadingPresentation,
                  editing.wrappedValue || readingPresentation == nil else { return }
            editor.applyNoteFont(font)
            let markdown = editor.serializedNote
            loadedSource = markdown
            if text.wrappedValue != markdown { text.wrappedValue = markdown }
        }
        func remember(_ editor: NSTextView) {
            let range = editor.selectedRange()
            onBookmark(TryBookmark(location: range.location, length: range.length,
                scrollY: Double(editor.enclosingScrollView?.contentView.bounds.origin.y ?? 0)))
        }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { publish(editor) }
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            publish(editor); remember(editor); onEnd()
        }
    }
}

final class TryNoteScrollView: PromptContextInput.PromptContextScrollView {
    var restorePoint: NSPoint?
    private var restoration: DispatchWorkItem?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        normalizeDocumentOrigin()
        scheduleRestoration()
    }
    override func layout() {
        super.layout()
        normalizeDocumentOrigin()
        scheduleRestoration()
    }
    private func normalizeDocumentOrigin() {
        guard let documentView, documentView.frame.origin != .zero else { return }
        // SwiftUI size probes can leave the document above its clip view.
        // Keep its coordinate system stable, retaining the visible text during resize.
        let visibleY = contentView.bounds.origin.y - documentView.frame.origin.y
        documentView.setFrameOrigin(.zero)
        if restorePoint == nil {
            contentView.scroll(to: NSPoint(x: 0, y: max(0, visibleY)))
            reflectScrolledClipView(contentView)
        }
    }
    func scheduleRestoration() {
        guard restorePoint != nil else { return }
        restoration?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let point = self.restorePoint else { return }
            self.restorePoint = nil
            let maximum = max(0, (self.documentView?.frame.height ?? 0) - self.contentView.bounds.height)
            self.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(point.y, maximum))))
            self.reflectScrolledClipView(self.contentView)
        }
        restoration = work
        // SwiftUI probes and resizes the editor before its final visible viewport is settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }
    deinit { restoration?.cancel() }
}

final class TryNoteTextView: DemandSpellTextView {
    var beginWritingAction: (() -> Void)?
    var endWriting: (() -> Void)?
    var allowsEditingFromInteraction = true
    var allowsReadingToEdit = false
    var usesNoteFormatting = false
    var noteBaseFont = NSFont.systemFont(ofSize: 16)
    var noteQuoteColor = NSColor.systemBlue {
        didSet { if oldValue != noteQuoteColor { invalidateNoteQuoteRails() } }
    }
    func invalidateNoteQuoteRails() {
        guard usesNoteFormatting else { return }
        // AppKit invalidates glyphs, but the custom rail sits outside their bounds.
        // Repaint the gutter so removed or moved quotes cannot leave old pixels behind.
        setNeedsDisplay(NSRect(x: bounds.minX, y: bounds.minY,
            width: min(bounds.width, textContainerOrigin.x + 10), height: bounds.height))
    }
    override func didChangeText() {
        if usesNoteFormatting, let storage = textStorage { TryNoteMarkup.normalizeQuoteParagraphs(storage) }
        super.didChangeText()
        invalidateNoteQuoteRails()
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        invalidateNoteQuoteRails()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateNoteQuoteRails()
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawNoteQuoteRails(in: dirtyRect)
    }
    var serializedNote: String {
        usesNoteFormatting ? TryNoteMarkup.markdown(attributedString()) : DemandSpellText.markdown(attributedString())
    }
    func renderedNote(_ text: String) -> NSAttributedString {
        usesNoteFormatting ? TryNoteMarkup.attributed(text, font: noteBaseFont) : DemandSpellText.attributed(text, font: noteBaseFont)
    }
    func applyNoteFont(_ font: NSFont) {
        noteBaseFont = font
        if usesNoteFormatting {
            if let storage = textStorage { TryNoteMarkup.style(storage, font: font) }
            typingAttributes[.font] = TryNoteMarkup.styledFont(font, attributes: typingAttributes)
            typingAttributes[.obliqueness] = TryNoteMarkup.obliqueness(typingAttributes)
            typingAttributes[.paragraphStyle] = TryNoteMarkup.paragraph(typingAttributes)
        } else { DBoardEditorFont.apply(font, to: self) }
        invalidateNoteQuoteRails()
    }
    func beginWriting(force: Bool = false) {
        guard force || isEditable || allowsEditingFromInteraction else { return }
        isEditable = true
        beginWritingAction?()
        invalidateNoteQuoteRails()
    }
    override func mouseDown(with event: NSEvent) {
        // A single click selects read-only text; double-clicking an image keeps its preview.
        let startsEditing = !isEditable && allowsReadingToEdit && event.clickCount == 2 && imageAttachment(at: event) == nil
        if startsEditing { beginWriting(force: true) }
        else if event.clickCount != 2 { beginWriting() }
        super.mouseDown(with: event)
        if startsEditing { window?.makeFirstResponder(self) }
    }
    override func paste(_ sender: Any?) {
        guard isEditable || allowsEditingFromInteraction else { return }
        beginWriting()
        if usesNoteFormatting, !pasteImages(from: pasteboard), let source = pasteboard.string(forType: .string) {
            insertText(renderedNote(source), replacementRange: selectedRange())
        } else if !usesNoteFormatting { super.paste(sender) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleNoteShortcut(event) { return true }
        if event.type == .keyDown, event.keyCode == 9,
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let marker = noteInputPrefix(before: insertString, range: range)
        if marker != nil { breakUndoCoalescing() }
        super.insertText(insertString, replacementRange: replacementRange)
        if let marker { convertNoteInputPrefix(marker) }
    }
    override func insertNewline(_ sender: Any?) {
        if !handleNoteNewline() { super.insertNewline(sender) }
    }
    override func deleteBackward(_ sender: Any?) {
        if !handleNoteBackspace() { super.deleteBackward(sender) }
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isEditable || allowsEditingFromInteraction else { return false }
        beginWriting()
        window?.makeFirstResponder(self)
        return super.performDragOperation(sender)
    }
    override func insertImageLinks(_ links: [String]) {
        breakUndoCoalescing()
        super.insertImageLinks(links)
        breakUndoCoalescing()
    }
    override func keyDown(with event: NSEvent) {
        if !isEditable, allowsReadingToEdit, [UInt16(36), 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            beginWriting(force: true)
            window?.makeFirstResponder(self)
            return // Enter starts writing without adding an empty paragraph.
        }
        if handleNoteShortcut(event) { return }
        if event.keyCode == 53 {
            if hasMarkedText() { super.keyDown(with: event); return }
            window?.makeFirstResponder(nil)
            isEditable = false; endWriting?()
            invalidateNoteQuoteRails()
            return
        }
        super.keyDown(with: event)
    }
}
