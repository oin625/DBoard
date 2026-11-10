import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandReleaseChecklistInteractionTests: XCTestCase {
    private let itemID = "D777"
    private var entry: DemandReleaseChecklist.Entry {
        .init(id: "L001", text: "发布 Ultra 服务", updatedBy: .ai,
              details: "分支：feature/release。\n先执行 SQL，再发布服务。", category: .release)
    }

    @MainActor
    func testViewingDetailsIsSeparateFromEditingAndDraftSurvivesReopening() throws {
        let vm = DBoardViewModel(loadCache: false)
        let before = try Data(contentsOf: URL(fileURLWithPath: CacheFile.path))
        var window = host(DemandReleaseChecklistRow(itemID: itemID, entry: entry, readOnly: false).environmentObject(vm),
                          width: 560, height: 400)
        press(window, id: "release-details-" + itemID + "-L001")
        XCTAssertTrue(vm.releaseDrafts.isEmpty)
        press(window, id: "release-edit-" + itemID + "-L001")
        let key = itemID + ":L001"
        XCTAssertEqual(vm.releaseDrafts[key]?.details, entry.details)
        press(window, id: "release-category-sql-" + key)
        XCTAssertEqual(vm.releaseDrafts[key]?.category, .sql)
        vm.releaseDrafts[key]?.text = "执行高德建表 SQL"
        window.close()
        XCTAssertEqual(vm.releaseDrafts[key]?.text, "执行高德建表 SQL")
        window = host(DemandReleaseChecklistRow(itemID: itemID, entry: entry, readOnly: false).environmentObject(vm),
                      width: 560, height: 400)
        defer { window.close() }
        XCTAssertEqual(vm.releaseDrafts[key]?.category, .sql)
        press(window, id: "release-cancel-" + key)
        XCTAssertNil(vm.releaseDrafts[key])
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: CacheFile.path)), before)
    }

    @MainActor
    func testGroupAddPreselectsCategoryAndCollapseKeepsDraft() throws {
        let vm = DBoardViewModel(loadCache: false)
        var item = DItem(id: itemID, project: "DBoard", title: "", headerTitle: "清单交互测试",
            status: .inProgress, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
        item.releaseChecklist.items = [entry]
        item.releaseChecklist.nextID = 2
        let window = host(DemandReleaseChecklistView(item: item).environmentObject(vm), width: 560, height: 520)
        defer { window.close() }
        press(window, id: "release-add-release-" + itemID)
        let key = itemID + ":release-new"
        XCTAssertEqual(vm.releaseDrafts[key]?.category, .release)
        vm.releaseDrafts[key]?.text = "配置生产开关"
        press(window, id: "release-category-configuration-" + key)
        XCTAssertEqual(vm.releaseDrafts[key]?.category, .configuration)
        press(window, id: "release-section-" + itemID)
        XCTAssertEqual(vm.releaseDrafts[key]?.text, "配置生产开关")
        press(window, id: "release-section-" + itemID)
        press(window, id: "release-cancel-" + key)
        XCTAssertTrue(vm.releaseDrafts.isEmpty)
    }


    @MainActor
    func testCustomCategoryCanBeTypedWithoutSavingTheItem() throws {
        let vm = DBoardViewModel(loadCache: false)
        let before = try Data(contentsOf: URL(fileURLWithPath: CacheFile.path))
        let window = host(DemandReleaseChecklistRow(itemID: itemID, entry: entry, readOnly: false).environmentObject(vm),
                          width: 560, height: 450)
        defer { window.close() }
        press(window, id: "release-edit-" + itemID + "-L001")
        press(window, id: "release-custom-category-" + itemID + ":L001")
        let field = try XCTUnwrap(window.firstResponder as? NSTextView)
        field.insertText("数据迁移", replacementRange: field.selectedRange())
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(event)
        settle(window)
        XCTAssertEqual(vm.releaseDrafts[itemID + ":L001"]?.category, .custom("数据迁移"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: CacheFile.path)), before)
        press(window, id: "release-cancel-" + itemID + ":L001")
        XCTAssertTrue(vm.releaseDrafts.isEmpty)
    }

    @MainActor
    func testRenderGroupsDetailsAndEditingInLightDarkAndNarrowWindows() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_RELEASE_UI_SNAPSHOTS"] else {
            throw XCTSkip("Enable checklist UI snapshots explicitly")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        let real = try DItemStore.currentItem(id: "D013")
        for (name, appearance, width) in [("light", NSAppearance.Name.aqua, CGFloat(650)),
                                          ("dark", .darkAqua, CGFloat(650)),
                                          ("narrow", .aqua, CGFloat(380))] {
            NSApp.appearance = NSAppearance(named: appearance)
            let vm = DBoardViewModel(loadCache: false)
            let window = host(DemandReleaseChecklistView(item: real).environmentObject(vm)
                .environment(\.colorScheme, name == "dark" ? .dark : .light), width: width, height: 650)
            if name == "narrow" {
                // Also exercise an action category outside the common set.
                vm.items = [real]
            }
            window.appearance = NSAppearance(named: appearance)
            try snapshot(window, at: output + "/groups-" + name + ".png")
            window.close()
            let row = host(DemandReleaseChecklistRow(itemID: itemID, entry: entry, readOnly: false)
                .environmentObject(vm).environment(\.colorScheme, name == "dark" ? .dark : .light),
                width: width, height: 400)
            row.appearance = NSAppearance(named: appearance)
            press(row, id: "release-details-" + itemID + "-L001")
            try snapshot(row, at: output + "/details-" + name + ".png")
            press(row, id: "release-edit-" + itemID + "-L001")
            vm.releaseDrafts[itemID + ":L001"]?.category = .custom("资源准备")
            try snapshot(row, at: output + "/editor-" + name + ".png")
            press(row, id: "release-cancel-" + itemID + ":L001")
            row.close()
        }
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
        settle(window)
        return window
    }

    @MainActor
    private func settle(_ window: NSWindow) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.18))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func press(_ window: NSWindow, id: String, file: StaticString = #filePath, line: UInt = #line) {
        // Drive real mouse events in a fixed-size hosting window, as in the chat-picker tests.
        let width = window.contentView!.bounds.width
        let height = window.contentView!.bounds.height
        let point: NSPoint
        if id.hasPrefix("release-details-") { point = NSPoint(x: 170, y: height - 29) }
        else if id.hasPrefix("release-edit-") { point = NSPoint(x: width - 34, y: height - 29) }
        else if id.hasPrefix("release-custom-category-") { point = NSPoint(x: 105, y: height - 204) }
        else if id.hasPrefix("release-add-release-") { point = NSPoint(x: width - 36, y: height - 75) }
        else if id.hasPrefix("release-section-") { point = NSPoint(x: 120, y: height - 35) }
        else if id.hasPrefix("release-cancel-") { point = NSPoint(x: width - 44, y: height - (id.contains(":release-new") ? 158 : 70)) }
        else if id.hasPrefix("release-category-") {
            let index: CGFloat = id.contains("-sql-") ? 1 : 2
            let segmentWidth = (width - 88) / 5
            point = NSPoint(x: 32 + segmentWidth / 2 + index * (segmentWidth + 6),
                            y: height - (id.contains(":release-new") ? 255 : 167))
        } else { XCTFail("Unknown test control: " + id, file: file, line: line); return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        settle(window)
    }

    @MainActor
    private func snapshot(_ window: NSWindow, at path: String) throws {
        settle(window)
        let view = try XCTUnwrap(window.contentView)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: path))
    }
}
