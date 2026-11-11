import SwiftUI
import Foundation

// MARK: - 通用交互样式: 按压缩放+透明度, hover 抬升, 全面板共用

struct SmoothButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    var hoverScale: CGFloat = 1.06
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : (hovered ? hoverScale : 1.0))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .brightness(hovered && !configuration.isPressed ? 0.03 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: configuration.isPressed)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: hovered)
            .onHover { hovered = $0 }
    }
}

struct HoverLift: ViewModifier {
    var scale: CGFloat = 1.05
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hovered ? scale : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovered)
            .onHover { hovered = $0 }
    }
}

// MARK: - 数据模型与 VM

struct WhitelistGroup: Identifiable, Equatable {
    let id: String      // openConversationId / openDingTalkId
    let title: String
}

final class WhitelistViewModel: ObservableObject {
    @Published var whitelist: [WhitelistGroup] = []
    @Published var userWhitelist: [WhitelistGroup] = []

    private var home: String { FileManager.default.homeDirectoryForCurrentUser.path }
    private var confPath: String { "\(home)/.dws/reply-daemon/auto-config.json" }
    private var knownPath: String { "\(home)/.dws/reply-daemon/known-groups.json" }
    private var knownUsersPath: String { "\(home)/.dws/reply-daemon/known-users.json" }

    func reload() {
        let conf = readDict(confPath)
        let cids = (conf?["whitelist_groups"] as? [String]) ?? []
        let known = readDict(knownPath)?.compactMapValues { $0 as? String } ?? [:]
        whitelist = cids.map { WhitelistGroup(id: $0, title: known[$0] ?? "群 " + String($0.prefix(10)) + "…") }
        let uids = (conf?["whitelist_users"] as? [String]) ?? []
        let knownUsers = readDict(knownUsersPath)?.compactMapValues { $0 as? String } ?? [:]
        userWhitelist = uids.map { WhitelistGroup(id: $0, title: knownUsers[$0] ?? $0) }
    }

    // 批量增删(供选择器与撤销用)
    func addGroups(_ gs: [WhitelistGroup]) {
        guard !gs.isEmpty else { return }
        var known = readDict(knownPath)?.compactMapValues { $0 as? String } ?? [:]
        for g in gs { known[g.id] = g.title }
        writeJSON(knownPath, known)
        mutateConf { conf in
            var cids = (conf["whitelist_groups"] as? [String]) ?? []
            var ctx = (conf["group_context"] as? [String: String]) ?? [:]
            for g in gs where !cids.contains(g.id) {
                cids.append(g.id)
                if ctx[g.id] == nil { ctx[g.id] = "" }
            }
            conf["whitelist_groups"] = cids
            conf["group_context"] = ctx
        }
        reload()
    }

    func removeGroups(_ ids: [String]) {
        mutateConf { conf in
            var cids = (conf["whitelist_groups"] as? [String]) ?? []
            cids.removeAll { ids.contains($0) }
            conf["whitelist_groups"] = cids
        }
        reload()
    }

    func addUsers(_ us: [WhitelistGroup]) {
        guard !us.isEmpty else { return }
        var known = readDict(knownUsersPath)?.compactMapValues { $0 as? String } ?? [:]
        for u in us { known[u.id] = u.title.components(separatedBy: " · ").first ?? u.title }
        writeJSON(knownUsersPath, known)
        mutateConf { conf in
            var uids = (conf["whitelist_users"] as? [String]) ?? []
            for u in us where !uids.contains(u.id) { uids.append(u.id) }
            conf["whitelist_users"] = uids
        }
        reload()
    }

    func removeUsers(_ ids: [String]) {
        mutateConf { conf in
            var uids = (conf["whitelist_users"] as? [String]) ?? []
            uids.removeAll { ids.contains($0) }
            conf["whitelist_users"] = uids
        }
        reload()
    }

    // 选择器数据源
    func fetchAllGroups(_ done: @escaping ([WhitelistGroup]) -> Void) {
        DispatchQueue.global().async {
            let out = self.runDws(["chat", "group", "list-all", "--limit", "200", "-f", "json"])
            var results: [WhitelistGroup] = []
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = obj["result"] as? [String: Any],
               let groups = result["groups"] as? [[String: Any]] {
                results = groups.compactMap { g in
                    guard let cid = g["openConversationId"] as? String,
                          let title = g["title"] as? String else { return nil }
                    return WhitelistGroup(id: cid, title: title)
                }
            }
            DispatchQueue.main.async { done(results) }
        }
    }

    func knownUserList() -> [WhitelistGroup] {
        (readDict(knownUsersPath)?.compactMapValues { $0 as? String } ?? [:])
            .map { WhitelistGroup(id: $0.key, title: $0.value) }
            .sorted { $0.title < $1.title }
    }

    func contactSearch(_ q: String, _ done: @escaping ([WhitelistGroup]) -> Void) {
        DispatchQueue.global().async {
            let out = self.runDws(["contact", "user", "search", "--query", q, "-f", "json"])
            var results: [WhitelistGroup] = []
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let users = obj["result"] as? [[String: Any]] {
                results = users.compactMap { u in
                    guard let ding = u["openDingTalkId"] as? String else { return nil }
                    let name = (u["name"] as? String) ?? (u["nick"] as? String) ?? ding
                    let title = (u["title"] as? String).map { "\(name) · \($0)" } ?? name
                    return WhitelistGroup(id: ding, title: title)
                }
            }
            DispatchQueue.main.async { done(results) }
        }
    }

    // MARK: helpers
    private func mutateConf(_ mutate: (inout [String: Any]) -> Void) {
        guard var conf = readDict(confPath) else { return }
        mutate(&conf)
        writeJSON(confPath, conf)
    }

    private func readDict(_ path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeJSON(_ path: String, _ obj: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    fileprivate func runDws(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let cmd = "\(home)/.qoderwork/bin/dws " + args.map { "'\($0)'" }.joined(separator: " ") + " -y"
        p.arguments = ["-c", cmd]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } catch { return "" }
    }
}

// MARK: - 主面板: 只展示当前生效配置

struct WhitelistPanel: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @StateObject private var vm = WhitelistViewModel()
    @State private var showGroupPicker = false
    @State private var showUserPicker = false
    @State private var confirmRemoveID: String? = nil
    @State private var toastText: String? = nil
    @State private var toastUndo: (() -> Void)? = nil
    @State private var toastToken = 0
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("值守白名单")
                        .font(fm.font(20))
                        .foregroundStyle(theme.current.accentGradient)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .dboardFont(size: 18)
                            .foregroundStyle(theme.current.textTertiary)
                    }
                    .buttonStyle(SmoothButtonStyle(hoverScale: 1.12))
                }
                Text("白名单内 AI 自动值守秒回；名单外等你 5 分钟没动才进面板。改完即生效。")
                    .font(fm.font(12))
                    .foregroundStyle(theme.current.textTertiary)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("群值守 (\(vm.whitelist.count))", add: "添加群") { showGroupPicker = true }
                        if vm.whitelist.isEmpty { emptyHint("还没有群开启自动值守") }
                        ForEach(vm.whitelist) { g in
                            memberRow(g, icon: "checkmark.shield.fill") { requestRemove(g, isUser: false) }
                        }

                        sectionHeader("单聊值守 (\(vm.userWhitelist.count))", add: "添加联系人") { showUserPicker = true }
                            .padding(.top, 8)
                        if vm.userWhitelist.isEmpty { emptyHint("还没有联系人开启自动值守") }
                        ForEach(vm.userWhitelist) { u in
                            memberRow(u, icon: "person.fill.checkmark") { requestRemove(u, isUser: true) }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .padding(20)

            if let text = toastText {
                toastView(text)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: 420, height: 480)
        .background(theme.current.background)
        .focusEffectDisabled()
        .onAppear { vm.reload() }
        .sheet(isPresented: $showGroupPicker) {
            MemberPicker(mode: .group, existingIds: Set(vm.whitelist.map(\.id)), vm: vm,
                onConfirm: { picked in
                    vm.addGroups(picked)
                    showGroupPicker = false
                    showToast("已加入 \(picked.map(\.title).joined(separator: "、"))") {
                        vm.removeGroups(picked.map(\.id))
                    }
                },
                onCancel: { showGroupPicker = false })
                .environmentObject(theme).dboardFont(size: 13).environmentObject(fm)
        }
        .sheet(isPresented: $showUserPicker) {
            MemberPicker(mode: .user, existingIds: Set(vm.userWhitelist.map(\.id)), vm: vm,
                onConfirm: { picked in
                    vm.addUsers(picked)
                    showUserPicker = false
                    showToast("已加入 \(picked.map { $0.title.components(separatedBy: " · ").first ?? $0.title }.joined(separator: "、"))") {
                        vm.removeUsers(picked.map(\.id))
                    }
                },
                onCancel: { showUserPicker = false })
                .environmentObject(theme).dboardFont(size: 13).environmentObject(fm)
        }
    }

    // MARK: 组件

    private func sectionHeader(_ title: String, add: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(fm.font(14))
                .foregroundStyle(theme.current.textSecondary)
            Spacer()
            Button(action: action) {
                HStack(spacing: 3) {
                    Image(systemName: "plus").dboardFont(size: 9, weight: .bold)
                    Text(add).font(fm.font(12))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(theme.current.accentPrimary))
                .shadow(color: theme.current.accentPrimary.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(SmoothButtonStyle())
        }
    }

    private func emptyHint(_ t: String) -> some View {
        Text(t)
            .font(fm.font(12))
            .foregroundStyle(theme.current.textTertiary)
            .padding(.vertical, 4)
    }

    private func memberRow(_ g: WhitelistGroup, icon: String, onRemove: @escaping () -> Void) -> some View {
        MemberRowView(g: g, icon: icon,
                      confirming: confirmRemoveID == g.id,
                      onRemove: onRemove)
            .environmentObject(theme).dboardFont(size: 13).environmentObject(fm)
    }

    private func requestRemove(_ g: WhitelistGroup, isUser: Bool) {
        if confirmRemoveID == g.id {
            confirmRemoveID = nil
            if isUser { vm.removeUsers([g.id]) } else { vm.removeGroups([g.id]) }
            showToast("已移除 \(g.title)") {
                if isUser { vm.addUsers([g]) } else { vm.addGroups([g]) }
            }
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { confirmRemoveID = g.id }
            let id = g.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if confirmRemoveID == id {
                    withAnimation { confirmRemoveID = nil }
                }
            }
        }
    }

    private func showToast(_ text: String, undo: @escaping () -> Void) {
        toastToken += 1
        let token = toastToken
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            toastText = text
            toastUndo = undo
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if toastToken == token {
                withAnimation(.easeOut(duration: 0.25)) { toastText = nil; toastUndo = nil }
            }
        }
    }

    private func toastView(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .dboardFont(size: 13)
                .foregroundStyle(.white.opacity(0.9))
            Text(text)
                .font(fm.font(12))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let undo = toastUndo {
                Button(action: {
                    undo()
                    withAnimation(.easeOut(duration: 0.2)) { toastText = nil; toastUndo = nil }
                }) {
                    Text("撤销")
                        .font(fm.font(12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.22)))
                }
                .buttonStyle(SmoothButtonStyle())
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(theme.current.accentPrimary.opacity(0.95))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3))
    }
}

// 行组件独立出来处理 hover 态
private struct MemberRowView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let g: WhitelistGroup
    let icon: String
    let confirming: Bool
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .dboardFont(size: 12)
                .foregroundStyle(theme.current.accentPrimary)
            Text(g.title)
                .font(fm.font(14))
                .foregroundStyle(theme.current.textPrimary)
                .lineLimit(1)
            Spacer()
            Button(action: onRemove) {
                Text(confirming ? "确认移除?" : "移除")
                    .font(fm.font(11))
                    .foregroundStyle(confirming ? .white : Color(hex: "#ff6b6b"))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(confirming ? Color(hex: "#ff6b6b") : Color(hex: "#ff6b6b").opacity(0.12)))
            }
            .buttonStyle(SmoothButtonStyle())
            .opacity(hovered || confirming ? 1 : 0.25)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(theme.current.textTertiary.opacity(hovered ? 0.12 : 0.06)))
        .scaleEffect(hovered ? 1.012 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovered)
        .onHover { hovered = $0 }
    }
}

// MARK: - 选择器弹层: 打开即列全量, 输入即过滤, 多选, 确认才生效

struct MemberPicker: View {
    enum Mode { case group, user }
    let mode: Mode
    let existingIds: Set<String>
    let vm: WhitelistViewModel
    var onConfirm: ([WhitelistGroup]) -> Void
    var onCancel: () -> Void

    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var query = ""
    @State private var base: [WhitelistGroup] = []
    @State private var remote: [WhitelistGroup] = []
    @State private var selected: [String: WhitelistGroup] = [:]
    @State private var loading = true
    @State private var remoteSearching = false
    @State private var searchWork: DispatchWorkItem? = nil

    private var shown: [WhitelistGroup] {
        var merged = base
        let ids = Set(base.map(\.id))
        merged += remote.filter { !ids.contains($0.id) }
        merged.removeAll { existingIds.contains($0.id) }
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            merged = merged.filter { $0.title.localizedCaseInsensitiveContains(q) }
        }
        return merged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .group ? "添加群到值守白名单" : "添加联系人到单聊值守")
                .font(fm.font(17))
                .foregroundStyle(theme.current.accentGradient)

            // 即时过滤输入框: 没有搜索按钮
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .dboardFont(size: 12)
                    .foregroundStyle(theme.current.textTertiary)
                TextField(mode == .group ? "输入过滤群名…" : "输入姓名过滤, 通讯录同步搜索…", text: $query)
                    .textFieldStyle(.plain)
                    .font(fm.font(13))
                if remoteSearching {
                    ProgressView().controlSize(.small)
                }
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .dboardFont(size: 12)
                            .foregroundStyle(theme.current.textTertiary)
                    }
                    .buttonStyle(SmoothButtonStyle())
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(theme.current.textTertiary.opacity(0.08)))

            if loading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Text(mode == .group ? "正在拉取群列表…" : "加载中…")
                        .font(fm.font(12))
                        .foregroundStyle(theme.current.textTertiary)
                    Spacer()
                }
                .padding(.vertical, 30)
            } else if shown.isEmpty {
                HStack {
                    Spacer()
                    Text(query.isEmpty ? "没有可添加的了" : (mode == .user ? "没找到, 试试完整姓名" : "没有匹配的群"))
                        .font(fm.font(12))
                        .foregroundStyle(theme.current.textTertiary)
                    Spacer()
                }
                .padding(.vertical, 30)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(shown) { item in
                        PickerRowView(item: item, selected: selected[item.id] != nil) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                if selected[item.id] != nil { selected.removeValue(forKey: item.id) }
                                else { selected[item.id] = item }
                            }
                        }
                        .environmentObject(theme).dboardFont(size: 13).environmentObject(fm)
                    }
                }
            }

            HStack {
                Button(action: onCancel) {
                    Text("取消")
                        .font(fm.font(13))
                        .foregroundStyle(theme.current.textSecondary)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(theme.current.textTertiary.opacity(0.12)))
                }
                .buttonStyle(SmoothButtonStyle())
                Spacer()
                Button(action: { onConfirm(Array(selected.values)) }) {
                    Text(selected.isEmpty ? "添加" : "添加 \(selected.count) 个")
                        .font(fm.font(13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 7)
                        .background(Capsule().fill(selected.isEmpty
                            ? AnyShapeStyle(theme.current.textTertiary.opacity(0.35))
                            : AnyShapeStyle(theme.current.accentPrimary)))
                        .shadow(color: selected.isEmpty ? .clear : theme.current.accentPrimary.opacity(0.35), radius: 3, y: 1)
                }
                .buttonStyle(SmoothButtonStyle())
                .disabled(selected.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400, height: 440)
        .background(theme.current.background)
        .focusEffectDisabled()
        .onAppear { loadBase() }
        .onChange(of: query) { _, newValue in
            guard mode == .user else { return }
            searchWork?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { remote = []; remoteSearching = false; return }
            let work = DispatchWorkItem { [q] in
                remoteSearching = true
                vm.contactSearch(q) { results in
                    remoteSearching = false
                    remote = results
                }
            }
            searchWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func loadBase() {
        switch mode {
        case .group:
            vm.fetchAllGroups { groups in
                base = groups
                loading = false
            }
        case .user:
            base = vm.knownUserList()
            loading = false
        }
    }
}

private struct PickerRowView: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let item: WhitelistGroup
    let selected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .dboardFont(size: 15)
                    .foregroundStyle(selected ? theme.current.accentPrimary : theme.current.textTertiary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                Text(item.title)
                    .font(fm.font(14))
                    .foregroundStyle(theme.current.textPrimary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected
                    ? theme.current.accentPrimary.opacity(0.12)
                    : theme.current.textTertiary.opacity(hovered ? 0.12 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? theme.current.accentPrimary.opacity(0.5) : .clear, lineWidth: 1))
            .scaleEffect(hovered ? 1.01 : 1.0)
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.99, hoverScale: 1.0))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovered)
        .onHover { hovered = $0 }
    }
}
