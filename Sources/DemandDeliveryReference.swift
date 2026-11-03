import Foundation

/// Prefer the technical document explicitly referenced in progress, from the declared
/// delivery branch. The repository may currently be checked out for another demand.
enum DemandDeliveryReference {
    static func read(item: DItem, repositories: [DemandVersion.Repository],
                     projects: [DemandDeliveryProject]) -> String {
        let expression = try? NSRegularExpression(pattern: #"(?:docs?/)[A-Za-z0-9_./-]+\.md\b"#)
        var paths: [String] = []
        for record in item.milestones.reversed() {
            let text = record.fullContent
            let range = NSRange(text.startIndex..., in: text)
            for match in expression?.matches(in: text, range: range) ?? [] {
                if let range = Range(match.range, in: text) {
                    let path = String(text[range])
                    if !path.split(separator: "/").contains(".."), !paths.contains(path) { paths.append(path) }
                }
            }
        }
        var results: [String] = []
        let declaredPaths = DemandRepositoryEntries.parse(item.project).filter {
            $0.hasPrefix("/") || $0.hasPrefix("~")
        }
        let candidates = Array(Set(repositories.map(\.path) + declaredPaths)).sorted()
        for path in candidates {
            guard let name = try? DemandDeliveryPlan.gitRepositoryName(path),
                  let project = projects.first(where: { $0.name == name }) else { continue }
            let root = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).resolvingSymlinksInPath()
            let current = git(root.path, ["branch", "--show-current"])
            for relative in paths {
                var content: String?
                if current?.trimmed == project.branch {
                    let file = root.appendingPathComponent(relative).resolvingSymlinksInPath()
                    if file.path.hasPrefix(root.path + "/") {
                        content = try? String(contentsOf: file, encoding: .utf8)
                    }
                } else {
                    content = git(root.path, ["show", "--no-ext-diff", "--no-textconv", project.branch + ":" + relative])
                }
                guard let content, let excerpt = excerpt(content) else { continue }
                results += ["### " + name + " · " + relative, "", excerpt, ""]
                break // One focused reference per engineering project; no repository-wide scan.
            }
        }
        return results.joined(separator: "\n")
    }

    private static func git(_ root: String, _ arguments: [String]) -> String? {
        let result = ProcessRunner.run("/usr/bin/git", arguments: ["--no-pager", "-C", root] + arguments,
            environment: ProcessInfo.processInfo.environment, timeout: 5)
        return result.succeeded ? String(decoding: result.stdout, as: UTF8.self) : nil
    }

    /// Select complete implementation sections. Examples and historical verification
    /// are excluded; the demand's latest progress supplies current verification/status.
    static func excerpt(_ markdown: String) -> String? {
        let selected = ["调用", "接口", "实现", "流程", "参数", "返回", "失败", "异常", "兼容", "约束"]
        let excluded = ["示例", "历史", "记录", "排查", "需要", "待确认", "验证", "测试", "发布", "上线"]
        var output: [String] = []
        var active = false
        var fenced = false
        var block: [String] = []
        var skipExample = false
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmed
            if line.hasPrefix("```") {
                if !active || skipExample { fenced.toggle(); continue }
                if !fenced { block = [raw]; fenced = true }
                else {
                    block.append(raw); fenced = false
                    // A small signature is useful; full JSON/code examples belong to the source.
                    if block.count <= 6 && !block[0].lowercased().contains("json") {
                        output += block + [""]
                    }
                    block = []
                }
                continue
            }
            if fenced { if active && !skipExample { block.append(raw) }; continue }
            if line.hasPrefix("#") {
                if line.hasPrefix("# ") { active = false; continue }
                active = selected.contains { line.contains($0) } && !excluded.contains { line.contains($0) }
                skipExample = false
                if active {
                    output += ["#### " + line.drop(while: { $0 == "#" || $0 == " " }), ""]
                }
                continue
            }
            if line.contains("示例") || line.contains("example") { skipExample = true; continue }
            guard active else { continue }
            if skipExample {
                // Examples end after their fenced block. Subsequent contract prose is still useful.
                if line.isEmpty { continue }
                skipExample = false
            }
            if line.hasPrefix("![") || line.hasPrefix("<!--") { continue }
            output.append(raw)
        }
        var spaced: [String] = []
        var inCode = false
        for line in output {
            if line.trimmed.hasPrefix("```") { inCode.toggle() }
            if !inCode && line.trimmed.isEmpty && spaced.last?.trimmed.isEmpty == true { continue }
            // Separate multi-sentence prose into short paragraphs, while preserving tables
            // and signatures exactly. Whitespace never changes the technical contract.
            if !inCode && !line.trimmed.hasPrefix("|") && !line.trimmed.hasPrefix("#") && !line.trimmed.hasPrefix("```") {
                let parts = DemandDeliveryDocument.sentences(line, splitClauses: false)
                if parts.count > 1 {
                    for part in parts { spaced += ["- " + part, ""] }
                    continue
                }
            }
            spaced.append(line)
        }
        let text = spaced.joined(separator: "\n").trimmed
        // A large, general API manual isn't a concise delivery reference. Fall back to
        // the demand's implementation records rather than cutting the manual mid-contract.
        guard !text.isEmpty, text.count <= 2400 else { return nil }
        return text
    }
}
