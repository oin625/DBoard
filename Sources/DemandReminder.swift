import SwiftUI
import AppKit

/// User-owned reminder, independent of AI progress and the requirement's execution scope.
enum DemandReminder {
    static let field = "- **进展提醒**"
    static let color = Color(nsColor: .systemTeal)

    static func singleLine(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }

    static func read(_ block: [String]) -> String {
        guard let line = block.first(where: { $0.hasPrefix(field) }) else { return "" }
        return String(line.dropFirst(field.count))
            .replacingOccurrences(of: "^\\s*[：:]?\\s*", with: "", options: .regularExpression).trimmed
    }
}

struct DemandReminderDraft {
    var text: String
    let expected: String
    let cache: URL?
}

extension DBoardViewModel {
    func editReminder(_ item: DItem, text: String, at cache: URL? = nil) {
        var draft = reminderDrafts[item.id] ?? DemandReminderDraft(text: item.reminder, expected: item.reminder, cache: cache)
        draft.text = DemandReminder.singleLine(text)
        reminderDrafts[item.id] = draft
        reminderSaveWork[item.id]?.cancel()
        let work = DispatchWorkItem { [weak self] in _ = self?.saveReminder(item.id) }
        reminderSaveWork[item.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @discardableResult
    func saveReminder(_ id: String) -> Bool {
        reminderSaveWork.removeValue(forKey: id)?.cancel()
        guard let draft = reminderDrafts[id] else { return true }
        let value = draft.text.trimmed
        if value == draft.expected {
            reminderDrafts[id] = nil
            return true
        }
        guard DItemStore.saveReminder(id: id, text: value, expected: draft.expected, at: draft.cache) else {
            flash("进展提醒未保存，输入已保留；请检查本地文件或核对是否被修改")
            return false
        }
        if draft.cache == nil { markSelfWrite(); reload() }
        else if let index = items.firstIndex(where: { $0.id == id }) { items[index].reminder = value }
        reminderDrafts[id] = nil
        return true
    }
}

struct DemandReminderView: View {
    @EnvironmentObject var vm: DBoardViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager
    let item: DItem
    @State private var editing = false
    @FocusState private var focused: Bool

    private var text: String { vm.reminderDrafts[item.id]?.text ?? item.reminder }

    var body: some View {
        HStack(spacing: 0) {
            if editing {
                TextField("", text: Binding(
                    get: { text }, set: { vm.editReminder(item, text: $0) }),
                    prompt: Text("写一句进展提醒…").foregroundStyle(theme.current.textMuted))
                    .textFieldStyle(.plain)
                    .font(fm.font(12))
                    .foregroundStyle(DemandReminder.color)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                    .focused($focused)
                    .accessibilityLabel(item.id + " 进展提醒")
                    .onAppear { focused = true }
                    .onSubmit { finishEditing() }
                    .onExitCommand { finishEditing() }
                    .onChange(of: focused) { _, active in if !active && editing { finishEditing() } }
                    .background(InlineEditClickBoundary(onOutsideClick: finishEditing))
            } else {
                Button { editing = true } label: {
                    Text(text.isEmpty ? "写一句进展提醒…" : text)
                        .font(fm.font(12))
                        .foregroundStyle(text.isEmpty ? theme.current.textMuted : DemandReminder.color)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .demandButtonStyle(.plain)
                .accessibilityLabel(item.id + " 进展提醒，点击编辑")
            }
        }
        .onDisappear { finishEditing() }
    }

    private func finishEditing() {
        editing = false
        focused = false
        vm.saveReminder(item.id)
    }
}

/// Native buttons and blank areas do not always transfer the field editor's focus.
/// Observe outside clicks only while editing, without consuming the original action.
struct InlineEditClickBoundary: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> BoundaryView {
        let view = BoundaryView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ view: BoundaryView, context: Context) { view.onOutsideClick = onOutsideClick }

    final class BoundaryView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                if event.window !== window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onOutsideClick?()
                }
                return event
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
