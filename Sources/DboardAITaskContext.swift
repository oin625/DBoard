import Foundation

/// Task identity and feedback entry points are generated only at copy time, never persisted as user input.
enum DboardAITaskContext {
    static func readInstruction(item: DItem, changeID: String? = nil, cacheURL: URL? = nil,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var command = quote(home + "/.local/bin/dboard-ai")
        if let cacheURL { command += " --cache " + quote(cacheURL.path) }
        command += " context " + quote(item.id)
        if let changeID { command += " --change " + quote(changeID) }
        let instruction = (item.isIncident ? "请接手 D板线上排查 " : "请接手 D板需求 ") + item.id + "「" + item.displayTitle + "」，通过本机命令工具执行：\n" +
            command + "\n请阅读原咒言、最新进度和追加变更，冲突以后续变更为准；仅继续未完成事项，无事可做则直接反馈，不重复开发或自行扩展。每次检查返回的压缩判断并遵循反馈规则；每轮结束前，有新进展时更新摘要和修改记录，先一句话概括，再按需写明细。"
        guard changeID == nil, item.status != .completed, AudiLocalTarget.canLaunch(item) else { return instruction }
        return instruction + "\n\n下方如有补充，作为本轮联调排查任务：结合最新现状定位原因，确认后修复并验证，保留已有实现和调试页；记录结论、验证结果及待人工联调事项。留空则按现状判断，不自行找问题或重复开发。\n可直接在最下面粘贴报错、请求和响应；环境、时间、traceId 有就带上。\n\n## 本次联调问题\n"
    }

    static func reviewInstruction(item: DItem, cacheURL: URL? = nil,
                                  home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var command = quote(home + "/.local/bin/dboard-ai")
        if let cacheURL { command += " --cache " + quote(cacheURL.path) }
        command += " context " + quote(item.id) + " --task code-review"
        return "请独立审查 D板任务 " + item.id + "「" + item.displayTitle + "」的整体代码，通过本机命令工具执行：\n" +
            command + "\n按返回的 CR 规则，结合原咒言、全部追加变更和实际开发分支，审查完整实现及相关调用链。先审查，不改代码；问题给出位置、触发条件和影响，结论先一句话概括，再按需明细记回 D板。"
    }

    static func debugInstruction(item: DItem, cacheURL: URL? = nil,
                                 home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var command = quote(home + "/.local/bin/dboard-ai")
        if let cacheURL { command += " --cache " + quote(cacheURL.path) }
        command += " context " + quote(item.id) + " --task debug-page"
        return "请接续 D板需求 " + item.id + "「" + item.displayTitle + "」的调试测试，通过本机命令工具执行：\n" +
            command + "\n核验开发后，在 audi 建/完善调试页挂到 /test-console；复用 DebugConsole 与 /cdd-reservation，首屏必填≤2、可选折叠、只读一键、副作用人工确认、结论先行、JSON 折叠，底部列已测/未测/待联调。不满足不标 debug-page-ready。AI试调验证项，最终联调由用户进行；记进展与已测/未测/待联调。"
    }


    static func planInstruction(item: DItem, cacheURL: URL? = nil,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        var command = quote(home + "/.local/bin/dboard-ai")
        if let cacheURL { command += " --cache " + quote(cacheURL.path) }
        command += " context " + quote(item.id) + " --task technical-plan"
        return "请准备／更新 D板需求 " + item.id + "「" + item.displayTitle + "」的技术方案，通过本机命令工具执行：\n" +
            command + "\n结合原咒言、全部追加变更、用户纠正和实际代码，按返回规则维护清晰完整的技术方案；核实源开发分支，预发／发布分支另记。用 plan save 保存到 D板，暂不上传或提交交付物。"
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
                let items = cacheURL.lastPathComponent == "dboard-archive-cache.md"
                    ? try DemandArchive.parse(content).map(\.item)
                    : CacheParser.parse(content: content).items
                let matches = items.filter { $0.id == id }
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
        return DemandCodeReviews.checked(try result.get())
    }
}
