import SwiftUI
import AppKit
import Foundation

// MARK: - Skills 看板: 扫描 ~/.claude/skills, 校验合规性, 管理启用/禁用
// 关键事实: ~/.qoder/skills 是指向 ~/.claude/skills 的符号链接, 单一数据源
// 禁用机制: 移到 ~/.claude/skills-disabled/ (彻底移出扫描范围, 可逆)
//   —— frontmatter 加 disabled 字段是假禁用(Qoder 不认这字段), 不采用

enum SkillHealth: Int, Comparable {
    case broken = 0     // Qoder 加载不到
    case warn = 1       // 能加载但有隐患
    case healthy = 2
    static func < (a: SkillHealth, b: SkillHealth) -> Bool { a.rawValue < b.rawValue }
}

struct SkillItem: Identifiable {
    let dir: String                // 目录名
    let path: String
    var name: String = ""          // frontmatter name
    var desc: String = ""
    var enabled: Bool = true
    var health: SkillHealth = .healthy
    var problems: [String] = []    // 硬性问题(影响加载)
    var hints: [String] = []       // 软性提示
    var missingCLI: [String] = []  // 依赖但未安装的命令
    /// 实战验证状态: 取自 SKILL.md 正文的「## 实战验证」段 —— 用来区分
    /// "装了但没用过"(未验证) 与 "真跑通过"(已验证), 避免把摆设当能力。
    var verify: String = ""          // 已验证 / 部分验证 / 未验证 / 空(未标注)
    var origin: String = "启用"      // 启用 / 已归档 / 分享版
    var external: Bool = false     // 第三方插件(marketplace 安装), 描述由上游维护, 本地改动会被覆盖
    var manualOnly: Bool = false   // frontmatter 声明 disable-model-invocation: 只能手动唤起
    var hardRefs: [String] = []    // 硬依赖我的 skill(写死了我的路径, 禁用即崩)
    var mentionCount: Int = 0      // 仅正文提及我的次数(参考值, 不作风险依据)
    var externalRefs: [String] = [] // 被 crontab/LaunchAgent 引用
    var modified: Date? = nil
    var category: String = "其他"
    var fileCount: Int = 0
    var id: String { dir }

    var refCount: Int { hardRefs.count }
    var isHub: Bool { hardRefs.count >= 2 }
    var riskyToDisable: Bool { !externalRefs.isEmpty || !hardRefs.isEmpty }
}

final class SkillsViewModel: ObservableObject {
    @Published var items: [SkillItem] = []
    @Published var loading = false
    @Published var search = ""
    @Published var categoryFilter = "全部"
    @Published var onlyProblems = false
    @Published var lastScan: Date? = nil
    @Published var actionMsg = ""

    /// 用户自定义分类覆盖表: 目录名 -> 分类名。
    /// **只存在这个独立 JSON 里, 绝不写入 SKILL.md** —— frontmatter 是 AI 路由的依据,
    /// 动它会影响 skill 实际行为; 分类纯属面板视图组织, 二者必须解耦。
    @Published var overrides: [String: String] = [:]
    /// 用户新建但暂时还没有成员的分类(保证空分类也能出现在菜单里)
    @Published var customCategories: [String] = []

    static let overrideFile = NSHomeDirectory() + "/.claude/skills-categories.json"

    private struct OverrideStore: Codable {
        var overrides: [String: String]
        var customCategories: [String]
    }

    func loadOverrides() {
        guard let d = FileManager.default.contents(atPath: Self.overrideFile),
              let st = try? JSONDecoder().decode(OverrideStore.self, from: d) else { return }
        overrides = st.overrides
        customCategories = st.customCategories
    }

    private func saveOverrides() {
        let st = OverrideStore(overrides: overrides, customCategories: customCategories)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(st) else { return }
        try? d.write(to: URL(fileURLWithPath: Self.overrideFile))
    }

    /// 全部可选分类 = 内置分类 + 当前已用分类 + 用户新建的; 尾部三类不可作为目标
    var assignableCategories: [String] {
        let builtin = ["TMYC", "钉钉", "Luban", "设计/动画", "开发方法论",
                       "开发工具", "信息获取", "浏览器", "个人效率", "知识库", "元技能", "其他"]
        var all = builtin
        for i in items where !Self.tailCategories.contains(i.category) {
            if !all.contains(i.category) { all.append(i.category) }
        }
        for c in customCategories where !all.contains(c) { all.append(c) }
        return all
    }

    /// 改某个 skill 的分类。仅写覆盖表, 不触碰 skill 目录与文件。
    func assign(_ item: SkillItem, to category: String) {
        overrides[item.dir] = category
        saveOverrides()
        applyOverridesInPlace()
        actionMsg = "\(item.dir) → \(category)"
    }

    /// 恢复某个 skill 为内置规则判定的分类
    func resetCategory(_ item: SkillItem) {
        overrides.removeValue(forKey: item.dir)
        saveOverrides()
        scan()
        actionMsg = "\(item.dir) 已恢复默认分类"
    }

    func addCategory(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !assignableCategories.contains(n) else { return }
        customCategories.append(n)
        saveOverrides()
        actionMsg = "已新建分类「\(n)」"
    }

    /// 重命名分类: 同步改写所有指向它的覆盖项
    func renameCategory(_ old: String, to new: String) {
        let n = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n != old, !Self.tailCategories.contains(old) else { return }
        // 原本靠内置规则落在 old 的 skill, 也要显式钉到新名字, 否则会弹回旧分类
        for i in items where i.category == old { overrides[i.dir] = n }
        for (k, v) in overrides where v == old { overrides[k] = n }
        customCategories.removeAll { $0 == old }
        if !customCategories.contains(n) && !assignableCategories.contains(n) {
            customCategories.append(n)
        }
        saveOverrides()
        applyOverridesInPlace()
        actionMsg = "「\(old)」已改名为「\(n)」"
    }

    /// 删除分类: 只清映射, 成员回落到内置规则判定的分类。skill 本身不受任何影响。
    func deleteCategory(_ name: String) {
        guard !Self.tailCategories.contains(name) else { return }
        for (k, v) in overrides where v == name { overrides.removeValue(forKey: k) }
        customCategories.removeAll { $0 == name }
        saveOverrides()
        scan()
        actionMsg = "已删除分类「\(name)」, 成员回落到默认分类"
    }

    /// 不重扫磁盘, 直接按覆盖表刷新内存里的 category(改分类是纯视图操作, 无需 IO)
    private func applyOverridesInPlace() {
        for idx in items.indices {
            let it = items[idx]
            guard !Self.tailCategories.contains(it.origin) || it.origin == "启用" else { continue }
            if it.origin == "启用", let c = overrides[it.dir] { items[idx].category = c }
        }
    }

    static let root = NSHomeDirectory() + "/.claude/skills"
    static let disabledRoot = NSHomeDirectory() + "/.claude/skills-disabled"
    /// 归档区: 确认不再使用, 移出扫描范围但保留可恢复
    static let archiveRoot = NSHomeDirectory() + "/.claude/skills-archive"
    /// 分享区: 对外分发的副本, 不参与本机路由(避免与自用版描述撞车)
    static let sharedRoot = NSHomeDirectory() + "/.claude/skills-shared"

    /// 非启用态的分类(已归档/分享版)不是日常关注对象, 固定排在最后,
    /// 否则会因数量大而挤到筛选条前排, 把常用业务分类推到"更多"里。
    static let tailCategories = ["分享版", "已归档"]

    /// 筛选条固定展示顺序 —— 之前按数量降序, 每次扫描数量一变顺序就重排, 视觉上一直在跳。
    /// 顺序按"日常使用频度"手工排定, 与数量无关。
    static let categoryOrder = ["TMYC", "Luban", "钉钉", "开发工具", "开发方法论",
                                "设计/动画", "浏览器", "信息获取", "知识库",
                                "个人效率", "元技能", "其他"]

    var categories: [(String, Int)] {
        var c: [String: Int] = [:]
        for i in items { c[i.category, default: 0] += 1 }
        func rank(_ k: String) -> Int {
            if let i = Self.categoryOrder.firstIndex(of: k) { return i }
            if let i = Self.tailCategories.firstIndex(of: k) { return 900 + i }  // 归档/分享垫底
            return 500                                                          // 自定义分类居中
        }
        let sorted = c.sorted { a, b in
            let (ra, rb) = (rank(a.key), rank(b.key))
            return ra != rb ? ra < rb : a.key < b.key   // 同档按名字, 保证稳定
        }
        return [("全部", items.count)] + sorted.map { ($0.key, $0.value) }
    }

    /// 只有归档/分享收进"更多", 其余全部平铺 —— 免得常用分类被折叠进下拉
    var visibleCategories: [(String, Int)] {
        categories.filter { !Self.tailCategories.contains($0.0) }
    }
    var hiddenCategories: [(String, Int)] {
        categories.filter { Self.tailCategories.contains($0.0) }
    }

    var filtered: [SkillItem] {
        items.filter { i in
            if onlyProblems && i.health == .healthy { return false }
            if categoryFilter != "全部" && i.category != categoryFilter { return false }
            if !search.isEmpty {
                let q = search.lowercased()
                return i.dir.lowercased().contains(q) || i.desc.lowercased().contains(q)
            }
            return true
        }
        .sorted {
            if $0.health != $1.health { return $0.health < $1.health }  // 有问题的排前面
            return $0.dir < $1.dir
        }
    }

    var stats: (total: Int, healthy: Int, warn: Int, broken: Int, disabled: Int) {
        (items.count,
         items.filter { $0.health == .healthy }.count,
         items.filter { $0.health == .warn }.count,
         items.filter { $0.health == .broken }.count,
         items.filter { !$0.enabled }.count)
    }

    func scan() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performScan()
            DispatchQueue.main.async {
                guard let self = self else { return }
                // 覆盖表只作用于启用中的 skill; 归档/分享/禁用保持来源分类不被改写
                self.items = result.map { it -> SkillItem in
                    guard it.origin == "启用", let c = self.overrides[it.dir] else { return it }
                    var m = it; m.category = c; return m
                }
                self.loading = false
                self.lastScan = Date()
            }
        }
    }

    // MARK: 扫描

    private static func performScan() -> [SkillItem] {
        let fm = FileManager.default
        var out: [SkillItem] = []

        // 外部引用来源: crontab + LaunchAgents
        let cronRefs = externalRefSet(from: runCmd("/bin/sh", ["-c", "crontab -l 2>/dev/null"]), tag: "定时任务")
        var launchRefs: [String: String] = [:]
        let laDir = NSHomeDirectory() + "/Library/LaunchAgents"
        if let files = try? fm.contentsOfDirectory(atPath: laDir) {
            for f in files where f.hasSuffix(".plist") {
                if let t = try? String(contentsOfFile: laDir + "/" + f, encoding: .utf8) {
                    for k in skillNames(in: t) { launchRefs[k] = "开机项 " + f }
                }
            }
        }

        // 收集所有目录(启用 + 禁用)
        var dirs: [(String, String, Bool)] = []   // (dir, path, enabled)
        if let ds = try? fm.contentsOfDirectory(atPath: root) {
            for d in ds where isDir(root + "/" + d) { dirs.append((d, root + "/" + d, true)) }
        }
        if let ds = try? fm.contentsOfDirectory(atPath: disabledRoot) {
            for d in ds where isDir(disabledRoot + "/" + d) { dirs.append((d, disabledRoot + "/" + d, false)) }
        }
        // 归档区 / 分享区同样纳入展示, 但都标记为未启用(不参与本机路由)
        for extraRoot in [archiveRoot, sharedRoot] {
            if let ds = try? fm.contentsOfDirectory(atPath: extraRoot) {
                for d in ds where isDir(extraRoot + "/" + d) { dirs.append((d, extraRoot + "/" + d, false)) }
            }
        }

        // 第一轮: 解析元数据
        var texts: [String: String] = [:]
        for (d, p, en) in dirs {
            var it = SkillItem(dir: d, path: p)
            it.enabled = en
            // skills-disabled 是历史遗留目录, 仍扫描以免漏掉, 但归口显示为"已归档"
            if p.hasPrefix(Self.archiveRoot) || p.hasPrefix(Self.disabledRoot) {
                it.origin = "已归档"
            } else if p.hasPrefix(Self.sharedRoot) {
                it.origin = "分享版"
            }
            let sk = p + "/SKILL.md"

            if let attrs = try? fm.attributesOfItem(atPath: p) {
                it.modified = attrs[.modificationDate] as? Date
            }
            it.fileCount = ((try? fm.contentsOfDirectory(atPath: p))?.count) ?? 0

            guard fm.fileExists(atPath: sk),
                  let txt = try? String(contentsOfFile: sk, encoding: .utf8) else {
                // 缺 SKILL.md: 若目录内有脚本, 判定为"仅定时任务", 否则是坏的
                let hasScript = ((try? fm.contentsOfDirectory(atPath: p)) ?? [])
                    .contains { $0.hasSuffix(".py") || $0.hasSuffix(".sh") || $0.hasSuffix(".js") }
                if hasScript {
                    it.health = .warn
                    it.hints.append("无 SKILL.md, 只能定时/命令行调用, 对话中无法唤起")
                } else {
                    it.health = .broken
                    it.problems.append("缺少 SKILL.md, Qoder 无法加载")
                }
                it.category = "其他"
                out.append(it)
                continue
            }
            texts[d] = txt

            // frontmatter
            guard let fmRange = txt.range(of: "^---\\s*\\n", options: .regularExpression),
                  let endRange = txt.range(of: "\\n---", options: .regularExpression,
                                           range: fmRange.upperBound..<txt.endIndex) else {
                it.health = .broken
                it.problems.append("SKILL.md 缺少 frontmatter (--- 开头的元数据块)")
                out.append(it)
                continue
            }
            let front = String(txt[fmRange.upperBound..<endRange.lowerBound])

            it.name = field(front, "name") ?? ""
            it.desc = field(front, "description") ?? ""

            if it.name.isEmpty {
                it.health = .broken
                it.problems.append("frontmatter 缺 name 字段")
            } else if it.name != d {
                // 归档/分享副本只是同一份 skill 的另一份拷贝, 目录名可以不同,
                // 它们不参与本机路由, 不构成"加载会错乱"的问题。
                if it.origin == "启用" {
                    it.health = min(it.health, .broken)
                    it.problems.append("name「\(it.name)」与目录名不符, 加载会错乱")
                }
            }
            if it.desc.isEmpty {
                it.health = .broken
                it.problems.append("frontmatter 缺 description, Qoder 无法判断何时触发")
            }

            // 仅手动调用的 skill(disable-model-invocation)不参与"触发词"检查 ——
            // 它本就不该被自动唤起, 没触发词是设计意图而非缺陷。
            it.manualOnly = front.contains("disable-model-invocation: true")
            for v in ["已验证", "部分验证", "未验证"] where txt.contains("状态：**\(v)**") {
                it.verify = v
                break
            }
            it.external = Self.isExternalPlugin(d)

            // ===== 软性检查 =====
            // 第三方插件的 description 由上游维护, 本地改了会被插件更新覆盖, 不提示。
            if !it.desc.isEmpty && !it.external && it.origin == "启用" {
                if it.desc.count < 40 {
                    it.hints.append("description 仅 \(it.desc.count) 字, 过短会导致 Qoder 匹配不准")
                }
                if !it.manualOnly && !Self.declaresTrigger(desc: it.desc, front: front) {
                    it.hints.append("description 没写触发条件(如\"当用户说…\"/\"Use when…\"), 可能不会被自动唤起")
                }
            }
            it.missingCLI = missingCommands(in: txt)
            if !it.missingCLI.isEmpty {
                it.hints.append("依赖的命令未安装: " + it.missingCLI.joined(separator: ", "))
            }
            if let m = it.modified, Date().timeIntervalSince(m) > 180 * 86400 {
                it.hints.append("半年以上未更新, 确认是否仍需要")
            }

            // 归档/分享/禁用的单独成类, 不混进业务分类
            it.category = it.origin == "启用" ? categorize(d) : it.origin
            if let ex = cronRefs[d] { it.externalRefs.append(ex) }
            if let ex = launchRefs[d] { it.externalRefs.append(ex) }

            out.append(it)
        }

        // 第二轮: 交叉引用 —— 分硬依赖 / 软提及两级
        // 旧实现用 txt.contains(other) 裸匹配, 导致 skill/open/canvas 这类
        // 普通英文词被算成几十次引用, isHub 与禁用风险判定全部失真。
        let allDirs = Set(out.map { $0.dir })
        var hardRefs: [String: [String]] = [:]   // 被依赖者 -> [依赖方]
        var mentions: [String: Int] = [:]
        for (d, txt) in texts {
            for other in allDirs where other != d {
                if isHardDependency(txt, on: other) {
                    hardRefs[other, default: []].append(d)
                } else if mentionsWord(txt, other) {
                    mentions[other, default: 0] += 1
                }
            }
        }
        for i in out.indices {
            let d = out[i].dir
            out[i].hardRefs = (hardRefs[d] ?? []).sorted()
            out[i].mentionCount = mentions[d] ?? 0
            // 软性提示汇总后定级
            if out[i].health == .healthy && !out[i].hints.isEmpty { out[i].health = .warn }
        }
        return out
    }

    // MARK: 动作

    /// 禁用: 移到 skills-disabled (可逆, 彻底移出扫描范围)
    /// 禁用即归档: 统一落到 skills-archive。
    /// "已禁用"和"已归档"对使用者是同一件事(移出扫描范围、可恢复), 分成两个目录
    /// 只会让分类多一层无意义的区分。
    func disable(_ item: SkillItem) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.archiveRoot, withIntermediateDirectories: true)
        let dst = Self.archiveRoot + "/" + item.dir
        do {
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.moveItem(atPath: item.path, toPath: dst)
            actionMsg = "已归档 \(item.dir)"
            scan()
        } catch {
            actionMsg = "归档失败: \(error.localizedDescription)"
        }
    }

    func enable(_ item: SkillItem) {
        let fm = FileManager.default
        let dst = Self.root + "/" + item.dir
        do {
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.moveItem(atPath: item.path, toPath: dst)
            actionMsg = "已启用 \(item.dir)"
            scan()
        } catch {
            actionMsg = "启用失败: \(error.localizedDescription)"
        }
    }

    func revealInFinder(_ item: SkillItem) {
        NSWorkspace.shared.selectFile(item.path + "/SKILL.md", inFileViewerRootedAtPath: item.path)
    }

    func openSkillMD(_ item: SkillItem) {
        let p = item.path + "/SKILL.md"
        if FileManager.default.fileExists(atPath: p) {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
        }
    }

    // MARK: 工具

    private static func isDir(_ p: String) -> Bool {
        var isD: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isD) && isD.boolValue
    }

    private static func field(_ front: String, _ key: String) -> String? {
        for line in front.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(key + ":") {
                var v = String(t.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return v
            }
        }
        return nil
    }

    /// 分类：显式白名单优先于前缀/模糊匹配 —— contains("skill")/hasPrefix("superpowers-")
    /// 这类规则会把"名字像但实际不是"的 skill 归错（如 playwright-skill 是工具、
    /// superpowers-using-git-worktrees 是开发流程而非元技能）。
    private static func categorize(_ d: String) -> String {
        // ① 天猫养车业务：除 tmyc- 前缀外, 公司内部平台工具也属此类
        let tmyc: Set<String> = ["ultra-pre-probe", "dubbo-pre-invoke",
                                 "gateway-auto-register", "gateway-auto-register-shared",
                                 "auth-center-menu-export", "prd-login", "yunxiao-bug-fixer"]
        if d.hasPrefix("tmyc-") || tmyc.contains(d) { return "TMYC" }

        // ② 钉钉 / Luban 插件
        if d.hasPrefix("dingtalk-") || d == "dws" || d == "dws-shared" || d == "mono" { return "钉钉" }
        if d.hasPrefix("luban-") { return "Luban" }

        // ③ 元技能 = 管理 skill/agent 资产本身
        let meta: Set<String> = ["create-skill", "create-skill-ui", "create-plugin",
                                 "create-subagent", "skills-gallery", "local-skills-bridge",
                                 "superpowers-writing-skills", "better-harness"]
        if meta.contains(d) { return "元技能" }

        // ④ 开发方法论 = 怎么做事的规范/流程, 不产出具体产物
        let method: Set<String> = ["code-discipline", "systematic-debugging", "grill-me",
                                   "superpowers-receiving-code-review",
                                   "superpowers-using-git-worktrees",
                                   "superpowers-finishing-a-development-branch"]
        if method.contains(d) { return "开发方法论" }

        // ⑤ 开发工具 = 具体的构建/调试/定位工具
        let devtool: Set<String> = ["ai-java-debugger", "maven-local-environment",
                                    "codemap-plus", "port-mapping", "vercel-deploy"]
        if devtool.contains(d) { return "开发工具" }

        // ⑥ 设计/动画
        if d.contains("animation") || d.contains("design") || d.contains("canvas")
            || d == "prototype" || d == "pick-ui-library"
            || d == "tech-architecture-visualizer" { return "设计/动画" }

        // ⑦ 信息获取 = 抓取/调研外部信息
        let info: Set<String> = ["tech-scout", "last30days", "defuddle", "open"]
        if info.contains(d) { return "信息获取" }

        // ⑧ 浏览器自动化
        if d == "ego-browser" || d == "playwright-skill" || d == "trace" || d == "skill" {
            return "浏览器"
        }

        // ⑨ 个人效率
        let personal: Set<String> = ["d-board", "dogfooding", "i-have-adhd", "schedule"]
        if personal.contains(d) { return "个人效率" }

        // ⑩ 知识库
        if d.contains("obsidian") || d.contains("wiki") || d.contains("memory") { return "知识库" }

        return "其他"
    }

    /// 从文本里找依赖的 CLI, 检查是否安装
    private static func missingCommands(in txt: String) -> [String] {
        let candidates = ["dws", "qodercli", "px", "kubectl", "defuddle", "obsidian-cli", "gh"]
        var missing: [String] = []
        for c in candidates {
            // 必须像命令调用那样出现(行首/反引号/$后), 避免误判普通词
            let patterns = ["`\(c) ", "$ \(c) ", "\n\(c) ", "```\(c)"]
            guard patterns.contains(where: { txt.contains($0) }) else { continue }
            if !commandExists(c) { missing.append(c) }
        }
        return missing
    }

    private static var cliCache: [String: Bool] = [:]
    /// GUI App 继承的是 launchd 的最小 PATH, 不含 ~/.zshrc 里 export 的目录 ——
    /// 直接 /bin/sh -c "command -v x" 会把 brew / ~/.local/bin / ~/.qoderwork/bin
    /// 里的命令全判成"未安装"。故显式补齐常见安装位置, 并兜底走一次登录 shell。
    private static func commandExists(_ c: String) -> Bool {
        if let v = cliCache[c] { return v }
        let home = NSHomeDirectory()
        let extraDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                         home + "/.local/bin", home + "/.qoderwork/bin",
                         home + "/.nvm/versions/node/v16.20.2/bin"]
        // ① 直接看文件是否存在(最快, 无需起 shell)
        for d in extraDirs where FileManager.default.isExecutableFile(atPath: d + "/" + c) {
            cliCache[c] = true
            return true
        }
        // ② 兜底: 用登录 shell 查一次, 覆盖 .zshrc 里自定义的 PATH
        let out = runCmd("/bin/zsh", ["-lic", "command -v \(c) 2>/dev/null"])
        let exists = !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cliCache[c] = exists
        return exists
    }

    /// 第三方插件: 由 marketplace 安装并在 plugins/cache 下有同名副本 ——
    /// 其 description 属上游资产, 本地修改会在插件升级时丢失, 因此不做描述质量检查。
    private static func isExternalPlugin(_ dir: String) -> Bool {
        let fm = FileManager.default
        let cacheRoot = NSHomeDirectory() + "/.claude/plugins/cache"
        guard let markets = try? fm.contentsOfDirectory(atPath: cacheRoot) else { return false }
        for market in markets {
            let marketPath = cacheRoot + "/" + market
            guard let plugins = try? fm.contentsOfDirectory(atPath: marketPath) else { continue }
            for plugin in plugins {
                let base = marketPath + "/" + plugin
                guard let versions = try? fm.contentsOfDirectory(atPath: base) else { continue }
                for v in versions {
                    if fm.fileExists(atPath: base + "/" + v + "/skills/" + dir + "/SKILL.md") {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// 是否声明了触发条件。除英文 Use when / 中文"当用户说"外,
    /// 也认"适用于/用于/场景"这类中文写法, 以及 argument-hint 显式声明调用形式。
    private static func declaresTrigger(desc: String, front: String) -> Bool {
        let phrases = ["when", "Use ", "use this skill", "Triggers",
                       "当用户", "用户说", "用户提到", "触发", "时使用",
                       "适用于", "用于", "场景", "命令前缀"]
        for p in phrases where desc.localizedCaseInsensitiveContains(p) { return true }
        // argument-hint 给出了调用示例, 等同于声明了唤起方式
        if front.contains("argument-hint") { return true }
        return false
    }

    /// 硬依赖: 正文把目标 skill 的**路径**或**专属环境变量**写死了 —— 禁用后调用方直接失败。
    /// 例: `~/.claude/skills/playwright-skill` / `PLAYWRIGHT_SKILL_DIR=...`
    private static func isHardDependency(_ txt: String, on other: String) -> Bool {
        if txt.contains("skills/" + other) { return true }
        // <NAME>_SKILL_DIR / <NAME>_DIR 形式(playwright-skill -> PLAYWRIGHT_SKILL)
        let envBase = other.replacingOccurrences(of: "-", with: "_").uppercased()
        if txt.contains(envBase + "_DIR") { return true }
        return false
    }

    /// 软提及: 词边界匹配, 前后不能紧邻字母/数字/连字符/下划线,
    /// 避免 "skill" 命中 "skills"、"open" 命中 "opened" 这类假引用。
    private static func mentionsWord(_ txt: String, _ word: String) -> Bool {
        guard word.count >= 3 else { return false }   // 太短的名字无法可靠判定
        let chars = Array(txt)
        let w = Array(word)
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }
        var i = 0
        let n = chars.count, m = w.count
        while i + m <= n {
            if chars[i] == w[0], Array(chars[i..<(i + m)]) == w {
                let leftOK  = i == 0 || !isWordChar(chars[i - 1])
                let rightOK = i + m >= n || !isWordChar(chars[i + m])
                if leftOK && rightOK { return true }
            }
            i += 1
        }
        return false
    }

    private static func skillNames(in text: String) -> [String] {
        var out: [String] = []
        var idx = text.startIndex
        while let r = text.range(of: "skills/", range: idx..<text.endIndex) {
            let rest = text[r.upperBound...]
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if !name.isEmpty { out.append(String(name)) }
            idx = r.upperBound
        }
        return out
    }

    private static func externalRefSet(from text: String, tag: String) -> [String: String] {
        var m: [String: String] = [:]
        for n in skillNames(in: text) { m[n] = tag }
        return m
    }

    private static func runCmd(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - 视图
// 设计依据(emil-design-eng + apple-design):
//  1. 网格分块: 每张卡片是独立单元, 卡间留白让眼睛有落点(上一版满行文字过密)
//  2. 状态色克制: 健康态不着色, 只有真问题才亮色
//  3. 卡内层级 = 名字(13 semibold) > 描述(11 secondary, 2行) > 元信息(9 muted)
//  4. 悬停整卡抬升 + 展开 spring(damping 1.0), 临界阻尼无过冲

struct SkillsBoardView: View {
    @EnvironmentObject var vm: SkillsViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var popoverMode: Bool = false                      // popover: 不撑最小尺寸, 详情面板收窄
    @State private var detailItem: SkillItem? = nil     // 点击卡片 -> 右侧详情
    @State private var confirmDisable: String? = nil
    @State private var hovered: String? = nil
    @State private var newCategoryFor: SkillItem? = nil   // 触发"新建分类并移入"的 skill
    @State private var newCategoryName = ""
    @State private var renamingCategory: String? = nil    // 正在重命名的分类
    @State private var renameText = ""
    @State private var tearProgress: CGFloat = 0          // popover 下拉撕出窗口的进度 0~1
    /// 归档组默认折叠 —— 它有十几个成员却几乎不看, 展开会把常用分类挤到屏幕外
    @State private var archiveExpanded = false
    /// 顶部 Tab: Skills 之外再暴露 MCP 与 Hooks —— 它们同样影响每次对话行为, 却一直不可见
    @State private var boardTab: BoardTab = .skills
    @StateObject private var envVM = AgentEnvViewModel()

    enum BoardTab: String, CaseIterable {
        case skills = "Skills", mcp = "MCP", hooks = "Hooks"
        case agents = "Agents", memory = "Memory"
    }

    static let archiveSection = "已归档 / 分享版"

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: popoverMode ? 208 : 236,
                            maximum: popoverMode ? 300 : 340), spacing: 10)]
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 chrome: 半透明材质带 —— 文字不能裸贴在桌面壁纸上, 否则对比度不可控
            VStack(spacing: 0) {
                header
                if boardTab == .skills { toolbar }
            }
            .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.75))
            Divider().opacity(0.4)
            switch boardTab {
            case .skills:
                HStack(spacing: 0) {
                    gridArea
                    if let d = detailItem {
                        Divider().opacity(0.4)
                        detailPane(d)
                            .frame(width: popoverMode ? 262 : 300)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            case .mcp:
                McpBoardView(env: envVM)
            case .hooks:
                HooksBoardView(env: envVM)
            case .agents:
                AgentsBoardView(env: envVM)
            case .memory:
                MemoryBoardView(env: envVM)
            }
        }
        .frame(minWidth: popoverMode ? 0 : 700, minHeight: popoverMode ? 0 : 540)
        .focusEffectDisabled()
        .background(ThemeBackground().environmentObject(theme).environmentObject(ThemeManager.shared))
        .onAppear {
            if vm.items.isEmpty { vm.loadOverrides(); vm.scan() }
            if envVM.mcps.isEmpty { envVM.scan() }
        }
        // 新建分类并把该 skill 移入
        .alert("新建分类", isPresented: Binding(
            get: { newCategoryFor != nil },
            set: { if !$0 { newCategoryFor = nil } })) {
            TextField("分类名", text: $newCategoryName)
            Button("创建并移入") {
                if let it = newCategoryFor {
                    let n = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !n.isEmpty { vm.addCategory(n); vm.assign(it, to: n) }
                }
                newCategoryFor = nil
            }
            Button("取消", role: .cancel) { newCategoryFor = nil }
        } message: {
            Text(newCategoryFor.map { "把「\($0.dir)」移入新分类" } ?? "")
        }
        // 重命名分类
        .alert("重命名分类", isPresented: Binding(
            get: { renamingCategory != nil },
            set: { if !$0 { renamingCategory = nil } })) {
            TextField("新名称", text: $renameText)
            Button("确定") {
                if let old = renamingCategory { vm.renameCategory(old, to: renameText) }
                renamingCategory = nil
            }
            Button("取消", role: .cancel) { renamingCategory = nil }
        } message: {
            Text(renamingCategory.map { "「\($0)」下的所有 skill 会一起改到新名称" } ?? "")
        }
    }

    private var gridArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if vm.loading && vm.items.isEmpty { loadingState }
                ForEach(grouped, id: \.0) { g in
                    let isArchive = g.0 == Self.archiveSection
                    // 用筛选条主动筛到归档/分享时视为"就是要看它", 强制展开,
                    // 否则会出现"点了分类却一片空白"
                    let forced = SkillsViewModel.tailCategories.contains(vm.categoryFilter)
                    if isArchive {
                        collapsibleHeader(g.0, g.1.count)
                    } else {
                        sectionHeader(g.0, g.1.count)
                    }
                    if !isArchive || archiveExpanded || forced {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(g.1) { item in card(item) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 16)
                    }
                }
                if !vm.loading && vm.filtered.isEmpty && !vm.items.isEmpty { emptyState }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var grouped: [(String, [SkillItem])] {
        let items = vm.filtered
        var order: [String] = []
        var map: [String: [SkillItem]] = [:]
        let bad = items.filter { $0.health != .healthy }
        if !bad.isEmpty { order.append("需要处理"); map["需要处理"] = bad }
        // 归档与分享合并成一组: 二者都是"移出使用范围、留档备查", 没必要分两栏各占一屏
        var archived: [SkillItem] = []
        for i in items where i.health == .healthy {
            if SkillsViewModel.tailCategories.contains(i.category) {
                archived.append(i)
                continue
            }
            if map[i.category] == nil { order.append(i.category) }
            map[i.category, default: []].append(i)
        }
        var result = order.map { ($0, map[$0] ?? []) }
        if !archived.isEmpty {
            // 分享版排在归档前面(数量少、更可能要找)，其余按名字稳定排序
            archived.sort {
                let ra = $0.origin == "分享版" ? 0 : 1
                let rb = $1.origin == "分享版" ? 0 : 1
                return ra != rb ? ra < rb : $0.dir < $1.dir
            }
            result.append((Self.archiveSection, archived))
        }
        return result
    }

    // MARK: 卡片

    private func card(_ item: SkillItem) -> some View {
        let isHover = hovered == item.dir
        let isSel = detailItem?.dir == item.dir
        let accent = accentColor(item)
        return VStack(alignment: .leading, spacing: 6) {
            // 标题行
            HStack(spacing: 6) {
                statusDot(item)
                Text(item.dir)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(item.enabled ? theme.current.textPrimary : theme.current.textMuted)
                    .strikethrough(!item.enabled, color: theme.current.textMuted.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                if item.isHub { miniBadge("\(item.refCount)", "link", Color(hex: "#8b6fb8")) }
                if !item.externalRefs.isEmpty {
                    miniBadge(nil, "clock.arrow.circlepath", Color(hex: "#c8863c"))
                }
                if !item.missingCLI.isEmpty {
                    miniBadge(nil, "exclamationmark.triangle.fill", Color(hex: "#d94f4f"))
                }
                // 只给"未验证"打标 —— 已验证是期望状态, 满屏打勾等于没有信息量
                if item.verify == "未验证" && item.origin == "启用" {
                    miniBadge(nil, "questionmark.circle", Color(hex: "#8a8f98"))
                        .help("已安装但尚未在真实任务中用过")
                }
            }

            // 描述: 固定 2 行, 卡片等高
            Text(item.desc.isEmpty ? "（无描述）" : item.desc)
                .font(fm.font(11))
                .lineSpacing(2.5)
                .foregroundStyle(theme.current.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                .multilineTextAlignment(.leading)

            // 问题优先, 无问题显示元信息
            if let first = item.problems.first ?? item.hints.first {
                HStack(spacing: 4) {
                    Image(systemName: item.problems.isEmpty ? "lightbulb" : "xmark.octagon.fill")
                        .font(.system(size: 8))
                    Text(first).font(.system(size: 10)).lineLimit(1)
                }
                .foregroundStyle(item.problems.isEmpty ? Color(hex: "#c8863c") : Color(hex: "#d94f4f"))
            } else {
                HStack(spacing: 8) {
                    if let m = item.modified {
                        Text(Self.dateStr(m)).font(.system(size: 9, design: .monospaced))
                    }
                    Text("\(item.fileCount) 文件").font(.system(size: 9))
                    if !item.enabled {
                        Text("已归档").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.current.textMuted)
                    }
                    Spacer()
                }
                .foregroundStyle(theme.current.textMuted)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(cardFill(item, isHover: isHover, isSel: isSel))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(isSel ? theme.current.accentPrimary.opacity(0.45)
                        : (item.health == .broken ? accent.opacity(0.3)
                           : theme.current.separator.opacity(isHover ? 0.5 : 0.22)),
                        lineWidth: isSel ? 1.4 : 1)
        )
        .shadow(color: .black.opacity(isHover ? 0.07 : 0), radius: isHover ? 7 : 0, y: isHover ? 2 : 0)
        .offset(y: isHover ? -2 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isHover)
        .animation(.spring(response: 0.3, dampingFraction: 1.0), value: isSel)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.32, dampingFraction: 1.0)) {
                detailItem = isSel ? nil : item
            }
        }
        .onHover { hovered = $0 ? item.dir : (hovered == item.dir ? nil : hovered) }
        .contextMenu { categoryMenu(item) }
    }

    /// 右键菜单: 改分类。仅写外置覆盖表, 不动 SKILL.md, 因此不影响 skill 实际可用性。
    @ViewBuilder
    private func categoryMenu(_ item: SkillItem) -> some View {
        if item.origin == "启用" {
            Text("当前: \(item.category)")
            Divider()
            ForEach(vm.assignableCategories, id: \.self) { c in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                        vm.assign(item, to: c)
                    }
                } label: {
                    // 勾选当前分类, 避免误点重复设置
                    Text(c == item.category ? "✓ \(c)" : "   \(c)")
                }
            }
            Divider()
            Button("新建分类并移入…") { newCategoryFor = item; newCategoryName = "" }
            if vm.overrides[item.dir] != nil {
                Button("恢复默认分类") { vm.resetCategory(item) }
            }
        } else {
            Text("\(item.origin) 的 skill 不参与分类调整")
        }
        Divider()
        Button("打开 SKILL.md") { vm.openSkillMD(item) }
        Button("在 Finder 中显示") { vm.revealInFinder(item) }
    }

    /// 卡片底色。半透明主题(毛玻璃)下不再叠 0.82 折扣 —— 那会让白底掉到 0.41,
    /// 桌面壁纸的彩色直接透到文字后面, 对比度崩掉。
    /// 选中/异常态只做描边和角标区分, 底色始终保持同一厚度。
    private func cardFill(_ item: SkillItem, isHover: Bool, isSel: Bool) -> Color {
        let base = theme.current.cardFillOpacity
        // 厚底(>=0.85)才允许 hover 时略微减淡; 薄底主题一律用满
        let op = base >= 0.85 ? base * (isHover ? 1.0 : 0.94) : base
        if isSel { return theme.current.cardFill.opacity(min(op + 0.05, 1.0)) }
        return theme.current.cardFill.opacity(op)
    }

    private func accentColor(_ item: SkillItem) -> Color {
        switch item.health {
        case .broken: return Color(hex: "#d94f4f")
        case .warn:   return Color(hex: "#c8863c")
        case .healthy: return Color(hex: "#5aa86c")
        }
    }

    private func statusDot(_ item: SkillItem) -> some View {
        Group {
            switch item.health {
            case .broken:
                Circle().fill(Color(hex: "#d94f4f")).frame(width: 6, height: 6)
            case .warn:
                Circle().stroke(Color(hex: "#c8863c"), lineWidth: 1.4).frame(width: 6, height: 6)
            case .healthy:
                Circle().fill(theme.current.textMuted.opacity(item.enabled ? 0.3 : 0.15))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 7)
    }

    private func miniBadge(_ text: String?, _ icon: String, _ c: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            if let t = text { Text(t).font(.system(size: 9, weight: .medium, design: .monospaced)) }
        }
        .foregroundStyle(c)
        .padding(.horizontal, 4).padding(.vertical, 1.5)
        .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.12)))
    }

    // MARK: 右侧详情

    private func detailPane(_ item: SkillItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    statusDot(item)
                    Text(item.dir)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.current.textPrimary)
                        .textSelection(.enabled)
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.28, dampingFraction: 1.0)) { detailItem = nil }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.current.textMuted)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(theme.current.textTertiary.opacity(0.1)))
                    }
                    .buttonStyle(SmoothButtonStyle(scale: 0.94, hoverScale: 1.0))
                }

                HStack(spacing: 6) {
                    tag(item.category, theme.current.textMuted)
                    if !item.verify.isEmpty {
                        tag(item.verify, item.verify == "已验证" ? Color(hex: "#5aa86c")
                                       : item.verify == "未验证" ? Color(hex: "#8a8f98")
                                       : Color(hex: "#c8863c"))
                    }
                    if !item.hardRefs.isEmpty {
                        tag("\(item.hardRefs.count) 个硬依赖", Color(hex: "#8b6fb8"))
                    }
                    if item.mentionCount > 0 {
                        tag("\(item.mentionCount) 处提及", Color(hex: "#8b6fb8").opacity(0.65))
                    }
                    if !item.enabled { tag(item.origin, theme.current.textMuted) }
                    Spacer()
                }

                if !item.desc.isEmpty {
                    Text(item.desc)
                        .font(fm.font(12))
                        .lineSpacing(4)
                        .foregroundStyle(theme.current.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !item.problems.isEmpty || !item.hints.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(item.problems, id: \.self) { p in
                            issueLine(p, "xmark.octagon.fill", Color(hex: "#d94f4f"))
                        }
                        ForEach(item.hints, id: \.self) { h in
                            issueLine(h, "lightbulb", Color(hex: "#c8863c"))
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(theme.current.textTertiary.opacity(0.06)))
                }

                if !item.externalRefs.isEmpty {
                    issueLine("被" + item.externalRefs.joined(separator: "、") + "引用",
                              "clock.arrow.circlepath", Color(hex: "#c8863c"))
                }

                HStack(spacing: 12) {
                    if let m = item.modified { meta("更新", Self.dateStr(m)) }
                    meta("文件", "\(item.fileCount)")
                    Spacer()
                }

                Divider().opacity(0.4)

                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        flatBtn("SKILL.md", "doc.text") { vm.openSkillMD(item) }
                        flatBtn("Finder", "folder") { vm.revealInFinder(item) }
                        Spacer()
                    }
                    HStack {
                        Spacer()
                        if item.enabled { disableControl(item) }
                        else { flatBtn("启用", "power", tint: Color(hex: "#5aa86c")) { vm.enable(item) } }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.5))
    }

    private func tag(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10))
            .foregroundStyle(c)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(c.opacity(0.11)))
    }

    // MARK: 头部 / 工具条

    private var header: some View {
        let s = vm.stats
        return HStack(alignment: .firstTextBaseline, spacing: 9) {
            // Tab 切换: Skills / MCP / Hooks。当前 Tab 用主题渐变高亮 + 数量角标
            ForEach(BoardTab.allCases, id: \.self) { t in
                let n: Int = t == .skills ? s.total
                           : t == .mcp ? envVM.mcps.count
                           : t == .hooks ? envVM.hooks.count
                           : t == .agents ? envVM.agents.count : envVM.memTotal
                Button(action: { withAnimation(.spring(response: 0.25, dampingFraction: 1.0)) { boardTab = t } }) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if boardTab == t {
                            Text(t.rawValue).font(fm.font(19))
                                .foregroundStyle(theme.current.accentGradient)
                        } else {
                            Text(t.rawValue).font(fm.font(14))
                                .foregroundStyle(theme.current.textMuted)
                        }
                        Text("\(n)").font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.current.textMuted.opacity(boardTab == t ? 1 : 0.6))
                        // Hooks 有失效脚本时, 未选中也要有红点提醒
                        if t == .hooks && envVM.brokenHooks > 0 {
                            Circle().fill(Color(hex: "#d94f4f")).frame(width: 5, height: 5)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if boardTab == .skills {
                if s.broken > 0 { statChip("\(s.broken)", "加载不到", Color(hex: "#d94f4f")) }
                if s.warn > 0 { statChip("\(s.warn)", "待优化", Color(hex: "#c8863c")) }
                if s.broken == 0 && s.warn == 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        Text("全部就绪").font(fm.font(11))
                    }
                    .foregroundStyle(Color(hex: "#5aa86c"))
                }
                if s.disabled > 0 {
                    Text("\(s.disabled) 已归档").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                }
            } else if boardTab == .hooks && envVM.brokenHooks > 0 {
                statChip("\(envVM.brokenHooks)", "脚本失效", Color(hex: "#d94f4f"))
            }
            Button(action: { vm.scan(); envVM.scan() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.current.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(theme.current.textTertiary.opacity(0.08)))
                    .rotationEffect(.degrees(vm.loading ? 360 : 0))
                    .animation(vm.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                                          : .default, value: vm.loading)
            }
            .buttonStyle(SmoothButtonStyle())
            .disabled(vm.loading)
            .help("重新扫描")
        }
        .padding(.leading, popoverMode ? 16 : 84).padding(.trailing, 16)
        .padding(.top, popoverMode ? 12 : 8).padding(.bottom, 10)
        .contentShape(Rectangle())
        // popover 顶部往下拖 => 撕成独立窗口。阈值 32pt: 小于它的位移多半是误触/手抖,
        // 且只认向下(dy>0) —— 向上拖没有语义, 避免与内容滚动抢手势。
        .gesture(popoverMode
            ? DragGesture(minimumDistance: 12)
                .onChanged { g in
                    tearProgress = max(0, min(1, g.translation.height / 32))
                }
                .onEnded { g in
                    if g.translation.height > 32 {
                        NotificationCenter.default.post(name: .init("tearOffSkillsBoard"), object: nil)
                    }
                    tearProgress = 0
                }
            : nil)
        // 拖拽中给出可见反馈: 顶部渐显一条提示, 让人知道"松手会变窗口"
        .overlay(alignment: .bottom) {
            if tearProgress > 0.05 {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.left.and.arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(tearProgress >= 1 ? "松手变为独立窗口" : "继续下拉…")
                        .font(fm.font(10))
                }
                .foregroundStyle(theme.current.accentPrimary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(theme.current.accentPrimary.opacity(0.12)))
                .opacity(Double(tearProgress))
            }
        }
    }

    private func statChip(_ n: String, _ label: String, _ c: Color) -> some View {
        HStack(spacing: 3) {
            Text(n).font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(label).font(fm.font(11))
        }
        .foregroundStyle(c)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(c.opacity(0.1)))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.current.textMuted)
                TextField("搜索", text: $vm.search).textFieldStyle(.plain).font(fm.font(12))
                if !vm.search.isEmpty {
                    Button(action: { vm.search = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                            .foregroundStyle(theme.current.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(width: 160)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.textTertiary.opacity(0.07)))

            // 分类全平铺后可能超出窗口宽度 —— 套横向滚动, 保证 chip 不被压缩变形
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 3) {
                ForEach(vm.visibleCategories, id: \.0) { c in catChip(c.0, c.1) }
                if !vm.hiddenCategories.isEmpty {
                    Menu {
                        ForEach(vm.hiddenCategories, id: \.0) { c in
                            Button("\(c.0) (\(c.1))") { vm.categoryFilter = c.0 }
                        }
                    } label: {
                        Text("更多").font(fm.font(11)).foregroundStyle(theme.current.textSecondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
              }
              .padding(.vertical, 1)   // 给 chip 的 hover 缩放留一点余量
            }
            Spacer(minLength: 2)
            Toggle(isOn: $vm.onlyProblems) { Text("仅问题").font(fm.font(11)) }
                .toggleStyle(.checkbox)
                .foregroundStyle(theme.current.textSecondary)
        }
        .padding(.horizontal, 16).padding(.bottom, 9)
    }

    private func catChip(_ name: String, _ n: Int) -> some View {
        let sel = vm.categoryFilter == name
        return Button(action: { vm.categoryFilter = name }) {
            Text(name).font(fm.font(11))
                .foregroundStyle(sel ? theme.current.accentPrimary : theme.current.textSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(sel ? theme.current.accentPrimary.opacity(0.12) : Color.clear))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.96, hoverScale: 1.0))
    }

    private func sectionHeader(_ title: String, _ n: Int) -> some View {
        let urgent = title == "需要处理"
        return HStack(spacing: 6) {
            // 分组标题压在背景图上, 需要底衬 + 加重字重才读得出
            HStack(spacing: 5) {
                Text(title).font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(urgent ? Color(hex: "#c43a3a") : theme.current.textSecondary)
                Text("\(n)").font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.current.textTertiary)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.7)))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
        .contentShape(Rectangle())
        .contextMenu { sectionMenu(title) }
    }

    /// 归档组标题: 整行可点, 箭头随状态旋转 —— 折叠态也要让人一眼看出"里面有东西"
    private func collapsibleHeader(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.current.textMuted.opacity(0.7))
                .rotationEffect(.degrees(archiveExpanded ? 90 : 0))
            Text(title)
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.current.textMuted)
            Text("\(n)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.current.textMuted.opacity(0.7))
            if !archiveExpanded {
                Text("已折叠").font(fm.font(9))
                    .foregroundStyle(theme.current.textMuted.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                archiveExpanded.toggle()
            }
        }
    }

    /// 分组标题右键: 就地改名/删除分类, 免得再去别处找入口。
    /// 删除只清覆盖映射 —— 成员回落到内置规则判定的分类, skill 文件一律不动。
    @ViewBuilder
    private func sectionMenu(_ title: String) -> some View {
        if title == "需要处理" || SkillsViewModel.tailCategories.contains(title) {
            Text("「\(title)」是系统分组, 不可改名或删除")
        } else {
            Button("重命名「\(title)」…") { renamingCategory = title; renameText = title }
            Button("删除「\(title)」") { vm.deleteCategory(title) }
            Divider()
            Text("删除仅解除分类归属, 不会删除任何 skill")
        }
    }

    // MARK: 复用组件

    private func issueLine(_ t: String, _ icon: String, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon).font(.system(size: 9)).padding(.top, 1.5)
            Text(t).font(fm.font(11)).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(c)
    }

    private func meta(_ k: String, _ v: String) -> some View {
        HStack(spacing: 3) {
            Text(k).font(.system(size: 9)).foregroundStyle(theme.current.textMuted.opacity(0.7))
            Text(v).font(.system(size: 10, design: .monospaced)).foregroundStyle(theme.current.textMuted)
        }
    }

    private func flatBtn(_ t: String, _ icon: String,
                         tint: Color? = nil, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 3.5) {
                Image(systemName: icon).font(.system(size: 9, weight: .medium))
                Text(t).font(fm.font(11))
            }
            .foregroundStyle(tint ?? theme.current.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill((tint ?? theme.current.textTertiary).opacity(0.1)))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.97, hoverScale: 1.0))
    }

    private func disableControl(_ item: SkillItem) -> some View {
        let pending = confirmDisable == item.dir
        return VStack(alignment: .trailing, spacing: 4) {
            if pending && item.riskyToDisable {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9)).padding(.top, 1)
                    Text(riskText(item)).font(fm.font(10)).lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .foregroundStyle(Color(hex: "#d94f4f"))
            }
            Button(action: {
                if pending { vm.disable(item); confirmDisable = nil }
                else {
                    confirmDisable = item.dir
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        if confirmDisable == item.dir { confirmDisable = nil }
                    }
                }
            }) {
                Text(pending ? "确认归档" : "归档")
                    .font(fm.font(11))
                    .foregroundStyle(pending ? .white : Color(hex: "#d94f4f").opacity(0.85))
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(pending ? Color(hex: "#d94f4f") : Color(hex: "#d94f4f").opacity(0.1)))
            }
            .buttonStyle(SmoothButtonStyle(scale: 0.97, hoverScale: 1.0))
        }
        .animation(.spring(response: 0.28, dampingFraction: 1.0), value: pending)
    }

    private func riskText(_ item: SkillItem) -> String {
        var p: [String] = []
        if !item.externalRefs.isEmpty { p.append(item.externalRefs.joined(separator: "/") + "会静默失败") }
        if !item.hardRefs.isEmpty {
            p.append(item.hardRefs.joined(separator: "/") + " 硬依赖它的路径")
        }
        return p.joined(separator: " · ")
    }

    private var loadingState: some View {
        VStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("扫描技能目录…").font(fm.font(12)).foregroundStyle(theme.current.textMuted)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 20, weight: .light))
                .foregroundStyle(theme.current.textMuted.opacity(0.5))
            Text("没有匹配的技能").font(fm.font(12)).foregroundStyle(theme.current.textMuted)
        }
        .frame(maxWidth: .infinity).padding(.top, 50)
    }

    private static func dateStr(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
}

// MARK: - 窗口

final class SkillsBoardWindowController {
    static let shared = SkillsBoardWindowController()
    private var window: NSWindow?
    private var popover: NSPopover?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let vm = SkillsViewModel()

    /// 菜单栏入口: 图标正下方展开, 点外部/Esc 自动收起(与系统监控同一套模式)
    /// 高度给上限而非自适应 —— 自适应会让内容长到屏幕外, ScrollView 拿不到超出状态就滚不动
    func togglePopover(relativeTo button: NSStatusBarButton) {
        if let pop = popover, pop.isShown {
            closePopover()
            return
        }
        let screenH = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let popH = min(max(screenH * 0.72, 420), 860)
        let popW: CGFloat = 660    // 网格(2列) + 详情面板 262 都能容下

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let host = NSHostingController(rootView:
            SkillsBoardView(popoverMode: true)
                .environmentObject(vm)
                .environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared)
                .frame(width: popW, height: popH))
        pop.contentSize = NSSize(width: popW, height: popH)
        pop.contentViewController = host
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
        vm.scan()

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, let p = self.popover, p.isShown else { return }
            DispatchQueue.main.async { self.closePopover() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53, let p = self?.popover, p.isShown {
                self?.closePopover()
                return nil
            }
            return e
        }
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            self?.teardownMonitors()
        }
        installTearOffObserver()
    }

    /// 下拉撕出独立窗口: 复用同一个 vm, 搜索词/分类筛选/已展开的详情全部保留,
    /// 用户感知上就是"同一个面板换了个容器", 不是重新打开。
    private var tearObserver: Any?
    private func installTearOffObserver() {
        guard tearObserver == nil else { return }
        tearObserver = NotificationCenter.default.addObserver(
            forName: .init("tearOffSkillsBoard"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.closePopover()
            self.show()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
        popover = nil
        teardownMonitors()
    }

    private func teardownMonitors() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            vm.scan()
            return
        }
        let view = SkillsBoardView()
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Skills 看板"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 780, height: 620))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false
        // 原生毛玻璃需要窗口透明才能透出桌面壁纸
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        win.contentMinSize = NSSize(width: 620, height: 440)
        win.contentMaxSize = NSSize(width: 2600, height: 2200)
        win.setFrameAutosaveName("DBoardSkillsWindow")
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
