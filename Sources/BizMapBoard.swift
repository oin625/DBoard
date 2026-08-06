import SwiftUI
import AppKit

// MARK: - BizMap 业务地图看板
// 数据源: ~/.claude/bizmap-cache.json (由 wiki projects/业务地图/gen_bizmap.py 生成)
// 定位: 接需求时的路由器 —— 输关键词 → 高亮该查哪个服务 → 直达作战地图文档

// MARK: - 数据模型 (对齐 bizmap-cache.json)

struct BizDItem: Codable, Identifiable {
    let id: String          // D001
    let projects: [String]
    let title: String
    let status: String
}

struct BizPRDItem: Codable, Identifiable {
    let id: Int             // PRD 系统 id
    let no: String          // R2607030033
    let name: String
    let code: String        // SJWC / KFZ / CSZ …
    let status: String      // 中文状态名
    let pri: String?
    let dev: String?
    let scopes: [String]    // pending / mine / dept
    let services: [String]  // AI 语义标注的目标服务, 空 = 未路由
    let note: String?       // 标注依据
    let docs: [String]      // 钉钉需求文档链接(交付物)
    let url: String         // PRD 明细页
}

struct BizService: Codable, Identifiable {
    let name: String
    let tier: String
    let c: Int              // 近半年 commits
    let st: String          // active / semi / dead
    let pkg: String
    let desc: String
    let mapLevel: String    // L0 / L2
    let routing: [String]
    let related: [String]
    let branch: String
    let div: String
    let doc: String
    let dItems: [BizDItem]
    let pItems: [BizPRDItem]?   // 旧缓存无此字段, 可选保解码兼容
    var id: String { name }
    var prds: [BizPRDItem] { pItems ?? [] }
}

struct BizGroup: Codable { let key: String; let label: String }
struct BizRoute: Codable { let kw: String; let primary: String; let secondary: String }
struct BizPhase: Codable { let done: [String]; let current: String; let rest: [String] }

struct BizMapCache: Codable {
    let generated: String
    let phase: BizPhase
    let groups: [BizGroup]
    let services: [BizService]
    let routes: [BizRoute]
    let dItemsAll: [BizDItem]
    let prdGenerated: String?
    let prdItemsAll: [BizPRDItem]?
}

// MARK: - ViewModel

enum BizPerspective { case services, requirements }

/// 需求流组内分栏: 一次只看一栏, 告别 27 条平铺
enum ReqTab: String, CaseIterable {
    case notStarted = "待开始"
    case inProgress = "进行中"
    case others = "其他"
}

final class BizMapViewModel: ObservableObject {
    @Published var cache: BizMapCache?
    @Published var query: String = ""
    @Published var selected: BizService?
    @Published var loadError: String?
    @Published var regenerating = false
    @Published var genError: String?   // 生成器失败不能静默: 老数据照常展示, 但 header 要亮警告
    @Published var perspective: BizPerspective = .services   // 服务视角 / 需求视角
    @Published var showUnroutedOnly = false                   // 需求视角: 只看未路由
    @Published var reqTab: ReqTab = .notStarted                // 需求流当前分栏

    private let cachePath = NSString(string: "~/.claude/bizmap-cache.json").expandingTildeInPath
    private let genScript = NSString(string: "~/Documents/one/projects/业务地图/gen_bizmap.py").expandingTildeInPath

    func load() {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: cachePath))
            cache = try JSONDecoder().decode(BizMapCache.self, from: data)
            loadError = nil
        } catch {
            loadError = "读取 bizmap-cache.json 失败: \(error.localizedDescription)"
        }
    }

    /// 重新生成: 跑 gen_bizmap.py 再重载 (地图文档或 D 板更新后用)
    func regenerate() {
        guard !regenerating else { return }
        regenerating = true
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [self.genScript]
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = FileHandle.nullDevice   // stdout 不读就不能用 Pipe: 写满缓冲区会永久卡死 waitUntilExit
            var failure: String?
            do {
                try p.run()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus != 0 {
                    let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    failure = "生成器退出码 \(p.terminationStatus)" + (msg.isEmpty ? "" : "：\(msg.prefix(120))")
                }
            } catch {
                failure = "生成器启动失败: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self.genError = failure
                self.load()
                self.regenerating = false
            }
        }
    }

    /// 需求路由: 返回 (首查集合, 次查集合) —— 与 HTML 版 route() 同一套逻辑
    var routeHits: (primary: Set<String>, secondary: Set<String>) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty, let c = cache else { return ([], []) }
        var p = Set<String>(), s = Set<String>()
        for r in c.routes where r.kw.lowercased().contains(q) {
            p.insert(r.primary)
            if !r.secondary.isEmpty { s.insert(r.secondary) }
        }
        for svc in c.services {
            if svc.routing.contains(where: { $0.lowercased().contains(q) }) || svc.name.lowercased().contains(q) {
                p.insert(svc.name)
            } else if svc.desc.lowercased().contains(q) {
                s.insert(svc.name)
            }
        }
        s.subtract(p)
        return (p, s)
    }

    var l2Count: Int { cache?.services.filter { $0.mapLevel == "L2" }.count ?? 0 }
    /// 关联 D 单总数(含待开始) —— 与卡片 D× 角标同口径, 避免同屏两个数字两套含义
    var dCount: Int { cache?.dItemsAll.count ?? 0 }
    var prdItems: [BizPRDItem] { cache?.prdItemsAll ?? [] }
    var prdUnrouted: [BizPRDItem] { prdItems.filter { $0.services.isEmpty } }

    // MARK: 需求视角: 搜索框降级为筛选器(名称/编号/开发/服务/状态)
    var filteredPRD: [BizPRDItem] {
        var base = prdItems
        if showUnroutedOnly { base = base.filter { $0.services.isEmpty } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter { p in
            p.name.lowercased().contains(q) || p.no.lowercased().contains(q)
                || (p.dev ?? "").lowercased().contains(q)
                || p.status.contains(q)
                || p.services.contains { $0.lowercased().contains(q) }
        }
    }

    /// 我参与的(非终态) —— 需求流首屏英雄区, 永远置顶
    var myActive: [BizPRDItem] { prdItems.filter { $0.scopes.contains("mine") }.sorted(by: Self.prdSort) }

    /// 组内分栏(排除"我的"避免重复): 待开始 / 进行中 / 其他
    func tabItems(_ t: ReqTab) -> [BizPRDItem] {
        let rest = prdItems.filter { !$0.scopes.contains("mine") }
        let notStarted: Set<String> = ["YTJ", "YJS", "SJWC"]
        let inProgress: Set<String> = ["KFZ", "CSZ"]
        var out: [BizPRDItem]
        switch t {
        case .notStarted: out = rest.filter { notStarted.contains($0.code) }
        case .inProgress: out = rest.filter { inProgress.contains($0.code) }
        case .others: out = rest.filter { !notStarted.contains($0.code) && !inProgress.contains($0.code) }
        }
        if showUnroutedOnly { out = out.filter { $0.services.isEmpty } }
        return out.sorted(by: Self.prdSort)
    }

    /// 排序: 可行动优先(待接在前) → P0 → 新编号
    static func prdSort(_ a: BizPRDItem, _ b: BizPRDItem) -> Bool {
        func stateRank(_ p: BizPRDItem) -> Int { p.code == "SJWC" ? 0 : 1 }
        func priRank(_ p: BizPRDItem) -> Int {
            switch p.pri { case "P0": return 0; case "P1": return 1; case "P2": return 2; default: return 3 }
        }
        if stateRank(a) != stateRank(b) { return stateRank(a) < stateRank(b) }
        if priRank(a) != priRank(b) { return priRank(a) < priRank(b) }
        return a.no > b.no
    }

    func service(_ name: String) -> BizService? {
        cache?.services.first { $0.name == name }
    }

    /// 打开外部链接 (PRD 明细页 / 钉钉需求文档)
    func openURL(_ s: String) {
        guard let u = URL(string: s) else { return }
        NSWorkspace.shared.open(u)
    }

    /// 打开作战地图文档 (Obsidian 优先, 失败落默认编辑器)
    func openDoc(_ svc: BizService) {
        guard !svc.doc.isEmpty else { return }
        let enc = svc.doc.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? svc.doc
        if let url = URL(string: "obsidian://open?path=\(enc)"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: svc.doc))
    }
}

// MARK: - 梯队配色

private func tierColor(_ tier: String) -> Color {
    switch tier {
    case "t1": return Color(hex: "#DC2626")
    case "t2": return Color(hex: "#059669")
    case "t3m": return Color(hex: "#2563EB")
    case "t3s": return Color(hex: "#0891B2")
    case "gw": return Color(hex: "#7C3AED")
    case "adm": return Color(hex: "#EA580C")
    case "infra": return Color(hex: "#64748B")
    default: return Color(hex: "#9CA3AF")
    }
}

private let hitPrimary = Color(hex: "#F59E0B")
private let hitSecondary = Color(hex: "#A78BFA")
private let prdBlue = Color(hex: "#2563EB")

// MARK: - 主视图

struct BizMapBoardView: View {
    @EnvironmentObject var vm: BizMapViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    var popoverMode: Bool = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 chrome(字标+搜索)结成一条带底色的区: 文字不能裸贴在壁纸上
            VStack(spacing: 0) {
                header
                searchBar
            }
            .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.78))
            Divider().opacity(0.4)
            if let err = vm.loadError {
                errorState(err)
            } else if vm.perspective == .requirements {
                requirementList
            } else {
                HStack(spacing: 0) {
                    wall
                    if let sel = vm.selected {
                        Divider().opacity(0.4)
                        detailPane(sel).frame(width: 262)
                            // 右侧详情区必须自带实底: 否则文字直接贴在壁纸/背景图上没法读
                            .background(theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.92))
                    }
                }
            }
            footer
        }
        // 底层走与 Skills Board 同一套 ThemeBackground: 毛玻璃皮肤下是 NSVisualEffectView 原生材质,
        // 不能用裸主题色 opacity —— 半透主题叠透明窗口会成"几乎全透"
        .background(ThemeBackground().environmentObject(theme))
        .onAppear { vm.load(); searchFocused = true }
    }

    // MARK: Header —— 叠卡式视角切换: 当前字标在前, 待切的缩小压暗垫在右斜下方, 点影子换前台

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            perspectiveStack
            Spacer()
            if let g = vm.cache?.generated {
                Text(g).font(fm.font(10)).foregroundStyle(theme.current.textMuted)
            }
            if let ge = vm.genError {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    .foregroundStyle(Color(hex: "#d94f4f"))
                    .help(ge)
            }
            Button(action: { vm.regenerate() }) {
                if vm.regenerating { ProgressView().controlSize(.mini) }
                else { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
            }
            .buttonStyle(.plain).foregroundStyle(theme.current.textSecondary)
            .help("重跑 gen_bizmap.py 并刷新")
            if popoverMode {
                TearOffButton(key: "BizMapBoard")
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
        .tearOffHandle("BizMapBoard", enabled: popoverMode)
    }

    /// 叠卡容器: 两张字标同栈, 谁 active 谁在前台原位, 另一张缩到影子位
    private var perspectiveStack: some View {
        ZStack(alignment: .topLeading) {
            wordCard("BizMap", "业务地图", .services)
            wordCard("ReqFlow", "需求流", .requirements)
        }
        .frame(width: 175, height: 48, alignment: .topLeading)
    }

    /// 字标卡: active = 前台原位重墨 + 下划标; 非 active = 右斜下影子位(缩小/压暗/微斜), 点击弹簧换位
    /// 纯英文字标, 不带中文小字(灰色小字很脏)——中文名只留在 tooltip
    private func wordCard(_ en: String, _ zh: String, _ p: BizPerspective) -> some View {
        let active = vm.perspective == p
        return Button(action: {
            guard !active else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { vm.perspective = p }
        }) {
            VStack(alignment: .leading, spacing: 2) {
                Text(en).font(fm.font(19).weight(.heavy))
                    .foregroundStyle(active ? theme.current.accentPrimary : theme.current.textMuted)
                Capsule()
                    .fill(active ? theme.current.accentPrimary : Color.clear)
                    .frame(width: 28, height: 2.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(active)
        .scaleEffect(active ? 1 : 0.78, anchor: .topLeading)
        .rotationEffect(.degrees(active ? 0 : 2.5), anchor: .topLeading)
        .offset(x: active ? 0 : 64, y: active ? 0 : 17)
        .opacity(active ? 1 : 0.4)
        .zIndex(active ? 1 : 0)
        .help(active ? "" : "切换到 \(en) \(zh)")
    }

    // MARK: Search / 路由

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.current.textMuted)
                TextField(vm.perspective == .requirements
                          ? "筛选需求：名称 / 编号 / 服务 / 开发 / 状态 …"
                          : "输入需求关键词做路由：验券 / 领券 / 企微群聊 / 售后退款 / 会员卡 / 下单 …", text: $vm.query)
                    .textFieldStyle(.plain).font(fm.font(12.5))
                    .focused($searchFocused)
                if !vm.query.isEmpty {
                    Button(action: { vm.query = "" }) { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundStyle(theme.current.textMuted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(searchFocused ? theme.current.accentPrimary.opacity(0.6) : theme.current.separator, lineWidth: 1))

            routeHint
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }

    @ViewBuilder private var routeHint: some View {
        let hits = vm.routeHits
        if vm.perspective == .services, !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if hits.primary.isEmpty && hits.secondary.isEmpty {
                Text("无命中 —— 换个关键词，或该记入路由表（告诉 AI 补）")
                    .font(fm.font(11)).foregroundStyle(theme.current.textMuted)
            } else {
                HStack(spacing: 4) {
                    Text("路由 →").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                    Text("首查 " + hits.primary.sorted().joined(separator: "、"))
                        .font(fm.font(11).weight(.semibold)).foregroundStyle(hitPrimary)
                    if !hits.secondary.isEmpty {
                        Text("次查 " + hits.secondary.sorted().joined(separator: "、"))
                            .font(fm.font(11)).foregroundStyle(hitSecondary)
                    }
                }
            }
        }
    }

    // MARK: 卡片墙

    private var wall: some View {
        ScrollView {
            let hits = vm.routeHits
            let searching = !vm.query.trimmingCharacters(in: .whitespaces).isEmpty
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                ForEach(vm.cache?.groups ?? [], id: \.key) { g in
                    let list = (vm.cache?.services ?? []).filter { $0.tier == g.key }
                    if !list.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 5) {
                                Text(g.label).font(fm.font(11.5).weight(.semibold)).foregroundStyle(theme.current.textSecondary)
                                Text("\(list.count)").font(fm.font(9.5))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(theme.current.separator.opacity(0.5)))
                                    .foregroundStyle(theme.current.textMuted)
                            }
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                                ForEach(list) { svc in
                                    card(svc, hits: hits, searching: searching)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func card(_ svc: BizService, hits: (primary: Set<String>, secondary: Set<String>), searching: Bool) -> some View {
        let isP = hits.primary.contains(svc.name)
        let isS = hits.secondary.contains(svc.name)
        let dimmed = searching && !isP && !isS
        let isSelected = vm.selected?.name == svc.name

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(tierColor(svc.tier)).frame(width: 3, height: 13)
                Text(svc.name).font(fm.font(13).weight(.bold)).foregroundStyle(theme.current.textPrimary).lineLimit(1)
                badge(svc.mapLevel, active: svc.mapLevel == "L2")
                if svc.st == "semi" { badge("半退役", tint: Color(hex: "#D97706")) }
                if svc.st == "dead" { badge("停维", tint: theme.current.textMuted) }
                Spacer(minLength: 0)
                if !svc.dItems.isEmpty {
                    Text("D×\(svc.dItems.count)").font(fm.font(9).weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(hitPrimary)).foregroundStyle(.white)
                }
                if !svc.prds.isEmpty {
                    Text("P×\(svc.prds.count)").font(fm.font(9).weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(prdBlue)).foregroundStyle(.white)
                }
            }
            Text(svc.desc).font(fm.font(10.5)).foregroundStyle(theme.current.textTertiary)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 26, alignment: .topLeading)
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.current.separator.opacity(0.5))
                        Capsule().fill(tierColor(svc.tier))
                            .frame(width: svc.c > 0 ? max(4, geo.size.width * log10(Double(svc.c) + 1) / log10(3000)) : 0)
                    }
                }
                .frame(height: 3)
                Text("\(svc.c)c").font(fm.font(9)).foregroundStyle(theme.current.textMuted).lineLimit(1)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            isP ? hitPrimary : (isS ? hitSecondary : (isSelected ? theme.current.accentPrimary.opacity(0.7) : theme.current.separator)),
            lineWidth: isP || isS || isSelected ? 1.5 : 0.5))
        .opacity(dimmed ? 0.3 : 1)
        .contentShape(Rectangle())
        .onTapGesture { vm.selected = isSelected ? nil : svc }
    }

    private func badge(_ text: String, active: Bool = false, tint: Color? = nil) -> some View {
        let color = tint ?? (active ? theme.current.accentPrimary : theme.current.textMuted)
        return Text(text).font(fm.font(8.5).weight(.semibold))
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.4), lineWidth: 0.5))
            .foregroundStyle(color)
    }

    // MARK: 详情面板

    private func detailPane(_ svc: BizService) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(svc.name).font(fm.font(16).weight(.bold)).foregroundStyle(theme.current.textPrimary)
                    badge(svc.mapLevel, active: svc.mapLevel == "L2")
                    Spacer()
                    Button(action: { vm.selected = nil }) { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(theme.current.textMuted)
                }
                Text("\(svc.pkg) · \(svc.c) commits/6mo").font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                if !svc.branch.isEmpty {
                    Text("基线 \(svc.branch)\(svc.div.isEmpty ? "" : "（\(svc.div)）")")
                        .font(fm.font(10)).foregroundStyle(theme.current.textMuted)
                }
                section("定位") {
                    Text(svc.desc).font(fm.font(11)).foregroundStyle(theme.current.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !svc.routing.isEmpty {
                    section("需求路由关键词") { chipFlow(svc.routing, clickable: false) }
                }
                if !svc.related.isEmpty {
                    section("强关联服务") { chipFlow(svc.related, clickable: true) }
                }
                if !svc.dItems.isEmpty {
                    section("关联 D 单") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(svc.dItems) { d in
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(d.id).font(fm.font(10).weight(.bold)).foregroundStyle(hitPrimary)
                                        Text("#\(d.status)").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                                    }
                                    Text(d.title).font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(theme.current.separator.opacity(0.3)))
                            }
                        }
                    }
                }
                if !svc.prds.isEmpty {
                    section("关联 PRD 需求 (\(svc.prds.count))") {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(svc.prds) { p in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(p.no).font(fm.font(9).weight(.bold)).foregroundStyle(prdBlue)
                                        if let pri = p.pri {
                                            Text(pri).font(fm.font(8.5).weight(.bold))
                                                .foregroundStyle(pri == "P0" ? Color(hex: "#d94f4f") : theme.current.textMuted)
                                        }
                                        Text(p.status).font(fm.font(9))
                                            .foregroundStyle(p.code == "SJWC" ? hitPrimary : theme.current.textMuted)
                                        if p.scopes.contains("mine") {
                                            Text("我参与").font(fm.font(8.5))
                                                .padding(.horizontal, 4).padding(.vertical, 1)
                                                .background(Capsule().fill(prdBlue.opacity(0.14)))
                                                .foregroundStyle(prdBlue)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    Text(p.name).font(fm.font(10.5)).foregroundStyle(theme.current.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: 8) {
                                        if let dev = p.dev, !dev.isEmpty {
                                            Text("开发 \(dev)").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                                        }
                                        Button("PRD明细") { vm.openURL(p.url) }
                                            .buttonStyle(.plain).font(fm.font(9).weight(.medium)).foregroundStyle(prdBlue)
                                        if let doc = p.docs.first {
                                            Button("需求文档") { vm.openURL(doc) }
                                                .buttonStyle(.plain).font(fm.font(9).weight(.medium)).foregroundStyle(prdBlue)
                                        }
                                    }
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 6).fill(prdBlue.opacity(0.06)))
                                .help(p.note ?? "")
                            }
                        }
                    }
                }
                Button(action: { vm.openDoc(svc) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text").font(.system(size: 10))
                        Text(svc.mapLevel == "L2" ? "打开作战地图" : "打开服务总览").font(fm.font(11).weight(.medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.accentPrimary.opacity(0.14)))
                    .foregroundStyle(theme.current.accentPrimary)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(fm.font(9.5).weight(.semibold)).foregroundStyle(theme.current.textMuted)
            content()
        }
    }

    /// 简易 chip 流式布局 (够用即可, 不引入 Layout 协议复杂度)
    private func chipFlow(_ items: [String], clickable: Bool) -> some View {
        FlowChips(items: items, clickable: clickable) { name in
            if clickable, let target = vm.service(name) { vm.selected = target }
        }
        .environmentObject(theme).environmentObject(fm)
    }

    // MARK: 需求流 —— 首屏英雄区(我的) + 组内分栏, 告别全量平铺

    private var requirementList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if vm.prdItems.isEmpty {
                    VStack(spacing: 6) {
                        Text("还没有 PRD 需求快照").font(fm.font(12)).foregroundStyle(theme.current.textMuted)
                        Text("对 AI 说「刷新PRD」拉取并标注").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity).padding(.top, 60)
                } else if !vm.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    // 搜索时直出全量命中, 不受分栏限制
                    let hits = vm.filteredPRD
                    if hits.isEmpty {
                        Text("无匹配需求 —— 换个筛选词").font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                            .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        sectionLabel("搜索结果", hits.count, tint: prdBlue)
                        ForEach(hits) { prdRow($0) }
                    }
                } else {
                    // 英雄区: 我正在参与的
                    sectionLabel("我的进行中", vm.myActive.count, tint: prdBlue)
                    if vm.myActive.isEmpty {
                        Text("暂无我参与的需求").font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                            .padding(.leading, 2)
                    } else {
                        ForEach(vm.myActive) { prdRow($0, hero: true) }
                    }
                    groupTabs.padding(.top, 8)
                    let items = vm.tabItems(vm.reqTab)
                    if items.isEmpty {
                        Text(vm.showUnroutedOnly ? "这一栏没有未路由需求" : "这一栏是空的")
                            .font(fm.font(10.5)).foregroundStyle(theme.current.textMuted)
                            .frame(maxWidth: .infinity).padding(.top, 24)
                    } else {
                        ForEach(items) { prdRow($0) }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func sectionLabel(_ title: String, _ n: Int, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(title).font(fm.font(11.5).weight(.semibold)).foregroundStyle(tint)
            Text("\(n)").font(fm.font(9.5))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(theme.current.separator.opacity(0.5)))
                .foregroundStyle(theme.current.textMuted)
        }
    }

    /// 组内分栏 Tab + 未路由筛选器
    private var groupTabs: some View {
        HStack(spacing: 6) {
            Text("组内").font(fm.font(11.5).weight(.semibold)).foregroundStyle(theme.current.textSecondary)
            ForEach(ReqTab.allCases, id: \.self) { t in
                let active = vm.reqTab == t
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { vm.reqTab = t } }) {
                    HStack(spacing: 4) {
                        Text(t.rawValue).font(fm.font(10.5).weight(active ? .bold : .regular))
                        Text("\(vm.tabItems(t).count)").font(fm.font(9))
                            .foregroundStyle(active ? theme.current.accentPrimary : theme.current.textMuted.opacity(0.7))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(active ? theme.current.accentPrimary.opacity(0.14) : theme.current.cardFill.opacity(theme.current.cardFillOpacity * 0.5)))
                    .overlay(Capsule().stroke(active ? theme.current.accentPrimary.opacity(0.4) : theme.current.separator, lineWidth: 0.5))
                    .foregroundStyle(active ? theme.current.accentPrimary : theme.current.textMuted)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if !vm.prdUnrouted.isEmpty {
                Button(action: { withAnimation(.easeInOut(duration: 0.15)) { vm.showUnroutedOnly.toggle() } }) {
                    HStack(spacing: 3) {
                        if vm.showUnroutedOnly { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                        Text("未路由 \(vm.prdUnrouted.count)").font(fm.font(10))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(hitPrimary.opacity(vm.showUnroutedOnly ? 0.28 : 0.12)))
                    .foregroundStyle(hitPrimary)
                }
                .buttonStyle(.plain)
                .help("只看定不出目标服务的需求（告诉 AI 补标注）")
            }
        }
    }

    private func prdRow(_ p: BizPRDItem, hero: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(p.no).font(fm.font(9.5).weight(.bold)).foregroundStyle(prdBlue)
                if let pri = p.pri {
                    Text(pri).font(fm.font(9).weight(.bold))
                        .foregroundStyle(pri == "P0" ? Color(hex: "#d94f4f") : theme.current.textMuted)
                }
                Text(p.status).font(fm.font(9))
                    .foregroundStyle(p.code == "SJWC" ? hitPrimary : (hero ? prdBlue : theme.current.textMuted))
                if let dev = p.dev, !dev.isEmpty {
                    Text("开发 \(dev)").font(fm.font(9)).foregroundStyle(theme.current.textMuted)
                }
                Spacer(minLength: 0)
                Button("PRD明细") { vm.openURL(p.url) }
                    .buttonStyle(.plain).font(fm.font(9).weight(.medium)).foregroundStyle(prdBlue)
                if let doc = p.docs.first {
                    Button("需求文档") { vm.openURL(doc) }
                        .buttonStyle(.plain).font(fm.font(9).weight(.medium)).foregroundStyle(prdBlue)
                }
            }
            Text(p.name).font(fm.font(hero ? 13 : 12).weight(hero ? .semibold : .regular))
                .foregroundStyle(theme.current.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                if p.services.isEmpty {
                    Text("未路由").font(fm.font(9))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(hitPrimary.opacity(0.14))).foregroundStyle(hitPrimary)
                        .help(p.note ?? "告诉 AI 这条该落哪个服务")
                } else {
                    ForEach(p.services, id: \.self) { name in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                vm.perspective = .services
                                vm.selected = vm.service(name)
                            }
                        }) {
                            Text(name).font(fm.font(9.5))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(theme.current.accentPrimary.opacity(0.1)))
                                .foregroundStyle(theme.current.accentPrimary)
                        }
                        .buttonStyle(.plain)
                        .help("跳到服务视角并选中 \(name)")
                    }
                }
            }
        }
        .padding(hero ? 11 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(hero ? prdBlue.opacity(0.07) : theme.current.cardFill.opacity(theme.current.cardFillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(hero ? prdBlue.opacity(0.45) : theme.current.separator, lineWidth: hero ? 1.2 : 0.5))
        .help(p.note ?? "")
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 20, weight: .light))
                .foregroundStyle(theme.current.textMuted.opacity(0.6))
            Text(msg).font(fm.font(11)).foregroundStyle(theme.current.textMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("重跑生成器") { vm.regenerate() }.font(fm.font(11))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("wiki projects/业务地图/ + D板缓存 · 点卡片看详情 · 搜索即路由")
                .font(fm.font(9)).foregroundStyle(theme.current.textMuted)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(theme.current.chrome.opacity(0.15))
    }
}

// MARK: - chip 流式布局

private struct FlowChips: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let items: [String]
    let clickable: Bool
    let onTap: (String) -> Void

    var body: some View {
        // 固定宽度详情栏内用简单换行网格即可
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 56), spacing: 4, alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { it in
                Text(it).font(fm.font(9.5)).lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(theme.current.separator.opacity(0.35)))
                    .overlay(Capsule().stroke(theme.current.separator, lineWidth: 0.5))
                    .foregroundStyle(clickable ? theme.current.accentPrimary : theme.current.textSecondary)
                    .onTapGesture { onTap(it) }
            }
        }
    }
}

// MARK: - 窗口控制器 (popover + 撕出, 与 SkillsBoard 同一套模式)

final class BizMapBoardWindowController {
    static let shared = BizMapBoardWindowController()
    private var window: NSWindow?
    private var popover: NSPopover?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private let tearOff = TearOffObserver()
    private var popCloseObserver: Any?
    private let vm = BizMapViewModel()

    func togglePopover(relativeTo button: NSStatusBarButton) {
        if let pop = popover, pop.isShown {
            closePopover()
            return
        }
        let screenH = (button.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let popH = min(max(screenH * 0.72, 420), 860)
        let popW: CGFloat = 680    // 卡片墙(2列) + 详情面板 262

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        let host = NSHostingController(rootView:
            BizMapBoardView(popoverMode: true)
                .environmentObject(vm)
                .environmentObject(ThemeManager.shared)
                .environmentObject(FontManager.shared)
                .frame(width: popW, height: popH))
        pop.contentSize = NSSize(width: popW, height: popH)
        pop.contentViewController = host
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover = pop
        vm.load()

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
        popCloseObserver = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: pop, queue: .main) { [weak self] _ in
            self?.teardownMonitors()
        }
        installTearOffObserver()
    }

    private func installTearOffObserver() {
        tearOff.install(key: "BizMapBoard") { [weak self] in
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
        if let o = popCloseObserver { NotificationCenter.default.removeObserver(o); popCloseObserver = nil }
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            vm.load()
            return
        }
        let view = BizMapBoardView()
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "BizMap 业务地图"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 800, height: 620))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false
        win.isOpaque = false
        win.backgroundColor = .clear
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
        win.contentMinSize = NSSize(width: 640, height: 440)
        win.setFrameAutosaveName("DBoardBizMapWindow")
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
    }
}
