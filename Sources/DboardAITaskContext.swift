import Foundation

/// Task identity and feedback entry points are generated only at copy time, never persisted as user input.
enum DboardAITaskContext {
    static func readInstruction(item: DItem, changeID: String? = nil, cacheURL: URL? = nil,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var command = quote(home + "/.local/bin/dboard-ai")
        if let cacheURL { command += " --cache " + quote(cacheURL.path) }
        command += " context " + quote(item.id)
        if let changeID { command += " --change " + quote(changeID) }
        return "请接手 D板需求 " + item.id + "「" + item.displayTitle + "」，通过本机命令工具执行：\n" +
            command + "\n请阅读原咒言、最新进度和追加变更，冲突以后续变更为准；仅继续未完成事项，无事可做则直接反馈，不重复开发或自行扩展。遵循返回的反馈规则；每轮结束前仅记录新进展，先一句话概括，再按需写明细。"
    }

    static func debugInstruction(item: DItem, cacheURL: URL? = nil,
                                 home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var command = quote(home + "/.local/bin/dboard-ai")
        if let cacheURL { command += " --cache " + quote(cacheURL.path) }
        command += " context " + quote(item.id) + " --task debug-page"
        return "请接续 D板需求 " + item.id + "「" + item.displayTitle + "」的调试测试，通过本机命令工具执行：\n" +
            command + "\n按最新原咒言和追加变更核验开发；在 audi 建立或完善可视化调试页，挂到 /test-console。AI先试调能独立验证的部分，最终内外部联调由用户进行。遵循返回规则，每轮结束前回写一句话概括、必要明细及已测／未测／待人工联调事项；无可执行事项则直接反馈。"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension DItemStore {
    enum SnapshotError: LocalizedError {
        case unavailable, missing, ambiguous, unreadableChanges, unreadableVersion, unreadableChats, unreadableExecution, unreadableDebugPagePolicy
        var errorDescription: String? {
            switch self {
            case .unavailable: return "无法读取需求数据，请重试"
            case .missing: return "这张需求已不存在，请刷新首页"
            case .ambiguous: return "需求编号重复，请先检查数据"
            case .unreadableChanges: return "变更记录无法读取，请检查数据后重试"
            case .unreadableVersion: return "上一版本的背景无法读取，请检查数据后重试"
            case .unreadableChats: return "关联群聊无法读取，请检查数据后重试"
            case .unreadableExecution: return "调试进度无法读取，请检查数据后重试"
            case .unreadableDebugPagePolicy: return "调试页设置无法读取，请检查数据后重试"
            }
        }
    }

    /// Read under the same lock as GUI/CLI writers, without falling back to a stale card.
    static func currentItem(id: String, at url: URL? = nil) throws -> DItem {
        guard let result = CacheFile.withLock(at: url, {
            Result<DItem, Error> {
                let cacheURL = url ?? URL(fileURLWithPath: CacheFile.path)
                let content = try String(contentsOf: cacheURL, encoding: .utf8)
                let matches = CacheParser.parse(content: content).items.filter { $0.id == id }
                guard let item = matches.first else { throw SnapshotError.missing }
                guard matches.count == 1 else { throw SnapshotError.ambiguous }
                guard item.changeReadError == nil else { throw SnapshotError.unreadableChanges }
                guard item.versionReadError == nil else { throw SnapshotError.unreadableVersion }
                guard item.chatReadError == nil else { throw SnapshotError.unreadableChats }
                guard item.executionReadError == nil else { throw SnapshotError.unreadableExecution }
                guard item.debugPageReadError == nil else { throw SnapshotError.unreadableDebugPagePolicy }
                return item
            }
        }) else { throw SnapshotError.unavailable }
        return try result.get()
    }
}
