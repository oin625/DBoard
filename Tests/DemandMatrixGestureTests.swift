import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandMatrixGestureTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!
    private let source = """
    ## 🔴 重要且紧急
    ### D882【audi】目标象限已有需求 #进行中
    - **描述**：保持原样
    ## 🟡 重要
    ### D881【ultra】实际鼠标拖动测试 #进行中
    - **描述**：保留原需求
    - **提示词**：
        保留现有咒言
    ## 🟠 紧急
    ### D883【ultra】第二个目标象限 #待开始
    - **描述**：保持原样
    ## 🟢 不紧急不重要
    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardMatrixGesture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("cache.md")
        try source.write(to: cache, atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor
    func testMouseDraggingFromTitleAcrossOccupiedAndEmptyQuadrantsActuallySavesAndMovesCard() throws {
        let realCache = try Data(contentsOf: URL(fileURLWithPath: CacheFile.path))
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        let session = DemandMatrixDragSession()
        let fixture = cache!
        let window = host(vm: vm, session: session) { drag, priority in
            let saved = DItemStore.setPriority(id: drag.id, priority, at: fixture, expectedPriority: drag.priority)
            if saved { vm.items = CacheParser.parse(content: (try? String(contentsOf: fixture, encoding: .utf8)) ?? "").items }
            return saved
        }
        defer { window.close() }
        let original = try DItemStore.currentItem(id: "D881", at: cache)
        for (index, destination) in [ItemPriority.p0, .p2, .p3, .p1].enumerated() {
            let card = try XCTUnwrap(session.frames.cards["D881"])
            let target = try XCTUnwrap(session.frames.quadrants[destination])
            let start = CGPoint(x: card.minX + 90, y: card.minY + 47)
            // Drop over an existing card, rather than relying on a blank patch of the scroll view.
            let occupiedID = destination == .p0 ? "D882" : destination == .p2 ? "D883" : ""
            let occupied = session.frames.cards[occupiedID]
            let end = occupied.map { CGPoint(x: $0.minX + 85, y: $0.minY + 47) }
                ?? CGPoint(x: target.midX, y: target.midY)
            beginDrag(window, start: start, end: end)
            XCTAssertEqual(session.active?.id, "D881", "The actual mouse gesture must start the drag")
            XCTAssertEqual(session.target, destination, "The whole occupied quadrant must accept the pointer")
            XCTAssertNil(vm.demandEditor, "A drag must not also open a detail sheet")
            if index == 0 { try snapshot(window, name: "drag-over-occupied-quadrant") }
            event(window, type: .leftMouseUp, at: end)
            settle()
            XCTAssertNil(session.active)
            XCTAssertEqual(try DItemStore.currentItem(id: "D881", at: cache).priority, destination)
            XCTAssertEqual(vm.items.first(where: { $0.id == "D881" })?.priority, destination)
            XCTAssertEqual(try DItemStore.currentItem(id: "D881", at: cache).prompt, original.prompt)
            XCTAssertEqual(vm.items.filter { $0.id == "D881" }.count, 1)
            XCTAssertEqual(vm.items.first(where: { $0.id == "D882" })?.priority, .p0)
        }
        try snapshot(window, name: "after-moves")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: CacheFile.path)), realCache)
    }

    @MainActor
    func testHeaderCanStartDragAndSameQuadrantOrOutsideDropDoesNotSave() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        let session = DemandMatrixDragSession()
        var writes = 0
        let window = host(vm: vm, session: session) { _, _ in writes += 1; return true }
        defer { window.close() }
        let card = try XCTUnwrap(session.frames.cards["D881"])
        let own = try XCTUnwrap(session.frames.quadrants[.p1])
        let start = CGPoint(x: card.minX + 55, y: card.minY + 20)
        for end in [CGPoint(x: own.maxX - 20, y: own.maxY - 20),
                    CGPoint(x: session.frames.board.minX - 15, y: own.midY)] {
            beginDrag(window, start: start, end: end)
            XCTAssertEqual(session.active?.id, "D881")
            XCTAssertNil(session.target)
            event(window, type: .leftMouseUp, at: end)
            settle()
            XCTAssertNil(session.active)
            XCTAssertNil(vm.demandEditor)
        }
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testClickStillOpensDetailsAndTinyPointerMovementDoesNotChangePriority() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        let session = DemandMatrixDragSession()
        var writes = 0
        let window = host(vm: vm, session: session) { _, _ in writes += 1; return true }
        defer { window.close() }
        let card = try XCTUnwrap(session.frames.cards["D881"])
        let start = CGPoint(x: card.minX + 85, y: card.minY + 47)
        event(window, type: .leftMouseDown, at: start)
        event(window, type: .leftMouseDragged, at: CGPoint(x: start.x + 2, y: start.y))
        event(window, type: .leftMouseUp, at: CGPoint(x: start.x + 2, y: start.y))
        settle()
        XCTAssertEqual(vm.demandEditor?.kind, .inspect)
        XCTAssertEqual(vm.demandEditor?.item.id, "D881")
        XCTAssertNil(session.active)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    func testBorderlessPanelWithOuterScrollAcceptsQuadrantEdges() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        let session = DemandMatrixDragSession()
        let fixture = cache!
        let window = host(vm: vm, session: session, panelWithOuterScroll: true) { drag, priority in
            let saved = DItemStore.setPriority(id: drag.id, priority, at: fixture, expectedPriority: drag.priority)
            if saved { vm.items = CacheParser.parse(content: (try? String(contentsOf: fixture, encoding: .utf8)) ?? "").items }
            return saved
        }
        defer { window.close() }
        for destination in [ItemPriority.p0, .p2, .p3] {
            let card = try XCTUnwrap(session.frames.cards["D881"])
            let target = try XCTUnwrap(session.frames.quadrants[destination])
            let start = CGPoint(x: card.minX + 90, y: card.minY + 47)
            let end = destination == .p0
                ? CGPoint(x: target.minX + 2, y: target.minY + 2)
                : CGPoint(x: target.maxX - 2, y: target.maxY - 2)
            beginDrag(window, start: start, end: end)
            XCTAssertEqual(session.active?.id, "D881")
            XCTAssertEqual(session.target, destination)
            event(window, type: .leftMouseUp, at: end)
            settle()
            XCTAssertEqual(try DItemStore.currentItem(id: "D881", at: cache).priority, destination)
            XCTAssertNil(vm.demandEditor)
        }
    }

    @MainActor
    func testCopyAndReminderRemainOutsideMouseDragSurface() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.items = CacheParser.parse(content: source).items
        let index = try XCTUnwrap(vm.items.firstIndex { $0.id == "D881" })
        vm.items[index].reminder = "等待上游联调"
        let session = DemandMatrixDragSession()
        var writes = 0
        let originalCache = try Data(contentsOf: URL(fileURLWithPath: CacheFile.path))
        let window = host(vm: vm, session: session) { _, _ in writes += 1; return true }
        defer {
            vm.reminderSaveWork.values.forEach { $0.cancel() }
            vm.reminderSaveWork.removeAll()
            vm.reminderDrafts.removeAll()
            window.close()
        }
        let card = try XCTUnwrap(session.frames.cards["D881"])
        let copy = CGPoint(x: card.maxX - 21, y: card.minY + 21)
        let reminder = CGPoint(x: card.minX + 90, y: card.maxY - 20)
        let content = try XCTUnwrap(window.contentView)
        for point in [copy, reminder] {
            let nativePoint = content.convert(NSPoint(x: point.x, y: window.frame.height - point.y), from: nil)
            XCTAssertFalse(content.hitTest(nativePoint) is DemandMatrixPointerView,
                           "Copying and reminder editing must not be covered by the drag view")
        }
        event(window, type: .leftMouseDown, at: reminder)
        event(window, type: .leftMouseUp, at: reminder)
        settle()
        XCTAssertTrue(window.firstResponder is NSTextView, "Reminder click must focus the text editor")
        XCTAssertNil(session.active)
        XCTAssertNil(vm.demandEditor)
        // SwiftUI may send the existing text through its binding when the field gains focus.
        // That is an unchanged draft, not an edit or a priority change.
        XCTAssertEqual(vm.reminderDrafts["D881"]?.text ?? vm.items[index].reminder, "等待上游联调")
        XCTAssertEqual(vm.reminderDrafts["D881"]?.expected ?? vm.items[index].reminder, "等待上游联调")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: CacheFile.path)), originalCache)
        XCTAssertEqual(writes, 0)
    }

    @MainActor
    private func host(vm: DBoardViewModel, session: DemandMatrixDragSession, panelWithOuterScroll: Bool = false,
                      move: @escaping (DemandMatrixDrag, ItemPriority) -> Bool) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 900, height: 620),
            styleMask: panelWithOuterScroll ? [.borderless] : [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MatrixGestureHost(vm: vm, session: session, move: move,
                                                                       outerScroll: panelWithOuterScroll)
            .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
            .padding(12).frame(width: 900, height: 620, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.orderBack(nil)
        settle()
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        return window
    }

    @MainActor
    private func beginDrag(_ window: NSWindow, start: CGPoint, end: CGPoint) {
        event(window, type: .leftMouseDown, at: start)
        for index in 1...10 {
            let fraction = CGFloat(index) / 10
            event(window, type: .leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * fraction,
                                                              y: start.y + (end.y - start.y) * fraction))
        }
        settle()
    }

    @MainActor
    private func event(_ window: NSWindow, type: NSEvent.EventType, at point: CGPoint) {
        let height = window.frame.height
        let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: point.x, y: height - point.y),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        window.sendEvent(event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
    }

    @MainActor
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    @MainActor
    private func snapshot(_ window: NSWindow, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_DRAG_FIX_SNAPSHOTS"] else { return }
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
    }
}

private struct MatrixGestureHost: View {
    @ObservedObject var vm: DBoardViewModel
    let session: DemandMatrixDragSession
    let move: (DemandMatrixDrag, ItemPriority) -> Bool
    var outerScroll = false
    var body: some View {
        if outerScroll {
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 32)
                    matrix
                }
            }
        } else {
            matrix
        }
    }
    private var matrix: some View {
        DemandMatrixView(items: vm.items, dragging: session, onMove: move).environmentObject(vm)
    }
}
