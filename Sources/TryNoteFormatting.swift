import AppKit

extension TryNoteTextView {
    func handleNoteShortcut(_ event: NSEvent) -> Bool {
        guard usesNoteFormatting, isEditable, !hasMarkedText(), event.type == .keyDown,
              event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
              window?.firstResponder === self else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": applyNoteFormat(.bold); return true
        case "i": applyNoteFormat(.italic); return true
        default: return false
        }
    }

    func applyNoteFormat(_ format: TryNoteFormat) {
        guard usesNoteFormatting, isEditable, !hasMarkedText(), let storage = textStorage else { return }
        switch format {
        case .bold, .italic, .code:
            let key: NSAttributedString.Key = format == .bold ? .tryNoteBold : (format == .italic ? .tryNoteItalic : .tryNoteCode)
            let selection = selectedRange()
            if selection.length == 0 {
                typingAttributes[key] = !(typingAttributes[key] as? Bool ?? false)
                typingAttributes[.font] = TryNoteMarkup.styledFont(noteBaseFont, attributes: typingAttributes)
                typingAttributes[.obliqueness] = TryNoteMarkup.obliqueness(typingAttributes)
            } else {
                var all = true
                storage.enumerateAttribute(key, in: selection) { value, _, _ in if value as? Bool != true { all = false } }
                recordNoteUndo("修改格式")
                storage.addAttribute(key, value: !all, range: selection)
                applyNoteFont(noteBaseFont); didChangeText()
                typingAttributes[key] = !all
                typingAttributes[.font] = TryNoteMarkup.styledFont(noteBaseFont, attributes: typingAttributes)
                typingAttributes[.obliqueness] = TryNoteMarkup.obliqueness(typingAttributes)
            }
        case .bullet, .numbered:
            formatNoteList(numbered: format == .numbered)
        case .heading, .quote, .codeBlock:
            let selection = selectedRange()
            let paragraphRange = noteParagraphRange(selection)
            let key: NSAttributedString.Key = format == .heading ? .tryNoteHeading : (format == .quote ? .tryNoteQuote : .tryNoteCodeBlock)
            let current = paragraphRange.length > 0 ? storage.attribute(key, at: paragraphRange.location, effectiveRange: nil) : typingAttributes[key]
            let remove = current != nil && !(current as? Bool == false)
            recordNoteUndo("修改段落格式")
            for incompatible in [NSAttributedString.Key.tryNoteHeading, .tryNoteQuote, .tryNoteCodeBlock] {
                storage.removeAttribute(incompatible, range: paragraphRange)
                typingAttributes.removeValue(forKey: incompatible)
            }
            if !remove {
                let value: Any = format == .heading ? 2 : true
                storage.addAttribute(key, value: value, range: paragraphRange)
                typingAttributes[key] = value
            }
            applyNoteFont(noteBaseFont); didChangeText()
        }
    }

    private struct NoteState {
        let text: NSAttributedString
        let selection: NSRange
        let typing: [NSAttributedString.Key: Any]
    }
    private var noteState: NoteState {
        NoteState(text: NSAttributedString(attributedString: attributedString()), selection: selectedRange(), typing: typingAttributes)
    }
    private func recordNoteUndo(_ name: String) {
        let state = noteState
        breakUndoCoalescing()
        // AppKit owns the event group. Do not close it while dispatching a keyboard event.
        undoManager?.registerUndo(withTarget: self) { target in target.restoreNoteState(state) }
        undoManager?.setActionName(name)
    }
    private func restoreNoteState(_ state: NoteState) {
        let redo = noteState
        undoManager?.registerUndo(withTarget: self) { target in target.restoreNoteState(redo) }
        textStorage?.setAttributedString(state.text)
        setSelectedRange(state.selection); typingAttributes = state.typing
        didChangeText()
    }

    private func noteParagraphRange(_ selection: NSRange) -> NSRange {
        (string as NSString).lineRange(for: NSRange(location: min(selection.location, string.utf16.count),
                                                  length: min(selection.length, string.utf16.count - min(selection.location, string.utf16.count))))
    }
    private func listPrefix(_ line: String) -> (range: NSRange, marker: String, number: Int?)? {
        guard let expression = try? NSRegularExpression(pattern: #"^([ \t]*)(• |[-*+] |(\d+)[.)] )"#),
              let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: line.utf16.count)) else { return nil }
        let number = match.range(at: 3).location == NSNotFound ? nil : Int((line as NSString).substring(with: match.range(at: 3)))
        return (match.range, (line as NSString).substring(with: match.range), number)
    }
    private func formatNoteList(numbered: Bool, togglesExisting: Bool = true) {
        guard let storage = textStorage else { return }
        let selection = selectedRange()
        let whole = noteParagraphRange(selection)
        let source = string as NSString
        var ranges: [NSRange] = []
        var index = whole.location
        repeat {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            ranges.append(range)
            if range.length == 0 { break }
            index = NSMaxRange(range)
        } while index < NSMaxRange(whole)
        let first = source.substring(with: ranges[0])
        let old = listPrefix(first)
        let remove = togglesExisting && old != nil && (numbered ? old?.number != nil : old?.marker.trimmingCharacters(in: .whitespaces) == "•")
        recordNoteUndo("修改列表")
        var delta = 0
        for (offset, range) in ranges.enumerated().reversed() {
            let line = source.substring(with: range)
            let prefix = listPrefix(line)
            let replace = NSRange(location: range.location, length: prefix?.range.length ?? 0)
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let marker = remove ? "" : indent + (numbered ? "\((togglesExisting ? 1 : (old?.number ?? 1)) + offset). " : "• ")
            storage.replaceCharacters(in: replace, with: NSAttributedString(string: marker, attributes: [.font: noteBaseFont]))
            delta += marker.utf16.count - replace.length
        }
        let newRange = NSRange(location: whole.location, length: max(0, whole.length + delta))
        for key in [NSAttributedString.Key.tryNoteHeading, .tryNoteQuote, .tryNoteCodeBlock] {
            storage.removeAttribute(key, range: newRange); typingAttributes.removeValue(forKey: key)
        }
        applyNoteFont(noteBaseFont)
        if selection.length > 0 { setSelectedRange(newRange) }
        else { setSelectedRange(NSRange(location: min(storage.length, max(whole.location, selection.location + delta)), length: 0)) }
        didChangeText()
    }

    /// Only a marker at the start of an otherwise empty line triggers automatic formatting.
    func noteInputPrefix(before value: Any, range: NSRange) -> String? {
        guard usesNoteFormatting, isEditable, !hasMarkedText(), [" ", "　"].contains(value as? String ?? ""),
              range.length == 0, typingAttributes[.tryNoteCodeBlock] as? Bool != true else { return nil }
        let source = string as NSString
        let paragraph = source.lineRange(for: NSRange(location: min(range.location, source.length), length: 0))
        guard range.location == NSMaxRange(paragraph) || (range.location + 1 == NSMaxRange(paragraph) && source.substring(with: paragraph).hasSuffix("\n")) else { return nil }
        let marker = source.substring(with: NSRange(location: paragraph.location, length: range.location - paragraph.location))
        if ["*", "-", "+", ">", "》", "#", "##", "###"].contains(marker) ||
            marker.range(of: #"^\d+\.$"#, options: .regularExpression) != nil { return marker }
        return nil
    }

    func convertNoteInputPrefix(_ marker: String) {
        if ["*", "-", "+"].contains(marker) { formatNoteList(numbered: false); return }
        if marker.hasSuffix("."), Int(marker.dropLast()) != nil { formatNoteList(numbered: true, togglesExisting: false); return }
        guard let storage = textStorage else { return }
        let range = noteParagraphRange(selectedRange())
        recordNoteUndo("自动段落格式")
        storage.deleteCharacters(in: NSRange(location: range.location, length: marker.utf16.count + 1))
        let quote = marker == ">" || marker == "》"
        let key: NSAttributedString.Key = quote ? .tryNoteQuote : .tryNoteHeading
        let value: Any = quote ? true : marker.count
        setSelectedRange(NSRange(location: range.location, length: 0))
        let paragraph = noteParagraphRange(selectedRange())
        for incompatible in [NSAttributedString.Key.tryNoteHeading, .tryNoteQuote, .tryNoteCodeBlock] {
            storage.removeAttribute(incompatible, range: paragraph)
            typingAttributes.removeValue(forKey: incompatible)
        }
        // Tag an existing empty paragraph's newline too; typing state is only needed at the document end.
        storage.addAttribute(key, value: value, range: paragraph)
        typingAttributes[key] = value
        applyNoteFont(noteBaseFont); didChangeText()
    }

    func handleNoteNewline() -> Bool {
        guard usesNoteFormatting, isEditable, !hasMarkedText(), selectedRange().length == 0 else { return false }
        let selection = selectedRange()
        let range = noteParagraphRange(selection)
        let line = (string as NSString).substring(with: range)
        guard let prefix = listPrefix(line), typingAttributes[.tryNoteCodeBlock] as? Bool != true else {
            if typingAttributes[.tryNoteQuote] as? Bool == true,
               line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                applyNoteFormat(.quote)
                return true
            }
            if typingAttributes[.tryNoteHeading] != nil {
                // Newline belongs to the heading; subsequent typing starts a normal paragraph.
                insertText("\n", replacementRange: selection)
                typingAttributes.removeValue(forKey: .tryNoteHeading)
                typingAttributes.removeValue(forKey: .tryNoteBold)
                typingAttributes[.font] = noteBaseFont
                typingAttributes[.paragraphStyle] = TryNoteMarkup.paragraph(typingAttributes)
                return true
            }
            return false
        }
        if (line as NSString).substring(from: NSMaxRange(prefix.range)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            insertText("", replacementRange: NSRange(location: range.location, length: prefix.range.length))
            typingAttributes[.paragraphStyle] = TryNoteMarkup.paragraph(typingAttributes)
        } else {
            var attributes = typingAttributes
            for key in [NSAttributedString.Key.tryNoteBold, .tryNoteItalic, .tryNoteCode, .tryNoteHeading] { attributes.removeValue(forKey: key) }
            attributes[.font] = noteBaseFont
            attributes[.obliqueness] = 0
            let indent = String(prefix.marker.prefix { $0 == " " || $0 == "\t" })
            let marker = prefix.number.map { "\($0 + 1). " } ?? "• "
            insertText(NSAttributedString(string: "\n" + indent + marker, attributes: attributes), replacementRange: selection)
            typingAttributes = attributes
        }
        return true
    }

    func handleNoteBackspace() -> Bool {
        guard usesNoteFormatting, isEditable, !hasMarkedText(), selectedRange().length == 0 else { return false }
        let selection = selectedRange()
        let range = noteParagraphRange(selection)
        let line = (string as NSString).substring(with: range)
        let quote = range.length > 0 ? textStorage?.attribute(.tryNoteQuote, at: range.location, effectiveRange: nil) as? Bool :
            typingAttributes[.tryNoteQuote] as? Bool
        if quote == true, selection.location == range.location {
            applyNoteFormat(.quote)
            return true
        }
        guard let prefix = listPrefix(line), selection.location == range.location + prefix.range.length else { return false }
        insertText("", replacementRange: NSRange(location: range.location, length: prefix.range.length))
        return true
    }

    /// Derive rails from whole logical paragraphs, using their current laid-out lines.
    /// Inline styles and newline glyphs must not create separate or misplaced rails.
    func noteQuoteRailRects() -> [NSRect] {
        guard usesNoteFormatting, let storage = textStorage, let layout = layoutManager, let container = textContainer else { return [] }
        layout.ensureLayout(for: container)
        let origin = textContainerOrigin
        let source = storage.string as NSString
        var rails: [NSRect] = []
        var lastQuoteEnd: Int?
        func append(_ bounds: NSRect, start: Int, end: Int) {
            guard bounds.height > 0, bounds.minY.isFinite, bounds.height.isFinite else { return }
            let rect = NSRect(x: origin.x + 4, y: origin.y + bounds.minY + 2,
                width: 2, height: max(1, bounds.height - 4))
            if lastQuoteEnd == start, let last = rails.last {
                rails[rails.count - 1] = last.union(rect)
            } else {
                rails.append(rect)
            }
            lastQuoteEnd = end
        }
        var index = 0
        while index < source.length {
            let paragraph = source.lineRange(for: NSRange(location: index, length: 0))
            if storage.attribute(.tryNoteQuote, at: index, effectiveRange: nil) as? Bool == true {
                let contentLength = source.substring(with: paragraph).trimmingCharacters(in: .newlines).utf16.count
                // The newline belongs to this paragraph, but must not extend a nonempty rail into the next one.
                let characters = contentLength > 0 ? NSRange(location: index, length: contentLength) : paragraph
                let glyphs = layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                var bounds: NSRect?
                layout.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                    bounds = bounds.map { $0.union(rect) } ?? rect
                }
                if let bounds { append(bounds, start: index, end: NSMaxRange(paragraph)) }
            } else {
                lastQuoteEnd = nil
            }
            index = NSMaxRange(paragraph)
        }
        // Only an editable, empty trailing paragraph needs a typing-state preview.
        // Stored empty paragraphs are handled above; reading never draws a transient caret format.
        let selection = selectedRange()
        if isEditable, typingAttributes[.tryNoteQuote] as? Bool == true,
           selection.length == 0, selection.location == source.length,
           source.lineRange(for: selection).length == 0 {
            append(layout.extraLineFragmentRect, start: source.length, end: source.length)
        }
        return rails
    }

    func drawNoteQuoteRails(in dirtyRect: NSRect) {
        for rect in noteQuoteRailRects() where rect.intersects(dirtyRect) {
            noteQuoteColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }

}
