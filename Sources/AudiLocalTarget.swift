import Foundation

struct AudiLocalTarget: Equatable, Sendable {
    let repository: URL
    let branch: String
    let page: String
    var nextExecutable: URL { repository.appendingPathComponent("node_modules/next/dist/bin/next") }

    static func load(id: String, at cacheURL: URL = URL(fileURLWithPath: CacheFile.path)) throws -> Self {
        guard let result = CacheFile.withLock(at: cacheURL, {
            Result<(DItem, [String]), Error> {
                let text = try String(contentsOf: cacheURL, encoding: .utf8)
                let matches = CacheParser.parse(content: text).items.filter { $0.id == id }
                guard matches.count == 1, let item = matches.first,
                      item.executionReadError == nil, item.debugPageReadError == nil,
                      item.versionReadError == nil, item.changeReadError == nil,
                      let range = DItemStore.blockRange(text.components(separatedBy: "\n"), id: id) else {
                    throw AudiLocalError.message("无法读取这条需求的最新调试记录，请刷新后重试。")
                }
                return (item, Array(text.components(separatedBy: "\n")[range]))
            }
        }) else { throw AudiLocalError.message("需求数据暂时无法读取，请重试。") }
        let (item, block) = try result.get()
        guard canLaunch(item) else {
            throw AudiLocalError.message("请先核验并同步本需求的调试页，再启动本地服务。")
        }
        let hints = try DemandVersion.repositoryHints(block, item: item)
        let prefix = "<!-- dboard-ai-feedback:v1:"
        var names: [String: String] = [:]
        if let record = block.first(where: { $0.hasPrefix(prefix) }),
           let data = Data(base64Encoded: String(record.dropFirst(prefix.count).dropLast(4))),
           let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let repositories = object["repositories"] as? [[String: String]] {
            for repo in repositories { if let path = repo["path"], let name = repo["name"] { names[path] = name } }
        }
        let known = hints.filter {
            names[$0.path] == "audi" || URL(fileURLWithPath: $0.path).lastPathComponent == "audi" ||
                (try? DemandDeliveryPlan.gitRepositoryName($0.path)) == "audi"
        }
        guard known.count <= 1 else {
            throw AudiLocalError.message("记录了多个 audi 开发目录，请先核对实际目录和分支。")
        }
        let declared = DemandRepositoryEntries.parse(item.project).filter { raw in
            let path = NSString(string: raw).expandingTildeInPath
            return path.hasPrefix("/") && (URL(fileURLWithPath: path).lastPathComponent == "audi" ||
                (try? DemandDeliveryPlan.gitRepositoryName(path)) == "audi")
        }
        guard declared.count <= 1 else { throw AudiLocalError.message("项目中有多个 audi 目录，请先核对。") }
        let path = known.first?.path ?? declared.first ?? AudiLocalLaunch.repositoryURL.path
        let repository = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        var expected = known.first?.branch
        let branchText = (item.branch ?? "").trimmed
        if branchText.contains(":") || branchText.contains("：") {
            let entries = branchText.components(separatedBy: CharacterSet(charactersIn: "；;\n\r"))
            let branches = entries.compactMap { entry -> String? in
                let parts = entry.replacingOccurrences(of: "：", with: ":").split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let name = String(parts[0]).trimmed
                guard name == "audi" || name == repository.path ||
                      (name.hasPrefix("/") && (try? DemandDeliveryPlan.gitRepositoryName(name)) == "audi") else { return nil }
                return String(parts[1]).trimmed
            }
            guard branches.count <= 1 else { throw AudiLocalError.message("audi 分支记录重复，请先核对。") }
            if let branch = branches.first { expected = branch }
        } else if DemandRepositoryEntries.parse(item.project).count == 1,
                  DemandDeliveryProject.name(item.project) == "audi", !branchText.isEmpty, branchText != "待定" {
            expected = branchText
        }
        guard let page = item.execution?.debugPage else { throw AudiLocalError.message("没有记录调试页路径。") }
        return try validate(repository: repository, expectedBranch: expected, page: page)
    }

    static func canLaunch(_ item: DItem) -> Bool {
        !item.debugPageNotNeeded && item.debugPageReadError == nil && item.executionReadError == nil &&
        !item.executionScopeNeedsReview && item.execution?.debugPage != nil &&
        [.debugPageReady, .testingPassed].contains(item.execution?.stage)
    }

    static func validate(repository: URL, expectedBranch: String?, page: String) throws -> Self {
        let files = FileManager.default
        guard DemandExecution.validPage(page) else { throw AudiLocalError.message("调试页路径无效。") }
        guard files.fileExists(atPath: repository.appendingPathComponent("package.json").path) else {
            throw AudiLocalError.message("找不到已记录的 audi 目录：" + repository.path)
        }
        guard (try? DemandDeliveryPlan.gitRepositoryName(repository.path)) == "audi" else {
            throw AudiLocalError.message("已记录目录不是 audi 仓库，请核对工程。")
        }
        guard let expectedBranch, DemandDeliveryProject.validBranch(expectedBranch) else {
            throw AudiLocalError.message("请先在需求中记录 audi 的开发分支。")
        }
        let git = ProcessRunner.run("/usr/bin/git",
            arguments: ["-C", repository.path, "symbolic-ref", "--short", "HEAD"], timeout: 5)
        guard git.succeeded else { throw AudiLocalError.message("无法读取 audi 当前分支，请检查仓库。") }
        let actual = String(decoding: git.stdout, as: UTF8.self).trimmed
        guard actual == expectedBranch else {
            throw AudiLocalError.message("audi 当前分支为 " + actual + "，需求记录为 " + expectedBranch + "；请切到正确目录或分支后重试。")
        }
        let route = String(page.dropFirst())
        let pageExists = ["app", "src/app"].contains { app in
            ["jsx", "tsx", "js", "ts"].contains { ext in
                files.fileExists(atPath: repository.appendingPathComponent(app + "/" + route + "/page." + ext).path)
            }
        }
        guard pageExists else { throw AudiLocalError.message("当前 audi 目录中找不到调试页面：" + page) }
        let target = Self(repository: repository, branch: actual, page: page)
        guard files.fileExists(atPath: target.nextExecutable.path) else {
            throw AudiLocalError.message("audi 依赖未安装，请先在该目录运行 npm install。")
        }
        return target
    }
}

enum AudiLocalError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
