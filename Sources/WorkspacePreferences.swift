import SwiftUI
import AppKit

enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, favorites, shortcuts, codexHooks, clipboard, usage
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "通用"
        case .appearance: return "外观"
        case .favorites: return "常用入口"
        case .shortcuts: return "快捷键"
        case .codexHooks: return "Codex Hooks"
        case .clipboard: return "剪切板"
        case .usage: return "使用记录"
        }
    }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .favorites: return "star"
        case .shortcuts: return "keyboard"
        case .codexHooks: return "switch.2"
        case .clipboard: return "doc.on.clipboard"
        case .usage: return "chart.bar"
        }
    }
}

enum WorkspacePage: String, CaseIterable, Identifiable {
    case overview, demands, todos, history
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "概览"
        case .demands: return "需求"
        case .todos: return "零碎"
        case .history: return "历史"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .demands: return "list.bullet.rectangle"
        case .todos: return "checklist"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

final class WorkspacePreferences: ObservableObject {
    static let shared = WorkspacePreferences()
    static let defaultsFavorites = ["apprelease", "logs", "reqflow", "bizmap"]
    @Published var settingsPage: SettingsPage = .general
    @Published var tabNavigationEnabled: Bool {
        didSet { defaults.set(tabNavigationEnabled, forKey: "workspace.tabNavigationEnabled") }
    }
    @Published var favorites: [String] {
        didSet { defaults.set(favorites, forKey: "workspace.favorites") }
    }
    @Published var recentModules: [String] {
        didSet { defaults.set(recentModules, forKey: "workspace.recentModules") }
    }
    @Published var pinnedWindows: Set<String> {
        didSet { defaults.set(Array(pinnedWindows), forKey: "workspace.pinnedWindows") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tabNavigationEnabled = defaults.bool(forKey: "workspace.tabNavigationEnabled")
        // Keep a previously saved monitor shortcut pointing to the native tool.
        let nativeTool: (String) -> String = {
            switch $0 {
            case "sysmon": return "activitymonitor"
            case "techscout": return "githubtrending"
            default: return $0
            }
        }
        favorites = (defaults.stringArray(forKey: "workspace.favorites") ?? Self.defaultsFavorites)
            .map(nativeTool).filter { $0 != "logsearch" }
        recentModules = (defaults.stringArray(forKey: "workspace.recentModules") ?? [])
            .map(nativeTool).filter { $0 != "logsearch" }
        pinnedWindows = Set((defaults.stringArray(forKey: "workspace.pinnedWindows") ?? [])
            .map(nativeTool).filter { $0 != "logsearch" })
    }

    func setFavorite(_ id: String, enabled: Bool) {
        if enabled, !favorites.contains(id) { favorites.append(id) }
        else if !enabled { favorites.removeAll { $0 == id } }
    }

    func remember(_ id: String) {
        recentModules = Array(([id] + recentModules.filter { $0 != id }).prefix(6))
    }

    func togglePin(_ id: String) {
        if pinnedWindows.contains(id) { pinnedWindows.remove(id) }
        else { pinnedWindows.insert(id) }
    }
}

enum DBoardUI {
    static let bodySize: CGFloat = 13
    static let captionSize: CGFloat = 11
    static let spring = Animation.spring(response: 0.25, dampingFraction: 0.85)
}

struct WorkspacePinButton: View {
    @ObservedObject private var prefs = WorkspacePreferences.shared
    let id: String
    var body: some View {
        Button { prefs.togglePin(id) } label: {
            Image(systemName: prefs.pinnedWindows.contains(id) ? "pin.fill" : "pin")
        }
        .accessibilityLabel(prefs.pinnedWindows.contains(id) ? "取消置顶窗口" : "置顶窗口")
    }
}

struct DBoardSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button { openSettings() } label: {
            Image(systemName: "gearshape").dboardClickTarget()
        }
        .buttonStyle(DBoardPlainButtonStyle())
        .accessibilityLabel("打开 D板设置")
        .accessibilityIdentifier("dboard-open-settings")
    }
}

struct EmptyWorkspaceState: View {
    let icon: String
    let title: String
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).dboardFont(size: 28, weight: .light).foregroundStyle(.secondary)
            Text(title).dboardFont(size: 13, weight: .semibold)
            Text(detail).dboardFont(size: 12).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action { Button(actionTitle, action: action).controlSize(.small) }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}

struct DBoardSettingsView: View {
    @ObservedObject private var prefs: WorkspacePreferences
    @ObservedObject private var theme: ThemeManager
    @ObservedObject private var flags = FeatureFlags.shared
    @ObservedObject private var chatPrivacy = DemandChatPrivacy.shared

    init(theme: ThemeManager = .shared, preferences: WorkspacePreferences = .shared) {
        self.theme = theme
        self.prefs = preferences
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 6) {
                Text("设置").dboardFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.current.textSecondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                ForEach(SettingsPage.allCases) { page in
                    Button { prefs.settingsPage = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.icon).frame(width: 18)
                                .foregroundStyle(prefs.settingsPage == page ? theme.current.accentPrimary : theme.current.textSecondary)
                            Text(page.title).dboardFont(size: 13, weight: prefs.settingsPage == page ? .medium : .regular)
                                .foregroundStyle(theme.current.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(prefs.settingsPage == page ? theme.current.accentPrimary.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(DBoardPlainButtonStyle())
                    .accessibilityIdentifier("settings-page-" + page.rawValue)
                    .accessibilityAddTraits(prefs.settingsPage == page ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ThemeCanvasBackground(palette: theme.current).ignoresSafeArea() }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            pageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(prefs.settingsPage.title)
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
        .navigationSplitViewStyle(.balanced)
        .background { ThemeCanvasBackground(palette: theme.current).ignoresSafeArea() }
        .background(SettingsWindowSkinBridge(palette: theme.current))
        .frame(minWidth: 800, idealWidth: 840, minHeight: 620, idealHeight: 650)
        .dboardFont(size: 13)
        .dboardThemeAccent()
        .environmentObject(theme)
        .environmentObject(FontManager.shared)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch prefs.settingsPage {
        case .general:
            Form {
                Section("隐私") {
                    Toggle("需求关联钉钉群聊", isOn: Binding(get: { chatPrivacy.enabled },
                        set: { chatPrivacy.setEnabled($0) }))
                        .accessibilityIdentifier("privacy-demand-chats")
                    Text("默认关闭。开启后显示群聊关联，并向接手 AI 提供关联群及聊天读取入口。")
                        .dboardFont(size: 11).foregroundStyle(.secondary)
                    if let error = chatPrivacy.error {
                        Text(error).dboardFont(size: 11).foregroundStyle(.orange)
                    }
                }
                Section("自动化") {
                    Toggle("钉钉值守", isOn: Binding(get: { flags.replyEnabled },
                        set: { flags.setReplyEnabled($0) }))
                    Text("开启后运行值守服务，并显示待回复入口和通知。")
                        .dboardFont(size: 11).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .appearance:
            AppearanceSettingsView(theme: theme)
        case .favorites:
            Form {
                Section("常用入口") {
                    ForEach(DBoardModule.visible) { module in
                        Toggle(isOn: Binding(get: { prefs.favorites.contains(module.id) },
                            set: { prefs.setFavorite(module.id, enabled: $0) })) {
                            Label(module.title, systemImage: module.icon)
                        }
                    }
                    Text("固定到工作窗口侧栏；命令面板优先显示常用和最近使用的模块。")
                        .dboardFont(size: 11).foregroundStyle(.secondary)
                    Button("恢复默认常用入口") { prefs.favorites = WorkspacePreferences.defaultsFavorites }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        case .shortcuts:
            ShortcutSettingsView()
        case .codexHooks:
            CodexHooksSettingsView()
        case .clipboard:
            ClipboardPreferencesView()
        case .usage:
            UsageSummaryView()
        }
    }
}

/// Native Settings windows share the same titlebar and backing as the home window.
private struct SettingsWindowSkinBridge: NSViewRepresentable {
    let palette: DBoardTheme
    func makeNSView(context: Context) -> SettingsWindowSkinView {
        let view = SettingsWindowSkinView()
        view.apply(palette)
        return view
    }
    func updateNSView(_ view: SettingsWindowSkinView, context: Context) { view.apply(palette) }
}

private final class SettingsWindowSkinView: NSView {
    private var palette = DBoardTheme.defaultTheme
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply(palette)
    }
    func apply(_ palette: DBoardTheme) {
        self.palette = palette
        guard let window else { return }
        if !window.styleMask.contains(.fullSizeContentView) {
            let frame = window.frame
            window.styleMask.insert(.fullSizeContentView)
            window.setFrame(frame, display: false)
        }
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified
        window.isOpaque = !palette.nativeBlur
        window.backgroundColor = palette.nativeBlur ? .clear : NSColor(palette.background)
    }
}

struct ClipboardPreferencesView: View {
    @AppStorage("clip.historyLimit") private var limit = 500
    @AppStorage("clip.recordImages") private var images = true
    @AppStorage("clip.sensitiveTTLMinutes") private var ttl = 30
    @AppStorage("clip.floatOnWriteBack") private var floatOnWriteBack = true
    var body: some View {
        Form {
            Section("记录") {
                Picker("历史上限", selection: $limit) {
                    ForEach(Array(Set([100, 500, 1000, 2000, max(1, limit)])).sorted(), id: \.self) {
                        Text("\($0) 条").tag($0)
                    }
                }
                Toggle("记录图片", isOn: $images)
                Toggle("回写后移到最上面", isOn: $floatOnWriteBack)
                Picker("敏感内容保留", selection: $ttl) {
                    ForEach(Array(Set([5, 15, 30, 60, max(1, ttl)])).sorted(), id: \.self) {
                        Text("\($0) 分钟").tag($0)
                    }
                }
            }
            Section {
                Button("立即清理过期与超限记录") { ClipboardStore.shared.purge() }
                Text("保存在本机，包含置顶内容的记录不会因历史上限被清理。")
                    .dboardFont(size: 11).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

struct UsageSummaryView: View {
    @State private var rows: [(String, Int)] = []
    private var names: [String: String] {
        var result = Dictionary(uniqueKeysWithValues: DBoardModule.all.map { ($0.id, $0.title) })
        result["dboard"] = "D板主面板"
        for op in OpsAction.all { result["ops:" + op.id] = op.title }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("最近 14 天").dboardFont(size: 13, weight: .semibold)
                Spacer()
                Button("刷新") { rows = UsageStats.summary() }.controlSize(.small)
            }
            Text("记录入口触发次数，包含快捷键的呼出和收起。用于了解入口偏好。")
                .dboardFont(size: 11).foregroundStyle(.secondary)
            if rows.isEmpty {
                EmptyWorkspaceState(icon: "chart.bar", title: "还没有使用记录",
                    detail: "使用模块后，可以在这里查看入口触发次数。")
            } else {
                List(rows, id: \.0) { row in
                    LabeledContent(names[row.0] ?? row.0) { Text("\(row.1) 次").monospacedDigit() }
                }.scrollContentBackground(.hidden)
            }
        }
        .padding(20)
        .onAppear { rows = UsageStats.summary() }
    }
}
