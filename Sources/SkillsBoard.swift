import SwiftUI
import AppKit
import Foundation

// MARK: - Skills 看板: 汇总 Codex / Agent 共享层 / Qoder CN / Claude 兼容资产
// Claude 旧 Skill 可逐项软链到 ~/.agents/skills 供 Codex 使用；看板将其单独折叠，
// 避免几十个兼容项淹没日常维护的原生 Skill。
// 禁用机制: 移到 ~/.claude/skills-disabled/ (彻底移出扫描范围, 可逆)
//   —— frontmatter 加 disabled 字段是假禁用(Qoder 不认这字段), 不采用

enum SkillHealth: Int, Comparable {
    case broken = 0     // Qoder 加载不到
    case warn = 1       // 能加载但有隐患
    case healthy = 2
    static func < (a: SkillHealth, b: SkillHealth) -> Bool { a.rawValue < b.rawValue }
}

struct SkillInstallation: Identifiable, Hashable {
    var id: String { source + "::" + path }
    var source: String
    var path: String
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
    var origin: String = "启用"      // 启用 / Claude 兼容 / 已归档 / 分享版
    var external: Bool = false     // 第三方插件(marketplace 安装), 描述由上游维护, 本地改动会被覆盖
    var manualOnly: Bool = false   // frontmatter 声明 disable-model-invocation: 只能手动唤起
    var hardRefs: [String] = []    // 硬依赖我的 skill(写死了我的路径, 禁用即崩)
    var mentionCount: Int = 0      // 仅正文提及我的次数(参考值, 不作风险依据)
    var externalRefs: [String] = [] // 被 crontab/LaunchAgent 引用
    var modified: Date? = nil
    var category: String = "其他"
    var fileCount: Int = 0
    var sources: [String] = []       // Codex / 共享 / Claude 兼容 / Qoder CN / 插件 / 遗留
    var installPaths: [String] = []  // 同名 skill 的全部安装位置
    var installations: [SkillInstallation] = []
    var definitionHash: Int = 0       // 本次扫描内用于识别同名异定义，不作持久化身份
    var divergentDefinitions = false  // 同名 skill 的 SKILL.md 内容不一致，需按运行时分别治理
    var readOnly: Bool = false       // 插件和遗留资产只展示，不移动目录
    /// 已在 ~/.codex/config.toml 的 [[skills.config]] 里 enabled=false —— 真禁用：
    /// 文件留在原地，但 Codex 不加载。对 readOnly 的 Codex/插件资产也能用，
    /// 且能扛住同步工具把文件重新生成回来（归档式移动会被重建，这个不会）。
    var codexDisabled: Bool = false
    var id: String { dir }

    var refCount: Int { hardRefs.count }
    var isHub: Bool { hardRefs.count >= 2 }
    var riskyToDisable: Bool { !externalRefs.isEmpty || !hardRefs.isEmpty }
    var duplicateCount: Int { max(0, installations.count - 1) }
}

final class SkillsViewModel: ObservableObject {
    @Published var items: [SkillItem] = []
    @Published var loading = false
    @Published var search = ""
    @Published var categoryFilter = "全部"
    @Published var onlyProblems = false
    @Published var lastScan: Date? = nil
    @Published var actionMsg = ""
    /// 默认只看日常维护的原生 Skill；兼容层、插件缓存、系统内置、遗留和归档进入资产库。
    @Published var showAssetLibrary = false
    @Published var assetLimit = 40

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

    // MARK: - Codex 真禁用（写 ~/.codex/config.toml，文件保留但 Codex 不加载）
    //
    // 与"归档"（移动目录）的区别：归档把文件移走，但养车卫士/鲁班这类同步工具
    // 会在下次启动时把文件重新生成回来，归档就失效了。真禁用只往 config.toml
    // 写一条 [[skills.config]] enabled=false —— 同步工具不碰 config.toml，
    // 文件即使被重建，Codex 仍按规则不加载它。对 readOnly 的插件资产同样有效。

    static let codexConfigFile = NSHomeDirectory() + "/.codex/config.toml"
    /// config.toml 中所有 enabled=false 的 skills.config name 集合。
    @Published var codexDisabledNames: Set<String> = []

    func loadCodexDisabled() {
        guard let txt = try? String(contentsOfFile: Self.codexConfigFile, encoding: .utf8) else {
            codexDisabledNames = []
            return
        }
        codexDisabledNames = Self.parseDisabledNames(txt)
    }

    /// 切换某 skill 在 Codex 的启用状态。按 frontmatter name 匹配（与目录名解耦）。
    func setCodexDisabled(_ item: SkillItem, _ disabled: Bool) {
        let name = item.name.isEmpty ? item.dir : item.name
        var txt = (try? String(contentsOfFile: Self.codexConfigFile, encoding: .utf8)) ?? ""
        if let flipped = Self.flipEnabled(in: txt, name: name, to: !disabled) {
            txt = flipped
        } else if disabled {
            let block = "[[skills.config]]\nname = \"\(name)\"\nenabled = false\n"
            txt = txt.hasSuffix("\n") ? txt + "\n" + block : txt + "\n\n" + block
        } else {
            actionMsg = "\(name) 本就处于启用状态"
            return
        }
        do {
            try txt.write(to: URL(fileURLWithPath: Self.codexConfigFile),
                          atomically: true, encoding: .utf8)
        } catch {
            actionMsg = "写入 config.toml 失败: \(error.localizedDescription)"
            return
        }
        loadCodexDisabled()
        for idx in items.indices
        where (items[idx].name.isEmpty ? items[idx].dir : items[idx].name) == name {
            items[idx].codexDisabled = disabled
        }
        actionMsg = disabled
            ? "已在 Codex 配置禁用 \(name)（下次新会话生效）"
            : "已恢复 \(name)"
    }

    /// 解析 config.toml，取出所有 enabled=false 的 [[skills.config]] name。
    private static func parseDisabledNames(_ text: String) -> Set<String> {
        var names = Set<String>()
        for block in text.components(separatedBy: "[[skills.config]]").dropFirst() {
            var name: String? = nil
            var enabled = true
            for raw in block.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }   // 下一个 section，本块结束
                if let n = skillNameIn(line) { name = n }
                if line.range(of: #"^enabled\s*=\s*false\b"#, options: .regularExpression) != nil { enabled = false }
                if line.range(of: #"^enabled\s*=\s*true\b"#, options: .regularExpression) != nil { enabled = true }
            }
            if let n = name, !enabled { names.insert(n) }
        }
        return names
    }

    /// 翻转某 name 对应块的 enabled；找不到该块返回 nil（调用方决定是否新增）。
    private static func flipEnabled(in text: String, name: String, to enabled: Bool) -> String? {
        let parts = text.components(separatedBy: "[[skills.config]]")
        guard parts.count > 1 else { return nil }
        var out = parts[0]
        var found = false
        for block in parts.dropFirst() {
            var lines = block.components(separatedBy: "\n")
            var blockName: String? = nil
            var endIdx = lines.count
            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { endIdx = i; break }
                if let n = skillNameIn(line) { blockName = n }
            }
            if blockName == name {
                found = true
                for i in 0..<endIdx where lines[i].trimmingCharacters(in: .whitespaces)
                    .range(of: #"^enabled\s*="#, options: .regularExpression) != nil {
                    lines[i] = "enabled = \(enabled)"
                }
            }
            out += "[[skills.config]]" + lines.joined(separator: "\n")
        }
        return found ? out : nil
    }

    /// 从 `name = "xxx"` 这一行取出 xxx。
    private static func skillNameIn(_ line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("name"), let eq = t.firstIndex(of: "=") else { return nil }
        let rhs = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard rhs.count >= 2, rhs.first == "\"", rhs.last == "\"" else { return nil }
        return String(rhs.dropFirst().dropLast())
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
    static let codexRoot = NSHomeDirectory() + "/.codex/skills"
    static let agentsRoot = NSHomeDirectory() + "/.agents/skills"
    static let qoderCNRoot = NSHomeDirectory() + "/.qoder-cn/skills"
    static let qoderCNLubanRoot = NSHomeDirectory() + "/.qoder-cn/luban"

    /// 非启用态的分类(已归档/分享版)不是日常关注对象, 固定排在最后,
    /// 否则会因数量大而挤到筛选条前排, 把常用业务分类推到"更多"里。
    static let tailCategories = ["分享版", "已归档", "Claude 兼容", "Claude 遗留"]

    /// 筛选条固定展示顺序 —— 之前按数量降序, 每次扫描数量一变顺序就重排, 视觉上一直在跳。
    /// 顺序按"日常使用频度"手工排定, 与数量无关。
    static let categoryOrder = ["TMYC", "Luban", "钉钉", "开发工具", "开发方法论",
                                "设计/动画", "浏览器", "信息获取", "知识库",
                                "个人效率", "元技能", "其他"]

    private func isCurrentManaged(_ item: SkillItem) -> Bool {
        item.sources.contains { ["Codex", "共享", "Qoder CN"].contains($0) }
            && !item.sources.contains("Claude 兼容")
    }

    var currentItems: [SkillItem] { items.filter(isCurrentManaged) }
    var assetItems: [SkillItem] { items.filter { !isCurrentManaged($0) } }
    var scopedItems: [SkillItem] { showAssetLibrary ? assetItems : currentItems }
    var assetTotal: Int { assetItems.count }
    var canLoadMoreAssets: Bool { showAssetLibrary && assetLimit < assetItems.count }

    func switchScope(assetLibrary: Bool) {
        showAssetLibrary = assetLibrary
        categoryFilter = "全部"
        onlyProblems = false
        assetLimit = 40
    }

    func loadMoreAssets() { assetLimit += 40 }

    var categories: [(String, Int)] {
        var c: [String: Int] = [:]
        for i in scopedItems { c[i.category, default: 0] += 1 }
        func rank(_ k: String) -> Int {
            if let i = Self.categoryOrder.firstIndex(of: k) { return i }
            if let i = Self.tailCategories.firstIndex(of: k) { return 900 + i }  // 归档/分享垫底
            return 500                                                          // 自定义分类居中
        }
        let sorted = c.sorted { a, b in
            let (ra, rb) = (rank(a.key), rank(b.key))
            return ra != rb ? ra < rb : a.key < b.key   // 同档按名字, 保证稳定
        }
        return [("全部", scopedItems.count)] + sorted.map { ($0.key, $0.value) }
    }

    /// 只有归档/分享收进"更多", 其余全部平铺 —— 免得常用分类被折叠进下拉
    var visibleCategories: [(String, Int)] {
        categories.filter { !Self.tailCategories.contains($0.0) }
    }
    var hiddenCategories: [(String, Int)] {
        categories.filter { Self.tailCategories.contains($0.0) }
    }

    var filtered: [SkillItem] {
        let result = scopedItems.filter { i in
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
        return showAssetLibrary ? Array(result.prefix(assetLimit)) : result
    }

    var stats: (total: Int, healthy: Int, warn: Int, broken: Int, disabled: Int) {
        let visible = currentItems
        return (visible.count,
         visible.filter { $0.health == .healthy }.count,
         visible.filter { $0.health == .warn }.count,
         visible.filter { $0.health == .broken }.count,
         assetItems.filter { $0.origin == "已归档" }.count)
    }

    var duplicateStats: (replicas: Int, divergent: Int) {
        (currentItems.filter { $0.duplicateCount > 0 }.count,
         currentItems.filter { $0.divergentDefinitions }.count)
    }

    func scan() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performScan()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadCodexDisabled()
                // 覆盖表只作用于启用中的 skill; 归档/分享/禁用保持来源分类不被改写
                self.items = result.map { it -> SkillItem in
                    var m = it
                    let idName = m.name.isEmpty ? m.dir : m.name
                    m.codexDisabled = self.codexDisabledNames.contains(idName)
                    if m.origin == "启用", let c = self.overrides[m.dir] { m.category = c }
                    return m
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

        // ⏱ 临时计时埋点（定位慢的根因后可删）
        let __t0 = Date(); var __marks: [(String, Double)] = []
        func __mark(_ s: String) { __marks.append((s, Date().timeIntervalSince(__t0))) }

        // 预热命令缓存：把 7 个候选命令的存在性一次性查完（单次登录 shell），
        // 避免每个 skill 各自触发一次 `/bin/zsh -lic`（每次 0.5~1.5s，是首扫最大开销）。
        warmCliCache()
        // 第三方插件 skill 名集合：一次性遍历 plugins/cache，替代逐 skill 重复遍历整棵树。
        let externalNames = Self.externalPluginSkillNames()
        __mark("setup(warmCli+extNames)")

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

        // 当前运行时优先；同名项稍后合并。~/.qoder/skills 是 Claude 的符号链接，不扫描。
        var dirs: [(String, String, Bool, String, Bool)] = [] // dir/path/enabled/source/readOnly
        func addRoot(_ base: String, source: String, enabled: Bool = true, readOnly: Bool = false) {
            guard let ds = try? fm.contentsOfDirectory(atPath: base) else { return }
            for d in ds where !d.hasPrefix(".") && isDir(base + "/" + d) {
                let path = base + "/" + d
                // ~/.agents/skills 中指回 ~/.claude/skills 的单项软链确实会被 Codex 加载，
                // 但属于迁移兼容层，不应与少量原生共享 Skill 混在首页平铺。
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                let actualSource = base == agentsRoot && resolved.hasPrefix(root + "/")
                    ? "Claude 兼容" : source
                dirs.append((d, path, enabled, actualSource, readOnly))
            }
        }
        func addNestedSkills(_ base: String, source: String) {
            guard let walk = fm.enumerator(at: URL(fileURLWithPath: base),
                                           includingPropertiesForKeys: [.isDirectoryKey],
                                           options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for case let url as URL in walk where url.lastPathComponent == "SKILL.md" {
                let dirURL = url.deletingLastPathComponent()
                dirs.append((dirURL.lastPathComponent, dirURL.path, true, source, true))
            }
        }
        addRoot(codexRoot, source: "Codex", readOnly: true)
        addRoot(agentsRoot, source: "共享", readOnly: true)
        addRoot(qoderCNRoot, source: "Qoder CN", readOnly: true)
        addNestedSkills(codexRoot + "/.system", source: "Codex 系统")
        addNestedSkills(NSHomeDirectory() + "/.codex/plugins/cache", source: "Codex 插件")
        // Qoder CN 企业插件（如 Luban）只扫最新版本: 旧版本目录是升级残留,
        // 内容与最新版几乎一致, 全扫只会给同名卡片制造重复安装噪音。
        if let plugins = try? fm.contentsOfDirectory(atPath: qoderCNLubanRoot) {
            if let latest = plugins.sorted(by: versionLess).last {
                addRoot(qoderCNLubanRoot + "/" + latest + "/skills",
                        source: "Qoder CN 插件", readOnly: true)
            }
        }
        // 旧 Claude 库只用于迁移对照，不再视为当前启用能力。
        addRoot(root, source: "Claude 遗留", enabled: false, readOnly: true)
        if let ds = try? fm.contentsOfDirectory(atPath: disabledRoot) {
            for d in ds where isDir(disabledRoot + "/" + d) {
                dirs.append((d, disabledRoot + "/" + d, false, "已归档", false))
            }
        }
        // 归档区 / 分享区同样纳入展示, 但都标记为未启用(不参与本机路由)
        for extraRoot in [archiveRoot, sharedRoot] {
            if let ds = try? fm.contentsOfDirectory(atPath: extraRoot) {
                for d in ds where isDir(extraRoot + "/" + d) {
                    dirs.append((d, extraRoot + "/" + d, false,
                                 extraRoot == sharedRoot ? "分享版" : "已归档", false))
                }
            }
        }

        // 第一轮: 解析元数据
        var texts: [String: String] = [:]
        for (d, p, en, source, readOnly) in dirs {
            var it = SkillItem(dir: d, path: p)
            it.enabled = en
            it.sources = [source]
            it.installPaths = [p]
            it.installations = [SkillInstallation(source: source, path: p)]
            it.readOnly = readOnly
            // skills-disabled 是历史遗留目录, 仍扫描以免漏掉, 但归口显示为"已归档"
            if p.hasPrefix(Self.archiveRoot) || p.hasPrefix(Self.disabledRoot) {
                it.origin = "已归档"
            } else if p.hasPrefix(Self.sharedRoot) {
                it.origin = "分享版"
            } else if source == "Claude 兼容" {
                it.origin = "Claude 兼容"
            } else if source == "Claude 遗留" {
                it.origin = "Claude 遗留"
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
                it.problems.append("缺少 SKILL.md, Agent 无法加载")
                }
                it.category = "其他"
                out.append(it)
                continue
            }
            // 同名多来源时，交叉引用只取优先级最高的首份定义，避免低优先级副本覆盖它。
            if texts[d] == nil { texts[d] = txt }
            it.definitionHash = txt.hashValue

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
                it.problems.append("frontmatter 缺 description, Agent 无法判断何时触发")
            }

            // 仅手动调用的 skill(disable-model-invocation)不参与"触发词"检查 ——
            // 它本就不该被自动唤起, 没触发词是设计意图而非缺陷。
            it.manualOnly = front.contains("disable-model-invocation: true")
            for v in ["已验证", "部分验证", "未验证"] where txt.contains("状态：**\(v)**") {
                it.verify = v
                break
            }
            it.external = externalNames.contains(d)

            // ===== 软性检查 =====
            // 第三方插件的 description 由上游维护, 本地改了会被插件更新覆盖, 不提示。
            if !it.desc.isEmpty && !it.external && it.origin == "启用" {
                if it.desc.count < 40 {
                    it.hints.append("description 仅 \(it.desc.count) 字, 过短会导致 Agent 匹配不准")
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

            // 同名合并：保留优先扫描到的当前版本，把安装位置与运行时来源汇总到一张卡。
            let identity = it.name.isEmpty ? d : it.name
            if let idx = out.firstIndex(where: { ($0.name.isEmpty ? $0.dir : $0.name) == identity }) {
                if !out[idx].sources.contains(source) { out[idx].sources.append(source) }
                // 指向同一实体目录的软链视为同一份副本: 只并入来源标签, 不计重复安装,
                // 否则多运行时软链布局(各运行时链到同一实体)会满屏 "+N" 重复徽章。
                let pReal = realPath(p)
                if !out[idx].installPaths.contains(where: { realPath($0) == pReal }) {
                    if !out[idx].installPaths.contains(p) { out[idx].installPaths.append(p) }
                    if !out[idx].installations.contains(SkillInstallation(source: source, path: p)) {
                        out[idx].installations.append(SkillInstallation(source: source, path: p))
                    }
                    if out[idx].definitionHash != it.definitionHash {
                        out[idx].divergentDefinitions = true
                        if !out[idx].hints.contains("同名 Skill 在不同来源的定义不一致；需按运行时分别确认路由结果") {
                            out[idx].hints.append("同名 Skill 在不同来源的定义不一致；需按运行时分别确认路由结果")
                        }
                    }
                }
            } else {
                out.append(it)
            }
        }
        __mark("readLoop")

        // 第二轮: 交叉引用 —— 分硬依赖 / 软提及两级
        // 旧实现用 txt.contains(other) 裸匹配, 导致 skill/open/canvas 这类
        // 普通英文词被算成几十次引用, isHub 与禁用风险判定全部失真。
        let allDirs = Set(out.map { $0.dir })
        var hardRefs: [String: [String]] = [:]   // 被依赖者 -> [依赖方]
        var mentions: [String: Int] = [:]
        // 关键提速: 旧实现对每对 (d, other) 都在整段 txt 上跑 String.contains,
        // 是 O(n² × 文本长度) 的 Unicode 扫描 —— 107 个 skill 实测要 10.7s。
        // 现在每段 txt 只扫一遍, 预先抽出三类 token 集合, 两两比对退化为 O(1) 查集合。
        var wordTokens: [String: Set<String>] = [:]   // 完整词 token -> 软提及判定
        var pathRefs: [String: Set<String>] = [:]     // "skills/xxx" 的 xxx -> 硬依赖判定
        var dirEnvRefs: [String: Set<String>] = [:]   // "XXX_DIR" 环境变量 -> 硬依赖判定
        for (d, txt) in texts {
            wordTokens[d] = Self.wordTokenSet(txt)
            pathRefs[d] = Set(Self.skillNames(in: txt))
            dirEnvRefs[d] = Self.dirEnvTokenSet(txt)
        }
        for (d, _) in texts {
            let words = wordTokens[d] ?? []
            let paths = pathRefs[d] ?? []
            let envs = dirEnvRefs[d] ?? []
            for other in allDirs where other != d {
                let envKey = other.replacingOccurrences(of: "-", with: "_").uppercased() + "_DIR"
                let hard = paths.contains(where: { $0 == other || $0.hasPrefix(other) })
                    || envs.contains(where: { $0.hasSuffix(envKey) })
                if hard {
                    hardRefs[other, default: []].append(d)
                } else if other.count >= 3, words.contains(other) {
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
        __mark("crossRef")
        let __total = Date().timeIntervalSince(__t0)
        let __txt = "total: \(String(format: "%.2f", __total))s\n" +
            __marks.map { "\($0.0): \(String(format: "%.2f", $0.1))s" }.joined(separator: "\n") +
            "\nskills: \(out.count)\n"
        try? __txt.write(toFile: "/tmp/dboard_scan_timing.txt", atomically: true, encoding: .utf8)
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

    /// 解析软链后的真实路径 —— 多个链接指向同一实体目录时视为同一份副本
    private static func realPath(_ p: String) -> String {
        URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }

    /// 点分数字版本号比较(1.1.9 < 1.1.10); 段非纯数字时退化为字符串比较
    private static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(separator: "."), pb = b.split(separator: ".")
        for i in 0..<max(pa.count, pb.count) {
            let sa = i < pa.count ? String(pa[i]) : "0"
            let sb = i < pb.count ? String(pb[i]) : "0"
            if let na = Int(sa), let nb = Int(sb) {
                if na != nb { return na < nb }
            } else if sa != sb { return sa < sb }
        }
        return false
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
    /// 需要探测是否安装的的外部命令清单（warmCliCache 与 missingCommands 共用）。
    private static let cliCandidates = ["dws", "qodercli", "px", "kubectl",
                                        "defuddle", "obsidian-cli", "gh"]

    private static func missingCommands(in txt: String) -> [String] {
        var missing: [String] = []
        for c in cliCandidates {
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

    /// 第三方插件 skill 名集合: 由 marketplace 安装、在 plugins/cache 下有副本 ——
    /// 其 description 属上游资产, 本地修改会在插件升级时丢失, 因此不做描述质量检查。
    /// 一次遍历整棵 cache 树收集所有 skill 名, 供本次扫描 O(1) 查询;
    /// 旧实现是"每个 skill 都重新遍历一遍整棵树", 是重复扫描的主要开销之一。
    private static func externalPluginSkillNames() -> Set<String> {
        let fm = FileManager.default
        let cacheRoot = NSHomeDirectory() + "/.claude/plugins/cache"
        var names = Set<String>()
        guard let walk = fm.enumerator(at: URL(fileURLWithPath: cacheRoot),
                                       includingPropertiesForKeys: [.isDirectoryKey],
                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return names }
        for case let url as URL in walk where url.lastPathComponent == "SKILL.md" {
            names.insert(url.deletingLastPathComponent().lastPathComponent)
        }
        return names
    }

    /// 预热命令存在性缓存。GUI App 继承 launchd 的最小 PATH, 直接 `command -v`
    /// 会把 brew / ~/.local/bin 里的命令误判为未安装, 故先看常见目录, 再用一次
    /// 登录 shell 批量兜底 —— 把原本"每个命令各起一次登录 shell"压成一次。
    /// 命令探测的磁盘缓存。登录 shell 探一次要 ~4s，用缓存把它压到最多 1 小时一次。
    private static let cliProbeFile = NSHomeDirectory() + "/.claude/skills-cli-probe.json"
    private static var cliCacheWarmed = false
    private struct CliProbeCache: Codable {
        var ts: TimeInterval
        var results: [String: Bool]
    }

    private static func warmCliCache() {
        guard !cliCacheWarmed else { return }
        cliCacheWarmed = true
        let home = NSHomeDirectory()
        let extraDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                         home + "/.local/bin", home + "/.qoderwork/bin",
                         home + "/.nvm/versions/node/v16.20.2/bin"]
        var toCheck: [String] = []
        for c in cliCandidates {
            if cliCache[c] != nil { continue }
            if extraDirs.contains(where: { FileManager.default.isExecutableFile(atPath: $0 + "/" + c) }) {
                cliCache[c] = true
            } else {
                toCheck.append(c)
            }
        }
        guard !toCheck.isEmpty else { return }
        // 缓存新鲜就直接读, 不起 shell; 过期才重新探测并回写。
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cliProbeFile)),
           let cache = try? JSONDecoder().decode(CliProbeCache.self, from: data),
           Date().timeIntervalSince1970 - cache.ts < 3600 {
            for c in toCheck { cliCache[c] = cache.results[c] ?? false }
            return
        }
        let script = "for c in " + toCheck.joined(separator: " ") +
            "; do command -v \"$c\" >/dev/null 2>&1 && echo \"Y $c\" || echo \"N $c\"; done"
        let out = runCmd("/bin/zsh", ["-lic", script])
        var results: [String: Bool] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 2 { results[String(parts[1])] = (parts[0] == "Y") }
        }
        for (k, v) in results { cliCache[k] = v }
        let cache = CliProbeCache(ts: Date().timeIntervalSince1970, results: results)
        if let d = try? JSONEncoder().encode(cache) {
            try? d.write(to: URL(fileURLWithPath: cliProbeFile))
        }
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
        // 快速短路: 绝大多数 (skill, 文本) 对根本不含该词, 用高度优化的
        // contains 先挡掉, 避免对 ~50×50 对全部做逐字符扫描。
        guard txt.contains(word) else { return false }
        let chars = Array(txt)
        let w = Array(word)
        func isWordChar(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || c == "-" || c == "_"
        }
        var i = 0
        let n = chars.count, m = w.count
        while i + m <= n {
            if chars[i] == w[0] {
                // 就地逐字符比较, 不再对每个候选位置切一段子数组(旧实现的主要开销)。
                var match = true
                var j = 1
                while j < m {
                    if chars[i + j] != w[j] { match = false; break }
                    j += 1
                }
                if !match { i += 1; continue }
                let leftOK  = i == 0 || !isWordChar(chars[i - 1])
                let rightOK = i + m >= n || !isWordChar(chars[i + m])
                if leftOK && rightOK { return true }
            }
            i += 1
        }
        return false
    }

    /// 把文本切成"完整词 token"集合: 连续的 字母/数字/-/_ 视为一个 token。
    /// 与 mentionsWord 的词边界语义一致(token 本身就是被非词字符包围的完整词),
    /// 但一段 txt 只需扫一遍, 之后 O(1) 判定某 skill 名是否作为完整词出现。
    private static func wordTokenSet(_ txt: String) -> Set<String> {
        var set = Set<String>()
        var cur = ""
        for ch in txt {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" {
                cur.append(ch)
            } else if !cur.isEmpty {
                set.insert(cur); cur = ""
            }
        }
        if !cur.isEmpty { set.insert(cur) }
        return set
    }

    /// 抽出所有形如 XXX_DIR 的环境变量 token(硬依赖判定用)。
    /// 环境变量只含 字母/数字/下划线, 故以这三类字符切分 token。
    private static func dirEnvTokenSet(_ txt: String) -> Set<String> {
        var set = Set<String>()
        var cur = ""
        for ch in txt {
            if ch.isLetter || ch.isNumber || ch == "_" {
                cur.append(ch)
            } else {
                if cur.count > 4, cur.hasSuffix("_DIR") { set.insert(cur) }
                cur = ""
            }
        }
        if cur.count > 4, cur.hasSuffix("_DIR") { set.insert(cur) }
        return set
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
    /// 归档组默认折叠 —— 它有十几个成员却几乎不看, 展开会把常用分类挤到屏幕外
    @State private var archiveExpanded = false
    /// Claude 遗留与真正归档不是一回事；默认单独折叠，只在迁移清理时查看。
    @State private var legacyExpanded = false
    /// 顶部 Tab: Skills 之外再暴露 MCP 与 Hooks —— 它们同样影响每次对话行为, 却一直不可见
    @State private var boardTab: BoardTab = .skills
    @StateObject private var envVM = AgentEnvViewModel()

    enum BoardTab: String, CaseIterable {
        case skills = "Skills", mcp = "MCP", hooks = "Hooks"
        case agents = "Agents", memory = "Context"
    }

    static let archiveSection = "已归档 / 分享版"
    static let legacySection = "Claude 遗留（迁移对照）"

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
                skillGovernancePanel
                if vm.loading && vm.items.isEmpty { loadingState }
                ForEach(grouped, id: \.0) { g in
                    let isArchive = g.0 == Self.archiveSection
                    let isLegacy = g.0 == Self.legacySection
                    // 用筛选条主动筛到归档/分享时视为"就是要看它", 强制展开,
                    // 否则会出现"点了分类却一片空白"
                    let forced = SkillsViewModel.tailCategories.contains(vm.categoryFilter)
                    if isArchive {
                        collapsibleHeader(g.0, g.1.count)
                    } else if isLegacy {
                        legacyHeader(g.0, g.1.count)
                    } else {
                        sectionHeader(g.0, g.1.count)
                    }
                    if !isArchive && !isLegacy || (isArchive && (archiveExpanded || forced)) || (isLegacy && (legacyExpanded || forced)) {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(g.1) { item in card(item) }
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 16)
                    }
                }
                if vm.canLoadMoreAssets {
                    Button(action: { vm.loadMoreAssets() }) {
                        Text("再加载 40 条（已显示 \(vm.filtered.count) / \(vm.assetTotal)）")
                            .font(fm.font(11)).foregroundStyle(theme.current.accentPrimary)
                            .padding(.vertical, 8).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
                if !vm.loading && vm.filtered.isEmpty && !vm.items.isEmpty { emptyState }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private var skillGovernancePanel: some View {
        let d = vm.duplicateStats
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.current.accentPrimary)
                Text("Skill 治理").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.current.textPrimary)
                Spacer()
                Text(vm.showAssetLibrary ? "资产库 \(vm.assetTotal) 项" : "当前 \(vm.currentItems.count) 个")
                    .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                if d.replicas > 0 { Text("\(d.replicas) 个多来源").font(fm.font(10)).foregroundStyle(theme.current.textMuted) }
                if d.divergent > 0 { Text("\(d.divergent) 个同名异定义").font(fm.font(10)).foregroundStyle(Color(hex: "#c8863c")) }
            }
            Text(vm.showAssetLibrary
                 ? "Claude 兼容、系统内置、插件缓存、遗留、归档和分享副本集中在这里；默认最多渲染 40 条，按需继续加载。"
                 : "这里只展示日常维护的 Codex、原生共享层和 Qoder CN Skill；兼容层虽已启用，但默认折叠到资产库。")
                .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.accentPrimary.opacity(0.055)))
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 3)
    }

    private var grouped: [(String, [SkillItem])] {
        let items = vm.filtered
        var order: [String] = []
        var map: [String: [SkillItem]] = [:]
        let bad = items.filter { $0.health != .healthy }
        if !bad.isEmpty { order.append("需要处理"); map["需要处理"] = bad }
        // 归档与分享才是"移出使用范围、留档备查"；Claude 遗留只是旧运行时的迁移对照，
        // 绝不能混入归档数，否则会制造“误归档了几十个”的错觉。
        var archived: [SkillItem] = []
        var compatible: [SkillItem] = []
        var legacy: [SkillItem] = []
        for i in items where i.health == .healthy {
            if i.category == "Claude 兼容" {
                compatible.append(i)
                continue
            }
            if i.category == "Claude 遗留" {
                legacy.append(i)
                continue
            }
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
        if !compatible.isEmpty {
            result.append(("Claude 兼容（Codex 已启用）", compatible.sorted { $0.dir < $1.dir }))
        }
        if !legacy.isEmpty {
            result.append((Self.legacySection, legacy.sorted { $0.dir < $1.dir }))
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
                    .foregroundStyle((item.enabled && !item.codexDisabled)
                                       ? theme.current.textPrimary : theme.current.textMuted)
                    .strikethrough(!item.enabled || item.codexDisabled,
                                     color: theme.current.textMuted.opacity(0.6))
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
                if item.duplicateCount > 0 {
                    miniBadge("+\(item.duplicateCount)", "square.stack.3d.up",
                              item.divergentDefinitions ? Color(hex: "#c8863c") : theme.current.textMuted)
                }
                if item.codexDisabled {
                    miniBadge("禁", "poweroff", Color(hex: "#8a8f98"))
                        .help("已在 Codex 配置中禁用：文件仍在，但 Codex 不加载")
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
                    if let source = item.sources.first {
                        Text(item.sources.count > 1 ? "\(source) +\(item.sources.count - 1)" : source)
                            .font(.system(size: 9, weight: .medium))
                    }
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
                    ForEach(item.sources, id: \.self) { source in
                        tag(source, source == "Claude 遗留" || source == "Claude 兼容" ? theme.current.textMuted
                            : theme.current.accentPrimary)
                    }
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

                if item.installations.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.divergentDefinitions ? "同名异定义：请按运行时分别管理" : "同名副本：定义一致，已合并展示")
                            .font(fm.font(10))
                            .foregroundStyle(item.divergentDefinitions ? Color(hex: "#c8863c") : theme.current.textMuted)
                        ForEach(item.installations) { install in
                            Text("\(install.source) · \(install.path)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(theme.current.textTertiary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.current.textTertiary.opacity(0.06)))
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
                    // Codex 真禁用：写 config.toml，对 readOnly 的 Codex/插件资产也能用，
                    // 且不怕同步工具把文件重新生成回来（这是它区别于"归档"的关键）。
                    if item.origin == "启用" {
                        HStack {
                            Spacer()
                            codexDisableControl(item)
                        }
                    }
                    HStack {
                        Spacer()
                        if item.readOnly {
                            Text("由 \(item.sources.joined(separator: " / ")) 管理")
                                .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                        } else if item.enabled {
                            disableControl(item)
                        } else {
                            flatBtn("启用", "power", tint: Color(hex: "#5aa86c")) { vm.enable(item) }
                        }
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
        .tearOffHandle("SkillsBoard", enabled: popoverMode)
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
            HStack(spacing: 2) {
                scopeButton("当前", asset: false)
                scopeButton("资产库 \(vm.assetTotal)", asset: true)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.textTertiary.opacity(0.07)))

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

    private func scopeButton(_ title: String, asset: Bool) -> some View {
        let selected = vm.showAssetLibrary == asset
        return Button(action: { vm.switchScope(assetLibrary: asset) }) {
            Text(title).font(fm.font(10))
                .foregroundStyle(selected ? theme.current.accentPrimary : theme.current.textMuted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? theme.current.cardFill.opacity(0.8) : Color.clear))
        }
        .buttonStyle(.plain)
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

    private func legacyHeader(_ title: String, _ n: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(theme.current.textMuted.opacity(0.7))
                .rotationEffect(.degrees(legacyExpanded ? 90 : 0))
            Text(title)
                .font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(theme.current.textMuted)
            Text("\(n)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.current.textMuted.opacity(0.7))
            if !legacyExpanded {
                Text("不参与当前运行时路由").font(fm.font(9))
                    .foregroundStyle(theme.current.textMuted.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 1.0)) {
                legacyExpanded.toggle()
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

    /// Codex 真禁用开关：写 ~/.codex/config.toml 的 [[skills.config]]。
    /// 与"归档"（移动目录）互补：归档适合彻底收起来；这里适合"文件留着、
    /// 只是别让 Codex 加载"，尤其适合会被同步工具重建的 readOnly 资产。
    @ViewBuilder
    private func codexDisableControl(_ item: SkillItem) -> some View {
        if item.codexDisabled {
            HStack(spacing: 6) {
                Text("Codex 已禁用").font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                flatBtn("恢复", "power", tint: Color(hex: "#5aa86c")) {
                    vm.setCodexDisabled(item, false)
                }
            }
        } else {
            flatBtn("禁用", "poweroff", tint: Color(hex: "#8a8f98")) {
                vm.setCodexDisabled(item, true)
            }
        }
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
    private let tearOff = TearOffObserver()
    private func installTearOffObserver() {
        tearOff.install(key: "SkillsBoard") { [weak self] in
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
        // 窗口透明度: 只在 nativeBlur 主题下透出桌面壁纸, 其它主题保持不透明避免顶栏透视
        let _needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !_needsTransparent
        win.backgroundColor = _needsTransparent ? .clear : .windowBackgroundColor
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
