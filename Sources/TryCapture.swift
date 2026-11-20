import SwiftUI
import AppKit

/// A reusable writing slot, not a numbered record. Only "收好" creates an entry.
struct TryCaptureComposer: View {
    @ObservedObject var store: TryStore
    let kind: TryKind
    var autofocus = false
    var close: (() -> Void)? = nil
    var saved: (String) -> Void = { _ in }
    @State private var editing = true
    @State private var titleExpanded = false
    @State private var clearConfirmation = false
    @StateObject private var controller = TryNoteController()
    @EnvironmentObject private var theme: ThemeManager

    var body: some View {
        let generation = store.captureGeneration(kind)
        let draft = store.capture(kind)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(kind == .digestion ? "开启一个学习主题" : "记个想法").dboardFont(size: 13, weight: .medium)
                    .foregroundStyle(theme.current.accentSecondary)
                Spacer()
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }
                        .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-capture-close").accessibilityLabel("关闭记录框")
                }
            }
            if kind == .digestion || titleExpanded || !draft.title.isEmpty {
                TextField(kind == .digestion ? "学习主题，可后补" : "标题，可不填", text: binding("title", generation))
                    .textFieldStyle(.plain).dboardFont(size: 17, weight: .medium)
            }
            TryNoteEditor(text: binding("body", generation), editing: $editing, bookmark: draft.bookmark,
                minimumHeight: 104, maximumHeight: 260, autofocus: autofocus, controller: controller,
                onBookmark: { store.rememberCapture(kind, bookmark: $0, generation: generation) },
                onEnd: { _ = store.flush() })
                .id(kind.rawValue + "-capture-" + String(generation))
                .overlay(alignment: .topLeading) {
                    if draft.body.isEmpty {
                        Text(kind.placeholder).dboardFont(size: 15).foregroundStyle(theme.current.textSecondary)
                            .padding(.top, 8).allowsHitTesting(false)
                    }
                }
            if let relatedID = draft.relatedID, let related = store.entry(relatedID) {
                Text("关联 " + related.displayTitle).dboardFont(size: 11).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Button { editing = true; controller.images() } label: { Image(systemName: "photo") }
                    .demandButtonStyle(TryControlStyle()).accessibilityLabel("添加图片")
                if kind != .digestion {
                    Button("标题") { titleExpanded.toggle() }
                        .demandButtonStyle(TryControlStyle()).accessibilityLabel("填写可选标题")
                }
                Spacer(minLength: 4)
                if !draft.isEmpty {
                    Button("清空") { clearConfirmation = true }
                        .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).foregroundStyle(.secondary)
                }
                Button(kind == .digestion ? "开始记笔记" : "收好") {
                    controller.end()
                    if let id = store.submitCapture(kind) {
                        editing = true; titleExpanded = false
                        saved(id)
                    }
                }
                .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.isEmpty).demandKeyboardID("try-capture-save").accessibilityIdentifier("try-capture-save")
            }.foregroundStyle(.secondary)
            if let error = controller.error ?? store.error {
                Text(error).dboardFont(size: 11).foregroundStyle(.orange)
            }
        }
        .padding(18)
        .workspaceSurface(radius: 16)
        .alert("清空未收好的内容？", isPresented: $clearConfirmation) {
            Button("清空", role: .destructive) {
                controller.end()
                if store.clearCapture(kind) { editing = true }
            }
            Button("取消", role: .cancel) {}
        }
        .onDisappear { controller.end(); _ = store.flush() }
    }

    private func binding(_ field: String, _ generation: Int) -> Binding<String> {
        Binding(get: { field == "title" ? store.capture(kind).title : store.capture(kind).body },
            set: { store.editCapture(kind, field: field, value: $0, generation: generation) })
    }
}

private struct TryCaptureRoot: View {
    @ObservedObject var store: TryStore
    let kind: TryKind
    let close: () -> Void
    let saved: (String) -> Void
    var body: some View {
        Group {
            if kind == .digestion { TryLearningStart(store: store, close: close, saved: saved) }
            else {
                TryCaptureComposer(store: store, kind: kind, autofocus: true, close: close, saved: saved)
                    .padding(20).demandFloatingCanvas().background(TryKeyboardBridge(onEscape: close, endsEditingOnEscape: false))
            }
        }
    }
}

final class TryCaptureWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var kind: TryKind?
    private let store: TryStore
    private let activates: Bool
    private let theme: ThemeManager
    // SwiftUI may replace the originating home view while this window is open.
    // Keep its actions alive until the window actually closes.
    private var windowLifetime: TryCaptureWindowController?
    private var openedDetail: TryDetailWindowController?
    private var interaction: WorkspaceWindowInteraction?
    private var centering: DemandWindowCentering?
    init(store: TryStore = .shared, activates: Bool = true, theme: ThemeManager = .shared) {
        self.store = store; self.activates = activates; self.theme = theme
    }
    func show(_ kind: TryKind, projectID: String? = nil, relatedID: String? = nil, centerIn: NSRect? = nil) {
        guard store.flush() else { return }
        if window != nil {
            guard commit() else { return }
            window?.close()
        }
        store.prepareCapture(kind, projectID: projectID, relatedID: relatedID)
        self.kind = kind
        let window = DemandWorkspaceWindow(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: 700, height: kind == .digestion ? 580 : 470))
        window.minSize = NSSize(width: 520, height: 300); window.delegate = self
        window.setContent(NSHostingController(rootView: TryCaptureRoot(store: store, kind: kind,
            close: { [weak self] in self?.close() }, saved: { [weak self] id in
                guard let self else { return }
                self.close()
                if kind == .digestion {
                    let detail = TryDetailWindowController(store: self.store, activates: self.activates, theme: self.theme)
                    self.openedDetail = detail
                    detail.show(id)
                    detail.session?.notice = "学习方案指令已复制，粘贴给 AI 制定方案"
                }
            }).environmentObject(theme).environmentObject(FontManager.shared)))
        self.window = window; windowLifetime = self
        interaction = WorkspaceWindowInteraction(window: window, id: "try-capture", handlesEscape: false)
        centering = DemandWindowCentering(window: window)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        centering?.center(in: centerIn ?? (activates ? screen?.visibleFrame : nil))
        if activates { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window.orderBack(nil) }
    }
    private func commit() -> Bool {
        if let editor = window?.firstResponder as? NSTextView {
            if editor.hasMarkedText() { editor.unmarkText() }
            editor.didChangeText()
        }
        window?.makeFirstResponder(nil)
        return store.flush()
    }
    func close() { if commit() { window?.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { commit() }
    func windowWillClose(_ notification: Notification) {
        window = nil; kind = nil; interaction = nil; centering = nil; windowLifetime = nil
    }
}

struct TryTrashView: View {
    @ObservedObject var store: TryStore
    let back: () -> Void
    @State private var clearConfirmation = false
    @State private var reviewedIDs: Set<String> = []
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("返回", systemImage: "chevron.left") }
                    .demandButtonStyle(TryControlStyle())
                Spacer()
                Text("回收站").dboardFont(size: 16, weight: .medium)
                Spacer()
                Button("清空") {
                    reviewedIDs = Set(store.trashed.map(\.id))
                    clearConfirmation = true
                }
                .demandButtonStyle(TryControlStyle()).foregroundStyle(.secondary)
                .disabled(store.trashed.isEmpty).accessibilityLabel("清空回收站")
                .demandKeyboardID("try-empty-trash")
            }.padding(20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.trashed.isEmpty {
                        Text("回收站是空的。").dboardFont(size: 14).foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                    ForEach(store.trashed) { entry in
                        HStack(alignment: .top, spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(entry.isEmpty ? "空白" + entry.kind.title + "草稿" : entry.displayTitle)
                                    .dboardFont(size: 15, weight: .medium)
                                Text(entry.kind.title + " · " + entry.id).dboardFont(size: 11).foregroundStyle(.secondary)
                                if !entry.body.isEmpty {
                                    Text(entry.body).dboardFont(size: 12).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("恢复") { _ = store.restore(entry.id) }
                                .demandButtonStyle(WorkspaceActionStyle())
                        }.padding(18).workspaceSurface(radius: 14)
                    }
                }.padding(.horizontal, 26).padding(.bottom, 26)
            }
        }
        .alert("永久删除回收站中的 " + String(reviewedIDs.count) + " 条记录？", isPresented: $clearConfirmation) {
            Button("永久删除", role: .destructive) { _ = store.emptyTrash(reviewedIDs) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这些记录的正文和反馈将被删除，无法恢复。")
        }
    }
}
