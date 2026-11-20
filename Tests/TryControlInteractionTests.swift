import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class TryControlInteractionTests: XCTestCase {
    // Notification delivery and cancellation both run on the main queue.
    private final class MenuProbe: @unchecked Sendable { var menu: NSMenu? }
    private final class State: ObservableObject {
        @Published var iconClicks = 0
        @Published var textClicks = 0
        @Published var menuClicks = 0
        @Published var expanded = false
        @Published var nestedExpanded = false
        @Published var text = "正文编辑不受按钮影响"
    }

    @MainActor
    func testIconAndTextButtonsRespondAcrossTheirPaddingWithoutStealingNeighborClicks() throws {
        _ = NSApplication.shared
        let state = State()
        let window = host(VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 18) {
                Button { state.iconClicks += 1 } label: { Image(systemName: "photo") }
                    .demandButtonStyle(TryControlStyle()).demandKeyboardID("icon")
                Button("继续写") { state.textClicks += 1 }
                    .demandButtonStyle(TryControlStyle()).demandKeyboardID("text")
                Button("禁用") { state.textClicks += 100 }
                    .demandButtonStyle(TryControlStyle()).disabled(true).demandKeyboardID("disabled")
            }
            TextField("正文", text: Binding(get: { state.text }, set: { state.text = $0 }))
                .textFieldStyle(.plain).frame(width: 300, height: 36)
        }.padding(24))
        defer { window.close() }
        settle()
        let icon = try target("icon", window)
        let text = try target("text", window)
        for (control, isIcon) in [(icon, true), (text, false)] {
            XCTAssertGreaterThanOrEqual(control.bounds.width, 36)
            XCTAssertGreaterThanOrEqual(control.bounds.height, 36)
            for point in samplePoints(control.bounds) {
                let before = isIcon ? state.iconClicks : state.textClicks
                click(window, at: control.convert(point, to: nil))
                XCTAssertEqual(isIcon ? state.iconClicks : state.textClicks, before + 1,
                    "Padding at \(point) should be part of the button")
            }
        }
        let iconRect = icon.convert(icon.bounds, to: nil)
        let textRect = text.convert(text.bounds, to: nil)
        let counts = (state.iconClicks, state.textClicks)
        click(window, at: NSPoint(x: (iconRect.maxX + textRect.minX) / 2, y: iconRect.midY))
        click(window, at: try target("disabled", window).convert(NSPoint(x: 8, y: 8), to: nil))
        XCTAssertEqual(state.iconClicks, counts.0)
        XCTAssertEqual(state.textClicks, counts.1, "Targets must not overlap their neighbors or bypass disabled state")

        let navigation = DemandWindowKeyboardNavigation(window: window)
        XCTAssertTrue(window.makeFirstResponder(icon))
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        XCTAssertNil(navigation.handleKeyPress(enter))
        XCTAssertEqual(state.iconClicks, counts.0 + 1, "The expanded pointer area retains the same keyboard action")
        XCTAssertEqual(state.text, "正文编辑不受按钮影响")
    }

    @MainActor
    func testMenuOpensFromPaddingAroundSmallIcon() throws {
        _ = NSApplication.shared
        let state = State()
        let window = host(
            Menu {
                Button("测试菜单操作") { state.menuClicks += 1 }
            } label: {
                Image(systemName: "ellipsis")
            }.demandMenuStyle(TryMenuStyle()).menuIndicator(.hidden).demandKeyboardID("menu")
                .padding(24)
        )
        defer { window.close() }
        settle()
        let menuTarget = try target("menu", window)
        XCTAssertGreaterThanOrEqual(menuTarget.bounds.width, 36)
        XCTAssertGreaterThanOrEqual(menuTarget.bounds.height, 36)
        let probe = MenuProbe()
        let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { note in
                guard let menu = note.object as? NSMenu else { return }
                probe.menu = menu
                DispatchQueue.main.async {
                    guard let menu = probe.menu else { return }
                    if let index = menu.items.firstIndex(where: { $0.title == "测试菜单操作" }) {
                        menu.performActionForItem(at: index)
                    }
                    menu.cancelTracking()
                }
            }
        defer { NotificationCenter.default.removeObserver(token) }
        for point in samplePoints(menuTarget.bounds) {
            let before = state.menuClicks
            click(window, at: menuTarget.convert(point, to: nil))
            XCTAssertEqual(state.menuClicks, before + 1, "Menu padding at \(point) should open its menu")
        }
    }

    private struct DisclosureFixture: View {
        @ObservedObject var state: State
        var body: some View {
            DisclosureGroup(isExpanded: $state.expanded) {
                DisclosureGroup(isExpanded: $state.nestedExpanded) {
                    Text("只有明确点击才展开的明细")
                } label: { Text("一行概括") }
                    .demandKeyboardID("nested")
            } label: { Text("反馈记录") }
                .demandKeyboardID("history").frame(width: 420)
                .disclosureGroupStyle(TryDisclosureStyle()).padding(24)
        }
    }

    @MainActor
    func testDisclosureTogglesFromRightWhitespaceAndNestedRowsStayIndependent() throws {
        _ = NSApplication.shared
        let state = State()
        let window = host(DisclosureFixture(state: state))
        defer { window.close() }
        settle()
        let header = try target("history", window)
        XCTAssertGreaterThanOrEqual(header.bounds.height, 36)
        for point in samplePoints(header.bounds) {
            let before = state.expanded
            click(window, at: header.convert(point, to: nil))
            XCTAssertEqual(state.expanded, !before, "The whole disclosure row should toggle")
        }
        if !state.expanded {
            click(window, at: header.convert(NSPoint(x: header.bounds.midX, y: header.bounds.midY), to: nil))
        }
        let nested = try target("nested", window)
        click(window, at: nested.convert(NSPoint(x: nested.bounds.maxX - 4, y: nested.bounds.midY), to: nil))
        XCTAssertTrue(state.expanded)
        XCTAssertTrue(state.nestedExpanded, "Opening a report detail must not collapse its parent")
    }

    @MainActor private func host<V: View>(_ view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 500, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view
            .frame(width: 500, height: 400, alignment: .topLeading)
            .demandFloatingCanvas()
            .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared))
        window.orderBack(nil)
        return window
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func target(_ id: String, _ window: NSWindow) throws -> DemandKeyboardActionView {
        let root = try XCTUnwrap(window.contentView)
        return try XCTUnwrap(descendants(root).compactMap { $0 as? DemandKeyboardActionView }
            .first { $0.keyboardIdentifier == id })
    }
    private func samplePoints(_ rect: NSRect) -> [NSPoint] {
        [rect.minX + 4, rect.midX, rect.maxX - 4].flatMap { x in
            [rect.minY + 4, rect.midY, rect.maxY - 4].map { NSPoint(x: x, y: $0) }
        }
    }
    @MainActor private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
    @MainActor private func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        settle()
    }
}
