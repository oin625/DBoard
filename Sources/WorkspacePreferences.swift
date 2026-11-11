import SwiftUI
import AppKit

enum SettingsPage: String, Hashable { case general, appearance, favorites, shortcuts, clipboard, usage }

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
    @Published var demandLayout: DemandLayout {
        didSet { defaults.set(demandLayout.rawValue, forKey: "workspace.demandLayout") }
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
        demandLayout = DemandLayout(rawValue: defaults.string(forKey: "workspace.demandLayout") ?? "") ?? .list
        // Keep a previously saved monitor shortcut pointing to the native tool.
        let nativeTool: (String) -> String = { $0 == "sysmon" ? "activitymonitor" : $0 }
        favorites = (defaults.stringArray(forKey: "workspace.favorites") ?? Self.defaultsFavorites)
            .map(nativeTool).filter { $0 != "logsearch" }
        recentModules = (defaults.stringArray(forKey: "workspace.recentModules") ?? [])
            .map(nativeTool).filter { $0 != "logsearch" }
        pinnedWindows = Set(defaults.stringArray(forKey: "workspace.pinnedWindows") ?? [])
            .filter { $0 != "logsearch" }
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
        Button { openSettings() } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("打开 D板设置")
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
    @ObservedObject private var prefs = WorkspacePreferences.shared
    @ObservedObject private var theme = ThemeManager.shared
    @ObservedObject private var flags = FeatureFlags.shared

    var body: some View {
        TabView(selection: $prefs.settingsPage) {
            Form {
                Section("自动化") {
                    Toggle("钉钉值守", isOn: Binding(get: { flags.replyEnabled },
                        set: { flags.setReplyEnabled($0) }))
                    Text("开启后运行值守服务，并显示待回复入口和通知。")
                        .dboardFont(size: 11).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }.tag(SettingsPage.general)

            AppearanceSettingsView(theme: theme)
                .tabItem { Label("外观", systemImage: "paintpalette") }.tag(SettingsPage.appearance)

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
            .tabItem { Label("常用入口", systemImage: "star") }.tag(SettingsPage.favorites)

            ShortcutSettingsView()
                .tabItem { Label("快捷键", systemImage: "keyboard") }.tag(SettingsPage.shortcuts)

            ClipboardPreferencesView()
                .tabItem { Label("剪切板", systemImage: "doc.on.clipboard") }.tag(SettingsPage.clipboard)

            UsageSummaryView()
                .tabItem { Label("使用记录", systemImage: "chart.bar") }.tag(SettingsPage.usage)
        }
        .frame(width: 640, height: 600)
        .dboardFont(size: 13)
        .dboardThemeAccent()
        .environmentObject(theme)
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
                }
            }
        }
        .padding(20)
        .onAppear { rows = UsageStats.summary() }
    }
}
