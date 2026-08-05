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
}

/// Hook: 来自 ~/.claude/settings.json 的 hooks 段
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
    var id: String { name }
    var name: String
    var desc: String
    var tools: String = ""
    var origin: String        // 自建 / 内置
    var path: String = ""
}

/// 长期记忆条目: ~/.qoder/memories 下的明文 Markdown
struct MemoryEntry: Identifiable {
    let id = UUID()
    var title: String
    var path: String
    var category: String
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
            DispatchQueue.main.async {
                self.mcps = m; self.hooks = h
                self.agents = a; self.memGroups = g
                self.loading = false
                self.probeAlive()
            }
        }
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
                    origin: "自建", path: p))
            }
        }
        // Qoder 内置 subagent —— 由 harness 提供, 无本地文件, 清单写死
        let builtins: [(String, String)] = [
            ("Browser", "浏览器子代理: 点击/输入/导航/截图, 操控网页完成任务"),
            ("CodeReview", "代码评审子代理: 找逻辑 Bug 与安全漏洞, 高信噪比"),
            ("ComputerUse", "桌面操控子代理: 点击/键盘/滚动本地 App(非浏览器)"),
            ("Debug", "调试子代理: 复现并定位运行时故障, 产出根因报告"),
            ("GeneralPurpose", "通用子代理: 复杂多步任务与代码搜索"),
            ("Search", "只读检索子代理: 调查代码/记忆/知识, 不做修改"),
            ("plan-agent", "规划子代理: 产出结构化实施计划 / spec 文档"),
        ]
        for (n, d) in builtins { out.append(AgentItem(name: n, desc: d, origin: "内置")) }
        return out
    }

    // MARK: Memory 扫描

    /// ~/.qoder/memories/<id>/{global, projects/<slug>}/<category>/<title>.md
    private static func scanMemories() -> [MemoryGroup] {
        let fm = FileManager.default
        let root = NSHomeDirectory() + "/.qoder/memories"
        guard let ids = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var groups: [String: [MemoryEntry]] = [:]

        func collect(_ dir: String, into name: String) {
            guard let cats = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for c in cats where !c.hasPrefix(".") {
                let cd = dir + "/" + c
                guard let files = try? fm.contentsOfDirectory(atPath: cd) else { continue }
                for f in files where f.hasSuffix(".md") {
                    groups[name, default: []].append(MemoryEntry(
                        title: String(f.dropLast(3)).replacingOccurrences(of: "_", with: " "),
                        path: cd + "/" + f, category: c))
                }
            }
        }

        for mid in ids where !mid.hasPrefix(".") {
            let base = root + "/" + mid
            collect(base + "/global", into: "全局")
            if let projs = try? fm.contentsOfDirectory(atPath: base + "/projects") {
                // slug 形如 Users-zz-work-code-muse —— 前缀由 home 路径推导, 不写死用户名
                let homeSlug = NSHomeDirectory().dropFirst()
                    .replacingOccurrences(of: "/", with: "-") + "-"
                for p in projs where !p.hasPrefix(".") {
                    let disp = p.hasPrefix(homeSlug) ? String(p.dropFirst(homeSlug.count)) : p
                    collect(base + "/projects/" + p, into: disp)
                }
            }
        }
        return groups.map { MemoryGroup(name: $0.key, entries: $0.value.sorted { $0.category < $1.category }) }
            .sorted { a, b in
                let (ra, rb) = (Self.sectionRank(a.name), Self.sectionRank(b.name))
                return ra != rb ? ra < rb : a.entries.count > b.entries.count
            }
    }

    /// 分区次序: 全局 > 代码项目 > 文档项目 > 临时会话
    static func sectionRank(_ name: String) -> Int {
        if name == "全局" { return 0 }
        if name.hasPrefix("work-code-") { return 1 }
        if name.hasPrefix("Documents-one-") { return 2 }
        return 3   // Documents-Qoder-* / Qoder-Chats 等临时会话
    }

    static func sectionName(_ rank: Int) -> String {
        ["📌 全局（任何会话都注入）", "💼 代码项目", "�� 文档项目", "💬 临时会话（chat 工作区）"][rank]
    }

    // MARK: MCP 扫描

    private static func scanMcps() -> [McpServerItem] {
        var map: [String: McpServerItem] = [:]
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // 1) Qoder 内置注入: SharedClientCache/projects/*/mcps/<server>/tools/*.json
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
                    var it = map[sv] ?? McpServerItem(name: sv)
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
                    map[sv] = it
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
                var it = map[k] ?? McpServerItem(name: k)
                it.origin = "自配"
                let ep = (cfg["url"] as? String) ?? (cfg["command"] as? String) ?? ""
                if !ep.isEmpty { it.endpoint = ep }
                map[k] = it
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

        // 来源 1: settings.json / settings.local.json 里手工注册的钩子
        for file in ["/.claude/settings.json", "/.claude/settings.local.json"] {
            guard let d = fm.contents(atPath: home + file),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let hooks = j["hooks"] as? [String: Any] else { continue }
            appendHooks(hooks, into: &out, sourceSuffix: "", pluginRoot: nil)
        }

        // 来源 2: 已安装插件自带的 hooks/hooks.json —— 由插件体系自动加载,
        // 不出现在 settings.json 里。之前面板漏了这块, 导致"只看得到 1.0.6 的死钩子,
        // 看不到 1.1.3 正在跑的新钩子"。
        // installed_plugins.json 记录了每个插件实际加载的 installPath。
        if let d = fm.contents(atPath: home + "/.claude/plugins/installed_plugins.json"),
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
                                sourceSuffix: "\(short) \(ver)(插件自带)",
                                pluginRoot: root)
                }
            }
        }
        return out
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
                        source: sourceSuffix.isEmpty ? classify(cmd) : sourceSuffix))
                }
            }
        }
    }

    /// 从 "node /path/x.js arg" / "bash /path/y.sh" / "/path/z.sh stop" 里抽脚本路径
    private static func extractScript(_ cmd: String) -> String {
        let parts = cmd.split(separator: " ").map(String.init)
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
                Text("MCP Server 由 Qoder 注入或 ~/.qoder/mcp.json 自配, 提供对话内可调用的工具。内置项跨项目聚合(不同项目注入的 server 不同)")
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
                Text(m.origin).font(fm.font(9))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.current.textTertiary.opacity(0.1)))
                    .foregroundStyle(theme.current.textSecondary)
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hook 在对话生命周期的固定时机自动执行脚本 —— 当前全部来自公司预置(埋点/审计/监控)。点条目看解释")
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
                Text("Subagent 是分工的班组: 主对话把任务派给它, 各干各的互不占上下文。自建的是 .agent.md 文件, 内置的由 Qoder 提供")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                ForEach(env.agents) { a in card(a) }
            }
            .padding(14)
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
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("长期记忆按「打开的项目目录」隔离: 只有在该项目干活时才注入; 全局组则任何会话都注入。每行是一个项目, 点行展开(分类分节), 点条目打开原文")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                TextField("搜标题…", text: $search)
                    .textFieldStyle(.roundedBorder).font(fm.font(11))
                    .frame(maxWidth: 260)
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
                    ForEach(list) { e in
                        HStack(spacing: 6) {
                            Circle().fill(theme.current.textMuted.opacity(0.35))
                                .frame(width: 3, height: 3)
                            Text(e.title).font(fm.font(11))
                                .foregroundStyle(theme.current.textSecondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 20)
                        .contentShape(Rectangle())
                        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: e.path)) }
                        .help(e.path)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.82)))
    }
}
