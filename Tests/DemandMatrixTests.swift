import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandMatrixTests: XCTestCase {
    private func item(_ id: String, _ priority: ItemPriority, status: ItemStatus = .pending, title: String = "需求测试") -> DItem {
        DItem(id: id, project: "ultra", title: "", headerTitle: title, status: status,
              priority: priority, deadline: nil, branch: nil, startDate: nil, milestones: [])
    }

    func testQuadrantsRespectUserPriorityEvenWhenDeadlineIsUrgent() {
        XCTAssertEqual(DemandMatrix.rows[0], [.p1, .p0])
        XCTAssertEqual(DemandMatrix.rows[1], [.p3, .p2])
        let today = DemandDates.today()
        var items = ItemPriority.allCases.enumerated().map { item("D" + String(881 + $0.offset), $0.element) }
        items.append(DItem(id: "D885", project: "audi", title: "", headerTitle: "已临近截止的低优先级需求",
            status: .pending, priority: .p3, deadline: today, branch: nil, startDate: nil, milestones: []))
        XCTAssertTrue(items.last!.isUrgent)
        XCTAssertEqual(DemandMatrix.items(items, in: .p3).map(\.id), ["D884", "D885"])
        XCTAssertEqual(DemandMatrix.items(items, in: .p0).map(\.id), ["D881"])
        XCTAssertEqual(DemandMatrix.rows.flatMap { $0 }.flatMap { DemandMatrix.items(items, in: $0) }.count, items.count)
    }

    func testOverviewIncludesAllOpenItemsWithoutListPreviewLimit() {
        var items = (881...890).map { item("D" + String($0), .p1) }
        items.append(item("D891", .p3, status: .suspended))
        items.append(item("D892", .p0, status: .completed))
        let open = DemandMatrix.openItems(items)
        XCTAssertEqual(open.count, 11)
        XCTAssertTrue(open.contains { $0.id == "D891" })
        XCTAssertFalse(open.contains { $0.id == "D892" })
        let vm = DBoardViewModel(loadCache: false)
        vm.items = open
        vm.demandQuery = "D887"
        XCTAssertEqual(DemandMatrix.items(vm.filteredItems, in: .p1).map(\.id), ["D887"])
    }

    func testLayoutSelectionPersistsAndInvalidStoredValueFallsBack() {
        let name = "DBoardMatrixTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = WorkspacePreferences(defaults: defaults)
        prefs.demandLayout = .matrix
        XCTAssertEqual(WorkspacePreferences(defaults: defaults).demandLayout, .matrix)
        prefs.demandLayout = .list
        XCTAssertEqual(WorkspacePreferences(defaults: defaults).demandLayout, .list)
        defaults.set("removed-layout", forKey: "workspace.demandLayout")
        XCTAssertEqual(WorkspacePreferences(defaults: defaults).demandLayout, .list)
    }

    @MainActor
    func testCardOpensFullDetailsAndCanContinueIntoEditing() throws {
        let vm = DBoardViewModel(loadCache: false)
        let value = item("D881", .p0, title: "详情测试")
        vm.items = [value]
        let window = host(DemandMatrixCard(item: value).demandEditorPresentation()
            .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared),
            width: 560, height: 520)
        defer { vm.demandEditor = nil; window.close() }
        click(window, x: 100, y: 520 - 56)
        XCTAssertEqual(vm.demandEditor?.kind, .inspect)
        XCTAssertEqual(vm.demandEditor?.item.id, value.id)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertTrue(vm.expandedIDs.contains(value.id))
        vm.openDemandEditor(.details, item: value)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(vm.demandEditor?.kind, .details)
        XCTAssertNotNil(window.attachedSheet)
        vm.demandEditor = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    @MainActor
    func testRenderMatrixAndOverviewInLightDarkAndCompactWindows() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_MATRIX_SNAPSHOTS"] else {
            throw XCTSkip("Enable matrix UI snapshots explicitly")
        }
        _ = NSApplication.shared
        // Prevent the fixture host from starting notifications or touching reply state.
        let processDefaults = UserDefaults.standard
        let arguments = processDefaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var isolatedArguments = arguments
        isolatedArguments["reply.enabled"] = false
        processDefaults.setVolatileDomain(isolatedArguments, forName: UserDefaults.argumentDomain)
        defer { processDefaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        let before = try Data(contentsOf: URL(fileURLWithPath: CacheFile.path))
        let name = "DBoardMatrixSnapshots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = WorkspacePreferences(defaults: defaults)
        prefs.demandLayout = .matrix
        let vm = DBoardViewModel(loadCache: false)
        vm.items = [
            item("D881", .p0, status: .inProgress, title: "车点点锁券链路改造"),
            item("D882", .p1, status: .inProgress, title: "高德电话线索接入养车系统"),
            item("D883", .p2, title: "核对上游接口权限"),
            item("D884", .p3, status: .suspended, title: "整理研发工具入口")
        ]
        vm.items[0].reminder = "正在和 SAAS 联调"
        vm.items[1].reminder = "等待门店验证归因结果"
        vm.items += (885...891).map { item("D" + String($0), .p1, title: "上线配置核对和服务验收") }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(940)),
                                          ("dark", .darkAqua, CGFloat(940)),
                                          ("compact", .aqua, CGFloat(420))] {
            NSApp.appearance = NSAppearance(named: appearance)
            let matrix = DemandMatrixView(items: DemandMatrix.openItems(vm.items))
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                .environment(\.colorScheme, name == "dark" ? .dark : .light)
            let window = host(matrix, width: width, height: 570)
            window.appearance = NSAppearance(named: appearance)
            try snapshot(window, path: output + "/matrix-" + name + ".png")
            window.close()
            let overview = ScrollView {
                WorkspaceOverview(preferences: prefs)
                    .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
            }.environment(\.colorScheme, name == "dark" ? .dark : .light)
            let home = host(overview, width: width, height: 760)
            home.appearance = NSAppearance(named: appearance)
            try snapshot(home, path: output + "/overview-" + name + ".png")
            home.close()
            prefs.demandLayout = .list
            let list = host(ScrollView {
                WorkspaceOverview(preferences: prefs)
                    .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
            }.environment(\.colorScheme, name == "dark" ? .dark : .light), width: width, height: 760)
            list.appearance = NSAppearance(named: appearance)
            try snapshot(list, path: output + "/list-" + name + ".png")
            list.close()
            prefs.demandLayout = .matrix
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: CacheFile.path)), before)
    }

    @MainActor
    private func host<V: View>(_ root: V, width: CGFloat, height: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root.padding(12)
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    @MainActor
    private func click(_ window: NSWindow, x: CGFloat, y: CGFloat) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }

    @MainActor
    private func snapshot(_ window: NSWindow, path: String) throws {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }
}
