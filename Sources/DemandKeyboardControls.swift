import SwiftUI
import AppKit
import QuartzCore

private struct DemandKeyboardIdentifierKey: EnvironmentKey { static let defaultValue = "" }
private struct DemandKeyboardSelectionKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var demandKeyboardIdentifier: String {
        get { self[DemandKeyboardIdentifierKey.self] }
        set { self[DemandKeyboardIdentifierKey.self] = newValue }
    }
    var demandKeyboardSelected: Bool {
        get { self[DemandKeyboardSelectionKey.self] }
        set { self[DemandKeyboardSelectionKey.self] = newValue }
    }
}

/// Keep the original button rendering and mouse behavior, and expose the same action to the keyboard.
struct DemandKeyboardButtonStyle<Base: ButtonStyle>: PrimitiveButtonStyle {
    let base: Base
    @Environment(\.demandFloatingCanvas) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(base)
            .overlay {
                if enabled {
                    DemandKeyboardActionTarget(action: configuration.trigger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

struct DemandKeyboardPrimitiveButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    let base: Base
    @Environment(\.demandFloatingCanvas) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(base)
            .overlay {
                if enabled {
                    DemandKeyboardActionTarget(action: configuration.trigger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

struct DemandKeyboardDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                    configuration.label
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.demandButtonStyle(.plain)
            if configuration.isExpanded { configuration.content.demandKeyboardID("") }
        }
    }
}

struct DemandKeyboardToggleStyle: ToggleStyle {
    @Environment(\.demandFloatingCanvas) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.checkbox)
            .overlay {
                if enabled {
                    DemandKeyboardActionTarget { configuration.isOn.toggle() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
    }
}

extension View {
    func demandButtonStyle<S: ButtonStyle>(_ style: S) -> some View {
        buttonStyle(DemandKeyboardButtonStyle(base: style))
    }
    func demandButtonStyle<S: PrimitiveButtonStyle>(_ style: S) -> some View {
        buttonStyle(DemandKeyboardPrimitiveButtonStyle(base: style))
    }
    func demandKeyboardID(_ id: String) -> some View {
        environment(\.demandKeyboardIdentifier, id)
    }
    func demandKeyboardSelected(_ selected: Bool) -> some View {
        environment(\.demandKeyboardSelected, selected)
    }
    func demandMenuStyle<S: MenuStyle>(_ style: S) -> some View {
        menuStyle(style).demandKeyboardMenu()
    }
    func demandKeyboardMenu() -> some View {
        modifier(DemandKeyboardMenuModifier())
    }
}

private struct DemandKeyboardMenuModifier: ViewModifier {
    @Environment(\.demandFloatingCanvas) private var enabled
    func body(content: Content) -> some View {
        content.overlay {
            if enabled { DemandKeyboardMenuTarget() }
        }
    }
}

private struct DemandKeyboardActionTarget: NSViewRepresentable {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.demandKeyboardIdentifier) private var identifier
    @Environment(\.demandKeyboardSelected) private var selected

    func makeNSView(context: Context) -> DemandKeyboardActionView { DemandKeyboardActionView() }
    func updateNSView(_ view: DemandKeyboardActionView, context: Context) {
        view.action = action
        view.enabled = enabled
        view.keyboardIdentifier = identifier
        view.selected = selected
    }
}

private struct DemandKeyboardMenuTarget: NSViewRepresentable {
    @Environment(\.demandFloatingCanvas) private var active
    @Environment(\.isEnabled) private var enabled
    @Environment(\.demandKeyboardIdentifier) private var identifier

    func makeNSView(context: Context) -> DemandKeyboardActionView { DemandKeyboardActionView() }
    func updateNSView(_ view: DemandKeyboardActionView, context: Context) {
        view.enabled = active && enabled
        view.keyboardIdentifier = identifier
        view.action = { [weak view] in
            guard let view, let window = view.window else { return }
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            }
            NSApp.postEvent(mouse(.leftMouseUp), atStart: false)
            window.sendEvent(mouse(.leftMouseDown))
        }
    }
}

/// This overlay receives focus and keyboard events, while all pointer events reach the original control.
final class DemandKeyboardActionView: NSView {
    static let focusRingIdleDelay: TimeInterval = 2.5
    var action: (() -> Void)?
    var enabled = true
    var keyboardIdentifier = ""
    var selected = false
    private var hasFocus = false
    private var ringVisible = false
    private var ringHide: DispatchWorkItem?

    deinit { ringHide?.cancel() }

    override var acceptsFirstResponder: Bool { enabled && !isHiddenOrHasHiddenAncestor }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder else { return false }
        hasFocus = true
        revealFocusRing()
        return true
    }
    override func resignFirstResponder() -> Bool {
        ringHide?.cancel()
        ringHide = nil
        hasFocus = false
        ringVisible = false
        updateRing()
        return true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRing()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, !(window is DemandWorkspaceWindow) {
            DemandWindowKeyboardNavigation.installForSheet(window)
        } else if window == nil {
            ringHide?.cancel()
            ringHide = nil
            hasFocus = false
            ringVisible = false
            updateRing()
        }
    }
    override func keyDown(with event: NSEvent) {
        if [UInt16(36), 76, 49].contains(event.keyCode) {
            activate()
        } else { super.keyDown(with: event) }
    }

    func activate() {
        if enabled && !isHiddenOrHasHiddenAncestor {
            revealFocusRing()
            action?()
        }
    }

    /// Only the visual hint expires; Enter and the next Tab still use this control's focus.
    func revealFocusRing() {
        guard hasFocus else { return }
        ringHide?.cancel()
        ringVisible = true
        updateRing()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.ringVisible = false
            self.ringHide = nil
            self.updateRing(animated: true)
        }
        ringHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusRingIdleDelay, execute: work)
    }

    private func updateRing(animated: Bool = false) {
        wantsLayer = true
        guard let layer else { return }
        let previousOpacity = layer.presentation()?.opacity ?? layer.opacity
        layer.removeAnimation(forKey: "keyboard-focus-opacity")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = 6
        layer.borderWidth = hasFocus ? 2 : 0
        layer.opacity = hasFocus && ringVisible ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.borderColor = NSColor.systemBlue.withAlphaComponent(0.8).cgColor
        }
        CATransaction.commit()
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = previousOpacity
            fade.toValue = layer.opacity
            fade.duration = 0.18
            layer.add(fade, forKey: "keyboard-focus-opacity")
        }
    }
}
