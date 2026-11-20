import AppKit

extension NSAttributedString.Key {
    static let tryNoteBold = NSAttributedString.Key("DBoard.note.bold")
    static let tryNoteItalic = NSAttributedString.Key("DBoard.note.italic")
    static let tryNoteCode = NSAttributedString.Key("DBoard.note.inlineCode")
    static let tryNoteHeading = NSAttributedString.Key("DBoard.note.heading")
    static let tryNoteQuote = NSAttributedString.Key("DBoard.note.quote")
    static let tryNoteCodeBlock = NSAttributedString.Key("DBoard.note.codeBlock")
    static let tryNoteCodeLanguage = NSAttributedString.Key("DBoard.note.codeLanguage")
}

/// Notes display native formatting and persist portable Markdown for the AI context.
enum TryNoteMarkup {
    static func plainLabel(_ text: String) -> String {
        let value = TryStudyDocument.heading(text)?.title ?? text
        if let rendered = try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(rendered.characters)
        }
        return value
    }

    static func paragraph(_ attributes: [NSAttributedString.Key: Any]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 6; style.paragraphSpacing = 5; style.lineBreakMode = .byCharWrapping
        if attributes[.tryNoteHeading] != nil { style.paragraphSpacingBefore = 10; style.paragraphSpacing = 8 }
        if attributes[.tryNoteQuote] as? Bool == true { style.headIndent = 16; style.firstLineHeadIndent = 16 }
        return style
    }

    static func obliqueness(_ attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        attributes[.tryNoteItalic] as? Bool == true ? 0.18 : 0
    }

    static func styledFont(_ base: NSFont, attributes: [NSAttributedString.Key: Any]) -> NSFont {
        let level = attributes[.tryNoteHeading] as? Int ?? 0
        var font = (attributes[.tryNoteCode] as? Bool == true || attributes[.tryNoteCodeBlock] as? Bool == true)
            ? NSFont.monospacedSystemFont(ofSize: max(12, base.pointSize - 1), weight: .regular)
            : NSFontManager.shared.convert(base, toSize: level == 0 ? base.pointSize : base.pointSize + CGFloat(max(1, 4 - level)) * 2)
        if attributes[.tryNoteBold] as? Bool == true || level > 0 {
            font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        }
        // Many Chinese fonts have no italic face; skew the glyphs without changing the chosen family.
        return font
    }

    /// A quote is a paragraph format. Pasting or joining lines can otherwise leave
    /// stale quote attributes on only part of a now-plain paragraph.
    static func normalizeQuoteParagraphs(_ text: NSMutableAttributedString) {
        let source = text.string as NSString
        var index = 0
        while index < source.length {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            let attributes = text.attributes(at: index, effectiveRange: nil)
            let quoted = attributes[.tryNoteQuote] as? Bool == true
            var mixed = false
            text.enumerateAttribute(.tryNoteQuote, in: range) { value, _, _ in
                if (value as? Bool == true) != quoted { mixed = true }
            }
            if mixed {
                if quoted { text.addAttribute(.tryNoteQuote, value: true, range: range) }
                else { text.removeAttribute(.tryNoteQuote, range: range) }
                let style = paragraph(attributes).mutableCopy() as! NSMutableParagraphStyle
                if source.substring(with: range).range(of: #"^\s*(?:• |\d+\. )"#, options: .regularExpression) != nil {
                    style.headIndent = quoted ? 38 : 22
                    style.firstLineHeadIndent = quoted ? 16 : 0
                }
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
            index = NSMaxRange(range)
        }
    }

    static func style(_ text: NSMutableAttributedString, font: NSFont) {
        normalizeQuoteParagraphs(text)
        let whole = NSRange(location: 0, length: text.length)
        var runs: [(NSRange, [NSAttributedString.Key: Any])] = []
        text.enumerateAttributes(in: whole) { attributes, range, _ in runs.append((range, attributes)) }
        for (range, attributes) in runs {
            text.addAttribute(.font, value: styledFont(font, attributes: attributes), range: range)
            text.addAttribute(.obliqueness, value: obliqueness(attributes), range: range)
            text.addAttribute(.paragraphStyle, value: paragraph(attributes), range: range)
        }
        let source = text.string as NSString
        var index = 0
        while index < source.length {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            let line = source.substring(with: range)
            if line.range(of: #"^\s*(?:• |\d+\. )"#, options: .regularExpression) != nil,
               let existing = text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
               let style = existing.mutableCopy() as? NSMutableParagraphStyle {
                let quoted = text.attribute(.tryNoteQuote, at: index, effectiveRange: nil) as? Bool == true
                style.headIndent = quoted ? 38 : 22; style.firstLineHeadIndent = quoted ? 16 : 0
                text.addAttribute(.paragraphStyle, value: style, range: range)
            }
            index = NSMaxRange(range)
        }
    }

    static func attributed(_ markdown: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        let lines = markdown.components(separatedBy: "\n")
        var codeLanguage: String?
        var inCode = false
        for (index, raw) in lines.enumerated() {
            if raw.hasPrefix("```") {
                if inCode { inCode = false; codeLanguage = nil }
                else { inCode = true; codeLanguage = String(raw.dropFirst(3)) }
                continue
            }
            var line = raw
            var attributes: [NSAttributedString.Key: Any] = [:]
            if inCode {
                attributes[.tryNoteCodeBlock] = true
                attributes[.tryNoteCodeLanguage] = codeLanguage ?? ""
            } else if let heading = TryStudyDocument.heading(line) {
                line = heading.title; attributes[.tryNoteHeading] = heading.level
            } else if line.hasPrefix("> ") || line.hasPrefix("》 ") {
                line = String(line.dropFirst(2)); attributes[.tryNoteQuote] = true
            } else if let prefix = line.range(of: #"^(\s*)[-*+] "#, options: .regularExpression) {
                let indent = String(line[prefix]).prefix { $0.isWhitespace }
                line.replaceSubrange(prefix, with: String(indent) + "• ")
            }
            let rendered = inCode ? DemandSpellText.attributed(line, font: font) : inline(line, font: font)
            let row = NSMutableAttributedString(attributedString: rendered)
            if index < lines.count - 1 { row.append(NSAttributedString(string: "\n")) }
            row.addAttributes(attributes, range: NSRange(location: 0, length: row.length))
            result.append(row)
        }
        // A closing code fence consumed the final logical line; its preceding line break is structural.
        if markdown.hasSuffix("```"), result.string.hasSuffix("\n") {
            result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
        }
        style(result, font: font)
        return result
    }

    private static func inline(_ source: String, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: DemandSpellText.attributed(source, font: font))
        let patterns: [(String, [NSAttributedString.Key: Any])] = [
            (#"`([^`\n]+?)`"#, [.tryNoteCode: true]),
            (#"\*\*\*([^\n]+?)\*\*\*"#, [.tryNoteBold: true, .tryNoteItalic: true]),
            (#"\*\*([^\n]+?)\*\*"#, [.tryNoteBold: true]),
            (#"__([^\n]+?)__"#, [.tryNoteBold: true]),
            (#"(?<!\*)\*([^*\n]+?)\*(?!\*)"#, [.tryNoteItalic: true]),
            (#"(?<!\w)_([^_\n]+?)_(?!\w)"#, [.tryNoteItalic: true])
        ]
        for (pattern, attributes) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = expression.matches(in: result.string, range: NSRange(location: 0, length: result.length))
            for match in matches.reversed() {
                if attributes[.tryNoteCode] == nil,
                   result.attribute(.tryNoteCode, at: match.range.location, effectiveRange: nil) as? Bool == true { continue }
                let value = result.attributedSubstring(from: match.range(at: 1))
                let replacement = NSMutableAttributedString(attributedString: value)
                replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
                result.replaceCharacters(in: match.range, with: replacement)
            }
        }
        if let expression = try? NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^\s)]+)\)"#) {
            for match in expression.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
                if result.attribute(.tryNoteCode, at: match.range.location, effectiveRange: nil) as? Bool == true { continue }
                let label = NSMutableAttributedString(attributedString: result.attributedSubstring(from: match.range(at: 1)))
                let url = (result.string as NSString).substring(with: match.range(at: 2))
                label.addAttribute(.link, value: url, range: NSRange(location: 0, length: label.length))
                result.replaceCharacters(in: match.range, with: label)
            }
        }
        return result
    }

    static func markdown(_ text: NSAttributedString) -> String {
        let source = text.string as NSString
        var output = ""
        var index = 0
        var inCode = false
        while index < source.length {
            let range = source.lineRange(for: NSRange(location: index, length: 0))
            var content = range
            let newline = source.substring(with: range).hasSuffix("\n")
            if newline { content.length -= 1 }
            let attributes = text.attributes(at: index, effectiveRange: nil)
            let code = attributes[.tryNoteCodeBlock] as? Bool == true
            if code && !inCode {
                output += "```" + (attributes[.tryNoteCodeLanguage] as? String ?? "") + "\n"
            } else if !code && inCode { output += "```\n" }
            inCode = code
            if code {
                output += DemandSpellText.markdown(text.attributedSubstring(from: content))
            } else {
                if let heading = attributes[.tryNoteHeading] as? Int { output += String(repeating: "#", count: heading) + " " }
                if attributes[.tryNoteQuote] as? Bool == true { output += "> " }
                let raw = source.substring(with: content)
                if let prefix = raw.range(of: #"^(\s*)(?:• |\d+\. )"#, options: .regularExpression) {
                    let marker = String(raw[prefix])
                    output += marker.replacingOccurrences(of: "• ", with: "- ")
                    let length = marker.utf16.count
                    output += encodeInline(text.attributedSubstring(from: NSRange(location: content.location + length, length: content.length - length)))
                } else {
                    output += encodeInline(text.attributedSubstring(from: content))
                }
            }
            if newline { output += "\n" }
            index = NSMaxRange(range)
        }
        if inCode { output += (output.hasSuffix("\n") ? "" : "\n") + "```" }
        return output
    }

    private static func encodeInline(_ text: NSAttributedString) -> String {
        // Merge style-equivalent runs so a font/colour refresh cannot split **words** into separate spans.
        struct Span {
            var text: String
            var bold: Bool
            var italic: Bool
            var code: Bool
            var link: String?
        }
        var spans: [Span] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            if let attachment = attrs[.attachment] as? DemandImageAttachment {
                spans.append(Span(text: attachment.reference.markdown, bold: false, italic: false, code: false, link: nil))
                return
            }
            let traits = (attrs[.font] as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            let heading = attrs[.tryNoteHeading] != nil
            let span = Span(text: (text.string as NSString).substring(with: range),
                bold: attrs[.tryNoteBold] as? Bool == true || (!heading && traits.contains(.boldFontMask)),
                italic: attrs[.tryNoteItalic] as? Bool == true || traits.contains(.italicFontMask),
                code: attrs[.tryNoteCode] as? Bool == true,
                link: (attrs[.link] as? URL)?.absoluteString ?? attrs[.link] as? String)
            if let last = spans.last, last.bold == span.bold, last.italic == span.italic,
               last.code == span.code, last.link == span.link, !last.text.hasPrefix("![") {
                spans[spans.count - 1].text += span.text
            } else { spans.append(span) }
        }
        return spans.map { span in
            var value = span.text
            if span.code { value = "`" + value + "`" }
            if span.bold { value = "**" + value + "**" }
            if span.italic { value = "*" + value + "*" }
            if let link = span.link { value = "[" + value + "](" + link + ")" }
            return value
        }.joined()
    }
}

enum TryNoteFormat {
    case bold, italic, heading, bullet, numbered, code, codeBlock, quote
}
