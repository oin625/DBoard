import Foundation

/// Keeps the original scene intact until an explicit edit is saved.
final class ExcalidrawDocument {
    enum DocumentError: LocalizedError {
        case invalidScene, unsupportedVersion, changedOnDisk, invalidSnapshot, missingDestination
        var errorDescription: String? {
            switch self {
            case .invalidScene: return "这不是有效的 Excalidraw 绘图文件。"
            case .unsupportedVersion: return "此绘图使用了暂不支持的文件版本，请先用新版 Excalidraw 检查。"
            case .changedOnDisk: return "文件已被其他程序修改，当前编辑仍保留在窗口中。请先处理需要保留的修改，再通过工具栏“重新加载”读取磁盘文件。"
            case .invalidSnapshot: return "编辑器没有返回有效的绘图，原文件未被修改。"
            case .missingDestination: return "请先选择 .excalidraw 文件的保存位置。"
            }
        }
    }
    private(set) var url: URL
    var isUntitled: Bool { diskData == nil }
    var displayName: String { isUntitled ? "未命名绘图" : url.deletingPathExtension().lastPathComponent }
    private(set) var original: [String: Any]
    private var diskData: Data?
    private var restoredElements: [String: [String: Any]] = [:]
    private var restoredState: [String: Any] = [:]

    static func handles(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == "excalidraw"
    }
    init(url: URL) throws {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        let data = try Data(contentsOf: self.url)
        diskData = data
        original = try Self.parse(data)
    }
    init() {
        url = URL(string: "dboard-untitled://drawing/" + UUID().uuidString)!
        diskData = nil
        original = ["type": "excalidraw", "version": 2, "source": "DBoard",
                    "elements": [], "appState": ["viewBackgroundColor": "#ffffff"], "files": [:]]
    }
    static func parse(_ data: Data) throws -> [String: Any] {
        guard let scene = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              scene["type"] as? String == "excalidraw",
              let version = scene["version"] as? Int,
              let elements = scene["elements"] as? [[String: Any]],
              elements.allSatisfy({ $0["id"] is String && $0["type"] is String }) else {
            throw DocumentError.invalidScene
        }
        guard (1...2).contains(version) else { throw DocumentError.unsupportedVersion }
        guard scene["appState"] == nil || scene["appState"] is [String: Any],
              scene["files"] == nil || scene["files"] is [String: Any],
              Set(elements.compactMap { $0["id"] as? String }).count == elements.count else {
            throw DocumentError.invalidScene
        }
        return scene
    }
    func recordRestoredSnapshot(_ json: String) throws {
        guard let data = json.data(using: .utf8) else { throw DocumentError.invalidSnapshot }
        let scene = try Self.parse(data)
        restoredElements = Self.index(scene["elements"] as? [[String: Any]] ?? [])
        restoredState = scene["appState"] as? [String: Any] ?? [:]
    }
    @discardableResult
    func save(snapshot json: String, to destination: URL? = nil, expectedDestinationData: Data? = nil) throws -> Bool {
        guard let data = json.data(using: .utf8) else { throw DocumentError.invalidSnapshot }
        let snapshot = try Self.parse(data)
        let originals = Self.index(original["elements"] as? [[String: Any]] ?? [])
        var merged = original
        merged["elements"] = (snapshot["elements"] as? [[String: Any]] ?? []).map { element -> [String: Any] in
            let id = element["id"] as! String
            if let restored = restoredElements[id], Self.equal(element, restored), let old = originals[id] {
                return old
            }
            // Retain future/custom fields even when the editor modifies an existing element.
            return (originals[id] ?? [:]).merging(element) { _, new in new }
        }
        var state = original["appState"] as? [String: Any] ?? [:]
        let newState = snapshot["appState"] as? [String: Any] ?? [:]
        // Viewport and current tool choices do not rewrite the source just from viewing.
        for key in ["viewBackgroundColor", "gridSize"] {
            if !Self.equalValue(newState[key], restoredState[key]) { state[key] = newState[key] }
        }
        merged["appState"] = state
        var files = original["files"] as? [String: Any] ?? [:]
        files.merge(snapshot["files"] as? [String: Any] ?? [:]) { _, new in new }
        merged["files"] = files
        let target: URL
        if isUntitled {
            guard let destination, Self.handles(destination) else { throw DocumentError.missingDestination }
            target = destination.standardizedFileURL.resolvingSymlinksInPath()
            let actual = FileManager.default.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
            guard actual == expectedDestinationData else { throw DocumentError.changedOnDisk }
        } else {
            target = url
            guard try Data(contentsOf: target) == diskData else { throw DocumentError.changedOnDisk }
            if Self.equal(merged, original) { return false }
        }
        let next = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try next.write(to: target, options: .atomic)
        url = target
        diskData = next
        original = merged
        try recordRestoredSnapshot(json)
        return true
    }
    private static func index(_ elements: [[String: Any]]) -> [String: [String: Any]] {
        Dictionary(elements.map { ($0["id"] as! String, $0) }, uniquingKeysWith: { _, last in last })
    }
    private static func equal(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        NSDictionary(dictionary: lhs).isEqual(to: rhs)
    }
    private static func equalValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        NSDictionary(dictionary: ["value": lhs ?? NSNull()]).isEqual(to: ["value": rhs ?? NSNull()])
    }
}
