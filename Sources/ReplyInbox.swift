import SwiftUI
import UserNotifications
import Combine
import AppKit

// MARK: - 数据模型 (对应 ~/.dws/reply-pending.json)

struct ReplyItem: Codable, Identifiable {
    let key: String
    let convId: String
    let convTitle: String
    let isSingle: Bool
    let sender: String
    let incoming: String
    let incomingTime: String
    let drafts: [String]
    let needInvestigation: Bool
    let investigationNote: String
    var peerDingId: String? = nil
    var msgId: String? = nil
    // 阶段4: 操作类消息 + 配方
    var kind: String? = "reply"          // "reply" | "action"
    var actionSummary: String? = nil
    var recipeMatch: String? = nil
    var recipeType: String? = nil        // "skill" | "command" | "manual"
    var slots: [String: String]? = nil
    var readOnly: Bool? = nil
    var plannedCommand: String? = nil

    var id: String { key }

    var isAction: Bool { (kind ?? "reply") == "action" }
    var hasRecipe: Bool { !(recipeMatch ?? "").isEmpty }
}

struct ReplyPayload: Codable {
    let timestamp: Double
    let items: [ReplyItem]
}

// MARK: - ViewModel

final class ReplyInboxViewModel: ObservableObject {
    static let shared = ReplyInboxViewModel()
    @Published var items: [ReplyItem] = []
    @Published var lastUpdate: Date? = nil

    private var fileObserver: FileRefreshObserver?
    private let actionDirectory: URL?
    @Published var actionFeedback: String?
    private var pollTimer: Timer?
    private var flagSubscription: AnyCancellable?
    private var lastNotifyTime: TimeInterval = 0
    private let notifyDebounce: TimeInterval = 20
    private var lastProcessedTimestamp: Double = 0

    static let pendingPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.dws/reply-pending.json"
    }()

    init(startObservers: Bool = true, actionDirectory: URL? = nil) {
        self.actionDirectory = actionDirectory
        guard startObservers else { return }
        startWatching()
        flagSubscription = FeatureFlags.shared.$replyEnabled.receive(on: RunLoop.main).sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.requestNotificationPermission(); self.startPolling(); self.reload() }
            else { self.pollTimer?.invalidate(); self.pollTimer = nil; self.items = [] }
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        // DispatchSource 对原子替换(os.replace)的文件监听不可靠,用定时轮询兜底,
        // 保证不打开窗口也能第一时间检测到新待回复并弹通知。
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    func reload() {
        guard FeatureFlags.shared.replyEnabled else {
            if !items.isEmpty { items = [] }
            return
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.pendingPath)),
              let payload = try? JSONDecoder().decode(ReplyPayload.self, from: data) else {
            return
        }
        let isNewData = payload.timestamp > lastProcessedTimestamp
        let prevCount = items.count
        lastProcessedTimestamp = payload.timestamp

        DispatchQueue.main.async {
            // 墓碑过滤: daemon 已写回(文件里没了)则销墓碑; 120秒兜底过期
            let now = Date().timeIntervalSince1970
            let fileKeys = Set(payload.items.map { $0.key })
            self.pendingRemoval = self.pendingRemoval.filter { fileKeys.contains($0.key) && now - $0.value < 120 }
            self.items = payload.items.filter { self.pendingRemoval[$0.key] == nil }
            self.lastUpdate = Date(timeIntervalSince1970: payload.timestamp)
        }

        // 仅对"没通知过的条目"提醒(key 持久化, app 重启不重复弹)
        _ = isNewData; _ = prevCount
        let notifiedPath = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.dws/reply-notified-keys.json"
        var notified = Set<String>()
        if let nd = FileManager.default.contents(atPath: notifiedPath),
           let arr = try? JSONDecoder().decode([String].self, from: nd) {
            notified = Set(arr)
        }
        let freshItems = payload.items.filter { !notified.contains($0.key) }
        if !freshItems.isEmpty {
            let now = Date().timeIntervalSince1970
            if now - lastNotifyTime > notifyDebounce {
                lastNotifyTime = now
                if let first = freshItems.first {
                    sendNotification(count: payload.items.count, sender: first.sender,
                                     preview: first.incoming)
                }
            }
        }
        // 记录全部当前key, 并清理已不在面板里的旧key(防文件无限膨胀)
        let currentKeys = Set(payload.items.map { $0.key })
        let merged = notified.union(currentKeys).intersection(currentKeys.union(Set(freshItems.map { $0.key })))
        if let out = try? JSONEncoder().encode(Array(notified.union(currentKeys).filter { currentKeys.contains($0) })) {
            _ = merged
            try? out.write(to: URL(fileURLWithPath: notifiedPath))
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(count: Int, sender: String, preview: String) {
        let content = UNMutableNotificationContent()
        content.title = "💬 有人找你"
        let head = preview.count > 30 ? String(preview.prefix(30)) + "…" : preview
        content.body = "\(sender)：\(head)" + (count > 1 ? "（共 \(count) 条待回复）" : "")
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "reply-inbox-\(Date().timeIntervalSince1970)",
            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func startWatching() {
        fileObserver = FileRefreshObserver(url: URL(fileURLWithPath: Self.pendingPath)) { [weak self] in self?.reload() }
    }

    func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func actionsDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.dws/reply-actions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 墓碑: 面板已操作、等待 daemon 写回的条目 key -> 操作时间。
    /// 防止 3 秒轮询把旧文件里的条目刷回来造成"消失又复活"。
    private var pendingRemoval: [String: TimeInterval] = [:]

    @discardableResult
    func writeAction(_ action: [String: Any], removeKey: String? = nil) -> Bool {
        let directory = actionDirectory ?? URL(fileURLWithPath: actionsDir())
        do {
            let data = try JSONSerialization.data(withJSONObject: action, options: [])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
        } catch {
            actionFeedback = "提交失败，请检查本地动作目录后重试；事项未移除"
            return false
        }
        let notice = "已提交给本地值守，尚不代表钉钉已发送"
        actionFeedback = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.actionFeedback == notice { self?.actionFeedback = nil }
        }
        if let key = removeKey {
            pendingRemoval[key] = Date().timeIntervalSince1970
            items.removeAll { $0.key == key }
        }
        return true
    }

    func send(_ item: ReplyItem, text: String, source: String = "") {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let action: [String: Any] = [
            "type": "reply",
            "key": item.key, "convId": item.convId, "convTitle": item.convTitle,
            "isSingle": item.isSingle, "peerDingId": item.peerDingId ?? "",
            "sender": item.sender, "text": trimmed, "source": source,
        ]
        writeAction(action, removeKey: item.key)
    }

    /// 操作类: 让守护进程按配方执行(调 skill / 命令), 执行完自动组织回复发出。
    func execRecipe(_ item: ReplyItem) {
        let action: [String: Any] = [
            "type": "exec",
            "key": item.key, "convId": item.convId, "convTitle": item.convTitle,
            "isSingle": item.isSingle, "peerDingId": item.peerDingId ?? "",
            "sender": item.sender,
            "recipeMatch": item.recipeMatch ?? "",
            "slots": item.slots ?? [:],
        ]
        writeAction(action, removeKey: item.key)
    }

    /// 贴文字表情("收到"气泡)或表情回应(👍角标), 由守护进程执行
    func sendEmotion(_ item: ReplyItem, name: String, isTextEmotion: Bool) {
        guard let mid = item.msgId, !mid.isEmpty else { return }
        let action: [String: Any] = [
            "type": isTextEmotion ? "emotion" : "emoji",
            "key": item.key, "convId": item.convId, "msgId": mid,
            "sender": item.sender, "name": name,
        ]
        writeAction(action, removeKey: item.key)
    }

    /// 已回复: 本人已在钉钉里亲自回过, 直接移除, 不记任何学习样本。
    func markReplied(_ item: ReplyItem) {
        let action: [String: Any] = [
            "type": "replied",
            "key": item.key, "sender": item.sender,
        ]
        writeAction(action, removeKey: item.key)
    }

    /// 不回复: 移除该条并记一条"无需回复"样本, 供起草时逐步学习判断。
    func dismiss(_ item: ReplyItem) {
        let action: [String: Any] = [
            "type": "dismiss",
            "key": item.key, "sender": item.sender,
            "incoming": item.incoming,
        ]
        writeAction(action, removeKey: item.key)
    }

    /// 清空: 一次性清掉所有待回复(多为已在钉钉直接回过、这边检测不到的残留)。
    /// 直接原子写空 pending.json, 已 seen 的旧条目不会被轮询刷回来。
    func clearAll() {
        let ts = Date().timeIntervalSince1970
        let payload: [String: Any] = ["timestamp": ts, "items": []]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: Self.pendingPath), options: .atomic)
        } catch {
            actionFeedback = "清空失败，本地记录保留；请检查文件权限后重试"
            return
        }
        lastProcessedTimestamp = ts
        DispatchQueue.main.async {
            self.items = []
            self.lastUpdate = Date(timeIntervalSince1970: ts)
        }
    }

    /// 教学: 保存一张新配方(不移除当前 item, 保存后用户可再选择怎么回)。
    func teach(name: String, triggers: [String], recipeType: String,
               skill: String, instruction: String, steps: String,
               replyTemplate: String, readOnly: Bool) {
        let isCommand = recipeType == "command"
        let action: [String: Any] = [
            "type": "teach",
            "name": name, "triggers": triggers, "recipeType": recipeType,
            "skill": skill,
            "instruction": isCommand ? "" : instruction,
            "commandTemplate": isCommand ? instruction : "",
            "steps": steps,
            "replyTemplate": replyTemplate, "readOnly": readOnly,
            "slots": [],
        ]
        writeAction(action)
    }

    deinit {
        pollTimer?.invalidate()
        fileObserver = nil
    }
}

// MARK: - 窗口控制器

final class ReplyInboxWindowController {
    private var window: NSWindow?
    private var windowInteraction: WorkspaceWindowInteraction?
    private var viewModel: ReplyInboxViewModel

    init(viewModel: ReplyInboxViewModel) { self.viewModel = viewModel }

    func show() {
        viewModel.reload()
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let contentView = ReplyInboxView()
            .environmentObject(viewModel)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let hosting = NSHostingController(rootView: contentView)
        let win = NSWindow(contentViewController: hosting)
        win.title = "钉钉待回复"
        win.setContentSize(NSSize(width: 500, height: 660))
        win.styleMask = [.titled, .closable, .resizable]
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.center()
        win.isReleasedWhenClosed = false
        // 原生毛玻璃需要窗口透明才能透出桌面壁纸
        // 窗口透明度: 只在 nativeBlur 主题下透出桌面壁纸, 其它主题保持不透明避免顶栏透视
        let _needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !_needsTransparent
        win.backgroundColor = _needsTransparent ? .clear : .windowBackgroundColor
        win.contentMinSize = NSSize(width: 420, height: 380)
        win.contentMaxSize = NSSize(width: 2600, height: 2200)
        win.setFrameAutosaveName("DBoardReplyInboxWindow")
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]  // 跟随当前桌面 + 保留全屏能力(赋值会覆盖默认行为集)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        windowInteraction = WorkspaceWindowInteraction(window: win, id: "reply")
    }
}

// MARK: - 视图

struct ReplyInboxView: View {
    @EnvironmentObject var vm: ReplyInboxViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    @State private var bgPhase: CGFloat = 0
    @State private var showNewRecipe = false
    @State private var showClearConfirm = false
    @State private var showWhitelist = false

    var body: some View {
        ZStack {
            theme.current.background
            VStack(spacing: 0) {
                header
                if vm.items.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(vm.items.enumerated()), id: \.element.id) { idx, item in
                                ReplyCard(item: item, appearDelay: Double(idx) * 0.04,
                                    onCopy: { vm.copyToClipboard($0) },
                                    onEmotion: { name, isText in vm.sendEmotion(item, name: name, isTextEmotion: isText) },
                                    onSend: { text, source in vm.send(item, text: text, source: source) },
                                    onExec: { vm.execRecipe(item) },
                                    onDismiss: { vm.dismiss(item) },
                                    onReplied: { vm.markReplied(item) },
                                    onTeach: { name, triggers, rtype, skill, instruction, steps, replyTmpl, readOnly in
                                        vm.teach(name: name, triggers: triggers, recipeType: rtype,
                                                 skill: skill, instruction: instruction, steps: steps,
                                                 replyTemplate: replyTmpl, readOnly: readOnly)
                                    })
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let feedback = vm.actionFeedback {
                Text(feedback).font(.system(size: 12)).foregroundStyle(.secondary)
                    .textSelection(.enabled).padding(12).frame(maxWidth: .infinity)
                    .background(.regularMaterial)
            }
        }
        .frame(minWidth: 440, minHeight: 480)
        .workspaceToolbar(id: "reply")
        .focusEffectDisabled()
        .sheet(isPresented: $showWhitelist) {
            WhitelistPanel(onClose: { showWhitelist = false })
                .environmentObject(theme)
                .environmentObject(fm)
        }
        .sheet(isPresented: $showNewRecipe) {
            RecipeTeachForm(
                title: "新建配方",
                onSave: { name, triggers, rtype, skill, instruction, steps, replyTmpl, readOnly in
                    vm.teach(name: name, triggers: triggers, recipeType: rtype,
                             skill: skill, instruction: instruction, steps: steps,
                             replyTemplate: replyTmpl, readOnly: readOnly)
                    showNewRecipe = false
                },
                onCancel: { showNewRecipe = false })
            .environmentObject(theme)
            .environmentObject(fm)
        }
        .confirmationDialog("清空全部待回复？",
                            isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("清空", role: .destructive) { vm.clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会移除列表里所有待回复（通常是已经在钉钉直接回过的残留）。新消息还会照常进来。")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("待回复")
                .font(fm.font(26))
                .foregroundStyle(theme.current.accentGradient)
            if !vm.items.isEmpty {
                Text("\(vm.items.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(theme.current.accentPrimary))
            }
            Spacer()
            Button(action: { showWhitelist = true }) {
                HStack(spacing: 3) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 10, weight: .bold))
                    Text("白名单").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(theme.current.accentPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(theme.current.accentPrimary.opacity(0.12)))
            }
            .buttonStyle(SmoothButtonStyle())
            .help("管理自动值守白名单群")
            Button(action: { showNewRecipe = true }) {
                HStack(spacing: 3) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("新配方").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(theme.current.accentPrimary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(theme.current.accentPrimary.opacity(0.12)))
            }
            .buttonStyle(SmoothButtonStyle())
            .help("手动新建一张操作配方")
            if !vm.items.isEmpty {
                Button(action: { showClearConfirm = true }) {
                    HStack(spacing: 3) {
                        Image(systemName: "trash").font(.system(size: 10, weight: .bold))
                        Text("清空").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Color(hex: "#ff6b6b"))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color(hex: "#ff6b6b").opacity(0.12)))
                }
                .buttonStyle(SmoothButtonStyle())
                .help("清空全部待回复（已在钉钉回过的残留）")
            }
            if let date = vm.lastUpdate {
                Text(date, style: .time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.current.textTertiary)
            }
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.current.accentGradient)
            Text("都回完啦，喝杯茶 ☕")
                .font(fm.font(17))
                .foregroundStyle(theme.current.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

struct ReplyCard: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let item: ReplyItem
    var appearDelay: Double = 0
    let onCopy: (String) -> Void
    var onEmotion: (String, Bool) -> Void = { _, _ in }
    let onSend: (String, String) -> Void
    let onExec: () -> Void
    let onDismiss: () -> Void
    let onReplied: () -> Void
    let onTeach: (String, [String], String, String, String, String, String, Bool) -> Void
    @State private var copiedIndex: Int? = nil
    @State private var customText: String = ""
    @State private var hovered = false
    @State private var appeared = false
    @State private var executing = false
    @State private var showTeach = false
    @State private var showCustomEmotion = false
    @State private var customEmotion = ""
    @State private var showEmojiPicker = false

    private var tagColor: Color {
        item.isSingle ? Color(hex: "#ff6b6b") : theme.current.accentPrimary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            incomingBubble
            if item.isAction {
                actionPanel
            } else if item.needInvestigation {
                investigationPanel
            } else {
                draftsSection
            }
            if item.msgId?.isEmpty == false {
                emotionBar
            }
            composer
            teachFooter
            if showTeach {
                RecipeTeachForm(
                    title: "教我怎么做（\(item.sender)）",
                    onSave: { name, triggers, rtype, skill, instruction, steps, replyTmpl, readOnly in
                        onTeach(name, triggers, rtype, skill, instruction, steps, replyTmpl, readOnly)
                        withAnimation { showTeach = false }
                    },
                    onCancel: { withAnimation { showTeach = false } })
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.current.cardFill.opacity(theme.current.cardFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.current.separator.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(hovered ? 0.10 : 0.05), radius: hovered ? 12 : 7, y: hovered ? 4 : 2)
        .offset(y: hovered ? -2 : 0)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
        .onAppear { withAnimation(.easeOut(duration: 0.3).delay(appearDelay)) { appeared = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(item.isSingle ? "单聊" : "群")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(tagColor))
            Text(item.sender)
                .font(fm.font(18))
                .foregroundStyle(theme.current.textPrimary)
            Spacer()
            Button(action: { onReplied() }) {
                Text("已回复")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.current.accentPrimary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().strokeBorder(theme.current.accentPrimary.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(SmoothButtonStyle())
            .help("我已经在钉钉里亲自回过了，直接划掉这条（不记任何学习样本）")
            Button(action: { onDismiss() }) {
                Text("不用回")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.current.textTertiary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().strokeBorder(theme.current.separator.opacity(0.7), lineWidth: 1))
            }
            .buttonStyle(SmoothButtonStyle())
            .help("不回复这条，并让我记住这类消息通常无需回复")
            Text(shortTime(item.incomingTime))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(theme.current.textTertiary)
        }
    }

    private var incomingBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !item.isSingle {
                Text(item.convTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.current.textMuted)
            }
            Text(item.incoming)
                .font(fm.font(16))
                .foregroundStyle(theme.current.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.current.accentPrimary.opacity(0.08))
                )
        }
    }

    private var investigationPanel: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "magnifyingglass.circle.fill")
                .foregroundStyle(Color(hex: "#e8a800"))
            Text("需先查：\(item.investigationNote.isEmpty ? "不确定怎么回，等你指点" : item.investigationNote)")
                .font(fm.font(15))
                .foregroundStyle(theme.current.textPrimary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#e8a800").opacity(0.12)))
    }

    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.badge.clock.fill")
                    .foregroundStyle(Color(hex: "#7c5cff"))
                Text("需要先操作")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.current.textTertiary)
            }
            if let s = item.actionSummary, !s.isEmpty {
                Text(s)
                    .font(fm.font(16))
                    .foregroundStyle(theme.current.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if item.hasRecipe {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars").font(.system(size: 11))
                        .foregroundStyle(theme.current.accentPrimary)
                    Text("已匹配配方：\(item.recipeMatch ?? "")")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.current.textSecondary)
                }
                if let cmd = item.plannedCommand, !cmd.isEmpty {
                    Text(cmd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.current.textSecondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.current.background.opacity(0.6)))
                }
                Button(action: { executing = true; onExec() }) {
                    HStack(spacing: 5) {
                        Image(systemName: executing ? "hourglass" : "play.fill").font(.system(size: 11))
                        Text(item.readOnly == true ? "执行并回复" : "确认执行(写操作)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(item.readOnly == true
                        ? AnyShapeStyle(Color(hex: "#34c759"))
                        : AnyShapeStyle(Color(hex: "#ff9500"))))
                }
                .buttonStyle(SmoothButtonStyle())
                .disabled(executing)
                .help(item.readOnly == true ? "只读查询, 跑完自动带结果回复" : "写操作, 点这里即视为你已确认")
            } else {
                Button(action: { withAnimation { showTeach.toggle() } }) {
                    HStack(spacing: 5) {
                        Image(systemName: "graduationcap.fill").font(.system(size: 11))
                        Text(showTeach ? "收起" : "教我怎么做")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(theme.current.accentPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(theme.current.accentPrimary.opacity(0.12)))
                }
                .buttonStyle(SmoothButtonStyle())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#7c5cff").opacity(0.08)))
    }

    @ViewBuilder
    private var teachFooter: some View {
        // action-无配方卡片已有醒目的「教我怎么做」按钮; 其余卡片给个低调入口, 防误判
        if !(item.isAction && !item.hasRecipe) {
            Button(action: { withAnimation { showTeach.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "graduationcap").font(.system(size: 10))
                    Text(showTeach ? "收起" : "这条其实要操作? 教我")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.current.textTertiary)
            }
            .buttonStyle(SmoothButtonStyle())
        }
    }

    // 表情快捷条: 第一排文字表情+自定义, 第二排emoji+选择器(全部经实测有效)
    private static let emojiQuick: [(String, String)] = [
        ("👍", "赞"), ("👌", "OK"), ("🤝", "握手"), ("👏", "鼓掌"),
        ("😂", "笑哭"), ("🤔", "思考"), ("🔥", "666"),
    ]
    private static let emojiAll: [(String, String)] = [
        ("👍", "赞"), ("👌", "OK"), ("🤝", "握手"), ("👏", "鼓掌"), ("💪", "加油"),
        ("❤️", "心"), ("😂", "笑哭"), ("🤦", "捂脸"), ("🔥", "666"), ("✌️", "耶"),
        ("🙏", "抱拳"), ("💡", "灵光一闪"), ("🙂", "微笑"), ("😄", "大笑"), ("😁", "呲牙"),
        ("🤭", "偷笑"), ("😏", "坏笑"), ("😎", "得意"), ("😢", "流泪"), ("😭", "大哭"),
        ("😡", "发怒"), ("😮", "惊讶"), ("❓", "疑问"), ("😓", "汗"), ("🤔", "思考"),
        ("🍉", "吃瓜"), ("🌹", "玫瑰"), ("☕", "咖啡"), ("🐮", "牛"), ("🙇", "拜托"),
        ("💐", "感谢"), ("👋", "再见"),
    ]

    private var emotionBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 第一排: 文字表情气泡 + 自定义
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["收到", "好的", "在看了", "我看看", "稍等", "辛苦了"], id: \.self) { name in
                        EmotionChip(label: name) { onEmotion(name, true) }
                    }
                    EmotionChip(label: "✏️ 自定义") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showCustomEmotion.toggle() }
                    }
                }
            }
            // 第二排: emoji + 末尾选择器
            HStack(spacing: 6) {
                ForEach(Self.emojiQuick, id: \.1) { pair in
                    EmotionChip(label: pair.0) { onEmotion(pair.1, false) }
                }
                EmotionChip(label: showEmojiPicker ? "▲" : "😀+") {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { showEmojiPicker.toggle() }
                }
                Spacer()
            }
            if showEmojiPicker {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), spacing: 4) {
                    ForEach(Self.emojiAll, id: \.1) { pair in
                        Button(action: { onEmotion(pair.1, false) }) {
                            Text(pair.0)
                                .font(.system(size: 17))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                                .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.separator.opacity(0.3)))
                        }
                        .buttonStyle(SmoothButtonStyle(scale: 0.8))
                        .help(pair.1)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(theme.current.background.opacity(0.6)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showCustomEmotion {
                HStack(spacing: 6) {
                    TextField("自定义气泡文字, 如\"马上到\"…", text: $customEmotion)
                        .textFieldStyle(.plain)
                        .font(fm.font(13))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.current.background.opacity(0.6)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.current.separator.opacity(0.6), lineWidth: 1))
                        .onSubmit { sendCustomEmotion() }
                    Button(action: sendCustomEmotion) {
                        Text("贴上")
                            .font(fm.font(12))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(theme.current.accentPrimary))
                    }
                    .buttonStyle(SmoothButtonStyle())
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func sendCustomEmotion() {
        let t = customEmotion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onEmotion(t, true)
    }

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("候选回复")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.current.textTertiary)
            ForEach(Array(item.drafts.enumerated()), id: \.offset) { idx, draft in
                HStack(alignment: .center, spacing: 10) {
                    Text("\(idx + 1)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(theme.current.accentGradient))
                    Text(draft)
                        .font(fm.font(16))
                        .foregroundStyle(theme.current.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: { onCopy(draft); copiedIndex = idx }) {
                        Image(systemName: copiedIndex == idx ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.current.textTertiary)
                            .frame(width: 26, height: 24)
                            .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.separator.opacity(0.5)))
                    }
                    .buttonStyle(SmoothButtonStyle())
                    .help("复制")
                    Button(action: { onSend(draft, "draft-\(idx + 1)") }) {
                        HStack(spacing: 3) {
                            Image(systemName: "paperplane.fill").font(.system(size: 9))
                            Text("发送").font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Capsule().fill(Color(hex: "#34c759")))
                    }
                    .buttonStyle(SmoothButtonStyle())
                    .help("直接发送这条")
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(theme.current.background.opacity(0.5))
                )
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("自己写一句…", text: $customText)
                .textFieldStyle(.plain)
                .font(fm.font(15))
                .foregroundStyle(theme.current.textPrimary)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(theme.current.background.opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(theme.current.separator.opacity(0.6), lineWidth: 1)
                )
                .onSubmit { sendCustom() }
            Button(action: sendCustom) {
                HStack(spacing: 3) {
                    Image(systemName: "paperplane.fill").font(.system(size: 10))
                    Text("发送").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Capsule().fill(
                    customText.trimmingCharacters(in: .whitespaces).isEmpty
                        ? AnyShapeStyle(theme.current.separator)
                        : AnyShapeStyle(theme.current.accentGradient)))
            }
            .buttonStyle(SmoothButtonStyle())
            .disabled(customText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func sendCustom() {
        let t = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        onSend(t, "custom")
        customText = ""
    }

    private func shortTime(_ s: String) -> String {
        // "2026-07-16 19:41:47" -> "07-16 19:41"
        let parts = s.split(separator: " ")
        guard parts.count == 2 else { return s }
        let d = parts[0].split(separator: "-")
        let t = parts[1].split(separator: ":")
        guard d.count == 3, t.count >= 2 else { return s }
        return "\(d[1])-\(d[2]) \(t[0]):\(t[1])"
    }
}

// MARK: - 可复用的配方教学表单(窗口顶部「+新配方」和每张卡片共用)

struct RecipeTeachForm: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let title: String
    let onSave: (String, [String], String, String, String, String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var triggers = ""
    @State private var type = "skill"
    @State private var skill = ""
    @State private var instruction = ""
    @State private var steps = ""
    @State private var reply = ""
    @State private var readOnly = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(fm.font(18))
                    .foregroundStyle(theme.current.accentGradient)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(theme.current.textTertiary)
                }
                .buttonStyle(SmoothButtonStyle())
            }
            field("配方名", text: $name, placeholder: "例:查订单结算状态")
            field("触发词(逗号分隔)", text: $triggers, placeholder: "结算,没结算,订单")
            Picker("类型", selection: $type) {
                Text("调 skill").tag("skill")
                Text("跑命令").tag("command")
                Text("人工步骤").tag("manual")
            }
            .pickerStyle(.segmented)
            if type == "skill" {
                field("用哪个 skill", text: $skill, placeholder: "tmyc-db-query")
                field("指令(可含 {参数})", text: $instruction, placeholder: "查订单 {orderId} 的结算状态,一句话结论")
            } else if type == "command" {
                field("命令模板(可含 {参数})", text: $instruction, placeholder: "some-cli --order {orderId}")
            } else {
                field("人工步骤", text: $steps, placeholder: "打开xx后台 → 点xx → 查xx")
            }
            field("回复模板(可选)", text: $reply, placeholder: "查了下,{result}")
            Toggle(isOn: $readOnly) {
                Text("只读(可自动执行, 写操作请关掉)").font(.system(size: 12))
                    .foregroundStyle(theme.current.textSecondary)
            }
            .toggleStyle(.switch)
            HStack {
                Spacer()
                Button(action: onCancel) {
                    Text("取消").font(.system(size: 13))
                        .foregroundStyle(theme.current.textSecondary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                }
                .buttonStyle(SmoothButtonStyle())
                Button(action: save) {
                    Text("保存配方")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(theme.current.accentGradient))
                }
                .buttonStyle(SmoothButtonStyle())
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 380)
        .background(theme.current.background)
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(theme.current.textTertiary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(theme.current.textPrimary)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(theme.current.cardFill.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(theme.current.separator.opacity(0.6), lineWidth: 1))
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        let trg = triggers.split(whereSeparator: { $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        onSave(n, trg, type, skill, instruction, steps, reply, readOnly)
    }
}



// MARK: - 表情快捷片
struct EmotionChip: View {
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let label: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(fm.font(12))
                .foregroundStyle(hovered ? theme.current.accentPrimary : theme.current.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(hovered
                    ? theme.current.accentPrimary.opacity(0.14)
                    : theme.current.separator.opacity(0.4)))
        }
        .buttonStyle(SmoothButtonStyle(scale: 0.88, hoverScale: 1.0))
        .scaleEffect(hovered ? 1.08 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
        .onHover { hovered = $0 }
        .help("以本人身份贴到对方消息上")
    }
}
