import Foundation
import AppKit
import CryptoKit

struct DemandImageReference {
    let label: String
    let path: String
    let markdown: String
    let range: NSRange
}

enum DemandImageMarkdown {
    private static let pattern = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(<(/[^>\n]+)>\)"#)

    static func references(in text: String) -> [DemandImageReference] {
        let source = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
            DemandImageReference(label: source.substring(with: $0.range(at: 1)),
                path: source.substring(with: $0.range(at: 2)), markdown: source.substring(with: $0.range), range: $0.range)
        }
    }

    static func link(label: String, path: String) -> String {
        let label = label.components(separatedBy: CharacterSet(charactersIn: "[]\r\n")).joined(separator: " ")
        return "![" + label + "](<" + path + ">)"
    }
}

/// Keep immutable copies, so moving the original or discarding another draft cannot break a demand.
final class DemandImageStore {
    static let shared = DemandImageStore()
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/dboard-images", isDirectory: true)
    let directory: URL

    enum ImageError: LocalizedError {
        case unreadable, saveFailed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "这份文件无法作为图片读取，请选择 PNG、JPEG 等图片。"
            case .saveFailed: return "图片保存失败，文字已保留，请重试。"
            }
        }
    }

    init(directory: URL = DemandImageStore.defaultURL) { self.directory = directory }

    func importFile(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try importData(Data(contentsOf: url), label: url.lastPathComponent)
    }

    func importData(_ data: Data, label: String = "粘贴的图片") throws -> String {
        // Normalize to PNG for consistent native display and AI image tools (including HEIC input).
        let bitmap = NSBitmapImageRep(data: data)
            ?? NSImage(data: data)?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }
        guard let bitmap, bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
              let png = bitmap.representation(using: .png, properties: [:]) else { throw ImageError.unreadable }
        let hash = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(hash + ".png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) {
                try png.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch { throw ImageError.saveFailed }
        return DemandImageMarkdown.link(label: label, path: file.path)
    }

    static func thumbnail(path: String, maximum: NSSize = NSSize(width: 300, height: 160)) -> NSImage? {
        guard let original = NSImage(contentsOfFile: path), original.size.width > 0, original.size.height > 0 else { return nil }
        let ratio = min(1, maximum.width / original.size.width, maximum.height / original.size.height)
        let size = NSSize(width: max(1, original.size.width * ratio), height: max(1, original.size.height * ratio))
        let image = NSImage(size: size)
        image.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }
}

/// The editor renders pictures inline; its binding remains lossless Markdown for drafts and the CLI.
final class DemandImageAttachment: NSTextAttachment {
    let reference: DemandImageReference

    init(reference: DemandImageReference) {
        self.reference = reference
        super.init(data: nil, ofType: nil)
        image = DemandImageStore.thumbnail(path: reference.path)
            ?? NSImage(systemSymbolName: "photo.badge.exclamationmark", accessibilityDescription: "图片无法读取")
        let size = image?.size ?? NSSize(width: 24, height: 24)
        bounds = NSRect(origin: .zero, size: size)
    }

    required init?(coder: NSCoder) { nil }
}

enum DemandSpellText {
    static func attributed(_ markdown: String, font: NSFont = .systemFont(ofSize: 13)) -> NSAttributedString {
        let source = markdown as NSString
        let result = NSMutableAttributedString(string: "")
        var offset = 0
        for reference in DemandImageMarkdown.references(in: markdown) {
            result.append(NSAttributedString(string: source.substring(with: NSRange(location: offset, length: reference.range.location - offset))))
            result.append(NSAttributedString(attachment: DemandImageAttachment(reference: reference)))
            offset = NSMaxRange(reference.range)
        }
        result.append(NSAttributedString(string: source.substring(from: offset)))
        result.addAttributes([.font: font, .foregroundColor: NSColor.labelColor],
                             range: NSRange(location: 0, length: result.length))
        return result
    }

    static func markdown(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let attachment = value as? DemandImageAttachment { result += attachment.reference.markdown }
            else { result += (text.string as NSString).substring(with: range) }
        }
        return result
    }
}
