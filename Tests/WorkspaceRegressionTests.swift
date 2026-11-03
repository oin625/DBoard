import XCTest
import AppKit
import Carbon.HIToolbox
@testable import DBoard

final class WorkspaceRegressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.register(defaults: ["reply.enabled": false])
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "DBoardTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }

    func testShortcutConflictKeepsOriginalBinding() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = ShortcutPreferences(defaults: defaults)
        let original = prefs.binding(for: "reqflow")
        XCTAssertFalse(prefs.set(prefs.binding(for: "logs")!, for: "reqflow"))
        XCTAssertEqual(prefs.binding(for: "reqflow"), original)
        XCTAssertTrue(prefs.error?.contains("Audi 日志") == true)
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    func testShortcutPersistenceAndConflictingReenable() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = ShortcutPreferences(defaults: defaults)
        prefs.setEnabled(false, for: "logs")
        let logBinding = ShortcutPreferences.defaultsBindings["logs"]!
        XCTAssertTrue(prefs.set(logBinding, for: "reqflow"))
        let restored = ShortcutPreferences(defaults: defaults)
        XCTAssertNil(restored.binding(for: "logs"))
        XCTAssertEqual(restored.binding(for: "reqflow"), logBinding)
        restored.setEnabled(true, for: "logs")
        XCTAssertNil(restored.binding(for: "logs"))
        XCTAssertNotNil(restored.error)
        restored.restoreDefaults()
        XCTAssertEqual(restored.binding(for: "reqflow"), ShortcutPreferences.defaultsBindings["reqflow"])
        XCTAssertEqual(restored.binding(for: "logs"), logBinding)
    }

    func testShortcutRejectsUnmodifiedAndReservedKeys() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = ShortcutPreferences(defaults: defaults)
        XCTAssertFalse(prefs.set(GlobalShortcut(keyCode: 9, modifiers: 0, keyLabel: "V"), for: "clipboard"))
        XCTAssertFalse(prefs.set(GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey), keyLabel: "K"), for: "clipboard"))
        XCTAssertTrue(prefs.overrides.isEmpty)
    }

    func testRecentModulesDeduplicateAndKeepSixWithIndependentPins() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = WorkspacePreferences(defaults: defaults)
        for id in ["a", "b", "c", "d", "e", "f", "g", "c"] { prefs.remember(id) }
        XCTAssertEqual(prefs.recentModules, ["c", "g", "f", "e", "d", "b"])
        prefs.togglePin("skills")
        prefs.togglePin("dboard")
        prefs.togglePin("skills")
        let restored = WorkspacePreferences(defaults: defaults)
        XCTAssertEqual(restored.recentModules, prefs.recentModules)
        XCTAssertEqual(restored.pinnedWindows, ["dboard"])
    }

    @MainActor
    func testEscapeClosesPaletteThenSelectionThenWindow() throws {
        _ = NSApplication.shared
        let vm = DBoardViewModel(loadCache: false)
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        var dismissals = 0
        vm.paletteOpen = true
        vm.selectedID = "D001"
        XCTAssertNil(DBoardRootView.handleKey(esc, vm: vm) { dismissals += 1 })
        XCTAssertFalse(vm.paletteOpen)
        XCTAssertEqual(vm.selectedID, "D001")
        XCTAssertNil(DBoardRootView.handleKey(esc, vm: vm) { dismissals += 1 })
        XCTAssertNil(vm.selectedID)
        XCTAssertEqual(dismissals, 0)
        XCTAssertNil(DBoardRootView.handleKey(esc, vm: vm) { dismissals += 1 })
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor
    func testEscapeLeavesActiveEditFormInControl() throws {
        let vm = DBoardViewModel(loadCache: false)
        vm.editingFormCount = 1
        vm.selectedID = "D001"
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        var dismissed = false
        XCTAssertNotNil(DBoardRootView.handleKey(esc, vm: vm) { dismissed = true })
        XCTAssertFalse(dismissed)
        XCTAssertEqual(vm.selectedID, "D001")
    }

    @MainActor
    func testPaletteAliasesAndStableUniqueModuleIDs() {
        let vm = DBoardViewModel(loadCache: false)
        vm.paletteQuery = "deploy"
        XCTAssertTrue(vm.paletteEntries.contains { $0.id == "module:apprelease" })
        vm.paletteQuery = "剪贴板"
        XCTAssertTrue(vm.paletteEntries.contains { $0.id == "module:clipboard" })
        vm.paletteQuery = ""
        let ids = vm.paletteEntries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    @MainActor
    func testFailedWriteRetainsStateAndDoesNotScheduleSync() {
        let vm = DBoardViewModel(loadCache: false)
        vm.newTodoText = "未保存的输入"
        XCTAssertFalse(vm.afterWrite(false, fail: "保存失败"))
        XCTAssertEqual(vm.newTodoText, "未保存的输入")
        XCTAssertEqual(vm.syncKind, .fail)
        XCTAssertEqual(vm.feedback?.message, "保存失败")
        XCTAssertEqual(vm.feedback?.failed, true)
    }

    func testCompletedAndSuspendedItemsAreNeverUrgent() {
        func item(_ status: ItemStatus) -> DItem {
            DItem(id: "D001", project: "测试", title: "", headerTitle: "测试",
                  status: status, priority: .p0, deadline: "1.1", branch: nil,
                  startDate: nil, milestones: [])
        }
        XCTAssertTrue(item(.pending).isUrgent)
        XCTAssertTrue(item(.inProgress).isUrgent)
        XCTAssertFalse(item(.completed).isUrgent)
        XCTAssertFalse(item(.suspended).isUrgent)
    }

    @MainActor
    func testHotKeyUnregisterReleasesCombination() throws {
        _ = NSApplication.shared
        let key = UInt32(kVK_F19)
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let first = HotKey()
        let second = HotKey()
        defer { first.unregister(); second.unregister() }
        first.register(keyCode: key, modifiers: mods) {}
        guard first.isRegistered else { throw XCTSkip("测试组合被其他应用占用") }
        first.unregister()
        second.register(keyCode: key, modifiers: mods) {}
        XCTAssertTrue(second.isRegistered)
        XCTAssertFalse(first.isRegistered)
    }

    @MainActor
    func testOldHotKeyRetryCannotRegisterPreviousBinding() throws {
        _ = NSApplication.shared
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let oldKey = UInt32(kVK_F18), newKey = UInt32(kVK_F20)
        let blockerA = HotKey(), blockerB = HotKey(), subject = HotKey(), probe = HotKey()
        defer { blockerA.unregister(); blockerB.unregister(); subject.unregister(); probe.unregister() }
        blockerA.register(keyCode: oldKey, modifiers: mods) {}
        blockerB.register(keyCode: newKey, modifiers: mods) {}
        guard blockerA.isRegistered && blockerB.isRegistered else { throw XCTSkip("测试组合被其他应用占用") }
        subject.register(keyCode: oldKey, modifiers: mods) {}
        XCTAssertFalse(subject.isRegistered)
        subject.register(keyCode: newKey, modifiers: mods) {}
        XCTAssertFalse(subject.isRegistered)
        blockerA.unregister()
        blockerB.unregister()
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        XCTAssertTrue(subject.isRegistered)
        probe.register(keyCode: oldKey, modifiers: mods) {}
        XCTAssertTrue(probe.isRegistered, "旧重试不能占住上一个组合")
        probe.unregister()
        probe.register(keyCode: newKey, modifiers: mods) {}
        XCTAssertFalse(probe.isRegistered, "当前组合仍由 subject 持有")
    }
}
