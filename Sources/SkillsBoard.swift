import SwiftUI
import AppKit
import Foundation

// MARK: - 本地技能库：分类、收藏、用途备注与安装来源。
// 面板只保存自己的组织信息，不改写 SKILL.md 或推断技能质量。
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
    var id: String { name.isEmpty ? dir : name }

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
    @Published var favoritesOnly = false
    @Published var sourceFilter = "全部来源"
    @Published private(set) var favorites: Set<String> = []
    @Published private(set) var personalNotes: [String: String] = [:]
    private let libraryURL: URL?
    private let categoryURL: URL?

    init(libraryURL: URL? = SkillLibraryMetadata.defaultURL,
         categoryURL: URL? = URL(fileURLWithPath: SkillsViewModel.overrideFile)) {
        self.libraryURL = libraryURL
        self.categoryURL = categoryURL
        guard let libraryURL, let data = try? Data(contentsOf: libraryURL),
              let metadata = try? JSONDecoder().decode(SkillLibraryMetadata.self, from: data) else { return }
        favorites = metadata.favorites
        personalNotes = metadata.notes
    }

    private func saveLibrary() {
        guard let libraryURL else { return }
        do {
            try FileManager.default.createDirectory(at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SkillLibraryMetadata(favorites: favorites, notes: personalNotes))
            try data.write(to: libraryURL, options: .atomic)
        } catch { actionMsg = "保存技能整理信息失败：\(error.localizedDescription)" }
    }

    func toggleFavorite(_ item: SkillItem) {
        if favorites.contains(item.id) { favorites.remove(item.id) }
        else { favorites.insert(item.id) }
        saveLibrary()
    }

    func note(for item: SkillItem) -> String { personalNotes[item.id] ?? "" }
    func setNote(_ note: String, for item: SkillItem) {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { personalNotes.removeValue(forKey: item.id) }
        else { personalNotes[item.id] = value }
        saveLibrary()
    }

    func copyInvocation(_ item: SkillItem, path: String? = nil) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.invocation(at: path), forType: .string)
        actionMsg = "已复制 \(item.displayName) 的调用入口"
    }
    @Published var lastScan: Date? = nil
    @Published var actionMsg = ""
    /// 本地安装与未接入的留存文件分别显示。
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
        guard let categoryURL, let d = try? Data(contentsOf: categoryURL),
              let st = try? JSONDecoder().decode(OverrideStore.self, from: d) else { return }
        overrides = st.overrides
        customCategories = st.customCategories
    }

    private func saveOverrides() {
        let st = OverrideStore(overrides: overrides, customCategories: customCategories)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(st) else { return }
        guard let categoryURL else { return }
        do {
            try FileManager.default.createDirectory(at: categoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: categoryURL, options: .atomic)
        } catch { actionMsg = "保存分类失败：\(error.localizedDescription)" }
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
        applyOverridesInPlace()
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
        applyOverridesInPlace()
        actionMsg = "已移除分类「\(name)」"
    }

    /// 不重扫磁盘, 直接按覆盖表刷新内存里的 category(改分类是纯视图操作, 无需 IO)
    private func applyOverridesInPlace() {
        for idx in items.indices {
            let it = items[idx]
            items[idx].category = overrides[it.dir] ?? Self.categorize(it.dir)
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
        item.enabled
    }

    var currentItems: [SkillItem] { items.filter(isCurrentManaged) }
    var assetItems: [SkillItem] { items.filter { !isCurrentManaged($0) } }
    var scopedItems: [SkillItem] {
        let base = showAssetLibrary ? assetItems : currentItems
        return favoritesOnly ? base.filter { favorites.contains($0.id) } : base
    }
    var assetTotal: Int { assetItems.count }
    var canLoadMoreAssets: Bool { showAssetLibrary && assetLimit < assetItems.count }

    func switchScope(assetLibrary: Bool) {
        showAssetLibrary = assetLibrary
        categoryFilter = "全部"
        favoritesOnly = false
        sourceFilter = "全部来源"
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

    var matchedItems: [SkillItem] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return scopedItems.filter { item in
            if categoryFilter != "全部" && item.category != categoryFilter { return false }
            if sourceFilter != "全部来源" && !item.sourceLabels.contains(sourceFilter) { return false }
            if q.isEmpty { return true }
            return [item.dir, item.name, item.desc, item.category, note(for: item)]
                .contains { $0.localizedCaseInsensitiveContains(q) }
        }.sorted {
            let a = favorites.contains($0.id), b = favorites.contains($1.id)
            if a != b { return a }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    var filtered: [SkillItem] { Array(matchedItems.prefix(assetLimit)) }
    var sourceOptions: [String] { ["全部来源"] + Set(scopedItems.flatMap(\.sourceLabels)).sorted() }
    var canLoadMore: Bool { filtered.count < matchedItems.count }
    func clearFilters() {
        search = ""; categoryFilter = "全部"; sourceFilter = "全部来源"; favoritesOnly = false
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

    func refreshIfNeeded() {
        if let lastScan, Date().timeIntervalSince(lastScan) < 60 { return }
        scan()
    }

    func scan() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.performScan()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.loadCodexDisabled()
                // 分类只用于面板组织，不修改技能文件。
                self.items = result.map { it -> SkillItem in
                    var m = it
                    let idName = m.name.isEmpty ? m.dir : m.name
                    m.codexDisabled = self.codexDisabledNames.contains(idName)
                    m.category = self.overrides[m.dir] ?? Self.categorize(m.dir)
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

        // 当前运行时优先；同名项稍后合并。~/.qoder/skills 是 Claude 的符号链接，不扫描。
        var dirs: [(String, String, Bool, String, Bool)] = [] // dir/path/enabled/source/readOnly
        func addRoot(_ base: String, source: String, enabled: Bool = true, readOnly: Bool = false) {
            guard let ds = try? fm.contentsOfDirectory(atPath: base) else { return }
            for d in ds.sorted() where !d.hasPrefix(".") && isDir(base + "/" + d) {
                guard fm.fileExists(atPath: base + "/" + d + "/SKILL.md") else { continue }
                let path = base + "/" + d
                // 兼容软链也属于本地安装，按实际入口显示。
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
        // 插件缓存只展示每个插件的最新版本文件，避免旧版本淹没技能库。
        let pluginRoot = NSHomeDirectory() + "/.codex/plugins/cache"
        for marketplace in (try? fm.contentsOfDirectory(atPath: pluginRoot)) ?? [] {
            let marketPath = pluginRoot + "/" + marketplace
            for plugin in (try? fm.contentsOfDirectory(atPath: marketPath)) ?? [] {
                let path = marketPath + "/" + plugin
                let versions = ((try? fm.contentsOfDirectory(atPath: path)) ?? []).filter { isDir(path + "/" + $0) }
                if let latest = versions.sorted(by: versionLess).last {
                    addNestedSkills(path + "/" + latest, source: "Codex 插件")
                }
            }
        }
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

            let definition = Self.parseDefinition(txt, directory: d, path: p)
            it.name = definition.name
            it.desc = definition.desc
            it.health = definition.health
            it.problems = definition.problems
            it.manualOnly = definition.manualOnly
            it.external = source.contains("插件") || source.contains("系统")
            it.category = categorize(d)

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

                    }
                }
            } else {
                out.append(it)
            }
        }

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
                let hard = paths.contains(other) || envs.contains(envKey)
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
            guard !item.readOnly else { actionMsg = "此技能由安装来源管理，不能直接移动"; return }
            guard !fm.fileExists(atPath: dst) else { actionMsg = "归档目录已有同名文件，未移动"; return }
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
            guard !item.readOnly else { actionMsg = "此技能由安装来源管理，不能直接移动"; return }
            guard !fm.fileExists(atPath: dst) else { actionMsg = "目标目录已有同名文件，未移动"; return }
            try fm.moveItem(atPath: item.path, toPath: dst)
            actionMsg = "已恢复至 Claude 本地目录 \(item.dir)"
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

    /// Read declared metadata only; names, length and trigger wording are not quality checks.
    static func parseDefinition(_ text: String, directory: String, path: String) -> SkillItem {
        var item = SkillItem(dir: directory, path: path)
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            item.health = .broken
            item.problems = ["SKILL.md 缺少文件头元数据"]
            return item
        }
        let front = lines[1..<end].joined(separator: "\n")
        item.name = field(front, "name") ?? ""
        item.desc = field(front, "description") ?? ""
        item.manualOnly = field(front, "disable-model-invocation") == "true"
        if item.name.isEmpty { item.problems.append("SKILL.md 未填写 name") }
        if item.desc.isEmpty { item.problems.append("SKILL.md 未填写 description") }
        if !item.problems.isEmpty { item.health = .broken }
        return item
    }

    private static func field(_ front: String, _ key: String) -> String? {
        let lines = front.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix(key + ":") else { continue }
            var value = String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if [">", ">-", ">+", "|", "|-", "|+"].contains(value) || value.isEmpty {
                var continuation: [String] = []
                for next in lines.dropFirst(index + 1) {
                    if next.isEmpty { continuation.append(""); continue }
                    guard next.first?.isWhitespace == true else { break }
                    continuation.append(next.trimmingCharacters(in: .whitespaces))
                }
                value = continuation.joined(separator: value.hasPrefix("|") ? "\n" : " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let quote = value.first, (quote == "\"" || quote == "'") {
                if value.count > 1 && value.last == quote {
                    value = String(value.dropFirst().dropLast())
                } else {
                    var continuation = [String(value.dropFirst())]
                    for next in lines.dropFirst(index + 1) {
                        continuation.append(next.trimmingCharacters(in: .whitespaces))
                        if next.trimmingCharacters(in: .whitespaces).last == quote { break }
                    }
                    value = continuation.joined(separator: " ")
                    if value.last == quote { value.removeLast() }
                }
            }
            return value
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

}

final class SkillsBoardWindowController {
    static let shared = SkillsBoardWindowController()
    private var window: NSWindow?
    private var popover: NSPopover?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let vm = SkillsViewModel()
    private var windowInteraction: WorkspaceWindowInteraction?

    /// 菜单栏入口: 图标正下方展开, 点外部/Esc 自动收起(与 D板主面板同一套模式)
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
                .dboardFont(size: 13).environmentObject(FontManager.shared)
                .frame(width: popW, height: popH))
        host.sizingOptions = []
        pop.contentSize = NSSize(width: popW, height: popH)
        pop.contentViewController = host
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
        vm.refreshIfNeeded()

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
            vm.refreshIfNeeded()
            return
        }
        let view = SkillsBoardView()
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .dboardFont(size: 13).environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = []
        let win = DemandWorkspaceWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 740))
        win.setContent(host)
        win.title = "Skills"
        win.setContentSize(NSSize(width: 1060, height: 740))
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        win.contentMinSize = NSSize(width: 760, height: 540)
        win.contentMaxSize = NSSize(width: 2600, height: 2200)
        win.setFrameAutosaveName("DBoardSkillsWindow")
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        windowInteraction = WorkspaceWindowInteraction(window: win, id: "skills", handlesEscape: false)
    }
}
