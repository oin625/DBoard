import SwiftUI
import AppKit

struct CodexHooksSettingsView: View {
    @State private var inspection: CodexHookControl.Inspection?
    @State private var busy = false
    @State private var error: String?
    @State private var expanded = false
    @State private var expandedHooks: Set<String> = []
    @EnvironmentObject private var theme: ThemeManager
    private let loadsOnAppear: Bool

    init(inspection: CodexHookControl.Inspection? = nil, expanded: Bool = false, loadsOnAppear: Bool = true) {
        _inspection = State(initialValue: inspection)
        _expanded = State(initialValue: expanded)
        self.loadsOnAppear = loadsOnAppear
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button { withAnimation(DBoardUI.spring) { expanded.toggle() } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                                    .dboardFont(size: 10, weight: .semibold).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Luban 事件上报").dboardFont(size: 14, weight: .semibold)
                                    Text(statusSummary).dboardFont(size: 11).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(DBoardPlainButtonStyle())
                        .accessibilityIdentifier("codex-hooks-details")
                        if busy { ProgressView().controlSize(.small) }
                        if let status = inspection?.status, status.total > 0 {
                            if status.enabled > 0 && status.enabled < status.total {
                                Menu {
                                    Button("全部开启") { refresh(enabled: true) }
                                    Button("全部关闭") { refresh(enabled: false) }
                                } label: { Text("部分开启") }
                                    .menuStyle(DBoardMenuStyle()).disabled(busy)
                            } else {
                                Toggle("Luban 事件上报", isOn: Binding(
                                    get: { status.enabled == status.total },
                                    set: { refresh(enabled: $0) }))
                                    .labelsHidden().toggleStyle(.switch).disabled(busy)
                            }
                        }
                        Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(DBoardPlainButtonStyle()).disabled(busy)
                            .accessibilityLabel("刷新 Codex Hooks 状态")
                    }
                    if let error { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
                    if expanded {
                        Divider()
                        reportDetails
                    }
                }.padding(18).workspaceSurface()

                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("最近上报记录").dboardFont(size: 13, weight: .medium)
                        Text("当前脚本不保存请求和响应，未找到可展示的本地上报记录。")
                            .dboardFont(size: 12).foregroundStyle(.secondary)
                        Text("开关状态表示 Hook 是否启用，不代表请求已上报成功。")
                            .dboardFont(size: 11).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18).workspaceSurface()
                }
            }.padding(24)
        }
        .task { if loadsOnAppear { await update() } }
    }

    private var statusSummary: String {
        guard let status = inspection?.status else { return busy ? "正在读取…" : "状态未读取" }
        guard status.total > 0 else { return "未找到用户级 Luban 上报 Hook" }
        return "已开启 \(status.enabled)/\(status.total) 项" +
            (status.awaitingTrust > 0 ? " · \(status.awaitingTrust) 项待在 Codex 审核" : "")
    }

    private var reportDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("上报哪些事件").dboardFont(size: 13, weight: .medium)
            if let inspection {
                ForEach(inspection.hooks.sorted { eventOrder($0) < eventOrder($1) }) { hook in
                    hookRow(hook)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("如何上报").dboardFont(size: 13, weight: .medium)
                Text("Codex 传入的事件 JSON 整体转发，原字段保留；具体字段随事件和 Codex 版本变化。")
                    .dboardFont(size: 12).foregroundStyle(.secondary)
                if inspection?.hooks.allSatisfy({ $0.version == "1.1.6" }) == true,
                   inspection?.hooks.isEmpty == false {
                    Text("Luban 1.1.6 · POST https://ai.tmallyc.com/api/hook/event")
                        .dboardFont(size: 11).textSelection(.enabled)
                    Text("补充来源 source_channel=codex、可用的员工标识 emp_id。提交提示时，若提供文件附件路径，会读取文件开头并补充最多 200 字符的内容。")
                        .dboardFont(size: 12).foregroundStyle(.secondary)
                    Text("请求头还带有插件名称、版本、操作系统；有签名密钥时带时间戳与签名。请求最长等待约 2 秒，网络错误被脚本忽略。")
                        .dboardFont(size: 12).foregroundStyle(.secondary)
                }
            }
            Button {
                NSWorkspace.shared.open(CodexHookControl().home.appendingPathComponent("hooks.json"))
            } label: { Label("打开本机 Hook 配置", systemImage: "doc.text") }
                .buttonStyle(DBoardPlainButtonStyle()).foregroundStyle(theme.current.accentPrimary)
            Text("这里仅控制 report-event.js；提示注入、更新检查等其他 Hook 不受此开关影响。切换后用新会话验证。")
                .dboardFont(size: 11).foregroundStyle(.secondary)
        }
    }

    private func eventOrder(_ hook: CodexHookControl.HookDetail) -> Int {
        ["userPromptSubmit", "preToolUse", "postToolUse", "postToolUseFailure", "stop"]
            .firstIndex(of: hook.eventName) ?? 99
    }

    private func hookRow(_ hook: CodexHookControl.HookDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(DBoardUI.spring) {
                    if expandedHooks.contains(hook.id) { expandedHooks.remove(hook.id) }
                    else { expandedHooks.insert(hook.id) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(hook.title).dboardFont(size: 12, weight: .medium)
                    Text(hook.eventName).dboardFont(size: 10, design: .monospaced).foregroundStyle(.secondary)
                    Spacer()
                    Text(hook.enabled ? (hook.trusted ? "已开启" : "待审核") : "已关闭")
                        .dboardFont(size: 11).foregroundStyle(hook.enabled ? theme.current.accentPrimary : Color.secondary)
                    Image(systemName: expandedHooks.contains(hook.id) ? "chevron.down" : "chevron.right")
                        .dboardFont(size: 9).foregroundStyle(.secondary)
                }
                Text(hook.contentSummary).dboardFont(size: 12).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(12).contentShape(Rectangle())
            }.buttonStyle(DBoardPlainButtonStyle()).accessibilityIdentifier("codex-hook-" + hook.eventName)
            if expandedHooks.contains(hook.id) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("匹配：\(hook.matcher ?? "全部") · \(hook.asynchronous ? "异步" : "同步")" +
                         (hook.timeout.map { " · 超时 \($0) 秒" } ?? ""))
                        .dboardFont(size: 11).foregroundStyle(.secondary)
                    Text(hook.command).dboardFont(size: 11, design: .monospaced)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let url = hook.scriptURL {
                        Button("查看上报脚本") { NSWorkspace.shared.open(url) }
                            .buttonStyle(DBoardPlainButtonStyle()).foregroundStyle(theme.current.accentPrimary)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
            .background(theme.current.accentPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func refresh(enabled: Bool? = nil) { Task { await update(enabled: enabled) } }
    @MainActor private func update(enabled: Bool? = nil) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            inspection = try await Task.detached(priority: .userInitiated) {
                try CodexHookControl().inspect(enabled: enabled)
            }.value
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
