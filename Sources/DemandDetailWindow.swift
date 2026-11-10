import SwiftUI
import AppKit

/// One requirement window, with its editors inside it; the home workspace is not its presenter.
struct DemandEditorContent: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let request: DemandCardEditor
    let close: () -> Void

    @ViewBuilder
    var body: some View {
        switch request.kind {
        case .inspect:
            DemandMatrixDetailSheet(id: request.item.id, close: close, isolatedExpansion: vm.demandEditorInWindow)
        case .prompt:
            DemandPromptEditor(item: request.item, draftStore: vm.promptDraftStore, cancel: close)
        case .changes:
            DemandChangesEditor(item: request.item, draftStore: vm.changeDraftStore, cancel: close)
        case .details:
            DemandItemEditor(draft: DItemDraft(from: request.item), original: request.item, close: close)
        case .chats:
            DemandChatAssociationEditor(item: request.item, close: close)
        case .technicalPlan:
            DemandTechnicalPlanEditor(itemID: request.item.id, cacheURL: vm.deliveryCoordinator.cacheURL, close: close)
        case .delivery:
            if let plan = request.deliveryPlan {
                DemandDeliveryPreviewView(plan: plan, close: close, submit: {
                    close()
                    vm.deliveryCoordinator.submit(id: plan.item.id, expectedKey: plan.key, refresh: { reqID in
                        vm.reload()
                        if vm.deliveryCoordinator.states[plan.item.id]?.failed != true { vm.scheduleSync() }
                        vm.reqFlow.loadDeliverableStatus(reqId: reqID, force: true)
                    })
                })
            }
        }
    }
}

private struct DemandDetailWindowRoot: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let close: () -> Void
    @State private var windowNumber: Int?
    var body: some View {
        Group {
            if let request = vm.demandEditor, vm.demandEditorInWindow {
                DemandEditorContent(request: request, close: {
                    if request.kind == .inspect { close() }
                    else {
                        let current = vm.items.first { $0.id == request.item.id } ?? request.item
                        vm.openDemandEditor(.inspect, item: current)
                    }
                })
                .id(request.id)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if let title = vm.undoTitle {
                    HStack(spacing: 8) {
                        Text("已删除，可从本机恢复").font(.system(size: 12))
                        Button(title) { vm.undoLastDeletion() }.controlSize(.small)
                        Button { vm.undoTitle = nil } label: { Image(systemName: "xmark") }
                            .demandButtonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if let feedback = vm.feedback {
                    WorkspaceFeedbackView(feedback: feedback) { vm.feedback = nil }
                }
            }.padding(16)
        }
        .demandFloatingCanvas()
        .background(WindowNumberReader { windowNumber = $0 })
        .onAppear { vm.refreshCodeReviews() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshCodeReviews()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { event in
            if (event.object as? NSWindow)?.windowNumber == windowNumber { vm.refreshCodeReviews() }
        }
    }
}

/// Explicit screen geometry avoids AppKit's cascading placement and multi-screen guesses.
enum DemandWindowPlacement {
    static func centeredFrame(_ frame: NSRect, in visibleFrame: NSRect) -> NSRect {
        let size = NSSize(width: min(frame.width, visibleFrame.width), height: min(frame.height, visibleFrame.height))
        return NSRect(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func center(_ window: NSWindow, in visibleFrame: NSRect) {
        window.setFrame(centeredFrame(window.frame, in: visibleFrame), display: true)
    }
}

final class DemandDetailWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private weak var viewModel: DBoardViewModel?
    private var interaction: WorkspaceWindowInteraction?
    private var centering: DemandWindowCentering?
    private(set) var keyboardNavigation: DemandWindowKeyboardNavigation?
    private let activates: Bool

    init(activates: Bool = true) { self.activates = activates }

    func show(_ vm: DBoardViewModel) {
        guard let request = vm.demandEditor, vm.demandEditorInWindow else { return }
        viewModel = vm
        let opening = window == nil
        let preferredScreen = vm.demandWindowCenterRect
        vm.demandWindowCenterRect = nil
        if window == nil {
            let host = NSHostingController(rootView: DemandDetailWindowRoot(close: { [weak self] in self?.close() })
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
            let value = DemandWorkspaceWindow(contentRect:
                NSRect(x: activates ? 0 : -10000, y: 0, width: 640, height: 680))
            value.isReleasedWhenClosed = false
            value.setContent(host)
            value.minSize = NSSize(width: 540, height: 560)
            value.delegate = self
            window = value
            interaction = WorkspaceWindowInteraction(window: value, id: "demand-detail", handlesEscape: false)
            centering = DemandWindowCentering(window: value)
            keyboardNavigation = DemandWindowKeyboardNavigation(window: value, onEscape: { [weak self] in self?.close() })
        }
        if let window, request.kind == .delivery {
            let content = window.contentRect(forFrameRect: window.frame)
            let chromeHeight = window.frame.height - content.height
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            let size = NSSize(
                width: min(max(content.width, 820), visible?.width ?? 820),
                height: min(max(content.height, 780), (visible?.height ?? 820) - chromeHeight))
            window.minSize = NSSize(width: 660, height: 700 + chromeHeight)
            window.setContentSize(size)
            if activates, let visible {
                var frame = window.frame
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
                window.setFrame(frame, display: true)
            }
        }
        if request.kind != .delivery { window?.minSize = NSSize(width: 540, height: 560) }
        window?.title = request.item.id + " · " + request.item.displayTitle
        let pointerScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let centerIn = preferredScreen ?? (opening && activates ? pointerScreen?.visibleFrame : nil)
        centering?.center(in: centerIn)
        if activates {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window?.orderBack(nil)
        }
    }

    func close() {
        window?.makeFirstResponder(nil)
        if let dismissal = viewModel?.demandEditorDismissal {
            dismissal { [weak self] in self?.window?.close() }
        } else { window?.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let dismissal = viewModel?.demandEditorDismissal else { return true }
        dismissal { [weak sender] in sender?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        if viewModel?.demandEditorInWindow == true {
            viewModel?.demandEditor = nil
            viewModel?.demandEditorInWindow = false
            viewModel?.demandEditorDismissal = nil
        }
        keyboardNavigation = nil
        centering = nil
        interaction = nil
        window = nil
    }
}
