import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

final class DemandSpellInputController: ObservableObject {
    weak var editor: DemandSpellTextView?
    @Published var error: String?
    func chooseImages() { editor?.chooseImages() }
    func paste() { editor?.paste(nil) }
    func endEditing() {
        guard let editor else { return }
        if let window = editor.window, window.firstResponder === editor {
            window.makeFirstResponder(nil)
        }
        if editor.hasMarkedText() { editor.unmarkText() }
        editor.didChangeText()
    }
}

struct DemandSpellField: View {
    @Binding var text: String
    let title: String
    let placeholder: String
    var autofocus = false
    var imageStore: DemandImageStore = .shared
    var height: CGFloat = 200
    var showPasteButton = false
    var onEditingEnded: () -> Void
    @StateObject private var controller: DemandSpellInputController

    init(text: Binding<String>, title: String, placeholder: String, autofocus: Bool = false,
         imageStore: DemandImageStore = .shared, height: CGFloat = 200, showPasteButton: Bool = false,
         onEditingEnded: @escaping () -> Void = {}, controller: DemandSpellInputController? = nil) {
        _text = text
        self.title = title; self.placeholder = placeholder; self.autofocus = autofocus
        self.imageStore = imageStore; self.height = height; self.showPasteButton = showPasteButton
        self.onEditingEnded = onEditingEnded
        _controller = StateObject(wrappedValue: controller ?? DemandSpellInputController())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DemandSpellInput(text: $text, title: title, controller: controller,
                             autofocus: autofocus, imageStore: imageStore, onEditingEnded: onEditingEnded)
                .frame(height: height)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).dboardFont(size: 13).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack(spacing: 8) {
                if showPasteButton {
                    Button("粘贴", systemImage: "doc.on.clipboard") { controller.paste() }
                        .demandButtonStyle(.borderless).dboardFont(size: 12)
                }
                Button("添加图片", systemImage: "photo.badge.plus") { controller.chooseImages() }
                    .demandButtonStyle(.borderless).dboardFont(size: 12)
                Text("也可粘贴或拖入图片，双击查看原图")
                    .dboardFont(size: 11).foregroundStyle(.secondary)
            }
            if let error = controller.error {
                Text(error).dboardFont(size: 12).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DemandSpellInput: NSViewRepresentable {
    @Binding var text: String
    let title: String
    let controller: DemandSpellInputController
    var autofocus = false
    var imageStore: DemandImageStore = .shared
    var onEditingEnded: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dboardFontOverride) private var fontOverride
    @ObservedObject private var fonts = FontManager.shared

    private var editorFont: NSFont { (fontOverride ?? fonts.current).appKitFont(13) }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onEditingEnded: onEditingEnded, font: editorFont) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptContextInput.PromptContextScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = DemandSpellTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        editor.imageStore = imageStore
        editor.onError = { [weak controller] in controller?.error = $0 }
        editor.isRichText = true
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = editorFont
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 6)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        editor.defaultParagraphStyle = paragraph
        editor.typingAttributes = [.font: editorFont, .paragraphStyle: paragraph]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.lineBreakMode = .byCharWrapping
        editor.setAccessibilityLabel(title)
        editor.textStorage?.setAttributedString(DemandSpellText.attributed(text, font: editorFont))
        editor.delegate = context.coordinator
        editor.registerForDraggedTypes([.fileURL, .png, .tiff])
        scroll.documentView = editor
        controller.editor = editor
        applyColors(to: editor)
        if autofocus {
            DispatchQueue.main.async { [weak editor] in
                if let editor, editor.window?.firstResponder is NSTextView == false {
                    editor.window?.makeFirstResponder(editor)
                }
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onEditingEnded = onEditingEnded
        context.coordinator.font = editorFont
        guard let editor = scroll.documentView as? DemandSpellTextView else { return }
        controller.editor = editor
        // Marked text belongs to the input method until it commits, including its attributes and selection.
        guard !editor.hasMarkedText() else { return }
        if DemandSpellText.markdown(editor.attributedString()) != text {
            let selection = editor.selectedRange()
            editor.textStorage?.setAttributedString(DemandSpellText.attributed(text, font: editorFont))
            editor.setSelectedRange(NSRange(location: min(selection.location, editor.string.utf16.count), length: 0))
        }
        applyColors(to: editor)
    }

    private func applyColors(to editor: NSTextView) {
        DBoardEditorFont.apply(editorFont, to: editor)
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        var color = NSColor.labelColor
        appearance?.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.deviceRGB) ?? .labelColor
        }
        editor.textColor = color
        editor.insertionPointColor = color
        editor.typingAttributes[.foregroundColor] = color
        editor.textStorage?.addAttribute(.foregroundColor, value: color,
                                        range: NSRange(location: 0, length: editor.attributedString().length))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onEditingEnded: () -> Void
        var font: NSFont
        init(text: Binding<String>, onEditingEnded: @escaping () -> Void, font: NSFont) {
            self.text = text; self.onEditingEnded = onEditingEnded; self.font = font
        }
        private func publish(_ editor: NSTextView) {
            guard !editor.hasMarkedText() else { return }
            // A preference changed during IME composition is applied when text commits.
            DBoardEditorFont.apply(font, to: editor)
            let value = DemandSpellText.markdown(editor.attributedString())
            if value != text.wrappedValue { text.wrappedValue = value }
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            publish(editor)
        }
        func textDidEndEditing(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            publish(editor)
            onEditingEnded()
        }
    }
}

final class DemandSpellTextView: NSTextView {
    var imageStore: DemandImageStore = .shared
    var onError: ((String?) -> Void)?
    var pasteboard: NSPasteboard = .general

    private static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.heic.identifier),
        .init(UTType.gif.identifier), .init(UTType.webP.identifier)
    ]

    // importsGraphics is false to keep all images in DBoard's managed store.
    // Advertise the formats explicitly so AppKit's paste validation still permits them.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types = super.readablePasteboardTypes
        for type in Self.imagePasteboardTypes + [.fileURL] where !types.contains(type) { types.append(type) }
        return types
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let pasteActions = [#selector(paste(_:)), #selector(pasteAsPlainText(_:)), #selector(pasteAsRichText(_:))]
        if let action = item.action, pasteActions.contains(action), Self.hasImages(pasteboard) {
            return isEditable
        }
        return super.validateUserInterfaceItem(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .keyDown, modifiers == .command, event.keyCode == 9,
           isEditable, window?.firstResponder === self {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加图片"
        if let window {
            panel.beginSheetModal(for: window) { [weak self] result in
                guard result == .OK else { return }
                self?.insertImages(from: panel.urls)
            }
        } else if panel.runModal() == .OK { insertImages(from: panel.urls) }
    }

    func insertImages(from urls: [URL]) {
        var links: [String] = []
        var failures: [String] = []
        for url in urls {
            do { links.append(try imageStore.importFile(url)) }
            catch { failures.append(url.lastPathComponent + "：" + error.localizedDescription) }
        }
        if !links.isEmpty { insertImageLinks(links) }
        onError?(failures.isEmpty ? nil : failures.joined(separator: "\n"))
    }

    func insertImageLinks(_ links: [String]) {
        let selection = selectedRange()
        let prefix = selection.location > 0 && (string as NSString).substring(with: NSRange(location: selection.location - 1, length: 1)) != "\n" ? "\n" : ""
        let font = typingAttributes[.font] as? NSFont ?? self.font ?? .systemFont(ofSize: 13)
        let content = DemandSpellText.attributed(prefix + links.joined(separator: "\n") + "\n", font: font)
        insertText(content, replacementRange: selection)
        scrollRangeToVisible(selectedRange())
    }

    /// Prefer image files from Finder, then screenshot bitmap data, then ordinary plain text.
    @discardableResult
    func pasteImages(from pasteboard: NSPasteboard) -> Bool {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty, urls.allSatisfy({ Self.isImageURL($0) }) {
            insertImages(from: urls)
            return true
        }
        var failure: Error?
        for type in Self.imagePasteboardTypes {
            if let data = pasteboard.data(forType: type) {
                do {
                    let link = try imageStore.importData(data)
                    insertImageLinks([link])
                    onError?(nil)
                    return true
                } catch { failure = error }
            }
        }
        if let failure {
            onError?(failure.localizedDescription)
            return true
        }
        return false
    }

    override func paste(_ sender: Any?) {
        if pasteImages(from: pasteboard) { return }
        if let text = pasteboard.string(forType: .string) {
            insertText(text, replacementRange: selectedRange())
        } else { super.pasteAsPlainText(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.hasImages(sender.draggingPasteboard) { return .copy }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.hasImages(sender.draggingPasteboard) { return .copy }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.hasImages(sender.draggingPasteboard) { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.hasImages(sender.draggingPasteboard) {
            let point = convert(sender.draggingLocation, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
            return pasteImages(from: sender.draggingPasteboard)
        }
        return super.performDragOperation(sender)
    }

    private static func hasImages(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.availableType(from: imagePasteboardTypes) != nil { return true }
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return !urls.isEmpty && urls.allSatisfy { isImageURL($0) }
    }

    private static func isImageURL(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 {
            let point = convert(event.locationInWindow, from: nil)
            let glyph = layoutManager.glyphIndex(for: NSPoint(x: point.x - textContainerOrigin.x,
                                                              y: point.y - textContainerOrigin.y), in: textContainer)
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            if index < attributedString().length,
               let attachment = textStorage?.attribute(.attachment, at: index, effectiveRange: nil) as? DemandImageAttachment {
                NSWorkspace.shared.open(URL(fileURLWithPath: attachment.reference.path))
                return
            }
        }
        super.mouseDown(with: event)
    }
}

/// Formal change history uses the same image references, without exposing file paths in the UI.
struct DemandSpellContentView: View {
    let text: String

    private struct Piece: Identifiable {
        let id: Int
        let text: String?
        let image: DemandImageReference?
    }

    private var pieces: [Piece] {
        let source = text as NSString
        var result: [Piece] = []
        var offset = 0
        for image in DemandImageMarkdown.references(in: text) {
            if image.range.location > offset {
                result.append(Piece(id: result.count, text: source.substring(with: NSRange(location: offset, length: image.range.location - offset)), image: nil))
            }
            result.append(Piece(id: result.count, text: nil, image: image))
            offset = NSMaxRange(image.range)
        }
        if offset < source.length { result.append(Piece(id: result.count, text: source.substring(from: offset), image: nil)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pieces) { piece in
                if let text = piece.text, !text.trimmingCharacters(in: .newlines).isEmpty {
                    Text(text.trimmingCharacters(in: .newlines)).dboardFont(size: 13).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let image = piece.image {
                    if let thumbnail = DemandImageStore.thumbnail(path: image.path) {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: image.path)) } label: {
                            Image(nsImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 160)
                        }
                        .demandButtonStyle(.plain)
                        .accessibilityLabel("查看图片：" + image.label)
                    } else {
                        Label("图片无法读取：" + image.label, systemImage: "photo.badge.exclamationmark")
                            .dboardFont(size: 12).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
