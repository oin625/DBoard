import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class ThemeTests: XCTestCase {
    func testSelectionPersistsAndRestoreDefaultSurvivesRestart() throws {
        try withDefaults { defaults in
            let manager = ThemeManager(defaults: defaults)
            XCTAssertEqual(manager.current, .indigo)
            manager.current = .sand
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .sand)
            manager.current = .glass
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .glass)
            manager.restoreDefault()
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .indigo)
        }
    }

    func testLegacyIDsMigrateWithoutResettingExplicitChoicesOrFonts() throws {
        try withDefaults { defaults in
            defaults.set("system", forKey: "dboard_theme_id")
            defaults.set("yuanti", forKey: "dboard_font_id")
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .indigo)
            XCTAssertEqual(defaults.string(forKey: "dboard_theme_id"), "indigo")
            XCTAssertEqual(defaults.string(forKey: "dboard_font_id"), "yuanti")
            defaults.set("minimal", forKey: "dboard_theme_id")
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .graphite)
            defaults.set("glass", forKey: "dboard_theme_id")
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .glass)
            defaults.set("removed-skin", forKey: "dboard_theme_id")
            XCTAssertEqual(ThemeManager(defaults: defaults).current, .indigo)
            XCTAssertEqual(defaults.string(forKey: "dboard_theme_id"), "indigo")
        }
    }

    @MainActor
    func testChangingSkinUpdatesOpenWindowsAndRetainsSelectionDraftAndKeyboardFocus() throws {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try withDefaults { defaults in
            let manager = ThemeManager(defaults: defaults)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardSkins-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            func model(_ suffix: String) -> DBoardViewModel {
                let archive = DemandArchiveStore(cache: directory.appendingPathComponent(suffix + "-archive.md"),
                    journalURL: directory.appendingPathComponent(suffix + "-journal.json"), allowsRemote: false)
                return DBoardViewModel(loadCache: false,
                    newItemDraftStore: NewDemandDraftStore(url: directory.appendingPathComponent(suffix + "-draft.json")),
                    archiveStore: archive)
            }
            let main = model("main")
            main.items = [sampleItem()]
            let home = host(DBoardRootView(popoverMode: true)
                .environmentObject(main).environmentObject(manager).environmentObject(FontManager.shared),
                size: NSSize(width: 660, height: 740))
            defer { home.close() }
            let quick = DemandQuickOpenWindowController(activates: false,
                recents: DemandQuickOpenRecents(defaults: defaults), theme: manager)
            quick.show(main)
            defer { quick.close() }
            let quickWindow = try XCTUnwrap(quick.window)

            let creation = model("new")
            var draft = DItemDraft(newID: "D883", priority: .p1)
            draft.name = "尚未保存的标题"
            draft.project = "ultra"
            draft.promptSections.intent = "保留正在填写的咒言"
            creation.newItemDraft = draft
            let newWindowController = NewDemandWindowController(activates: false, theme: manager)
            creation.newDemandWindowPresenter = { newWindowController.show($0) }
            creation.beginNewItemDraft()
            defer { newWindowController.close() }
            let newWindow = try XCTUnwrap(newWindowController.window)

            let detail = model("detail")
            detail.items = [sampleItem()]
            let detailController = DemandDetailWindowController(activates: false, theme: manager)
            detail.demandWindowPresenter = { detailController.show($0) }
            detail.openDemandEditor(.inspect, item: detail.items[0])
            defer { detailController.close() }
            let detailWindow = try XCTUnwrap(detailController.window)
            settle()
            let focus = try XCTUnwrap(newWindow.firstResponder as? DemandKeyboardActionView)
            let detailRequest = try XCTUnwrap(detail.demandEditor).id
            let output = ProcessInfo.processInfo.environment["DBOARD_SKIN_SNAPSHOTS"]
            if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                var last: [String: Data] = [:]
                for palette in DBoardTheme.all {
                    manager.current = palette
                    let windows: [(String, NSWindow)] = [("home", home), ("quick", quickWindow),
                                                        ("new", newWindow), ("detail", detailWindow)]
                    for (_, window) in windows { window.appearance = NSAppearance(named: appearance) }
                    settle()
                    for (root, window) in windows {
                        let image = try bitmap(window)
                        if let previous = last[root] {
                            XCTAssertNotEqual(image, previous, "\(root) must update its existing content when skin changes")
                        }
                        last[root] = image
                        if let output {
                            try image.write(to: URL(fileURLWithPath: output + "/\(palette.id)-\(root)-\(name).png"))
                        }
                    }
                    XCTAssertTrue(quick.window === quickWindow)
                    XCTAssertTrue(newWindowController.window === newWindow)
                    XCTAssertTrue(detailController.window === detailWindow)
                    XCTAssertEqual(quick.model.selectedID, "D014")
                    XCTAssertEqual(creation.newItemDraft?.name, "尚未保存的标题")
                    XCTAssertEqual(creation.newItemDraft?.promptSections.intent, "保留正在填写的咒言")
                    XCTAssertEqual(detail.demandEditor?.id, detailRequest)
                    XCTAssertTrue(newWindow.firstResponder === focus)
                    appearanceColorCheck(focus, palette: palette)
                    if let output {
                        quick.model.scope = .all
                        main.workspacePage = .demands
                        settle()
                        try bitmap(quickWindow).write(to: URL(fileURLWithPath: output + "/\(palette.id)-grid-\(name).png"))
                        try bitmap(home).write(to: URL(fileURLWithPath: output + "/\(palette.id)-all-\(name).png"))
                        let matrix = host(DemandMatrixView(items: main.items)
                            .padding(.vertical, 20).background { DemandCanvasBackground() }.dboardThemeAccent()
                            .environmentObject(main).environmentObject(manager).environmentObject(FontManager.shared),
                            size: NSSize(width: 660, height: 580))
                        matrix.appearance = NSAppearance(named: appearance)
                        settle()
                        try bitmap(matrix).write(to: URL(fileURLWithPath: output + "/\(palette.id)-matrix-\(name).png"))
                        matrix.close()
                        quick.model.scope = .development
                        main.workspacePage = .overview
                        settle()
                    }
                }
                // Inspect the appearance page with both miniatures visible.
                let settings = host(AppearanceSettingsView(theme: manager), size: NSSize(width: 640, height: 560))
                settings.appearance = NSAppearance(named: appearance)
                settle()
                if let output {
                    try bitmap(settings).write(to: URL(fileURLWithPath: output + "/settings-\(name).png"))
                }
                settings.close()
            }
            settle(DemandKeyboardActionView.focusRingIdleDelay + 0.2)
            XCTAssertEqual(focus.layer?.opacity, 0)
            manager.current = .sand
            settle()
            XCTAssertEqual(focus.layer?.opacity, 0, "A skin change must not reveal an expired focus hint")
            XCTAssertTrue(newWindow.firstResponder === focus)
        }
    }

    @MainActor
    private func appearanceColorCheck(_ view: DemandKeyboardActionView, palette: DBoardTheme,
                                      file: StaticString = #filePath, line: UInt = #line) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let actual = view.layer?.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.deviceRGB) }
            let expected = NSColor(palette.accentPrimary).withAlphaComponent(0.8).usingColorSpace(.deviceRGB)
            XCTAssertNotNil(actual, file: file, line: line)
            XCTAssertNotNil(expected, file: file, line: line)
            if let actual, let expected {
                XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.02, file: file, line: line)
                XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 0.02, file: file, line: line)
                XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.02, file: file, line: line)
            }
        }
    }

    private func sampleItem() -> DItem {
        var item = DItem(id: "D014", project: "ultra", title: "验券只查券，工单创建后再调用独立锁券接口。",
            headerTitle: "车点点锁券链路改造", status: .inProgress, priority: .p1,
            deadline: nil, branch: "feature/cdd-lock", startDate: nil,
            milestones: [Milestone(date: "11.10", content: "独立锁券接口与调试页就绪，等待调用方联调。")])
        item.reminder = "等待调用方联调"
        item.releaseChecklist.items = [.init(id: "L001", text: "发布 ultra 服务", updatedBy: .ai,
            details: "开发分支 feature/cdd-lock", category: .release)]
        return item
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "DBoardThemeTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @MainActor
    private func host<V: View>(_ root: V, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.orderBack(nil)
        return window
    }

    @MainActor
    private func bitmap(_ window: NSWindow) throws -> Data {
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    @MainActor
    private func settle(_ duration: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }
}
