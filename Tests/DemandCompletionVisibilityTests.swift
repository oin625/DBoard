import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandCompletionVisibilityTests: XCTestCase {
    private func fixture(_ body: (URL, DemandArchiveStore) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardCompleted-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journalURL = directory.appendingPathComponent("journal.json")
        let journal = ArchiveJournal(url: journalURL)
        for (id, title, state, day) in [
            ("D018", "新车线索黑名单配置转移", ArchiveJournal.Entry.State.removed, "2026-11-04"),
            ("D015", "账单排查", .uploaded, "2026-10-30"),
            ("D019", "尚未确认的归档", .submitted, "2026-11-04")
        ] {
            let original = ["### \(id)【tesla】\(title) #进行中", "- **分支**：audi:feature/vibe",
                "- **描述**：保留上下文", "- **进度**：", "    - 11.3: 已完成验证，待验收"]
            var archived = original
            archived[0] = archived[0].replacingOccurrences(of: "#进行中", with: "#已完成") + " ✅" + day
            let date = ISO8601DateFormatter().date(from: day + "T08:00:00Z")!
            XCTAssertTrue(journal.save(.init(id: id, original: original, archived: archived, state: state, createdAt: date)))
        }
        let store = DemandArchiveStore(cache: directory.appendingPathComponent("archive.md"),
            journalURL: journalURL, allowsRemote: false)
        try body(directory, store)
    }

    private func item(_ id: String, status: ItemStatus) -> DItem {
        DItem(id: id, project: "ultra", title: "保留现状", headerTitle: "当前需求",
            status: status, priority: .p1, deadline: nil, branch: nil, startDate: nil, milestones: [])
    }

    func testCompletedCatalogMixesIncidentAndDevelopmentWithCurrentDataWinning() throws {
        try fixture { _, store in
            var incident = item("P001", status: .completed)
            incident.kind = .incident
            incident.incidentClosure = IncidentClosure(outcome: .resolved, summary: "已定位并处理登录态过期",
                                                        closed_at: "2026-11-10T08:00:00Z")
            let completed = item("D021", status: .completed)
            let reopened = item("D018", status: .inProgress)
            let rows = DemandCompletedCatalog.entries(current: [completed, incident, reopened, incident],
                                                       archived: store.records + store.records)
            XCTAssertEqual(rows.map(\.item.id), ["P001", "D015", "D021"])
            XCTAssertEqual(rows.filter { $0.item.isIncident }.count, 1)
            XCTAssertEqual(rows.first?.item.incidentClosure?.summary, "已定位并处理登录态过期")
            XCTAssertEqual(rows.first?.completionDay, "2026-11-10")
            XCTAssertNil(rows.first?.archive)
            XCTAssertEqual(rows[1].archive?.item.id, "D015")
            XCTAssertFalse(rows.contains { $0.item.id == "D018" })
        }
    }

    @MainActor
    func testCompletedCatalogHonorsSharedSearchAndFilters() throws {
        try fixture { _, store in
            var incident = item("P001", status: .completed)
            incident.kind = .incident
            let vm = DBoardViewModel(loadCache: false, archiveStore: store)
            vm.items = [incident, item("D021", status: .completed), item("D013", status: .inProgress)]
            vm.showDemands(.all)
            let all = DemandCompletedCatalog.entries(current: vm.filteredItems, archived: vm.filteredArchiveRecords)
            XCTAssertEqual(all.count, 4)
            XCTAssertFalse(all.contains { $0.item.status != .completed })
            vm.showDemands(.incidents)
            XCTAssertEqual(DemandCompletedCatalog.entries(current: vm.filteredItems, archived: vm.filteredArchiveRecords).map(\.id), ["P001"])
            vm.showDemands(.completed)
            vm.demandQuery = "线索 feature/vibe"
            XCTAssertEqual(DemandCompletedCatalog.entries(current: vm.filteredItems, archived: vm.filteredArchiveRecords).map(\.id), ["D018"])
        }
    }

    @MainActor
    func testAllPageCompletedSectionStartsCollapsedAndCanExpandCollapseAndRevealSelection() throws {
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
        _ = NSApplication.shared
        try fixture { _, store in
            let vm = DBoardViewModel(loadCache: false, archiveStore: store)
            vm.items = [item("D013", status: .inProgress)]
            vm.showDemands(.all)
            let view = NSHostingView(rootView: DBoardRootView(popoverMode: true)
                .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                .environment(\.demandFloatingCanvas, true).frame(width: 520, height: 700))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 520, height: 700),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view; window.orderBack(nil)
            defer { window.close() }
            @MainActor func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded() }
            @MainActor func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
            @MainActor func controls() -> [DemandKeyboardActionView] { descendants(view).compactMap { $0 as? DemandKeyboardActionView } }
            @MainActor func screenshot(_ name: String) throws {
                guard let output = ProcessInfo.processInfo.environment["DBOARD_HOME_UI_SNAPSHOTS"] else { return }
                try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
            }
            settle()
            let toggle = try XCTUnwrap(controls().first { $0.keyboardIdentifier == "completed-section-toggle" })
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier.hasPrefix("completed-toggle-") })
            try screenshot("all-collapsed")
            toggle.activate()
            settle()
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "completed-toggle-D018" })
            try screenshot("all-expanded")
            try XCTUnwrap(controls().first { $0.keyboardIdentifier == "completed-section-toggle" }).activate()
            settle()
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier.hasPrefix("completed-toggle-") })
            vm.focusArchive(try XCTUnwrap(store.records.first { $0.item.id == "D018" }))
            settle()
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "completed-toggle-D018" },
                          "Opening a specific completed demand still reveals its section")
            vm.showDemands(.completed)
            settle()
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier == "completed-section-toggle" })
            XCTAssertTrue(controls().contains { $0.keyboardIdentifier == "completed-toggle-D018" })
            vm.selectedID = nil
            vm.showDemands(.all)
            settle()
            XCTAssertFalse(controls().contains { $0.keyboardIdentifier.hasPrefix("completed-toggle-") },
                           "Returning from completed-only to all starts with the completed section collapsed")
            vm.workspacePage = .overview
            settle()
            try screenshot("home")
        }
    }

    @MainActor
    func testRenderOneCompletedSectionForBothLayouts() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_COMPLETED_UI_SNAPSHOTS"] else {
            throw XCTSkip("Enable completed UI snapshots explicitly")
        }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        try fixture { _, store in
            _ = NSApplication.shared
            let suite = "DBoardCompletedUI-" + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let preferences = WorkspacePreferences(defaults: defaults)
            let vm = DBoardViewModel(loadCache: false, archiveStore: store)
            var incident = item("P001", status: .completed)
            incident.kind = .incident
            incident.incidentClosure = IncidentClosure(outcome: .resolved, summary: "核对上游响应后确认照片配置缺失，已交接车点点补齐。",
                                                        closed_at: "2026-11-10T08:00:00Z")
            vm.items = [incident, item("D013", status: .inProgress)]
            vm.showDemands(.all)
            let original = NSApp.appearance
            defer { NSApp.appearance = original }
            for (name, layout, appearance, width) in [
                ("matrix-light", DemandLayout.matrix, NSAppearance.Name.aqua, CGFloat(760)),
                ("matrix-dark", .matrix, .darkAqua, CGFloat(760)),
                ("list-compact", .list, .aqua, CGFloat(440))
            ] {
                preferences.demandLayout = layout
                NSApp.appearance = NSAppearance(named: appearance)
                let view = NSHostingView(rootView: ScrollView {
                    VStack(spacing: 0) { DemandListView(store: store, preferences: preferences) }
                }.environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
                    .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
                    .frame(width: width, height: 1080).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: width, height: 1080),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = view; window.orderBack(nil)
                defer { window.close() }
                RunLoop.main.run(until: Date().addingTimeInterval(0.4))
                view.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output + "/" + name + ".png"))
                XCTAssertEqual(DemandCompletedCatalog.entries(current: vm.filteredItems, archived: vm.filteredArchiveRecords).count, 3)
            }
        }
    }

    func testLegacyCompletedCacheRemainsReadableWithEveryContextField() throws {
        try fixture { directory, _ in
            let cache = directory.appendingPathComponent("active.md")
            let text = """
            ## 🟡 重要
            ### D018【tesla】线索黑名单 #进行中
            - **提示词**：
                ## 要做什么
                将原逻辑迁到 Redis，保留上下文。
            - **分支**：tesla:feature/blacklist；audi:feature/vibe
            - **进度**：
                - 11.3: 已完成实现，待验收
                  明细：
                    调试页已建立，已有变更不能丢失。

            ### D020【audi】其他需求 #进行中
            - **描述**：不受影响
            """
            try text.write(to: cache, atomically: true, encoding: .utf8)
            XCTAssertTrue(FileMutator.setStatus(id: "D018", newStatusRaw: ItemStatus.completed.rawValue, at: cache))
            let actual = try String(contentsOf: cache, encoding: .utf8)
            XCTAssertEqual(actual, text.replacingOccurrences(of: "线索黑名单 #进行中", with: "线索黑名单 #已完成"))
            let saved = try DItemStore.currentItem(id: "D018", at: cache)
            XCTAssertEqual(saved.status, .completed)
            XCTAssertFalse(saved.prompt.isEmpty)
            XCTAssertEqual(saved.milestones.count, 1)
            XCTAssertTrue(DemandFilter.completed.includes(saved))
            XCTAssertEqual(try DItemStore.currentItem(id: "D020", at: cache).status, .inProgress)
            let before = try Data(contentsOf: cache)
            XCTAssertFalse(FileMutator.setStatus(id: "D999", newStatusRaw: ItemStatus.completed.rawValue, at: cache))
            XCTAssertEqual(try Data(contentsOf: cache), before)
        }
    }

    @MainActor
    func testCompletedAndAllIncludeArchivedDemandWithoutMixingItIntoActiveWork() throws {
        try fixture { _, store in
            let vm = DBoardViewModel(loadCache: false, archiveStore: store)
            vm.items = [item("D021", status: .completed), item("D013", status: .inProgress)]
            XCTAssertEqual(store.records.map { $0.item.id }, ["D018", "D015"])
            vm.showDemands(.completed)
            XCTAssertEqual(vm.filteredItems.map(\.id), ["D021"])
            XCTAssertEqual(vm.filteredArchiveRecords.map { $0.item.id }, ["D018", "D015"])
            XCTAssertEqual(vm.filteredDemandCount, 3)
            XCTAssertEqual(vm.knownDemandCount, 4)
            vm.showDemands(.all)
            vm.demandQuery = "线索 feature/vibe"
            XCTAssertEqual(vm.filteredDemandCount, 1)
            XCTAssertEqual(vm.filteredArchiveRecords.first?.item.id, "D018")
            vm.showDemands(.inProgress)
            XCTAssertEqual(vm.filteredItems.map(\.id), ["D013"])
            XCTAssertTrue(vm.filteredArchiveRecords.isEmpty)
            XCTAssertFalse(vm.attentionItems.contains { $0.id == "D018" })
        }
    }

    @MainActor
    func testReopenedDemandWinsOverHistoryAndPaletteCanOpenAnArchive() throws {
        try fixture { _, store in
            let vm = DBoardViewModel(loadCache: false, archiveStore: store)
            vm.items = [item("D018", status: .inProgress)]
            vm.showDemands(.completed)
            XCTAssertFalse(vm.filteredArchiveRecords.contains { $0.item.id == "D018" })
            vm.focusArchive(try XCTUnwrap(store.records.first { $0.item.id == "D018" }))
            XCTAssertEqual(vm.workspacePage, .history)
            XCTAssertEqual(vm.selectedID, store.records.first?.id)
            vm.items = []
            vm.paletteQuery = "线索"
            let entry = try XCTUnwrap(vm.paletteEntries.first(where: { $0.id.hasPrefix("archive:") }))
            entry.action()
            XCTAssertEqual(vm.workspacePage, .demands)
            XCTAssertEqual(vm.demandFilter, .completed)
            XCTAssertEqual(vm.demandQuery, "D018")
            XCTAssertEqual(vm.selectedID, store.records.first?.id)
            XCTAssertEqual(vm.filteredDemandCount, 1)
        }
    }

    @MainActor
    func testCompletionButtonAndStatusSwitchUseTheSameWorkflowWithoutMarkingOnlyStatus() throws {
        try fixture { _, store in
            var requests: [DItem] = []
            let vm = DBoardViewModel(loadCache: false, archiveStore: store, completionRequest: { requests.append($0) })
            let demand = item("D013", status: .inProgress)
            vm.items = [demand]
            vm.completeItem(demand)
            vm.cycleToStatus(demand.id, target: .completed)
            vm.cycleStatus(demand.id)
            XCTAssertEqual(requests.map(\.id), ["D013", "D013", "D013"])
            XCTAssertTrue(requests.allSatisfy { $0.status == .inProgress })
            XCTAssertEqual(vm.items.first?.status, .inProgress, "Completion stays pending until the full snapshot is saved")
            vm.archivingIDs.insert(demand.id)
            vm.completeItem(demand)
            XCTAssertEqual(requests.count, 3, "A running completion cannot be submitted again")
            XCTAssertEqual(DemandFilter.allCases.map(\.rawValue), ["全部", "紧急", "进行中", "待开始", "挂起", "已完成", "线上排查"])
        }
    }

    func testLocalArchiveSurvivesBrokenRemoteCacheAndClearsStaleError() throws {
        try fixture { directory, store in
            let cache = directory.appendingPathComponent("archive.md")
            try Data([0xff, 0xfe]).write(to: cache, options: .atomic)
            store.reloadLocal()
            XCTAssertNotNil(store.error)
            XCTAssertTrue(store.records.contains { $0.item.id == "D018" })
            try "".write(to: cache, atomically: true, encoding: .utf8)
            store.reloadLocal()
            XCTAssertNil(store.error)
            XCTAssertEqual(store.records.count, 2)
            XCTAssertFalse(store.records.contains { $0.item.id == "D019" })
        }
    }

    @MainActor
    func testRealD018ArchiveCanBeFoundAndRenderedWithoutChangingUserData() throws {
        guard let output = ProcessInfo.processInfo.environment["DBOARD_ARCHIVE_SMOKE"] else {
            throw XCTSkip("Enable read-only archive smoke test explicitly")
        }
        _ = NSApplication.shared
        let journal = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/dboard-archive-journal.json")
        let cache = URL(fileURLWithPath: CacheFile.path)
        let before = try Data(contentsOf: journal), activeBefore = try Data(contentsOf: cache)
        let store = DemandArchiveStore(allowsRemote: false)
        let record = try XCTUnwrap(store.records.first { $0.item.id == "D018" })
        XCTAssertEqual(record.item.displayTitle, "新车线索黑名单配置转移")
        let vm = DBoardViewModel(loadCache: false, archiveStore: store)
        vm.items = CacheParser.parse(content: try String(contentsOf: cache, encoding: .utf8)).items
        vm.showDemands(.completed)
        vm.demandQuery = "D018"
        XCTAssertEqual(vm.filteredDemandCount, 1)
        vm.selectedID = record.id
        let view = NSHostingView(rootView: ScrollView {
            DemandListView(store: store)
        }.environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
            .frame(width: 760, height: 600).background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output))
        XCTAssertEqual(try Data(contentsOf: journal), before)
        XCTAssertEqual(try Data(contentsOf: cache), activeBefore)
    }
}
