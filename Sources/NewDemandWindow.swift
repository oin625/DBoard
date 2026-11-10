import SwiftUI
import AppKit

/// Creation owns one window, so the transient home never has to become a sheet presenter.
private struct NewDemandWindowRoot: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let close: () -> Void

    var body: some View {
        Group {
            if vm.newItemFormOpen && vm.newItemFormInWindow, let draft = vm.newItemDraft {
                DemandItemEditor(draft: draft, close: close)
            }
        }
        .overlay(alignment: .bottom) {
            if let feedback = vm.feedback {
                WorkspaceFeedbackView(feedback: feedback) { vm.feedback = nil }.padding(16)
            }
        }
        .demandFloatingCanvas()
    }
}

final class NewDemandWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var viewModel: DBoardViewModel?
    private var interaction: WorkspaceWindowInteraction?
    private var centering: DemandWindowCentering?
    private(set) var keyboardNavigation: DemandWindowKeyboardNavigation?
    private let activates: Bool

    init(activates: Bool = true) { self.activates = activates }

    func show(_ vm: DBoardViewModel) {
        guard vm.newItemFormOpen, vm.newItemFormInWindow, vm.newItemDraft != nil else { return }
        viewModel = vm
        let opening = window == nil
        let preferredScreen = vm.newDemandWindowCenterRect
        vm.newDemandWindowCenterRect = nil
        if window == nil {
            let host = NSHostingController(rootView: NewDemandWindowRoot(close: { [weak self] in self?.close() })
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
            let value = DemandWorkspaceWindow(contentRect:
                NSRect(x: activates ? 0 : -10000, y: 0, width: 660, height: 740))
            value.isReleasedWhenClosed = false
            value.setContent(host)
            value.minSize = NSSize(width: 560, height: 600)
            value.title = "新增需求 / 线上排查"
            value.delegate = self
            window = value
            interaction = WorkspaceWindowInteraction(window: value, id: "new-demand", handlesEscape: false)
            centering = DemandWindowCentering(window: value)
            keyboardNavigation = DemandWindowKeyboardNavigation(window: value, allowsKindSwitching: true, onEscape: { [weak self] in self?.close() })
        }
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        centering?.center(in: preferredScreen ?? (opening && activates ? pointerScreen?.visibleFrame : nil))
        if activates {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else { window?.orderBack(nil) }
        if opening {
            DispatchQueue.main.async { [weak self, weak vm] in
                guard let self, let vm else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                self.keyboardNavigation?.focusControl(identifier:
                    vm.newItemDraft?.isIncident == true ? "demand-kind-incident" : "demand-kind-development")
            }
        }
    }

    func close() { window?.performClose(nil) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.makeFirstResponder(nil)
        return true
    }

    func windowWillClose(_ notification: Notification) {
        viewModel?.newItemFormOpen = false
        viewModel?.newItemFormInWindow = false
        keyboardNavigation = nil
        centering = nil
        interaction = nil
        window = nil
    }
}
