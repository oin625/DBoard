import SwiftUI
import AppKit

// MARK: - 数据模型

/// MCP Server: 来自 ~/.qoder/mcp.json(自配) 与 Qoder SharedClientCache(内置注入)
struct McpServerItem: Identifiable {
    var id: String { name }
    var name: String
    var endpoint: String = ""        // command 或 url
    var origin: String = "内置"      // 内置 / 自配
    var toolCount: Int = 0
    var tools: [String] = []
    var alive: Bool? = nil           // 仅 HTTP 端点探测; nil = 不适用/未探测
    var sources: [String] = []        // Codex / Zed / Qoder CN / Qoder 遗留
    var enabled: Bool = true
}

/// Hook: 来自 Codex / Qoder CN / Claude 遗留配置
struct HookItem: Identifiable {
    let id = UUID()
    var event: String                // SessionStart / PreToolUse / ...
    var matcher: String
    var command: String
    var scriptPath: String           // 从 command 里抽出的脚本路径
    var scriptExists: Bool
    var source: String               // Luban插件 / 反馈调查 / R2C安全 / LoongSuite监控 / 自定义
}

/// Subagent: 自建的 .agent.md 或 Qoder 内置子代理
struct AgentItem: Identifiable {
    var id: String { origin + "::" + name }
    var name: String
    var desc: String
    var tools: String = ""
    var origin: String        // 自建 / 内置
    var path: String = ""
}

/// 每次扫描实时取样的运行健康度；只读本机配置/进程，不触发 AI 调用。
struct RuntimeHealthItem: Identifiable {
    enum Level { case good, warning, bad, neutral }
    var id: String { title }
    var title: String
    var detail: String
    var level: Level
}

/// 可审计上下文条目：项目规则或运行时的明文 Memory。
struct MemoryEntry: Identifiable {
    let id = UUID()
    var title: String
    var path: String
    var category: String
    var source: String = ""
}

struct MemoryGroup: Identifiable {
    var id: String { name }
    var name: String          // 全局 / 项目名
    var entries: [MemoryEntry]
}

// MARK: - ViewModel

final class AgentEnvViewModel: ObservableObject {
    @Published var mcps: [McpServerItem] = []
    @Published var hooks: [HookItem] = []
    @Published var loading = false
    @Published var agents: [AgentItem] = []
    @Published var memGroups: [MemoryGroup] = []
    @Published var runtimeHealth: [RuntimeHealthItem] = []
    var memTotal: Int { memGroups.reduce(0) { $0 + $1.entries.count } }

    /// hooks 按事件分组, 保持固定的生命周期顺序
    static let eventOrder = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                             "PostToolUseFailure", "Stop", "SubagentStart", "SubagentStop", "SessionEnd"]

    var hooksByEvent: [(String, [HookItem])] {
        let g = Dictionary(grouping: hooks, by: { $0.event })
        return g.keys.sorted {
            (Self.eventOrder.firstIndex(of: $0) ?? 99) < (Self.eventOrder.firstIndex(of: $1) ?? 99)
        }.map { ($0, g[$0] ?? []) }
    }

    var brokenHooks: Int { hooks.filter { !$0.scriptExists }.count }

    func scan() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let m = Self.scanMcps()
            let h = Self.scanHooks()
            let a = Self.scanAgents()
            let g = Self.scanMemories()
            let health = Self.scanRuntimeHealth(hooks: h)
            DispatchQueue.main.async {
                self.mcps = m; self.hooks = h
                self.agents = a; self.memGroups = g
                self.runtimeHealth = health
                self.loading = false
                self.probeAlive()
            }
        }
    }

    // MARK: Runtime health

    private static func scanRuntimeHealth(hooks: [HookItem]) -> [RuntimeHealthItem] {
        let home = NSHomeDirectory()
        let fm = FileManager.default
        let cli = home + "/.local/bin/qoderclicn"
        var result: [RuntimeHealthItem] = []

        if fm.isExecutableFile(atPath: cli) {
            result.append(RuntimeHealthItem(title: "Qoder CN CLI", detail: "命令可执行", level: .good))
        } else {
            result.append(RuntimeHealthItem(title: "Qoder CN CLI", detail: "未找到或不可执行：\(cli)", level: .bad))
        }

        // status 是本地 CLI 的只读状态查询；失败时只报未知，不把网络瞬断误判成未登录。
        if fm.isExecutableFile(atPath: cli) {
            let p = Process()
            let out = Pipe()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["status", "-o", "json"]
            p.standardOutput = out
            p.standardError = Pipe()
            if (try? p.run()) != nil {
                p.waitUntilExit()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                if let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   info["logged_in"] as? Bool == true {
                    let user = info["username"] as? String ?? "团队账号"
                    result.append(RuntimeHealthItem(title: "团队登录", detail: "已登录：\(user) · BYOK 受组织策略控制", level: .good))
                } else {
                    result.append(RuntimeHealthItem(title: "团队登录", detail: "状态未知；在终端执行 qoderclicn status 查看", level: .warning))
                }
            } else {
                result.append(RuntimeHealthItem(title: "团队登录", detail: "无法读取 CLI 状态", level: .warning))
            }
        }

        let zedPath = home + "/.config/zed/settings.json"
        let zedConfigured = (try? Data(contentsOf: URL(fileURLWithPath: zedPath)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["agent_servers"] as? [String: Any] }?["Qoder CN CLI"] != nil
        result.append(RuntimeHealthItem(title: "Zed ACP", detail: zedConfigured ? "已配置 Qoder CN CLI 外部 Agent" : "未发现 Qoder CN CLI 配置", level: zedConfigured ? .good : .warning))

        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "qoderclicn --acp"]
        pgrep.standardOutput = Pipe()
        if (try? pgrep.run()) != nil {
            pgrep.waitUntilExit()
            result.append(RuntimeHealthItem(title: "Zed ACP 进程", detail: pgrep.terminationStatus == 0 ? "运行中" : "未运行（启动 Zed 对话后会出现）", level: pgrep.terminationStatus == 0 ? .good : .neutral))
        }

        let broken = hooks.filter { !$0.scriptExists }.count
        result.append(RuntimeHealthItem(title: "公司 Hooks", detail: broken == 0 ? "\(hooks.count) 条脚本均可访问" : "\(broken) 条脚本失效 / 共 \(hooks.count) 条", level: broken == 0 ? .good : .warning))
        return result
    }

    /// 物理删除自建 agent 文件（用户明确要求直接删, 不做隔离区）。
    /// 仅允许删 origin==自建 且路径在 agents 目录下的文件, 内置项无文件不可删。
    func deleteAgent(_ a: AgentItem) {
        guard a.origin == "自建", !a.path.isEmpty,
              a.path.contains("/agents/") else { return }
        do {
            try FileManager.default.removeItem(atPath: a.path)
            agents.removeAll { $0.id == a.id }
        } catch {
            // 删除失败保持原样, 下次刷新还能看到
        }
    }

    // MARK: Agents 扫描

    private static func scanAgents() -> [AgentItem] {
        var out: [AgentItem] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Qoder ACP 配置保存的是内部 key；看板只展示人能读懂的名称。
        // 新 key 未覆盖时仍保留原值，避免因版本升级而误报模型。
        func displayModel(_ key: String) -> String {
            let names = [
                "gm51model": "GLM-5.2",
                "qmodel_38max": "Qwen3.8-Max",
                "q36fmodel": "Qwen3.6-Flash",
                "qmodel_latest": "Qwen3.7-Max",
                "qmodel": "Qwen3.7-Plus",
                "dmodel": "DeepSeek-V4-Pro",
                "dfmodel": "DeepSeek-V4-Flash",
                "kmodel": "Kimi-K2.7-Code"
            ]
            return names[key] ?? key
        }

        // 工作入口与运行时：从真实配置生成，不再硬编码 Qoder 内置子代理。
        if let d = fm.contents(atPath: home + "/.config/zed/settings.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            var models: [String] = []
            if let providers = j["language_models"] as? [String: Any] {
                func collectModels(_ value: Any) {
                    if let dict = value as? [String: Any] {
                        if let list = dict["available_models"] as? [[String: Any]] {
                            models += list.compactMap { ($0["display_name"] as? String) ?? ($0["name"] as? String) }
                        }
                        for child in dict.values { collectModels(child) }
                    }
                }
                collectModels(providers)
            }
            out.append(AgentItem(name: "Zed", desc: "代码与 Git 工作入口",
                                 tools: models.isEmpty ? "未发现自配模型" : models.joined(separator: ", "),
                                 origin: "工作入口", path: home + "/.config/zed/settings.json"))
            if let servers = j["agent_servers"] as? [String: Any] {
                for (name, value) in servers.sorted(by: { $0.key < $1.key }) {
                    guard let cfg = value as? [String: Any] else { continue }
                    let options = cfg["default_config_options"] as? [String: Any]
                    let rawModel = options?["model"] as? String ?? "自动"
                    let model = displayModel(rawModel)
                    let command = cfg["command"] as? String ?? "Zed Registry"
                    let stale = command.hasSuffix("/qodercli") || rawModel.lowercased() == "ultimate"
                    out.append(AgentItem(name: name,
                        desc: stale ? "⚠️ 仍指向国际版 Qoder CLI / 旧模型，需要迁移到 qoderclicn" : "由 Zed 调用的 Agent Runtime",
                        tools: "模型: \(model) · \(command)", origin: stale ? "Zed 遗留" : "Zed Runtime",
                        path: home + "/.config/zed/settings.json"))
                }
            }
        }

        if let text = try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8),
           let line = text.components(separatedBy: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("model =") }),
           let eq = line.firstIndex(of: "=") {
            let model = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            out.append(AgentItem(name: "Codex Desktop", desc: "复杂日常任务、插件与跨应用执行",
                                 tools: "默认模型: \(model)", origin: "工作入口",
                                 path: home + "/.codex/config.toml"))
        }
        out.append(AgentItem(name: "Qoder CN CLI", desc: "DBoard 的低成本后台 AI 引擎（团队版）",
                             tools: "后台: Qwen3.6-Flash · 主动对话: Qwen3.8-Max",
                             origin: "DBoard Runtime", path: home + "/.local/bin/qoderclicn"))

        // 旧 Agent 文件只作迁移对照。
        for dir in [home + "/.qoder/agents", home + "/.claude/agents"] {
            guard let fs = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for f in fs.sorted() where f.hasSuffix(".md") {
                let p = dir + "/" + f
                let txt = (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
                func line(after key: String) -> String {
                    guard let r = txt.range(of: key) else { return "" }
                    return String(txt[r.upperBound...].prefix(while: { $0 != "\n" }))
                        .trimmingCharacters(in: .whitespaces)
                }
                out.append(AgentItem(
                    name: f.replacingOccurrences(of: ".agent.md", with: "")
                          .replacingOccurrences(of: ".md", with: ""),
                    desc: line(after: "description:"),
                    tools: line(after: "tools:"),
                    origin: "Claude/Qoder 遗留", path: p))
            }
        }
        return out
    }

    // MARK: Memory 扫描

    /// 把“可读、可审计”的上下文放在同一视图：项目规则优先，其次是 Qoder CN Memory；
    /// Codex 内部 SQLite 不直接展开，以免把私有会话中间产物误当成可维护知识。
    private static func scanMemories() -> [MemoryGroup] {
        let fm = FileManager.default
        var groups: [String: [MemoryEntry]] = [:]
        let home = NSHomeDirectory()

        func collectMemory(_ dir: String, into name: String, source: String) {
            guard let cats = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for c in cats where !c.hasPrefix(".") {
                let cd = dir + "/" + c
                guard let files = try? fm.contentsOfDirectory(atPath: cd) else { continue }
                for f in files where f.hasSuffix(".md") {
                    groups[name, default: []].append(MemoryEntry(
                        title: String(f.dropLast(3)).replacingOccurrences(of: "_", with: " "),
                        path: cd + "/" + f, category: c, source: source))
                }
            }
        }

        func collectRuntimeMemory(root: String, label: String) {
            guard let ids = try? fm.contentsOfDirectory(atPath: root) else { return }
            for mid in ids where !mid.hasPrefix(".") {
                let base = root + "/" + mid
                collectMemory(base + "/global", into: label + " · 全局", source: label)
                if let projs = try? fm.contentsOfDirectory(atPath: base + "/projects") {
                    let homeSlug = home.dropFirst()
                    .replacingOccurrences(of: "/", with: "-") + "-"
                    for p in projs where !p.hasPrefix(".") {
                        let disp = p.hasPrefix(homeSlug) ? String(p.dropFirst(homeSlug.count)) : p
                        collectMemory(base + "/projects/" + p, into: label + " · " + disp, source: label)
                    }
                }
            }
        }

        // 项目规则是 Codex/Zed 都能直接读取的“权威上下文”。
        let codeRoot = home + "/work/code"
        if let projects = try? fm.contentsOfDirectory(atPath: codeRoot) {
            for project in projects where !project.hasPrefix(".") {
                let base = codeRoot + "/" + project
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: base, isDirectory: &isDir), isDir.boolValue else { continue }
                for file in ["AGENTS.md", "CLAUDE.md"] where fm.fileExists(atPath: base + "/" + file) {
                    groups["项目规则", default: []].append(MemoryEntry(
                        title: project + " · " + file, path: base + "/" + file,
                        category: file == "AGENTS.md" ? "agent_rules" : "legacy_rules",
                        source: file == "AGENTS.md" ? "Codex/Zed" : "Claude 遗留"))
                }
            }
        }
        for (name, path) in [("工作区", codeRoot + "/AGENTS.md"), ("知识库", home + "/Documents/one/AGENTS.md")]
            where fm.fileExists(atPath: path) {
            groups["项目规则", default: []].append(MemoryEntry(title: name + " · AGENTS.md", path: path,
                category: "agent_rules", source: "Codex/Zed"))
        }

        collectRuntimeMemory(root: home + "/.qoder-cn/memories", label: "Qoder CN")
        collectRuntimeMemory(root: home + "/.qoder/memories", label: "Qoder 遗留")
        return groups.map { MemoryGroup(name: $0.key, entries: $0.value.sorted { $0.category < $1.category }) }
            .sorted { a, b in
                let (ra, rb) = (Self.sectionRank(a.name), Self.sectionRank(b.name))
                return ra != rb ? ra < rb : a.entries.count > b.entries.count
            }
    }

    /// 分区次序: 全局 > 代码项目 > 文档项目 > 临时会话
    static func sectionRank(_ name: String) -> Int {
        if name == "项目规则" { return 0 }
        if name.contains("全局") { return 1 }
        if name.hasPrefix("work-code-") { return 1 }
        if name.hasPrefix("Documents-one-") { return 2 }
        return 3
    }

    static func sectionName(_ rank: Int) -> String {
        ["📌 项目规则（权威上下文）", "🌐 全局上下文", "💼 项目上下文", "📦 运行时与历史上下文"][rank]
    }

    // MARK: MCP 扫描

    private static func scanMcps() -> [McpServerItem] {
        var map: [String: McpServerItem] = [:]
        let fm = FileManager.default
        let home = NSHomeDirectory()

        func merge(_ incoming: McpServerItem) {
            if var old = map[incoming.name] {
                for source in incoming.sources where !old.sources.contains(source) { old.sources.append(source) }
                if old.endpoint.isEmpty { old.endpoint = incoming.endpoint }
                if incoming.toolCount > old.toolCount {
                    old.toolCount = incoming.toolCount; old.tools = incoming.tools
                }
                old.enabled = old.enabled || incoming.enabled
                map[incoming.name] = old
            } else {
                map[incoming.name] = incoming
            }
        }

        // 1) Codex TOML。只解析顶层 [mcp_servers.NAME]，忽略其 .env 子表。
        let codexConfig = home + "/.codex/config.toml"
        if let text = try? String(contentsOfFile: codexConfig, encoding: .utf8) {
            var current: McpServerItem?
            func flush() { if let item = current { merge(item) }; current = nil }
            for raw in text.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") {
                    flush()
                    if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                        let name = String(line.dropFirst(13).dropLast())
                        if !name.contains(".") {
                            current = McpServerItem(name: name, origin: "自配", sources: ["Codex"])
                        }
                    }
                    continue
                }
                guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if key == "command" || key == "url" { current?.endpoint = value }
                if key == "enabled" { current?.enabled = value.lowercased() != "false" }
            }
            flush()
        }

        // 2) Zed context_servers / mcp_servers（当前为空也保持兼容）。
        if let d = fm.contents(atPath: home + "/.config/zed/settings.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for key in ["context_servers", "mcp_servers"] {
                guard let servers = j[key] as? [String: Any] else { continue }
                for (name, value) in servers {
                    guard let cfg = value as? [String: Any] else { continue }
                    let endpoint = (cfg["url"] as? String) ?? (cfg["command"] as? String) ?? ""
                    merge(McpServerItem(name: name, endpoint: endpoint, origin: "自配",
                                        sources: ["Zed"], enabled: (cfg["enabled"] as? Bool) ?? true))
                }
            }
        }

        // 3) Qoder CN 本地 MCP；企业策略文件只控制准入，不伪装成 Server。
        let qoderCNMcp = home + "/Library/Application Support/QoderCN/SharedClientCache/extension/local/mcp.json"
        if let d = fm.contents(atPath: qoderCNMcp),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let servers = j["mcpServers"] as? [String: Any] {
            for (name, value) in servers {
                guard let cfg = value as? [String: Any] else { continue }
                let endpoint = (cfg["url"] as? String) ?? (cfg["command"] as? String) ?? ""
                merge(McpServerItem(name: name, endpoint: endpoint, origin: "自配",
                                    sources: ["Qoder CN"], enabled: (cfg["disabled"] as? Bool) != true))
            }
        }

        // 4) 旧 Qoder 缓存仅作迁移对照。
        //    多个项目会重复出现同名 server, 取工具数最全的一份
        let cacheRoot = home + "/Library/Application Support/Qoder/SharedClientCache/projects"
        if let projects = try? fm.contentsOfDirectory(atPath: cacheRoot) {
            for proj in projects {
                let mcpsDir = cacheRoot + "/" + proj + "/mcps"
                guard let servers = try? fm.contentsOfDirectory(atPath: mcpsDir) else { continue }
                for sv in servers where !sv.hasPrefix(".") {
                    let toolsDir = mcpsDir + "/" + sv + "/tools"
                    let tools = ((try? fm.contentsOfDirectory(atPath: toolsDir)) ?? [])
                        .filter { $0.hasSuffix(".json") }
                        .map { String($0.dropLast(5)) }
                        .sorted()
                    var it = McpServerItem(name: sv, origin: "历史", sources: ["Qoder 遗留"])
                    if tools.count >= it.toolCount {
                        it.toolCount = tools.count
                        it.tools = tools
                    }
                    // 端点信息尽量从 SERVER_METADATA.json 里补
                    if it.endpoint.isEmpty {
                        let meta = mcpsDir + "/" + sv + "/SERVER_METADATA.json"
                        if let d = fm.contents(atPath: meta),
                           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                            it.endpoint = (j["url"] as? String)
                                ?? (j["command"] as? String)
                                ?? (j["type"] as? String) ?? ""
                        }
                    }
                    merge(it)
                }
            }
        }

        // 2) 用户自配: ~/.qoder/mcp.json —— 覆盖 origin 标记, 补端点
        let cfgPath = home + "/.qoder/mcp.json"
        if let d = fm.contents(atPath: cfgPath),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let servers = (j["mcpServers"] as? [String: Any]) ?? j
            for (k, v) in servers {
                guard let cfg = v as? [String: Any] else { continue }
                var it = McpServerItem(name: k, origin: "历史", sources: ["Qoder 遗留"])
                let ep = (cfg["url"] as? String) ?? (cfg["command"] as? String) ?? ""
                if !ep.isEmpty { it.endpoint = ep }
                merge(it)
            }
        }
        return map.values.sorted { $0.name < $1.name }
    }

    /// 对 http 端点做一次轻量存活探测(1 秒超时)。command 型无法探测, 保持 nil。
    private func probeAlive() {
        for (idx, it) in mcps.enumerated() where it.endpoint.hasPrefix("http") {
            guard let url = URL(string: it.endpoint) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 1.0)
            req.httpMethod = "HEAD"
            URLSession.shared.dataTask(with: req) { [weak self] _, resp, err in
                DispatchQueue.main.async {
                    guard let self, idx < self.mcps.count, self.mcps[idx].name == it.name else { return }
                    // 只要端口有响应(哪怕 4xx/5xx)就算活着; 连接被拒/超时才算挂
                    self.mcps[idx].alive = (resp != nil)
                }
            }.resume()
        }
    }

    // MARK: Hooks 扫描

    private static func scanHooks() -> [HookItem] {
        var out: [HookItem] = []
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // 当前运行时优先；Claude 仅作迁移对照。
        let settingsFiles: [(String, String)] = [
            ("/.codex/hooks.json", "Codex"),
            ("/.qoder-cn/settings.json", "Qoder CN"),
            ("/.qoder-cn/settings.local.json", "Qoder CN"),
            ("/.claude/settings.json", "Claude 遗留"),
            ("/.claude/settings.local.json", "Claude 遗留")
        ]
        for (file, source) in settingsFiles {
            guard let d = fm.contents(atPath: home + file),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let hooks = j["hooks"] as? [String: Any] else { continue }
            appendHooks(hooks, into: &out, sourceSuffix: source, pluginRoot: nil)
        }

        // 插件 Hook 不一定写进 settings，按安装登记表读取实际 installPath。
        let registries: [(String, String)] = [
            (home + "/.qoder-cn/plugins/installed_plugins.json", "Qoder CN 插件"),
            (home + "/.claude/plugins/installed_plugins.json", "Claude 遗留插件")
        ]
        for (registry, runtime) in registries {
          if let d = fm.contents(atPath: registry),
             let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
             let plugins = j["plugins"] as? [String: Any] {
            for (name, v) in plugins {
                guard let installs = v as? [[String: Any]] else { continue }
                for inst in installs {
                    guard let root = inst["installPath"] as? String else { continue }
                    let ver = (inst["version"] as? String) ?? "?"
                    guard let hd = fm.contents(atPath: root + "/hooks/hooks.json"),
                          let hj = try? JSONSerialization.jsonObject(with: hd) as? [String: Any],
                          let hooks = (hj["hooks"] as? [String: Any]) ?? (hj as [String: Any]?) else { continue }
                    let short = name.split(separator: "@").first.map(String.init) ?? name
                    appendHooks(hooks, into: &out,
                                sourceSuffix: "\(runtime) · \(short) \(ver)",
                                pluginRoot: root)
                }
            }
          }
        }
        // 同一条 Hook 可能被当前配置和遗留配置重复登记，按行为去重并保留当前来源。
        var seen: Set<String> = []
        return out.filter {
            let key = $0.event + "\u{1f}" + $0.matcher + "\u{1f}" + $0.command
            return seen.insert(key).inserted
        }
    }

    /// 解析一段 hooks 配置(事件 -> [{matcher, hooks:[{command}]}]) 并追加到结果。
    /// pluginRoot 非空时展开 ${CLAUDE_PLUGIN_ROOT} 变量。
    private static func appendHooks(_ hooks: [String: Any], into out: inout [HookItem],
                                    sourceSuffix: String, pluginRoot: String?) {
        let fm = FileManager.default
        for (event, v) in hooks {
            guard let arr = v as? [[String: Any]] else { continue }
            for entry in arr {
                let matcher = (entry["matcher"] as? String) ?? "*"
                for hk in (entry["hooks"] as? [[String: Any]]) ?? [] {
                    var cmd = (hk["command"] as? String) ?? ""
                    guard !cmd.isEmpty else { continue }
                    if let root = pluginRoot {
                        cmd = cmd.replacingOccurrences(of: "${CLAUDE_PLUGIN_ROOT}", with: root)
                        cmd = cmd.replacingOccurrences(of: "\"", with: "")
                    }
                    let script = extractScript(cmd)
                    out.append(HookItem(
                        event: event, matcher: matcher, command: cmd,
                        scriptPath: script,
                        scriptExists: script.isEmpty ? true : fm.fileExists(atPath: script),
                        source: sourceSuffix.isEmpty ? classify(cmd)
                            : sourceSuffix + " · " + classify(cmd)))
                }
            }
        }
    }

    /// 从 "node /path/x.js arg" / "bash /path/y.sh" / "/path/z.sh stop" 里抽脚本路径
    private static func extractScript(_ cmd: String) -> String {
        let parts = cmd.split(separator: " ").map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        guard let first = parts.first else { return "" }
        let interpreters = ["node", "bash", "sh", "python3", "python", "zsh"]
        let candidate: String
        if interpreters.contains((first as NSString).lastPathComponent), parts.count > 1 {
            candidate = parts[1]
        } else {
            candidate = first
        }
        return candidate.hasPrefix("/") ? candidate : ""
    }

    private static func classify(_ cmd: String) -> String {
        if cmd.contains("luban") { return "Luban 插件" }
        if cmd.contains("ali-feedback-survey") { return "反馈调查" }
        if cmd.contains(".r2c/") { return "R2C 安全" }
        if cmd.contains("loongsuite") { return "LoongSuite 监控" }
        return "自定义"
    }
}

// MARK: - MCP 页

struct McpBoardView: View {
    @ObservedObject var env: AgentEnvViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var expanded: Set<String> = []

    /// 每个已知 MCP Server 的白话说明 —— 面板的价值就是让人不用去翻文档
    private static let desc: [String: String] = [
        "browser-use": "Qoder 内置的浏览器自动化：AI 可以打开网页、点击、填表、截图、看网络请求和控制台。之前抓 GitHub 趋势榜就是它干的。与 ego-browser 的区别：这个是临时浏览器实例，ego 复用你本人的登录态。",
        "genui": "对话内弹交互式 UI 面板：show_widget 渲染 HTML 小组件（表单/确认框/数据展示），load_guidelines 加载组件规范。",
        "schedule": "定时任务引擎：让 AI 在指定时间自动执行任务。tech-scout 每天 10 点/14 点的资讯抓取就挂在它上面。",
        "utools": "你自己配的 uTools 集成（本机 3501 端口）：二维码生成/解码、待办管理、笔记。绿点 = uTools 客户端正在运行。",
        "computer-use": "桌面 App 自动化：点击/键盘/滚动本地应用程序（非浏览器）。Qoder 在别的项目里注入的，与 ego-browser 互补——ego 管网页，它管桌面。",
        "codegraph": "Qoder 在代码仓库项目（muse/tesla）里自动注入的代码图谱查询，仅 codegraph_explore 一个工具。与你手动装的 codegraph CLI 同名但相互独立。",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("汇总 Codex、Zed、Qoder CN 的 MCP Server；旧 Qoder 配置仅作迁移对照，同名 Server 合并显示来源")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                Text("● 绿 = HTTP 端点在线 · ● 红 = 探测失败 · ● 灰 = 按会话注入无常驻端口, 无法探测(不代表没用) · 点卡片看说明")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                ForEach(env.mcps) { m in card(m) }
                if env.mcps.isEmpty && !env.loading {
                    Text("未发现 MCP Server").font(fm.font(12))
                        .foregroundStyle(theme.current.textMuted).padding(.top, 30)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
        }
    }

    private func card(_ m: McpServerItem) -> some View {
        let isOpen = expanded.contains(m.name)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(m.alive == false ? Color(hex: "#d94f4f")
                          : m.alive == true ? Color(hex: "#5aa86c")
                          : theme.current.textMuted.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(m.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.current.textPrimary)
                ForEach(m.sources, id: \.self) { source in
                    Text(source).font(fm.font(9))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(theme.current.textTertiary.opacity(0.1)))
                        .foregroundStyle(source.contains("遗留") ? theme.current.textMuted : theme.current.textSecondary)
                }
                if !m.enabled {
                    Text("已停用").font(fm.font(9)).foregroundStyle(Color(hex: "#c8863c"))
                }
                Spacer()
                Text("\(m.toolCount) 工具").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.current.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.current.textMuted.opacity(0.6))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            if !m.endpoint.isEmpty {
                Text(m.endpoint).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.current.textMuted).lineLimit(1).truncationMode(.middle)
            }
            if isOpen {
                if let d = Self.desc[m.name] {
                    Text(d).font(fm.font(11))
                        .foregroundStyle(theme.current.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                // 展开态给全量工具清单
                Text(m.tools.joined(separator: " · "))
                    .font(fm.font(10)).foregroundStyle(theme.current.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !m.tools.isEmpty {
                Text(m.tools.prefix(8).joined(separator: " · ") + (m.tools.count > 8 ? " …" : ""))
                    .font(fm.font(10)).foregroundStyle(theme.current.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.82)))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                if isOpen { expanded.remove(m.name) } else { expanded.insert(m.name) }
            }
        }
    }
}

// MARK: - Hooks 页

struct HooksBoardView: View {
    @ObservedObject var env: AgentEnvViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var expandedIDs: Set<UUID> = []

    /// 事件的中文说明, 让人一眼知道"什么时候触发"
    private static let eventDesc: [String: String] = [
        "SessionStart": "会话开始时",
        "UserPromptSubmit": "你每次发消息前",
        "PreToolUse": "AI 调工具前",
        "PostToolUse": "AI 调工具后",
        "PostToolUseFailure": "工具执行失败时",
        "Stop": "AI 回答结束时",
        "SubagentStart": "子 Agent 启动时",
        "SubagentStop": "子 Agent 结束时",
        "SessionEnd": "会话结束时",
    ]

    /// 按脚本名给出白话解释 —— 关键词匹配 command
    private static func explain(_ h: HookItem) -> String {
        let c = h.command
        if c.contains("feedback-intercept") { return "反馈调查：拦截你发的每条消息, 判断是否该弹满意度问卷。" }
        if c.contains("feedback-prompt")    { return "反馈调查：AI 回答结束后决定是否弹问卷。" }
        if c.contains("feedback-env") || c.contains("feedback-session") {
            return "反馈调查：记录会话环境与起止时间, 用于公司 AI 使用调研。" }
        if c.contains("report-event")  { return "Luban 埋点：把事件(发消息/调工具等)异步上报到公司统计, 不影响对话。" }
        if c.contains("check-update")  { return "Luban：启动时检查插件有没有新版本。" }
        if c.contains("check-emp-id")  { return "Luban：校验本机的工号绑定。" }
        if c.contains(".r2c/")         { return "R2C 安全审计：把每条 Bash 命令上报审计(调用前/后/失败各拦一次), 公司安全合规组件, 与 luban 同属'公司要求'性质。" }
        if c.contains("loongsuite")    { return "LoongSuite 可观测试点：上报会话与子 Agent 的生命周期事件。注意它还在 .zshrc 里包了 qodercli/claude 一层拦截, 单删钩子卸不干净。" }
        return "未知脚本, 展开看完整命令自行判断。"
    }

    /// Hook 归宿不能只看脚本：同一脚本被不同 harness 调起，生效范围完全不同。
    private static func scope(_ h: HookItem) -> String {
        if h.source.contains("Qoder CN") {
            return "仅 Qoder CN CLI：终端 Qoder 会话，以及 Zed 中选择 Qoder CN 外部 Agent 时生效"
        }
        if h.source.contains("Codex") {
            return "仅 Codex：不会随 Zed 原生 Agent 或 Qoder CN CLI 触发"
        }
        if h.source.contains("Claude") || h.source.contains("遗留") {
            return "仅旧 Claude/Qoder 入口：当前只作迁移对照，不保证仍会触发"
        }
        return "按配置来源触发；展开查看完整命令与来源"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hook 在对话生命周期的固定时机自动执行脚本；已按 Codex、Qoder CN 与 Claude 遗留来源汇总。点条目看解释")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                ForEach(env.hooksByEvent, id: \.0) { ev, items in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(ev).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(theme.current.textPrimary)
                            Text(Self.eventDesc[ev] ?? "").font(fm.font(10))
                                .foregroundStyle(theme.current.textMuted)
                            Spacer()
                            Text("\(items.count)").font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(theme.current.textMuted)
                        }
                        ForEach(items) { h in row(h) }
                    }
                    .padding(11)
                    .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.82)))
                }
            }
            .padding(14)
        }
    }

    private func row(_ h: HookItem) -> some View {
        let isOpen = expandedIDs.contains(h.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: h.scriptExists ? "circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: h.scriptExists ? 5 : 9))
                    .foregroundStyle(h.scriptExists ? Color(hex: "#5aa86c") : Color(hex: "#d94f4f"))
                Text(h.source).font(fm.font(10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(theme.current.textTertiary.opacity(0.1)))
                    .foregroundStyle(theme.current.textSecondary)
                if h.matcher != "*" {
                    Text(h.matcher).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.current.accentPrimary.opacity(0.8))
                }
                Text((h.scriptPath.isEmpty ? h.command : h.scriptPath) as String)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(h.scriptExists ? theme.current.textMuted : Color(hex: "#d94f4f"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.current.textMuted.opacity(0.5))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.explain(h)).font(fm.font(11))
                        .foregroundStyle(theme.current.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("生效范围：\(Self.scope(h))").font(fm.font(10))
                        .foregroundStyle(theme.current.accentPrimary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(h.command).font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(theme.current.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 14).padding(.top, 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                if isOpen { expandedIDs.remove(h.id) } else { expandedIDs.insert(h.id) }
            }
        }
    }
}

// MARK: - Agents 页

struct AgentsBoardView: View {
    @ObservedObject var env: AgentEnvViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    /// 两段式删除确认: 存待确认的 agent 名, 点第二次才真删
    @State private var confirmDelete: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("区分工作入口、模型与 Agent Runtime；旧 Qoder/Claude Agent 仅作迁移对照")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                healthPanel
                ForEach(env.agents) { a in card(a) }
            }
            .padding(14)
        }
    }

    private var healthPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("运行健康度").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.current.textPrimary)
            ForEach(env.runtimeHealth) { h in
                HStack(spacing: 6) {
                    Circle().fill(healthColor(h.level)).frame(width: 6, height: 6)
                    Text(h.title).font(fm.font(10)).foregroundStyle(theme.current.textSecondary)
                    Spacer()
                    Text(h.detail).font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.accentPrimary.opacity(0.06)))
    }

    private func healthColor(_ level: RuntimeHealthItem.Level) -> Color {
        switch level {
        case .good: return Color(hex: "#5aa86c")
        case .warning: return Color(hex: "#c8863c")
        case .bad: return Color(hex: "#d94f4f")
        case .neutral: return theme.current.textMuted
        }
    }

    private func card(_ a: AgentItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: a.origin == "自建" ? "person.crop.rectangle.badge.plus" : "cpu")
                    .font(.system(size: 10))
                    .foregroundStyle(a.origin == "自建" ? theme.current.accentPrimary : theme.current.textMuted)
                Text(a.name).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.current.textPrimary)
                Text(a.origin).font(fm.font(9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.current.textTertiary.opacity(0.1)))
                    .foregroundStyle(theme.current.textSecondary)
                Spacer()
                if !a.path.isEmpty {
                    Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: a.path)) }) {
                        Image(systemName: "doc.text").font(.system(size: 10))
                            .foregroundStyle(theme.current.textSecondary)
                    }
                    .buttonStyle(.plain).help(a.path)
                }
                // 自建才能删; 物理删除, 两段式确认防误触
                if a.origin == "自建" {
                    if confirmDelete == a.name {
                        Button(action: { env.deleteAgent(a); confirmDelete = nil }) {
                            Text("确认删除").font(fm.font(10))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color(hex: "#d94f4f")))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        Button(action: { confirmDelete = nil }) {
                            Text("取消").font(fm.font(10))
                                .foregroundStyle(theme.current.textMuted)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: { confirmDelete = a.name }) {
                            Image(systemName: "trash").font(.system(size: 10))
                                .foregroundStyle(Color(hex: "#d94f4f").opacity(0.75))
                        }
                        .buttonStyle(.plain).help("物理删除该 agent 文件（不可恢复）")
                    }
                }
            }
            if !a.desc.isEmpty {
                Text(a.desc).font(fm.font(11))
                    .foregroundStyle(theme.current.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !a.tools.isEmpty {
                Text("工具: \(a.tools)").font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.current.textTertiary).lineLimit(1)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.82)))
    }
}

// MARK: - Memory 页

struct MemoryBoardView: View {
    @ObservedObject var env: AgentEnvViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var expandedGroups: Set<String> = []
    @State private var search = ""
    /// 原地展开的记忆条目及其正文缓存 —— 点击不再跳编辑器, 就地预览
    @State private var expandedEntries: Set<UUID> = []
    @State private var contentCache: [UUID: String] = [:]
    /// 已"显示全部"的分类节(组名|分类名) —— 大节默认只渲染前 15 条, 控制视图数量
    @State private var fullCats: Set<String> = []

    /// 分类名 -> 中文
    private static let catZh: [String: String] = [
        "project_tech_stack": "技术栈", "project_build_configuration": "构建配置",
        "project_dependency_configuration": "依赖配置", "project_ide_configuration": "IDE配置",
        "project_scm_configuration": "版本控制", "project_environment_configuration": "环境配置",
        "project_introduction": "项目简介", "project_architecture": "架构",
        "development_code_specification": "代码规范", "development_practice_specification": "实践规范",
        "development_test_specification": "测试规范", "development_comment_specification": "注释规范",
        "task_summary_experience": "任务总结", "common_pitfalls_experience": "踩坑",
        "important_decision_experience": "决策", "skill_experience": "技能经验",
        "tool_experience": "工具经验", "task_experience": "任务经验",
        "user_info": "用户信息", "user_hobby": "用户偏好",
        "user_communication": "沟通偏好", "user_behavior": "行为约定",
        "agent_rules": "AGENTS 规则", "legacy_rules": "Claude 遗留规则",
    ]

    var body: some View {
        ScrollView {
            // Lazy: 只构建滚入可视区的行 —— 全量 VStack 在 tesla(993条)展开时会一次建近千个视图
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("这里展示可审计的上下文：项目 AGENTS 规则、Qoder CN 当前 Memory 和旧 Qoder 历史。Codex 内部数据库不直接展开，避免将会话中间产物当作长期知识。")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                HStack(spacing: 8) {
                    TextField("搜标题…", text: $search)
                        .textFieldStyle(.roundedBorder).font(fm.font(11))
                        .frame(maxWidth: 260)
                    // 一键收起: 展开过东西才出现, 组和条目一起收
                    if !expandedGroups.isEmpty || !expandedEntries.isEmpty {
                        Button(action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                                expandedGroups.removeAll()
                                expandedEntries.removeAll()
                                fullCats.removeAll()
                            }
                        }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 9, weight: .semibold))
                                Text("全部收起").font(fm.font(11))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(theme.current.textTertiary.opacity(0.1)))
                            .foregroundStyle(theme.current.textSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                let ranked = Dictionary(grouping: env.memGroups,
                                        by: { AgentEnvViewModel.sectionRank($0.name) })
                ForEach(ranked.keys.sorted(), id: \.self) { r in
                    Text(AgentEnvViewModel.sectionName(r))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.current.textMuted)
                        .padding(.top, r == 0 ? 0 : 8)
                    ForEach(ranked[r] ?? []) { g in groupCard(g) }
                }
            }
            .padding(14)
        }
    }

    private func filtered(_ g: MemoryGroup) -> [MemoryEntry] {
        search.isEmpty ? g.entries
            : g.entries.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    /// 单条记忆: 点击原地展开正文预览(去 frontmatter, 可滚动可复制), 行尾图标才是外跳
    private func entryRow(_ e: MemoryEntry) -> some View {
        let isOpen = expandedEntries.contains(e.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 6, weight: .bold))
                    .foregroundStyle(theme.current.textMuted.opacity(0.6))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(e.title).font(fm.font(11))
                    .foregroundStyle(isOpen ? theme.current.textPrimary : theme.current.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if !e.source.isEmpty {
                    Text(e.source).font(.system(size: 9))
                        .foregroundStyle(e.source.contains("遗留") ? theme.current.textMuted : theme.current.accentPrimary.opacity(0.8))
                }
                Spacer(minLength: 0)
                Button(action: { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.current.textMuted.opacity(0.7))
                }
                .buttonStyle(.plain).help("用默认编辑器打开原文件")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                    if isOpen { expandedEntries.remove(e.id) }
                    else {
                        expandedEntries.insert(e.id)
                        if contentCache[e.id] == nil {
                            var t = (try? String(contentsOfFile: e.path, encoding: .utf8)) ?? "(读取失败)"
                            // 去掉 frontmatter, 只留正文
                            if t.hasPrefix("---"),
                               let r = t.range(of: "---", range: t.index(t.startIndex, offsetBy: 3)..<t.endIndex) {
                                t = String(t[r.upperBound...])
                            }
                            contentCache[e.id] = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
            if isOpen {
                ScrollView {
                    Text(contentCache[e.id] ?? "")
                        .font(fm.font(11))
                        .foregroundStyle(theme.current.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)   // 长文在框内滚动, 不撑爆列表
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(theme.current.textTertiary.opacity(0.06)))
                .padding(.leading, 12)
            }
        }
        .padding(.leading, 20)
    }

    private func groupCard(_ g: MemoryGroup) -> some View {
        let items = filtered(g)
        let isOpen = expandedGroups.contains(g.name) || !search.isEmpty
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.current.textMuted.opacity(0.7))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                Text(g.name
                        .replacingOccurrences(of: "work-code-", with: "")
                        .replacingOccurrences(of: "Documents-one-projects-", with: "")
                        .replacingOccurrences(of: "Documents-Qoder-", with: ""))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(g.name == "全局" ? theme.current.accentPrimary : theme.current.textPrimary)
                Spacer()
                Text("\(items.count)\(search.isEmpty ? "" : "/\(g.entries.count)")")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.current.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) {
                    if expandedGroups.contains(g.name) { expandedGroups.remove(g.name) }
                    else { expandedGroups.insert(g.name) }
                }
            }
            if isOpen && !items.isEmpty {
                // 大项目上千条平铺没法看 —— 按分类分节, 节头带计数, 条目只留标题
                let byCat = Dictionary(grouping: items, by: { $0.category })
                    .sorted { $0.value.count != $1.value.count
                              ? $0.value.count > $1.value.count : $0.key < $1.key }
                ForEach(byCat, id: \.key) { cat, list in
                    HStack(spacing: 5) {
                        Text(Self.catZh[cat] ?? cat)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.current.textSecondary)
                        Text("\(list.count)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(theme.current.textMuted)
                        Rectangle().fill(theme.current.textTertiary.opacity(0.15)).frame(height: 1)
                    }
                    .padding(.leading, 14).padding(.top, 5)
                    let capKey = g.name + "|" + cat
                    let showAll = fullCats.contains(capKey) || !search.isEmpty
                    ForEach(showAll ? list : Array(list.prefix(15))) { e in entryRow(e) }
                    if !showAll && list.count > 15 {
                        Button(action: { fullCats.insert(capKey) }) {
                            Text("… 展开其余 \(list.count - 15) 条")
                                .font(fm.font(10))
                                .foregroundStyle(theme.current.accentPrimary.opacity(0.85))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 20)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.82)))
    }
}
