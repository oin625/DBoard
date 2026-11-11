import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

struct GlobalShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    var title: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + keyLabel
    }

    func usesSameKeys(as other: GlobalShortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    static func capture(_ event: NSEvent) -> GlobalShortcut {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "Space", 51: "⌫",
                                       123: "←", 124: "→", 125: "↓", 126: "↑"]
        let label = special[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "").uppercased()
        return GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers,
                              keyLabel: label.isEmpty ? "Key \(event.keyCode)" : label)
    }
}

final class ShortcutPreferences: ObservableObject {
    static let shared = ShortcutPreferences()
    static let order = ["dboard", "quickopen", "clipboard", "reqflow", "logs", "apprelease", "audihome"]
    static let names = ["dboard": "D板首页", "quickopen": "快速打开需求 / 排查", "clipboard": "剪切板历史", "reqflow": "ReqFlow 需求流",
                        "logs": "Audi 日志", "apprelease": "应用发布台",
                        "audihome": "Audi 首页"]
    static let defaultsBindings: [String: GlobalShortcut] = [
        "quickopen": GlobalShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey), keyLabel: "P"),
        "dboard": GlobalShortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | shiftKey), keyLabel: "D"),
        "clipboard": GlobalShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey), keyLabel: "V"),
        "reqflow": GlobalShortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(controlKey), keyLabel: "E"),
        "logs": GlobalShortcut(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey), keyLabel: "L"),
        "apprelease": GlobalShortcut(keyCode: UInt32(kVK_ANSI_Q), modifiers: UInt32(controlKey), keyLabel: "Q"),
        "audihome": GlobalShortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(controlKey), keyLabel: "W"),
    ]
    @Published private(set) var overrides: [String: GlobalShortcut]
    @Published private(set) var disabled: Set<String>
    @Published var error: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = defaults.data(forKey: "shortcuts.bindings").flatMap {
            try? JSONDecoder().decode([String: GlobalShortcut].self, from: $0)
        }?.filter { Self.defaultsBindings[$0.key] != nil } ?? [:]
        disabled = Set(defaults.stringArray(forKey: "shortcuts.disabled") ?? [])
            .filter { Self.defaultsBindings[$0] != nil }
    }

    func binding(for id: String) -> GlobalShortcut? {
        guard Self.defaultsBindings[id] != nil, !disabled.contains(id) else { return nil }
        return overrides[id] ?? Self.defaultsBindings[id]
    }

    @discardableResult
    func set(_ shortcut: GlobalShortcut, for id: String) -> Bool {
        guard Self.defaultsBindings[id] != nil else { return false }
        guard shortcut.modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            error = "全局快捷键需要包含 Control、Option 或 Command。"
            return false
        }
        if shortcut.modifiers == UInt32(cmdKey), [UInt32(kVK_ANSI_K), UInt32(kVK_ANSI_Q),
                                                 UInt32(kVK_ANSI_Comma)].contains(shortcut.keyCode) {
            error = "⌘K、⌘Q 和 ⌘, 保留给命令面板、退出和设置。"
            return false
        }
        for otherID in Self.order where otherID != id {
            if let other = binding(for: otherID), shortcut.usesSameKeys(as: other) {
                error = "这个快捷键已用于「\(Self.names[otherID] ?? otherID)」。"
                return false
            }
        }
        overrides[id] = shortcut
        disabled.remove(id)
        error = nil
        persist()
        return true
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        guard Self.defaultsBindings[id] != nil else { return }
        if enabled {
            if let shortcut = overrides[id] ?? Self.defaultsBindings[id] {
                _ = set(shortcut, for: id)
            }
        } else {
            disabled.insert(id)
            error = nil
            persist()
        }
    }

    func restoreDefaults() {
        overrides = [:]
        disabled = []
        error = nil
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(overrides) { defaults.set(data, forKey: "shortcuts.bindings") }
        defaults.set(Array(disabled), forKey: "shortcuts.disabled")
    }
}

final class GlobalShortcutManager: ObservableObject {
    static let shared = GlobalShortcutManager()
    @Published private(set) var statuses: [String: String] = [:]
    private var hotKeys: [String: HotKey] = [:]
    private var actions: [String: () -> Void] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var recording = false

    func configure(actions: [String: () -> Void]) {
        self.actions = actions
        subscriptions.removeAll()
        let prefs = ShortcutPreferences.shared
        Publishers.CombineLatest(prefs.$overrides, prefs.$disabled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &subscriptions)
        reload()
    }

    func beginRecording() {
        recording = true
        for hotKey in hotKeys.values { hotKey.unregister() }
    }

    func endRecording() {
        recording = false
        reload()
    }

    private func reload() {
        guard !recording else { return }
        for hotKey in hotKeys.values { hotKey.unregister() }
        hotKeys.removeAll()
        statuses = [:]
        for id in ShortcutPreferences.order {
            guard let binding = ShortcutPreferences.shared.binding(for: id), let action = actions[id] else {
                statuses[id] = "已关闭"
                continue
            }
            let hotKey = HotKey()
            hotKeys[id] = hotKey
            statuses[id] = "注册中"
            hotKey.register(keyCode: binding.keyCode, modifiers: binding.modifiers,
                onStatus: { [weak self] status in
                    self?.statuses[id] = status == noErr ? "已生效" : "系统或其他应用已占用（\(status)）"
                }, callback: action)
        }
    }

    func isRegistered(_ id: String) -> Bool { hotKeys[id]?.isRegistered ?? false }

    var report: String {
        ShortcutPreferences.order.map {
            let key = ShortcutPreferences.shared.binding(for: $0)?.title ?? "关闭"
            return "\($0)(\(key))=\(isRegistered($0))"
        }.joined(separator: " ")
    }
}

private final class ShortcutCaptureButton: NSButton {
    var onCapture: ((GlobalShortcut) -> Void)?
    var shortcutTitle = ""
    private var recording = false
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        target = self
        action = #selector(beginRecording)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func beginRecording() {
        guard !recording else { return }
        recording = true
        title = "按下快捷键…"
        GlobalShortcutManager.shared.beginRecording()
        window?.makeFirstResponder(self)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.recording, event.window === self.window else { return event }
            self.finishRecording(event: event)
            return nil
        }
    }

    private func finishRecording(event: NSEvent? = nil) {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        title = shortcutTitle
        if let event, event.keyCode != 53 { onCapture?(GlobalShortcut.capture(event)) }
        GlobalShortcutManager.shared.endRecording()
    }

    override func resignFirstResponder() -> Bool {
        finishRecording()
        return super.resignFirstResponder()
    }

    deinit { finishRecording() }

}

private struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    let onCapture: (GlobalShortcut) -> Void
    func makeNSView(context: Context) -> ShortcutCaptureButton { ShortcutCaptureButton(frame: .zero) }
    func updateNSView(_ view: ShortcutCaptureButton, context: Context) {
        view.shortcutTitle = title
        view.title = title
        view.onCapture = onCapture
        view.setAccessibilityLabel("修改快捷键，当前 \(title)")
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject private var prefs = ShortcutPreferences.shared
    @ObservedObject private var manager = GlobalShortcutManager.shared
    var body: some View {
        Form {
            Section("全局快捷键") {
                ForEach(ShortcutPreferences.order, id: \.self) { id in
                    LabeledContent {
                        HStack(spacing: 8) {
                            ShortcutRecorder(title: (prefs.overrides[id] ?? ShortcutPreferences.defaultsBindings[id])?.title ?? "设置",
                                onCapture: { _ = prefs.set($0, for: id) })
                                .frame(width: 135)
                            Toggle("", isOn: Binding(get: { !prefs.disabled.contains(id) },
                                set: { prefs.setEnabled($0, for: id) }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ShortcutPreferences.names[id] ?? id)
                            Text(manager.statuses[id] ?? "等待应用注册")
                                .dboardFont(size: 11)
                                .foregroundStyle(manager.statuses[id]?.contains("占用") == true ? Color.orange : Color.secondary)
                        }
                    }
                }
            }
            Section {
                if let error = prefs.error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .dboardFont(size: 12).foregroundStyle(.orange)
                }
                Text("点击快捷键后按下新组合，Esc 取消。修改立即生效；⌘K 打开命令面板，⌘, 打开设置。")
                    .dboardFont(size: 11).foregroundStyle(.secondary)
                Button("恢复默认快捷键") { prefs.restoreDefaults() }
            }
        }
        .formStyle(.grouped)
    }
}
