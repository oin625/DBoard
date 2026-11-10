import Foundation

/// Compare a Dingtalk Markdown round trip without discarding technical punctuation.
/// Export may escape prose punctuation and resize table rulers; code remains literal.
enum DemandDeliveryDocumentVerification {
    static func matches(actual: String, expected: String) -> Bool {
        let expected = canonical(expected)
        return !expected.isEmpty && canonical(actual) == expected
    }

    private static func canonical(_ markdown: String) -> String {
        let punctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")
        var result = ""
        var fence: String?
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmed
            if let marker = fence {
                if line.hasPrefix(marker), line.dropFirst(marker.count).allSatisfy(\.isWhitespace) {
                    result += marker + "\n"
                    fence = nil
                } else {
                    result += line + "\n"
                }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let character = line.first!
                let marker = String(line.prefix(while: { $0 == character }))
                fence = marker
                result += "\n" + line + "\n"
                continue
            }
            // A Markdown table ruler has no document content.
            if line.range(of: #"^\|(?:\s*:?-+:?\s*\|)+$"#, options: .regularExpression) != nil { continue }

            let characters = Array(line)
            var index = 0
            var inlineDelimiter = 0
            while index < characters.count {
                let character = characters[index]
                if character == "`" {
                    var end = index + 1
                    while end < characters.count && characters[end] == "`" { end += 1 }
                    let count = end - index
                    if inlineDelimiter == 0 { inlineDelimiter = count }
                    else if inlineDelimiter == count { inlineDelimiter = 0 }
                    result += String(repeating: "`", count: count)
                    index = end
                    continue
                }
                if inlineDelimiter == 0 && character == "\\" && index + 1 < characters.count,
                   punctuation.contains(characters[index + 1]) {
                    result.append(characters[index + 1])
                    index += 2
                    continue
                }
                if inlineDelimiter != 0 || !character.isWhitespace { result.append(character) }
                index += 1
            }
        }
        return result
    }
}
