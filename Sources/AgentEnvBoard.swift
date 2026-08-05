import SwiftUI

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

// MARK: - ViewModel

final class AgentEnvViewModel: ObservableObject {
    @Published var mcps: [McpServerItem] = []
    @Published var hooks: [HookItem] = []
    @Published var loading = false

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
            DispatchQueue.main.async {
                self.mcps = m; self.hooks = h; self.loading = false
                self.probeAlive()
            }
        }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("MCP Server 由 Qoder 注入或 ~/.qoder/mcp.json 自配, 提供对话内可调用的工具。内置项跨项目聚合(不同项目注入的 server 不同)")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                    .padding(.horizontal, 2)
                Text("● 绿 = HTTP 端点在线 · ● 红 = 探测失败 · ● 灰 = 按会话注入无常驻端口, 无法探测(不代表没用)")
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
        VStack(alignment: .leading, spacing: 7) {
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
            }
            if !m.endpoint.isEmpty {
                Text(m.endpoint).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.current.textMuted).lineLimit(1).truncationMode(.middle)
            }
            if !m.tools.isEmpty {
                Text(m.tools.prefix(8).joined(separator: " · ") + (m.tools.count > 8 ? " …" : ""))
                    .font(fm.font(10)).foregroundStyle(theme.current.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.82)))
    }
}

// MARK: - Hooks 页

struct HooksBoardView: View {
    @ObservedObject var env: AgentEnvViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hook 在对话生命周期的固定时机自动执行脚本 —— 当前全部来自公司预置(埋点/调查/监控)")
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
                .help(h.command)
            Spacer(minLength: 0)
        }
    }
}
