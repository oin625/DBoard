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

    static let root = NSHomeDirectory() + "/.claude/skills"
    static let disabledRoot = NSHomeDirectory() + "/.claude/skills-disabled"

    var categories: [(String, Int)] {
        var c: [String: Int] = [:]
        for i in items { c[i.category, default: 0] += 1 }
        return [("全部", items.count)] + c.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
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
                self?.items = result
                self?.loading = false
                self?.lastScan = Date()
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

        // 第一轮: 解析元数据
        var texts: [String: String] = [:]
        for (d, p, en) in dirs {
            var it = SkillItem(dir: d, path: p)
            it.enabled = en
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
                it.health = min(it.health, .broken)
                it.problems.append("name「\(it.name)」与目录名不符, 加载会错乱")
            }
            if it.desc.isEmpty {
                it.health = .broken
                it.problems.append("frontmatter 缺 description, Qoder 无法判断何时触发")
            }

            // ===== 软性检查 =====
            if !it.desc.isEmpty {
                if it.desc.count < 40 {
                    it.hints.append("description 仅 \(it.desc.count) 字, 过短会导致 Qoder 匹配不准")
                }
                let hasTrigger = it.desc.contains("when") || it.desc.contains("Use ")
                    || it.desc.contains("当用户") || it.desc.contains("触发")
                    || it.desc.contains("时使用") || it.desc.contains("用户说")
                if !hasTrigger {
                    it.hints.append("description 没写触发条件(如\"当用户说…\"), 可能不会被自动唤起")
                }
            }
            it.missingCLI = missingCommands(in: txt)
            if !it.missingCLI.isEmpty {
                it.hints.append("依赖的命令未安装: " + it.missingCLI.joined(separator: ", "))
            }
            if let m = it.modified, Date().timeIntervalSince(m) > 180 * 86400 {
                it.hints.append("半年以上未更新, 确认是否仍需要")
            }

            it.category = categorize(d)
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
    func disable(_ item: SkillItem) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.disabledRoot, withIntermediateDirectories: true)
        let dst = Self.disabledRoot + "/" + item.dir
        do {
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.moveItem(atPath: item.path, toPath: dst)
            actionMsg = "已禁用 \(item.dir)"
            scan()
        } catch {
            actionMsg = "禁用失败: \(error.localizedDescription)"
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

    private static func categorize(_ d: String) -> String {
        if d.hasPrefix("dingtalk-") || d == "dws" || d == "dws-shared" || d == "mono" { return "钉钉" }
        if d.hasPrefix("tmyc-") || d == "ultra-pre-probe" || d == "dubbo-pre-invoke" { return "TMYC" }
        if d.hasPrefix("luban-") { return "Luban" }
        if d.contains("animation") || d.contains("design") || d.contains("canvas")
            || d == "prototype" || d == "pick-ui-library" { return "设计/动画" }
        if d.hasPrefix("superpowers-") || d.contains("skill") || d.contains("plugin")
            || d.contains("subagent") { return "元技能" }
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
    private static func commandExists(_ c: String) -> Bool {
        if let v = cliCache[c] { return v }
        let out = runCmd("/bin/sh", ["-c", "command -v \(c) 2>/dev/null || ls ~/.local/bin/\(c) 2>/dev/null"])
        let exists = !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        cliCache[c] = exists
        return exists
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
    @State private var detailItem: SkillItem? = nil     // 点击卡片 -> 右侧详情
    @State private var confirmDisable: String? = nil
    @State private var hovered: String? = nil

    private let columns = [GridItem(.adaptive(minimum: 236, maximum: 340), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                gridArea
                if let d = detailItem {
                    Divider().opacity(0.4)
                    detailPane(d)
                        .frame(width: 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(minWidth: 700, minHeight: 540)
        .focusEffectDisabled()
        .background(theme.current.background.ignoresSafeArea())
        .onAppear { if vm.items.isEmpty { vm.scan() } }
    }

    private var gridArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if vm.loading && vm.items.isEmpty { loadingState }
                ForEach(grouped, id: \.0) { g in
                    sectionHeader(g.0, g.1.count)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(g.1) { item in card(item) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
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
        for i in items where i.health == .healthy {
            if map[i.category] == nil { order.append(i.category) }
            map[i.category, default: []].append(i)
        }
        return order.map { ($0, map[$0] ?? []) }
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
            }

            // 描述: 固定 2 行, 卡片等高
            Text(item.desc.isEmpty ? "（无描述）" : item.desc)
                .font(fm.font(11))
                .lineSpacing(2.5)
                .foregroundStyle(theme.current.textSecondary.opacity(0.85))
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
                        Text("已禁用").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(theme.current.textMuted)
                    }
                    Spacer()
                }
                .foregroundStyle(theme.current.textMuted.opacity(0.8))
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
    }

    private func cardFill(_ item: SkillItem, isHover: Bool, isSel: Bool) -> Color {
        if isSel { return theme.current.accentPrimary.opacity(0.09) }
        if item.health == .broken { return Color(hex: "#d94f4f").opacity(0.055) }
        return theme.current.cardFill.opacity(theme.current.cardFillOpacity * (isHover ? 1.0 : 0.82))
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
                    if !item.hardRefs.isEmpty {
                        tag("\(item.hardRefs.count) 个硬依赖", Color(hex: "#8b6fb8"))
                    }
                    if item.mentionCount > 0 {
                        tag("\(item.mentionCount) 处提及", Color(hex: "#8b6fb8").opacity(0.65))
                    }
                    if !item.enabled { tag("已禁用", theme.current.textMuted) }
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
            Text("Skills").font(fm.font(19)).foregroundStyle(theme.current.accentGradient)
            Text("\(s.total)").font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.current.textMuted)
            Spacer()
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
                Text("\(s.disabled) 已禁用").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
            }
            Button(action: { vm.scan() }) {
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
        .padding(.leading, 84).padding(.trailing, 16)
        .padding(.top, 8).padding(.bottom, 10)
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

            HStack(spacing: 3) {
                ForEach(vm.categories.prefix(5), id: \.0) { c in catChip(c.0, c.1) }
                if vm.categories.count > 5 {
                    Menu {
                        ForEach(vm.categories.dropFirst(5), id: \.0) { c in
                            Button("\(c.0) (\(c.1))") { vm.categoryFilter = c.0 }
                        }
                    } label: {
                        Text("更多").font(fm.font(11)).foregroundStyle(theme.current.textSecondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
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
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(urgent ? Color(hex: "#d94f4f") : theme.current.textMuted)
            Text("\(n)").font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.current.textMuted.opacity(0.7))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 7)
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
                Text(pending ? "确认禁用" : "禁用")
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
    private let vm = SkillsViewModel()

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
