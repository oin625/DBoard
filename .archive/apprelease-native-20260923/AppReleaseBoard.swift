import SwiftUI
import Cocoa

// MARK: - 应用发布台面板（抄袭 audi /app-release，⌃Q 呼出/收起）

enum ARP {
    static let blue = Color(hex: "#2878E5")
    static let blueDeep = Color(hex: "#1768D0")
    static let grad = LinearGradient(colors: [Color(hex: "#468CF0"), Color(hex: "#2574DC")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
    static let gradPublish = LinearGradient(colors: [Color(hex: "#3A91EF"), Color(hex: "#1768D0")],
                                            startPoint: .topLeading, endPoint: .bottomTrailing)
    static let ok = Color(hex: "#2FA876")
    static let err = Color(hex: "#E05C64")
    static let warn = Color(hex: "#D98E2B")
    static let info = Color(hex: "#4B95E3")

    static func guideImage() -> NSImage? {
        if let url = Bundle.main.url(forResource: "app-release-token-guide", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        let fallback = "/Users/zz/work/code/other/DBoard/Resources/app-release-token-guide.png"
        return FileManager.default.fileExists(atPath: fallback) ? NSImage(contentsOfFile: fallback) : nil
    }
}

private let mono11 = Font.system(size: 11, weight: .medium, design: .monospaced)
private let mono10 = Font.system(size: 10, weight: .medium, design: .monospaced)

private struct ARAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct AppReleaseBoardView: View {
    @ObservedObject var model: AppReleaseModel
    @EnvironmentObject var theme: ThemeManager
    @FocusState private var searchFocused: Bool
    @State private var dropdownHideWork: DispatchWorkItem?
    @State private var expandedErrors: Set<String> = []

    var body: some View {
        let t = theme.current
        ZStack(alignment: .topLeading) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header(t)
                    tokenCard(t)
                    searchCard(t)
                    if let notice = model.notice { noticeBar(notice, t) }
                    if model.selectedApp != nil {
                        goodsCard(t)
                    } else {
                        emptyHint(t)
                    }
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlayPreferenceValue(ARAnchorKey.self) { anchors in
            GeometryReader { proxy in
                if let anchor = anchors["search"], model.showAppDropdown {
                    let field = proxy[anchor]
                    let width = max(field.width, 420)
                    appDropdown(t)
                        .frame(width: width)
                        .frame(maxHeight: max(140, min(280, proxy.size.height - field.maxY - 24)))
                        .offset(x: field.minX, y: field.maxY + 8)
                }
            }
            .allowsHitTesting(model.showAppDropdown)
        }
        .overlay {
            if model.showScheduleModal { scheduleModal(t) }
        }
        .overlay {
            if model.showCreateModal { createModal(t) }
        }
        .overlay {
            if model.showTokenGuide { guideModal(t) }
        }
        .background(ThemeBackground())
        .onChange(of: searchFocused) { focused in
            dropdownHideWork?.cancel()
            if !focused, model.showAppDropdown {
                let work = DispatchWorkItem { model.showAppDropdown = false }
                dropdownHideWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        }
    }

    // MARK: 头部

    private func header(_ t: DBoardTheme) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(ARP.blue).frame(width: 7, height: 7)
                        .shadow(color: ARP.blue.opacity(0.8), radius: 4)
                    Text("RELEASE CONTROL")
                        .font(.system(size: 11, weight: .heavy, design: .monospaced))
                        .tracking(2.2)
                        .foregroundColor(ARP.blue)
                }
                Text("应用发布台")
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundColor(t.textPrimary)
                Text("选择制品，按预发验证后的路径发布到线上。网关直连运维平台，token 仅保存在本机。")
                    .font(.system(size: 13))
                    .foregroundColor(t.textSecondary)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    routeStep("制品", strong: false)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(ARP.blue)
                    routeStep("预发", strong: false)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(ARP.blue)
                    routeStep("验证", strong: false)
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundColor(ARP.blue)
                    routeStep("线上", strong: true)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 12).fill(t.cardFill.opacity(0.85)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.separator.opacity(0.8)))
                HStack(spacing: 8) {
                    Button {
                        AppReleaseWindowController.shared.togglePin()
                    } label: {
                        Image(systemName: model.pinned ? "pin.fill" : "pin.slash")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(model.pinned ? ARP.blue : t.textMuted)
                            .padding(7)
                            .background(Circle().fill(model.pinned ? ARP.blue.opacity(0.14) : t.cardFill.opacity(0.7)))
                    }
                    .buttonStyle(.plain)
                    .help(model.pinned ? "已置顶 · 点击取消置顶(失焦自动收起)" : "未置顶 · 点击置顶(失焦不收起)")
                }
            }
        }
    }

    private func routeStep(_ s: String, strong: Bool) -> some View {
        Text(s).font(.system(size: 11, weight: strong ? .heavy : .medium, design: .monospaced))
            .foregroundColor(strong ? ARP.blue : theme.current.textSecondary)
    }


    // MARK: Token 卡

    private func tokenCard(_ t: DBoardTheme) -> some View {
        card(t) {
            if let token = model.savedToken, model.tokenEditorCollapsed {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(ARP.ok).frame(width: 7, height: 7)
                            .shadow(color: ARP.ok.opacity(0.7), radius: 3)
                        Text("运维平台 token 已配置")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(t.textPrimary)
                        Text("本地 · \(arMaskToken(token))")
                            .font(mono10)
                            .foregroundColor(t.textTertiary)
                            .help("token 仅保存在本机 UserDefaults")
                    }
                    Spacer()
                    Button { model.showTokenGuide = true } label: {
                        Text("?")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundColor(ARP.blue)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(ARP.blue.opacity(0.12)))
                            .overlay(Circle().stroke(ARP.blue.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("查看 token 获取指引")
                    Button { model.tokenEditorCollapsed = false } label: {
                        Text("更换 token")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(ARP.blue)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(ARP.blue.opacity(0.10)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ARP.blue.opacity(0.35)))
                    }
                    .buttonStyle(BounceButtonStyle())
                    Button { model.clearToken() } label: {
                        Text("清除")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(t.textSecondary)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(t.cardFill.opacity(0.6)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator))
                    }
                    .buttonStyle(BounceButtonStyle())
                }
            } else {
                HStack(spacing: 14) {
                    HStack(spacing: 7) {
                        Text("运维平台 token")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(t.textPrimary)
                        Button { model.showTokenGuide = true } label: {
                            Text("?")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundColor(ARP.blue)
                                .frame(width: 18, height: 18)
                                .background(Circle().fill(ARP.blue.opacity(0.12)))
                                .overlay(Circle().stroke(ARP.blue.opacity(0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("查看 token 获取指引")
                    }
                    .frame(width: 150, alignment: .leading)
                    TextField("粘贴授权 token（仅保存到本机）", text: $model.tokenInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(t.textPrimary)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 10).fill(t.background.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.separator))
                    Button { model.saveToken() } label: {
                        Text("保存 token")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 10).fill(ARP.grad))
                    }
                    .buttonStyle(BounceButtonStyle())
                    if model.savedToken != nil {
                        Button { model.tokenEditorCollapsed = true } label: {
                            Text("收起")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(t.textSecondary)
                                .padding(.horizontal, 12).frame(height: 38)
                                .background(RoundedRectangle(cornerRadius: 10).fill(t.cardFill.opacity(0.6)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.separator))
                        }
                        .buttonStyle(BounceButtonStyle())
                    } else {
                        Button { model.clearToken() } label: {
                            Text("清除")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(t.textSecondary)
                                .padding(.horizontal, 12).frame(height: 38)
                                .background(RoundedRectangle(cornerRadius: 10).fill(t.cardFill.opacity(0.6)))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.separator))
                        }
                        .buttonStyle(BounceButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: 搜索卡 01

    private func searchCard(_ t: DBoardTheme) -> some View {
        card(t) {
            VStack(alignment: .leading, spacing: 14) {
                sectionHead(index: "01", title: "选择应用", right: "按名称搜索", t)
                HStack(spacing: 10) {
                    TextField("应用名称，回车添加",
                              text: Binding(get: { model.query }, set: { model.updateQuery($0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(t.textPrimary)
                        .focused($searchFocused)
                        .padding(.horizontal, 12)
                        .frame(width: 200, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).fill(t.background.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.separator))
                        .onSubmit { dropdownHideWork?.cancel(); model.addAppByName() }
                        .anchorPreference(key: ARAnchorKey.self, value: .bounds) { ["search": $0] }
                    Button { dropdownHideWork?.cancel(); model.addAppByName() } label: {
                        Text(model.addingApp ? "添加中…" : "添加应用")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(minWidth: 92).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10).fill(ARP.grad))
                    }
                    .buttonStyle(BounceButtonStyle())
                    .disabled(model.addingApp || model.loading)
                    Spacer()
                }
                if !model.appTabs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.appTabs) { tab in
                                appTab(tab, active: model.selectedApp?.id == tab.id, t)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func appDropdown(_ t: DBoardTheme) -> some View {
        ScrollView(showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                if model.loading {
                    dropdownText("正在匹配应用…", t)
                } else if model.apps.isEmpty {
                    dropdownText(model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "请输入应用名称" : "未找到匹配的应用", t)
                } else {
                    ForEach(model.apps) { app in
                        Button { dropdownHideWork?.cancel(); model.chooseApp(app) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(t.textPrimary)
                                Text("\(app.level) · \(app.desc) · ID \(app.id)")
                                    .font(mono10)
                                    .foregroundColor(t.textTertiary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.selectedApp?.id == app.id ? ARP.blue.opacity(0.10) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 12).fill(t.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(ARP.blue.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private func dropdownText(_ s: String, _ t: DBoardTheme) -> some View {
        Text(s).font(.system(size: 13)).foregroundColor(t.textTertiary)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func appTab(_ tab: StoredApp, active: Bool, _ t: DBoardTheme) -> some View {
        HStack(spacing: 0) {
            Button { model.chooseApp(tab.app) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(tab.name).font(.system(size: 12, weight: .bold))
                    Text("#\(tab.id)").font(mono10).foregroundColor(active ? ARP.blue.opacity(0.7) : t.textMuted)
                }
                .foregroundColor(active ? ARP.blueDeep : t.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            Button { model.removeAppTab(tab.id) } label: {
                Text("×")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(t.textMuted)
                    .frame(width: 22, height: 26)
            }
            .buttonStyle(.plain)
            .help("移除 \(tab.name)")
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(active ? ARP.blue.opacity(0.12) : t.cardFill.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(active ? ARP.blue.opacity(0.55) : t.separator.opacity(0.8)))
    }

    // MARK: Notice

    private func noticeBar(_ notice: (kind: String, text: String), _ t: DBoardTheme) -> some View {
        let color: Color = notice.kind == "success" ? ARP.ok : (notice.kind == "error" ? ARP.err : ARP.info)
        return HStack(spacing: 9) {
            Image(systemName: notice.kind == "success" ? "checkmark.circle.fill" : (notice.kind == "error" ? "xmark.octagon.fill" : "info.circle.fill"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
            Text(notice.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(t.textPrimary)
            Spacer()
            Button { model.notice = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(t.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.35)))
    }

    private func emptyHint(_ t: DBoardTheme) -> some View {
        card(t) {
            VStack(spacing: 8) {
                Image(systemName: "paperplane")
                    .font(.system(size: 28))
                    .foregroundColor(t.textMuted)
                Text("保存 token 并搜索应用后，这里会列出制品与发布操作")
                    .font(.system(size: 13))
                    .foregroundColor(t.textTertiary)
                Text("⌃Q 呼出/收起 · Esc 关闭")
                    .font(mono10)
                    .foregroundColor(t.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
        }
    }

    // MARK: 制品卡 02

    private func goodsCard(_ t: DBoardTheme) -> some View {
        card(t, corner: 18) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    sectionHead(index: "02", title: "\(model.selectedApp?.name ?? "") 的制品", right: "", t)
                    Spacer()
                    HStack(spacing: 10) {
                        HStack(spacing: 4) {
                            Text("线上副本").font(.system(size: 12)).foregroundColor(t.textSecondary)
                            Text("\(model.replicas)").font(.system(size: 16, weight: .heavy, design: .monospaced)).foregroundColor(ARP.blue)
                        }
                        Button { model.openCreateModal() } label: {
                            Text("新建制品")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 9).fill(ARP.grad))
                        }
                        .buttonStyle(BounceButtonStyle())
                        .disabled(model.loading)
                        Button { model.refreshSelectedApp() } label: {
                            Text("刷新")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(t.textSecondary)
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8).fill(t.cardFill.opacity(0.6)))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator))
                        }
                        .buttonStyle(BounceButtonStyle())
                        .disabled(model.loading)
                    }
                }
                .padding(.bottom, 14)

                scheduleList(t)

                if model.loading {
                    emptyRow("正在加载制品信息…", t)
                } else if model.goods.isEmpty {
                    emptyRow("未查询到制品。请确认应用权限或在运维平台检查制品。", t)
                } else {
                    unverifiedBanner(t)
                    Text(model.goodsExpanded ? "展开显示最近 10 个制品" : "仅展示最近 5 个制品")
                        .font(.system(size: 11))
                        .foregroundColor(t.textTertiary)
                        .padding(.bottom, 6)
                    ScrollView(.vertical, showsIndicators: true) {
                        goodsTable(t)
                    }
                    .frame(maxHeight: 460)
                    if model.goods.count > 5 {
                        Button { model.goodsExpanded.toggle() } label: {
                            HStack(spacing: 5) {
                                Text(model.goodsExpanded ? "收起" : "查看更多制品（共 \(model.goods.count) 个）")
                                    .font(.system(size: 12, weight: .bold))
                                Image(systemName: model.goodsExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 10, weight: .heavy))
                            }
                            .foregroundColor(ARP.blue)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(ARP.blue.opacity(0.07)))
                        }
                        .buttonStyle(BounceButtonStyle())
                        .padding(.top, 6)
                    }
                }

                publishHistoryBlock(t)
                HStack(alignment: .top, spacing: 12) {
                    envState(env: "pre", label: "预发环境", icon: "waveform.path", t)
                    envState(env: "prod", label: "生产环境", icon: "arrow.up.circle", t)
                }
                .padding(.top, 16)
            }
        }
    }

    private func sectionHead(index: String, title: String, right: String, _ t: DBoardTheme) -> some View {
        HStack(spacing: 10) {
            Text(index).font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundColor(ARP.blue)
            Text(title).font(.system(size: 17, weight: .heavy)).foregroundColor(t.textPrimary)
            if !right.isEmpty {
                Text(right).font(mono10).foregroundColor(t.textTertiary)
            }
        }
    }

    // MARK: 预发/线上发布记录（最近 3 次）

    private func publishHistoryBlock(_ t: DBoardTheme) -> some View {
        func row(_ rec: ReleaseRecord) -> some View {
            HStack(spacing: 8) {
                Text(rec.time).font(.system(size: 11, design: .monospaced)).foregroundColor(t.textMuted)
                Text("#\(rec.goodsID)").font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(t.textPrimary)
                Text(rec.branch).font(.system(size: 11, design: .monospaced)).foregroundColor(ARP.blue.opacity(0.9))
                    .frame(maxWidth: 120, alignment: .leading)
                    .lineLimit(1).truncationMode(.middle)
                Text(rec.operatorName).font(.system(size: 11)).foregroundColor(t.textSecondary).lineLimit(1)
                Text(rec.status).font(.system(size: 11, weight: .semibold)).foregroundColor(rec.succeeded ? ARP.ok : ARP.err).lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7).fill((rec.succeeded ? ARP.ok : ARP.err).opacity(0.06)))
        }
        func col<Content: View>(_ key: String, _ label: String, @ViewBuilder content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12, weight: .bold)).foregroundColor(t.textSecondary)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        let preItems = model.records["pre"] ?? []
        let prodItems = model.records["prod"] ?? []
        let emptyTip = Text(model.loading ? "正在加载发布记录…" : "暂无发布记录")
            .font(.system(size: 11)).foregroundColor(t.textMuted)
        return HStack(alignment: .top, spacing: 14) {
            col("pre", "预发发布记录") {
                if preItems.isEmpty { emptyTip }
                ForEach(preItems) { rec in row(rec) }
            }
            col("prod", "线上发布记录") {
                if prodItems.isEmpty { emptyTip }
                ForEach(prodItems) { rec in row(rec) }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(t.cardFill.opacity(0.5)))
    }

    // MARK: 定时任务列表

    private func scheduleList(_ t: DBoardTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("定时").font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundColor(ARP.blue)
                Text("定时部署").font(.system(size: 13, weight: .bold)).foregroundColor(t.textPrimary)
                Spacer()
                Text("DBoard 本地任务队列").font(mono10).foregroundColor(t.textTertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            ForEach(model.schedules) { task in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 9) {
                        Image(systemName: "clock").font(.system(size: 11)).foregroundColor(t.textTertiary)
                        Text(arFormatFull(task.at)).font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(ARP.blue)
                        Text("\(task.appName) · 制品 \(task.goodsID) · \(task.replicas) 副本")
                            .font(.system(size: 12)).foregroundColor(t.textSecondary).lineLimit(1)
                        Spacer()
                        Text(task.status == "failed" ? "失败详情 ▾" : task.statusLabel)
                            .font(mono10)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(schedColor(task.status).opacity(0.15)))
                            .foregroundColor(schedColor(task.status))
                        if task.status == "scheduled" {
                            Button { model.cancelSchedule(task) } label: {
                                Text("删除").font(.system(size: 11, weight: .medium)).foregroundColor(ARP.err)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if task.status == "failed", expandedErrors.contains(task.id), !task.error.isEmpty {
                        Text(task.error)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(ARP.err)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(9)
                            .background(RoundedRectangle(cornerRadius: 7).fill(ARP.err.opacity(0.07)))
                    } else if task.status == "failed", !task.error.isEmpty {
                        Text(task.error).font(.system(size: 11)).foregroundColor(ARP.err)
                            .lineLimit(1).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard task.status == "failed" else { return }
                    if expandedErrors.contains(task.id) { expandedErrors.remove(task.id) }
                    else { expandedErrors.insert(task.id) }
                }
                Divider()
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(t.chrome.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.separator.opacity(0.8)))
        .padding(.bottom, 14)
    }

    private func schedColor(_ status: String) -> Color {
        switch status {
        case "completed": return ARP.ok
        case "failed": return ARP.err
        case "running": return ARP.info
        default: return ARP.blue
        }
    }

    private func goodStatusFg(_ good: ReleaseGood, _ t: DBoardTheme) -> Color {
        if good.awaitingProdVerify { return ARP.warn }
        if good.prodVerifying { return ARP.info }
        if good.awaitingProduction { return ARP.blue }
        if good.waitingVerification { return ARP.warn }
        return t.textSecondary
    }

    // MARK: 制品表

    @ViewBuilder
    private func unverifiedBanner(_ t: DBoardTheme) -> some View {
        let pending = model.pendingProdVerify
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(pending) { g in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(ARP.warn)
                            .font(.system(size: 12))
                        Text("制品 \(g.name)（ID \(g.id)）处于「\(g.status)」，尚未完成生产验证")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(ARP.warn)
                            .textSelection(.enabled)
                    }
                }
                Text("线上发布进行中，请先完成「线上制品验证」或确认该制品不再发布，否则新发布会与其相互覆盖。")
                    .font(.system(size: 11))
                    .foregroundColor(ARP.warn.opacity(0.85))
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(ARP.warn.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ARP.warn.opacity(0.5)))
            .padding(.bottom, 9)
        }
    }

    private func goodsTable(_ t: DBoardTheme) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tableHead("制品", 200)
                tableHead("Git 分支", 170)
                tableHead("状态", 130)
                tableHead("创建", 120)
                tableHead("更新", 80)
                tableHead("操作", 0)
            }
            .padding(.vertical, 10).padding(.horizontal, 12)
            .background(t.chrome.opacity(0.22))
            ForEach(model.displayGoods) { good in
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(good.name).font(.system(size: 13, weight: .semibold)).foregroundColor(t.textPrimary).lineLimit(2)
                            Text("ID \(good.id)").font(mono10).foregroundColor(t.textMuted)
                        }.frame(width: 200, alignment: .leading)
                        Text(good.branch).font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(ARP.blue.opacity(0.9)).lineLimit(1)
                            .frame(width: 170, alignment: .leading)
                        Text(good.status)
                            .font(mono10)
                            .foregroundColor(goodStatusFg(good, t))
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(goodStatusFg(good, t).opacity(0.12)))
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                        Text(good.created).font(mono10).foregroundColor(t.textTertiary).frame(width: 90, alignment: .leading)
                        Text(good.updated).font(mono10).foregroundColor(t.textTertiary).frame(width: 90, alignment: .leading)
                        HStack(spacing: 6) {
                            if !good.logURL.isEmpty {
                                smallLinkButton("制品日志", t) { NSWorkspace.shared.open(URL(string: good.logURL)!) }
                            }
                            rowActions(good, t)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 12).padding(.horizontal, 12)
                    Divider()
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(t.cardFill.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(t.separator.opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func tableHead(_ s: String, _ w: CGFloat) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .foregroundColor(theme.current.textTertiary)
            .frame(width: w == 0 ? nil : w, alignment: .leading)
            .frame(maxWidth: w == 0 ? .infinity : nil, alignment: .leading)
    }

    enum BtnStyle { case plain, publish }

    @ViewBuilder
    private func rowActions(_ good: ReleaseGood, _ t: DBoardTheme) -> some View {
        let publishing = model.busyAction == "prod-\(good.id)" || model.busyAction == "pub-\(good.id)" || model.busyAction == "vp-\(good.id)"
        if good.waitingVerification || good.awaitingProduction || good.awaitingProdVerify {
            actionButton(model.busyAction == "pre-\(good.id)" ? "部署中…" : "重新部署预发", style: .plain, busy: model.busyAction != nil) {
                model.deployPre(good)
            }
            actionButton(good.awaitingProdVerify && !publishing ? "线上制品验证" : (publishing ? "发布中…" : "部署线上"),
                         style: .publish, busy: model.busyAction != nil) {
                if good.awaitingProdVerify { model.verifyProduction(good) } else { model.deployProduction(good) }
            }
            actionButton(model.busyAction == "rebuild-\(good.id)" ? "处理中…" : "重制并部署线上", style: .plain, busy: model.busyAction != nil) {
                model.redeployThenPublish(good)
            }
            actionButton("定时部署", style: .plain, busy: false) {
                model.openScheduleModal(goodID: good.id)
            }
        }
    }

    private func actionButton(_ title: String, style: BtnStyle, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(style == .publish ? .white : ARP.blue)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(style == .publish ? AnyShapeStyle(ARP.gradPublish) : AnyShapeStyle(ARP.blue.opacity(0.10))))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(style == .publish ? Color.clear : ARP.blue.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(BounceButtonStyle())
        .disabled(busy)
    }

    private func smallLinkButton(_ title: String, _ t: DBoardTheme, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(ARP.blue)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(ARP.blue.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(ARP.blue.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(BounceButtonStyle())
    }

    private func emptyRow(_ s: String, _ t: DBoardTheme) -> some View {
        Text(s).font(.system(size: 13)).foregroundColor(t.textTertiary)
            .frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    // MARK: 环境部署状态

    private func envState(env: String, label: String, icon: String, _ t: DBoardTheme) -> some View {
        let state = model.envStates[env]
        return VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup {
                VStack(spacing: 8) {
                    if let s = state, s.hasPods {
                        ForEach(s.pods) { pod in podCard(pod, t) }
                    } else if let s = state {
                        Text(s.detail).font(.system(size: 12)).foregroundColor(t.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        Text("等待应用状态接口返回部署信息").font(.system(size: 12)).foregroundColor(t.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(ARP.blue)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(ARP.blue.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(label)部署情况").font(.system(size: 11)).foregroundColor(t.textTertiary)
                        Text(state?.title ?? (model.selectedApp?.name ?? ""))
                            .font(.system(size: 14, weight: .bold)).foregroundColor(t.textPrimary)
                        Text(state?.summary ?? "暂无部署记录")
                            .font(.system(size: 11)).foregroundColor(t.textTertiary).lineLimit(1)
                    }
                    Spacer()
                }
            }
            .tint(ARP.blue)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(t.cardFill.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(env == "prod" ? ARP.blue.opacity(0.3) : t.separator.opacity(0.8)))
    }

    private func podCard(_ pod: ReleasePod, _ t: DBoardTheme) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pod.name).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(t.textPrimary).lineLimit(1)
                Spacer()
                Text(pod.state)
                    .font(mono10)
                    .foregroundColor(ARP.ok)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(ARP.ok.opacity(0.14)))
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 8) {
                podField("Pod IP", pod.podIP, t)
                podField("主机 IP", pod.hostIP, t)
                podField("Git 分支", pod.branch, t)
                podField("制品 ID", pod.goodsID, t)
                podField("重启次数", pod.restarts, t)
                podField("启动时间", pod.startTime, t)
                podField("镜像", pod.image, t)
            }
            if !pod.webShell.isEmpty {
                Button { NSWorkspace.shared.open(URL(string: pod.webShell)!) } label: {
                    Text("打开 WebShell ↗").font(.system(size: 11, weight: .bold)).foregroundColor(ARP.blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(t.background.opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(t.separator.opacity(0.8)))
    }

    private func podField(_ key: String, _ value: String, _ t: DBoardTheme) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.system(size: 10)).foregroundColor(t.textMuted)
            Text(value).font(.system(size: 11, design: .monospaced)).foregroundColor(t.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 弹层

    private func scheduleModal(_ t: DBoardTheme) -> some View {
        modalBackdrop {
            VStack(alignment: .leading, spacing: 14) {
                modalHead(kicker: "定时发布", title: "选择发布时间") { model.showScheduleModal = false }
                VStack(alignment: .leading, spacing: 6) {
                    Text("制品").font(.system(size: 12, weight: .bold)).foregroundColor(t.textSecondary)
                    Picker("", selection: $model.scheduleGoodID) {
                        ForEach(model.displayGoods) { good in
                            Text("\(good.name) · ID \(good.id)").tag(good.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("发布时间").font(.system(size: 12, weight: .bold)).foregroundColor(t.textSecondary)
                    DatePicker("", selection: $model.scheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                HStack {
                    Spacer()
                    Button { model.showScheduleModal = false } label: {
                        modalButtonTitle("取消", filled: false, t)
                    }
                    .buttonStyle(.plain)
                    Button {
                        guard !model.scheduleGoodID.isEmpty else {
                            model.noticeMsg("error", "请先选择要定时部署的制品")
                            return
                        }
                        model.scheduleProduction(model.scheduleGoodID, at: model.scheduleDate)
                    } label: {
                        modalButtonTitle("确认定时发布", filled: true, t)
                    }
                    .buttonStyle(BounceButtonStyle())
                }
                .padding(.top, 8)
            }
            .modalCard(t)
        }
    }

    private func createModal(_ t: DBoardTheme) -> some View {
        modalBackdrop {
            VStack(alignment: .leading, spacing: 14) {
                modalHead(kicker: "新建制品", title: "从 Git 分支创建预发制品") { if !model.creatingGood { model.showCreateModal = false } }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Git 分支").font(.system(size: 12, weight: .bold)).foregroundColor(t.textSecondary)
                    TextField("输入分支名称，自动匹配，例如 feature/user", text: $model.branchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(t.textPrimary)
                        .padding(.horizontal, 10).frame(height: 38)
                        .background(RoundedRectangle(cornerRadius: 9).fill(t.background.opacity(0.35)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(t.separator))
                        .onChange(of: model.branchQuery) { model.updateBranchQuery($0) }
                    if model.branchLoading {
                        Text("正在匹配分支…").font(.system(size: 11)).foregroundColor(t.textTertiary)
                    } else if !model.branchSuggestions.isEmpty {
                        ScrollView(showsIndicators: true) {
                            VStack(spacing: 0) {
                                ForEach(model.branchSuggestions, id: \.self) { branch in
                                    Button { model.branchQuery = branch; model.branchSuggestions = []; model.branchSearched = false } label: {
                                        Text(branch)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(branch == model.branchQuery ? ARP.blueDeep : t.textSecondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 10).padding(.vertical, 7)
                                            .background(branch == model.branchQuery ? ARP.blue.opacity(0.10) : Color.clear)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    Divider()
                                }
                            }
                        }
                        .frame(maxHeight: 160)
                        .background(RoundedRectangle(cornerRadius: 9).fill(t.background))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(t.separator))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    } else if model.branchSearched {
                        Text("未找到匹配分支").font(.system(size: 11)).foregroundColor(t.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("创建后操作").font(.system(size: 12, weight: .bold)).foregroundColor(t.textSecondary)
                    Picker("", selection: $model.createMode) {
                        ForEach(AppReleaseModel.CreateMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                    .onChange(of: model.createMode) { _ in }
                }
                if model.createMode == .schedule {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("发布时间").font(.system(size: 12, weight: .bold)).foregroundColor(t.textSecondary)
                        DatePicker("", selection: $model.scheduleDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .datePickerStyle(.field)
                    }
                }
                HStack {
                    Spacer()
                    Button { if !model.creatingGood { model.showCreateModal = false } } label: {
                        modalButtonTitle("取消", filled: false, t)
                    }
                    .buttonStyle(.plain)
                    Button { model.createGood() } label: {
                        modalButtonTitle(model.creatingGood ? "创建中…" : "创建预发制品", filled: true, t)
                    }
                    .buttonStyle(BounceButtonStyle())
                    .disabled(model.creatingGood)
                }
                .padding(.top, 8)
            }
            .modalCard(t)
        }
    }

    private func guideModal(_ t: DBoardTheme) -> some View {
        modalBackdrop {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("获取运维平台 token").font(.system(size: 18, weight: .heavy)).foregroundColor(t.textPrimary)
                    Spacer()
                    Button { model.showTokenGuide = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(t.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                if let img = ARP.guideImage() {
                    ScrollView {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(maxHeight: 540)
                } else {
                    Text("指引图片缺失：Resources/app-release-token-guide.png 未找到")
                        .font(.system(size: 13)).foregroundColor(t.textSecondary)
                }
            }
            .padding(20)
            .frame(width: 860)
            .background(RoundedRectangle(cornerRadius: 20).fill(t.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(t.separator))
            .shadow(color: .black.opacity(0.35), radius: 34, y: 14)
        }
    }

    private func modalBackdrop<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .background(.ultraThickMaterial)
                .onTapGesture {
                    if model.showTokenGuide { model.showTokenGuide = false }
                    else if model.showScheduleModal { model.showScheduleModal = false }
                    else if model.showCreateModal, !model.creatingGood { model.showCreateModal = false }
                }
            content()
        }
        .transition(.opacity)
    }

    private func modalHead(kicker: String = "", title: String, close: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                if !kicker.isEmpty {
                    Text(kicker).font(.system(size: 11, weight: .heavy, design: .monospaced)).foregroundColor(ARP.blue)
                }
                Text(title).font(.system(size: 20, weight: .heavy)).foregroundColor(theme.current.textPrimary)
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(theme.current.textMuted)
            }
            .buttonStyle(.plain)
        }
    }

    private func modalButtonTitle(_ s: String, filled: Bool, _ t: DBoardTheme) -> some View {
        Text(s)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(filled ? .white : t.textSecondary)
            .padding(.horizontal, 14).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9).fill(filled ? AnyShapeStyle(ARP.grad) : AnyShapeStyle(Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(filled ? Color.clear : t.separator, lineWidth: 1))
    }

    @ViewBuilder
    private func card<Content: View>(_ t: DBoardTheme, corner: CGFloat = 16, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                (t.cardMaterial
                 ? AnyShapeStyle(.regularMaterial)
                 : AnyShapeStyle(t.cardFill.opacity(min(t.cardFillOpacity + 0.25, 0.95))))
            )
            .overlay(RoundedRectangle(cornerRadius: corner).stroke(t.separator.opacity(0.9)))
            .clipShape(RoundedRectangle(cornerRadius: corner))
            .shadow(color: .black.opacity(t.glowEnabled ? 0.35 : 0.06), radius: 14, y: 6)
    }
}

private extension View {
    func modalCard(_ t: DBoardTheme) -> some View {
        self
            .padding(22)
            .frame(width: 460)
            .background(RoundedRectangle(cornerRadius: 20).fill(t.cardFill))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(t.separator))
            .shadow(color: .black.opacity(0.35), radius: 34, y: 14)
    }
}

// MARK: - 浮窗

final class AppReleasePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var pinned = false

    override func resignKey() {
        super.resignKey()
        if !pinned { orderOut(nil) }
    }
}

final class AppReleaseWindowController {
    static let shared = AppReleaseWindowController()
    private var window: NSWindow?
    private var escMonitor: Any?
    private let model = AppReleaseModel()

    var pinned: Bool { (window as? AppReleasePanel)?.pinned ?? false }

    func toggle() {
        if let w = window, w.isVisible { hide() } else { show() }
    }

    func togglePin() {
        guard let panel = window as? AppReleasePanel else { return }
        panel.pinned.toggle()
        model.pinned = panel.pinned
    }

    func show() {
        model.loadSelectedAppIfNeeded()
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = AppReleaseBoardView(model: model)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = AppReleasePanel(contentViewController: host)
        win.title = "应用发布台"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.setContentSize(NSSize(width: 1160, height: 800))
        win.contentMinSize = NSSize(width: 940, height: 560)
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.isMovableByWindowBackground = true
        win.backgroundColor = .windowBackgroundColor
        centerOnScreen(win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEscMonitor(win)
        window = win
    }

    func hide() {
        teardownEscMonitor()
        window?.orderOut(nil)
    }

    private func installEscMonitor(_ win: NSWindow) {
        teardownEscMonitor()
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53, win.isKeyWindow else { return e }
            if self.model.closeTopModal() { return nil }
            self.hide()
            return nil
        }
    }

    private func teardownEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    private func centerOnScreen(_ win: NSWindow) {
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first { $0.frame.contains(mouse) }
        let scr = NSScreen.main ?? mouseScreen ?? NSScreen.screens.first
        guard let f = scr?.visibleFrame else { win.center(); return }
        var fr = win.frame
        fr.size.width = min(fr.size.width, f.width - 40)
        fr.size.height = min(fr.size.height, f.height - 40)
        fr.origin.x = f.minX + (f.width - fr.width) / 2
        fr.origin.y = f.minY + (f.height - fr.height) * 0.42
        win.setFrame(fr, display: true)
    }
}
