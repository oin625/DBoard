import SwiftUI
import AppKit

// MARK: - 首屏驾驶舱
// 打开 D板 第一眼只回答一个问题: "现在有什么需要我出手?"
// 来源: 引擎心跳异常 / 钉钉待回复 / 一键运维失败 / Cookie 即将到期。没有待处理事项就不显示。

struct CockpitSection: View {
    @EnvironmentObject var theme: ThemeManager
    @ObservedObject private var health = EngineHealthModel.shared
    @ObservedObject private var reply = ReplyInboxViewModel.shared
    @ObservedObject private var ops = OpsRunner.shared
    @ObservedObject private var cookieReminder = DouyinCookieReminderStore.shared

    private var troubled: [EngineStatus] { health.engines.filter { $0.state == .warn || $0.state == .dead } }
    private var activeOperations: [OpsAction] { OpsAction.all.filter { [.running, .failed].contains(ops.state($0).phase) } }
    private var cookieDue: DouyinCookieExpiry? {
        guard let expiry = cookieReminder.expiry, expiry.needsReminder,
              !activeOperations.contains(where: { $0.id == OpsAction.douyinCookie.id }) else { return nil }
        return expiry
    }
    private var hasAttention: Bool {
        !troubled.isEmpty || !reply.items.isEmpty || !activeOperations.isEmpty || cookieDue != nil
    }

    var body: some View {
        Group {
            if hasAttention {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "待处理")
                    attentionContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }
        }
        .onAppear { cookieReminder.refresh() }
    }

    private var attentionContent: some View {
        VStack(spacing: 0) {
            if !reply.items.isEmpty {
                AttentionRow(icon: "bubble.left.and.bubble.right.fill", tint: .orange,
                             title: "\(reply.items.count) 条钉钉待回复",
                             subtitle: reply.items.first.map { "\($0.sender)：\($0.incoming)" } ?? "",
                             button: "处理") {
                    DBoardModule.all.first { $0.id == "reply" }?.launch()
                }
            }
            ForEach(activeOperations) { op in
                Divider().padding(.leading, 40)
                OpsActionRow(action: op).padding(.horizontal, 12).padding(.vertical, 10)
            }
            if let expiry = cookieDue {
                if !reply.items.isEmpty || !activeOperations.isEmpty { Divider().padding(.leading, 40) }
                AttentionRow(icon: "clock.badge.exclamationmark", tint: expiry.expired ? .red : .orange,
                             title: expiry.reminderTitle, subtitle: expiry.detail, button: "刷新") {
                    ops.requestRun(.douyinCookie)
                }
            }
            ForEach(troubled) { e in
                if !reply.items.isEmpty || !activeOperations.isEmpty || cookieDue != nil || e.id != troubled.first?.id { Divider().padding(.leading, 40) }
                AttentionRow(icon: e.icon, tint: e.state == .dead ? .red : .orange,
                             title: e.problem ?? e.name,
                             subtitle: e.detail,
                             button: e.hint == nil ? nil : "复制修复") {
                    if let h = e.hint {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(h, forType: .string)
                    }
                }
            }
        }
        .workspaceSurface()
    }
}

struct AttentionRow: View {
    @EnvironmentObject var theme: ThemeManager
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    let button: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).dboardFont(size: 14).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dboardFont(size: 13, weight: .medium).foregroundStyle(theme.current.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle).dboardFont(size: 11).foregroundStyle(theme.current.textTertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            if let b = button {
                Button(b, action: action).controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

// MARK: - 设计 token(对齐 DESIGN.md: 13 正文 / 8pt 栅格 / 卡片圆角 8)
struct SectionHeader: View {
    @EnvironmentObject var theme: ThemeManager
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title).dboardFont(size: 13, weight: .semibold).foregroundStyle(theme.current.textSecondary)
            Spacer()
            if let t = trailing {
                Label(t, systemImage: "checkmark.circle")
                    .dboardFont(size: 11).foregroundStyle(theme.current.textTertiary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 12)
    }
}

extension View {
    func cardStyle(_ t: DBoardTheme) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.cardFill.opacity(t.cardFillOpacity)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.separator.opacity(0.6), lineWidth: 0.5))
    }
}

extension ItemPriority {
    /// 语义色(深浅色自适应), 替代 dotColor 十六进制
    var color: Color {
        switch self {
        case .p0: return .red
        case .p1: return .blue
        case .p2: return .orange
        case .p3: return .secondary
        }
    }
}
