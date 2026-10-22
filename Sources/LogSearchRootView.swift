import SwiftUI
import Cocoa

// MARK: - 日志面板根视图
// 布局 = audi logs-hist 的信息架构(全宽: 工具栏/chips/应用芯片/时间行/列表/翻页)，
// 视觉 = DESIGN.md(Liquid Glass 材质条/系统字体/语义色/spring 微动效)。
// 2026-09-21: 中途试过 Pulse 式"侧栏+列表+inspector"三栏, 主区被挤死, 已回退全宽单列。

struct LogSearchRootView: View {
    @ObservedObject var vm: LogSearchViewModel
    @EnvironmentObject var theme: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 工具栏输入态
    @State private var appInput = ""
    @State private var appsOpen = false
    @State private var historyOpen = false
    @State private var timeCustomOpen = false
    @State private var draftStart = Date()
    @State private var draftEnd = Date()
    @FocusState private var kwFocused: Bool
    @FocusState private var appFocused: Bool

    // toast(对齐 audi UI.TOAST_MS=1600)
    @State private var toastText: String?
    @State private var toastToken = 0

    // 应用芯片零延迟双击判定
    @State private var lastChipTapApp: String?
    @State private var lastChipTapAt = Date.distantPast
    /// 单击"暂隐"要等双击窗口结束才落地, 否则双击钻取前会先闪一下"该应用的行被抽走"
    @State private var pendingMute: DispatchWorkItem?

    // 日志搜索模板
    @State private var templates = LogTemplateStore.load()
    @State private var tplDraft: LogSearchTemplate?
    @State private var tplValues: [String] = []
    @State private var tplSaveOpen = false
    @State private var tplSaveName = ""
    @State private var tplSaveQuery = ""
    @State private var tplSaveErr: String?

    private static let chipDoubleTapGap: TimeInterval = 0.3

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = vm.errorMsg { errorLine(err) }
            if !vm.kwTags.isEmpty { tagsStrip }
            appChipsStrip
            timeRow
            if timeCustomOpen { customTimeBar }
            Divider().opacity(0.5)
            LogResultsListView(vm: vm, toast: flashToast)
            LogPagerBar(vm: vm)
        }
        .background(theme.current.background)
        .onAppear { kwFocused = true }
        .overlay(alignment: .bottom) {
            if let toastText {
                Text(toastText)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                    .padding(.bottom, 52)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .animation(LogMotion.springUI(reduceMotion: reduceMotion), value: toastText)
        .sheet(item: $tplDraft) { t in slotSheet(t) }
        .sheet(isPresented: $tplSaveOpen) { templateSaveSheet }
    }

    // MARK: 统一工具栏

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                envChip("预发", "pre")
                envChip("生产", "prod")
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06)))

            appField
            kwField

            errToggle

            Button { vm.runQuery(1) } label: {
                Text(vm.loading ? "查询中…" : "查询")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(vm.loading ? Color.secondary.opacity(0.5) : Color.accentColor))
            }
            .buttonStyle(.plain)
            .disabled(vm.loading)
            .help("查询 (⌘Return)")
            .keyboardShortcut(.return, modifiers: .command)

            Spacer(minLength: 4)

            Button { historyOpen.toggle() } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(HoverButtonStyle(selected: historyOpen))
            .popover(isPresented: $historyOpen, arrowEdge: .bottom) { historyPopover }

            Button { vm.isPinned.toggle() } label: {
                Image(systemName: vm.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(vm.isPinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(HoverButtonStyle())
            .help("置顶：点击面板外部不再自动收起")
        }
        .padding(.horizontal, 14)
        .padding(.top, 34)          // 让出红绿灯区
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private func envChip(_ label: String, _ tag: String) -> some View {
        let active = vm.env == tag
        return Button {
            vm.env = tag
            if !vm.rows.isEmpty { vm.runQuery(1) }
        } label: {
            Text(label)
                .font(.callout.weight(active ? .medium : .regular))
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 11).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(active ? 0.9 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var errToggle: some View {
        Button { vm.errOnly.toggle() } label: {
            Text("只看ERROR")
                .font(.callout.weight(vm.errOnly ? .semibold : .regular))
                .foregroundStyle(vm.errOnly ? Color.white : Color.secondary)
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(vm.errOnly ? Color.red : Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .keyboardShortcut("e")
        .help("只显示当前结果中的 ERROR 行（本地过滤，⌘E）")
    }

    private var appField: some View {
        TextField(appInput.isEmpty && !vm.appName.isEmpty
                  ? "应用: \(vm.appName)" : "应用名",
                  text: $appInput)
            .textFieldStyle(.plain)
            .font(.body)
            .frame(width: 124)
            .focused($appFocused)
            .padding(.horizontal, 10).frame(height: 30)
            .glassField()
            .onSubmit { commitAppInput() }
            .onChange(of: appInput) { _, _ in
                // 只在真的有输入时弹联想; 窗口 key 化自动落焦不再惊扰(修"开面板自动弹下拉")
                if appFocused, !appInput.isEmpty { appsOpen = !filteredApps.isEmpty }
            }
            .popover(isPresented: $appsOpen, arrowEdge: .bottom) { appSuggestPopover }
    }

    private func commitAppInput() {
        appsOpen = false
        let name = appInput.trimmingCharacters(in: .whitespacesAndNewlines)
        appInput = ""
        if name.isEmpty { vm.runQuery(1) } else { vm.setApp(name) }
    }

    private var kwField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.secondary)
            TextField("关键词，回车固化", text: $vm.kwInput)
                .textFieldStyle(.plain)
                .font(.body)
                .focused($kwFocused)
                .onSubmit {
                    // 回车 = 固化 tag 并立即查询
                    if vm.kwInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        vm.runQuery(1)
                    } else {
                        vm.addTag(vm.kwInput)
                        vm.runQuery(1)
                    }
                }
            Menu {
                ForEach(templates) { t in
                    Button {
                        useTemplate(t)
                    } label: {
                        if let icon = t.icon { Label(t.name, systemImage: icon) }
                        else { Text(t.name) }
                    }
                }
                Divider()
                Button("保存当前关键词为模板…") {
                    tplSaveName = ""
                    tplSaveQuery = vm.activeKeywords.joined(separator: " ")
                    tplSaveErr = nil
                    tplSaveOpen = true
                }
                Button("重新加载模板") { templates = LogTemplateStore.load() }
            } label: {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("搜索模板：固定关键词一键带入，动态部分(如券码)点击时再填")
        }
        .frame(width: 240)
        .padding(.horizontal, 10).frame(height: 30)
        .glassField()
    }

    private func useTemplate(_ t: LogSearchTemplate) {
        let slots = t.slots
        if slots.isEmpty {
            vm.applyTemplate(app: t.app, env: t.env, tags: t.expand(values: []))
            vm.runQuery(1)
        } else {
            tplValues = Array(repeating: "", count: slots.count)
            tplDraft = t
        }
    }

    private func applyTemplateDraft(_ t: LogSearchTemplate) {
        vm.applyTemplate(app: t.app, env: t.env, tags: t.expand(values: tplValues))
        tplDraft = nil
        vm.runQuery(1)
    }

    @ViewBuilder
    private func slotSheet(_ t: LogSearchTemplate) -> some View {
        let slots = t.slots
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                Text("模板 · \(t.name)").font(.headline)
            }
            Text(t.query)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            ForEach(Array(slots.enumerated()), id: \.offset) { i, slot in
                HStack(spacing: 8) {
                    Text(slot.name)
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .leading)
                    TextField(slot.prompt, text: tplIndicesBinding(i))
                        .textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("取消") { tplDraft = nil }
                Button {
                    applyTemplateDraft(t)
                } label: {
                    Text("搜索").frame(minWidth: 52)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tplValues.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func tplIndicesBinding(_ i: Int) -> Binding<String> {
        Binding(get: { i < tplValues.count ? tplValues[i] : "" },
                set: { if i < tplValues.count { tplValues[i] = $0 } })
    }

    private var templateSaveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("保存为搜索模板").font(.headline)
            HStack(spacing: 8) {
                Text("名称").font(.callout).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                TextField("如: 车点点查券", text: $tplSaveName).textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: 8) {
                Text("关键词").font(.callout).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("API 车点点 {券码:粘贴券码}", text: $tplSaveQuery)
                        .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    Text("空格分隔多个关键词；{名称} 或 {名称:提示语} 标记点击时需输入的动态部分")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let err = tplSaveErr { Text(err).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { tplSaveOpen = false }
                Button("保存") {
                    let t = LogSearchTemplate(name: tplSaveName.trimmingCharacters(in: .whitespaces),
                                              app: vm.appName, env: vm.env,
                                              query: tplSaveQuery.trimmingCharacters(in: .whitespaces))
                    tplSaveErr = LogTemplateStore.save(t)
                    if tplSaveErr == nil {
                        templates = LogTemplateStore.load()
                        tplSaveOpen = false
                        flashToast("模板「\(t.name)」已保存")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(tplSaveName.trimmingCharacters(in: .whitespaces).isEmpty
                            || tplSaveQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }

    private func errorLine(_ msg: String) -> some View {
        Text(msg)
            .font(.callout)
            .foregroundStyle(Color.red)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 4)
            .background(.bar)
    }

    // MARK: 关键词 chips (点=启禁, ×=删)

    private var tagsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(vm.kwTags) { tag in
                    HStack(spacing: 4) {
                        Button { vm.toggleTag(tag.id) } label: {
                            Text(tag.text)
                                .font(.subheadline.monospaced())
                                .strikethrough(tag.disabled)
                                .foregroundStyle(tag.disabled ? Color.secondary : Color.primary)
                        }
                        .buttonStyle(.plain)
                        .help("点击切换启用/禁用")
                        Button { vm.removeTag(tag.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("删除")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(tag.disabled
                        ? Color.primary.opacity(0.05)
                        : Color.accentColor.opacity(0.13)))
                }
            }
            .padding(.horizontal, 14).padding(.bottom, 6)
        }
        .background(.bar)
    }

    // MARK: 应用芯片行 (单击暂隐 / 双击只看它 / × 排除; 灰片=恢复)

    @ViewBuilder
    private var appChipsStrip: some View {
        if !vm.detectedApps.isEmpty || !vm.excludedApps.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("应用")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                    if !vm.appName.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 9, weight: .semibold))
                            Text(vm.appName).font(.subheadline.monospaced().weight(.medium))
                            Button { vm.clearApp() } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .opacity(0.7)
                            }
                            .buttonStyle(.plain)
                            .help("移除应用过滤并重查")
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .help("当前只看该应用")
                    }
                    ForEach(vm.detectedApps.filter { $0.name != vm.appName }) { a in
                        appChip(a)
                    }
                    ForEach(vm.excludedApps, id: \.self) { name in
                        Button { vm.restoreApp(name) } label: {
                            HStack(spacing: 4) {
                                Text(name)
                                    .font(.subheadline.monospaced())
                                    .strikethrough()
                                Image(systemName: "arrow.uturn.left")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(Color.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                        .help("已排除 · 点击恢复")
                    }
                }
                .padding(.horizontal, 14).padding(.bottom, 6)
            }
            .background(.bar)
        }
    }

    private func appChip(_ a: AppCount) -> some View {
        let muted = vm.mutedApps.contains(a.name)
        return HStack(spacing: 4) {
            Text(a.name)
                .font(.subheadline.monospaced())
                .strikethrough(muted)
                .foregroundStyle(muted ? Color.secondary : Color.primary)
            Text("\(a.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
            Button { vm.excludeApp(a.name) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.secondary)
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("彻底排除 \(a.name)（NOT 重查）")
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(muted ? 0.04 : 0.07)))
        .onTapGesture { handleAppChipTap(a.name) }
        .help(muted ? "已暂隐 · 点击恢复" : "单击暂时隐藏 · 双击只看它")
    }

    private func handleAppChipTap(_ name: String) {
        let now = Date()
        if lastChipTapApp == name, now.timeIntervalSince(lastChipTapAt) < Self.chipDoubleTapGap {
            lastChipTapApp = nil
            pendingMute?.cancel()          // 双击: 那下"暂隐"根本不该落地
            pendingMute = nil
            vm.appDrill(name)
            return
        }
        lastChipTapApp = name
        lastChipTapAt = now
        pendingMute?.cancel()
        let work = DispatchWorkItem {
            lastChipTapApp = nil
            vm.toggleMute(name)
        }
        pendingMute = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chipDoubleTapGap, execute: work)
    }

    // MARK: 时间行 (6 预设 ⌘1-6 + 起止)

    private var timeRow: some View {
        HStack(spacing: 4) {
            ForEach(Array(LogSearchViewModel.presets.enumerated()), id: \.element.key) { i, p in
                timeChip(p.key, p.label, kbd: Self.presetKbd[i])
            }
            timeChipCustom
            Spacer(minLength: 6)
            Text("\(Self.fmt(vm.start)) → \(Self.fmt(vm.end))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.secondary)
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
        .background(.bar)
    }

    private func timeChip(_ key: String, _ label: String, kbd: KeyEquivalent) -> some View {
        let on = vm.activePreset == key
        return Button { vm.applyPreset(key) } label: {
            Text(label)
                .font(.callout.weight(on ? .medium : .regular))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(kbd)
    }

    private var timeChipCustom: some View {
        let on = vm.activePreset == nil
        return Button {
            if !timeCustomOpen {
                draftStart = vm.start
                draftEnd = vm.end
            }
            timeCustomOpen.toggle()
        } label: {
            Text("自定义")
                .font(.callout.weight(on ? .medium : .regular))
                .foregroundStyle(on ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? Color.accentColor.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    /// 行内自定义时间编辑器(不用 popover: 非激活面板里弹层会秒关, 导致"点了没反应")
    private var customTimeBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary)
            DatePicker("", selection: $draftStart, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.compact).controlSize(.small)
            Text("~").font(.callout).foregroundStyle(Color.secondary)
            DatePicker("", selection: $draftEnd, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.compact).controlSize(.small)
            Text("最长 15 天(生产日志保留期)")
                .font(.caption).foregroundStyle(Color.secondary)
            Button("应用") {
                timeCustomOpen = false
                vm.setCustomTime(draftStart, draftEnd)
                vm.runQuery(1)
            }
            .buttonStyle(HoverButtonStyle())
            Button("取消") { timeCustomOpen = false }
                .buttonStyle(HoverButtonStyle())
            Spacer()
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
        .background(.bar)
    }

    private static func fmt(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }

    private static let presetKbd: [KeyEquivalent] = ["1", "2", "3", "4", "5", "6"]

    // MARK: 应用联想 & 历史 popover

    private var filteredApps: [String] {
        vm.recentApps.filter {
            appInput.trimmingCharacters(in: .whitespaces).isEmpty
                || $0.localizedCaseInsensitiveContains(appInput)
        }
    }

    private var appSuggestPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(filteredApps, id: \.self) { name in
                Button {
                    appsOpen = false
                    appInput = ""
                    vm.setApp(name)
                } label: {
                    HStack(spacing: 8) {
                        Text(name).font(.body.monospaced())
                        Spacer()
                        Text("最近").font(.caption).foregroundStyle(Color.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 230)
        .padding(.vertical, 4)
    }

    private var historyPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近查询").font(.headline)
                Spacer()
                Button("清除") { vm.clearHistory() }
                    .font(.callout).foregroundStyle(Color.secondary)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if vm.recentHistory.isEmpty {
                Text("还没有历史查询")
                    .font(.callout).foregroundStyle(Color.secondary)
                    .padding(14)
            } else {
                ForEach(vm.recentHistory) { entry in
                    Button {
                        historyOpen = false
                        vm.applyHistory(entry)
                    } label: {
                        HStack(spacing: 8) {
                            Text(entry.app.isEmpty ? "(无应用)" : entry.app)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(entry.app.isEmpty
                                                 ? Color.secondary : Color.accentColor)
                                .lineLimit(1)
                                .frame(width: 96, alignment: .leading)
                            Text(entry.tagsLabel)
                                .font(.callout.monospaced())
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 390)
        .padding(.vertical, 4)
    }

    // MARK: toast

    private func flashToast(_ msg: String) {
        toastToken += 1
        let token = toastToken
        toastText = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if toastToken == token { toastText = nil }
        }
    }
}

/// 玻璃输入域: 统一搜索/应用输入框外观
private struct GlassField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09)))
    }
}

extension View {
    func glassField() -> some View { modifier(GlassField()) }
}
