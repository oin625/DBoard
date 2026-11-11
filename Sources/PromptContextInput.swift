import SwiftUI
import AppKit

/// Measures the wrapped text, including URLs with no spaces, instead of using a single-line field.
struct PromptContextInput: NSViewRepresentable {
    @Binding var text: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dboardFontOverride) private var fontOverride
    @ObservedObject private var fonts = FontManager.shared
    let title: String

    private var editorFont: NSFont { (fontOverride ?? fonts.current).appKitFont(13) }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, font: editorFont) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = PromptContextScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = editorFont
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 8, height: 4)
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
        if let container = editor.textContainer {
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byCharWrapping
        }
        editor.setAccessibilityLabel(title)
        editor.string = text
        applyColors(to: editor)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.font = editorFont
        if let editor = scroll.documentView as? NSTextView, !editor.hasMarkedText() {
            if editor.string != text { editor.string = text }
            applyColors(to: editor)
        }
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
                                        range: NSRange(location: 0, length: (editor.string as NSString).length))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let editor = scroll.documentView as? NSTextView else { return nil }
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite { width = max(80, proposed) }
        else { width = 300 }
        // SwiftUI also probes very narrow widths. Measure separately so a discarded probe cannot
        // change the live text container and leave pasted text wrapped at the wrong width.
        let storage = NSTextStorage(attributedString: editor.attributedString())
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width - editor.textContainerInset.width * 2),
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byCharWrapping
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = ceil(textHeight + editor.textContainerInset.height * 2)
        return CGSize(width: width, height: min(160, max(24, height)))
    }

    /// Sheet animations can leave the document sized for an earlier, wider viewport.
    /// Always wrap at the final visible width rather than relying on document autoresizing.
    final class PromptContextScrollView: NSScrollView {
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            synchronizeTextWidth()
        }

        override func layout() {
            super.layout()
            synchronizeTextWidth()
        }

        private func synchronizeTextWidth() {
            guard let editor = documentView as? NSTextView,
                  let container = editor.textContainer else { return }
            let width = contentView.bounds.width
            guard width > 0 else { return }
            if abs(editor.frame.width - width) > 0.1 {
                editor.setFrameSize(NSSize(width: width, height: editor.frame.height))
            }
            let textWidth = max(1, width - editor.textContainerInset.width * 2)
            if abs(container.containerSize.width - textWidth) > 0.1 {
                container.containerSize = NSSize(width: textWidth, height: container.containerSize.height)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var font: NSFont
        init(text: Binding<String>, font: NSFont) { self.text = text; self.font = font }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, !editor.hasMarkedText() else { return }
            DBoardEditorFont.apply(font, to: editor)
            text.wrappedValue = editor.string
        }
    }
}
