import SwiftUI
import AppKit

final class TryDetailSession: ObservableObject {
    @Published var id: String
    @Published var projectID: String?
    @Published var notice: String?
    init(id: String) { self.id = id }
}

private struct TryDetailRoot: View {
    @ObservedObject var store: TryStore
    @ObservedObject var session: TryDetailSession
    let close: () -> Void
    let compose: (TryKind, String?, String?) -> Void
    var body: some View {
        Group {
            if let projectID = session.projectID, let project = store.document.projects.first(where: { $0.id == projectID }) {
                TryProjectEditor(store: store, project: project) { session.projectID = nil }
            } else {
                TryEntryDetail(store: store, id: session.id, initiallyEditing: store.entry(session.id)?.isEmpty == true,
                    openProject: { session.projectID = $0 }, notify: { session.notice = $0 }, select: { id in
                        if let id { session.id = id } else { close() }
                    }, compose: compose).id(session.id)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = store.error {
                Text(error).dboardFont(size: 12).foregroundStyle(.orange).padding(12).background(.regularMaterial).padding(12)
            } else if let notice = session.notice {
                Text(notice).dboardFont(size: 12).padding(12).background(.regularMaterial, in: Capsule()).padding(16)
            }
        }
        .onChange(of: session.notice) { _, value in
            guard let value else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if session.notice == value { session.notice = nil } }
        }
        .dboardDrawingLinks()
        .demandFloatingCanvas()
        .background(TryKeyboardBridge {
            if session.projectID != nil { session.projectID = nil }
            else { close() }
        })
        .disclosureGroupStyle(TryDisclosureStyle())
    }
}

final class TryDetailWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private(set) var session: TryDetailSession?
    private let store: TryStore
    private let activates: Bool
    private let theme: ThemeManager
    private var windowLifetime: TryDetailWindowController?
    private let capture: TryCaptureWindowController
    private var interaction: WorkspaceWindowInteraction?
    private var centering: DemandWindowCentering?
    init(store: TryStore = .shared, activates: Bool = true, theme: ThemeManager = .shared) {
        self.store = store; self.activates = activates; self.theme = theme
        capture = TryCaptureWindowController(store: store, activates: activates, theme: theme)
    }
    func show(_ id: String, centerIn: NSRect? = nil) {
        guard let entry = store.entry(id), store.flush() else { return }
        let enteringLearning = entry.kind == .digestion && session.flatMap { store.entry($0.id)?.kind } != .digestion
        if let session { session.id = id; session.projectID = nil }
        else { session = TryDetailSession(id: id) }
        if window == nil, let session {
            let window = DemandWorkspaceWindow(contentRect: NSRect(x: activates ? 0 : -10000, y: 0, width: entry.kind == .digestion ? 920 : 700, height: 780))
            window.minSize = NSSize(width: 540, height: 560); window.delegate = self
            let host = NSHostingController(rootView: TryDetailRoot(store: store, session: session,
                close: { [weak self] in self?.close() }, compose: { [weak self] kind, projectID, relatedID in
                    self?.capture.show(kind, projectID: projectID, relatedID: relatedID)
                }).environmentObject(theme).environmentObject(FontManager.shared))
            host.sizingOptions = []
            window.setContent(host)
            window.setContentSize(NSSize(width: entry.kind == .digestion ? 920 : 700, height: 780))
            self.window = window; windowLifetime = self
            interaction = WorkspaceWindowInteraction(window: window, id: entry.kind == .digestion ? "try-learning-detail" : "try-detail", handlesEscape: false)
            centering = DemandWindowCentering(window: window)
        }
        if enteringLearning { window?.setContentSize(NSSize(width: 920, height: 780)) }
        window?.title = entry.displayTitle
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        centering?.center(in: centerIn ?? (activates ? screen?.visibleFrame : nil))
        if activates { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        else { window?.orderBack(nil) }
    }
    @discardableResult
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
        window = nil; session = nil; interaction = nil; centering = nil; windowLifetime = nil
    }
}
