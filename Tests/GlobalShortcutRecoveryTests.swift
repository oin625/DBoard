import XCTest
import AppKit
import Carbon.HIToolbox
@testable import DBoard

final class GlobalShortcutRecoveryTests: XCTestCase {
    @MainActor
    func testWakeAndUnlockRestoreConfiguredShortcutAndItsAction() throws {
        let name = "DBoardShortcutRecovery-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShortcutPreferences(defaults: defaults)
        let binding = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P),
                                     modifiers: UInt32(controlKey | optionKey), keyLabel: "P")
        XCTAssertTrue(preferences.set(binding, for: "quickopen"))
        preferences.setEnabled(false, for: "clipboard")
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        let session = NotificationCenter()
        var registrations: [StubHotKey] = []
        var invocations = 0
        let manager = GlobalShortcutManager(preferences: preferences,
            workspaceNotifications: workspace, applicationNotifications: application,
            sessionNotifications: session, makeHotKey: {
                let registration = StubHotKey()
                registrations.append(registration)
                return registration
            })
        manager.configure(actions: ["quickopen": { invocations += 1 }, "clipboard": { XCTFail("Disabled shortcut fired") }])
        settle()

        for (center, notification) in [
            (workspace, NSWorkspace.didWakeNotification),
            (session, Notification.Name("com.apple.screenIsUnlocked"))
        ] {
            let previous = try XCTUnwrap(registrations.last)
            previous.unregister()
            XCTAssertFalse(manager.isRegistered("quickopen"))
            center.post(name: notification, object: nil)
            settle()

            let restored = try XCTUnwrap(registrations.last)
            XCTAssertFalse(restored === previous)
            XCTAssertTrue(manager.isRegistered("quickopen"))
            XCTAssertFalse(manager.isRegistered("clipboard"))
            XCTAssertEqual(restored.keyCode, binding.keyCode)
            XCTAssertEqual(restored.modifiers, binding.modifiers)
            restored.fire()
        }
        XCTAssertEqual(invocations, 2)
        XCTAssertEqual(preferences.binding(for: "quickopen"), binding)
    }

    @MainActor
    func testSessionResumeCannotEnableShortcutsWhileRecording() throws {
        let name = "DBoardShortcutRecording-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = ShortcutPreferences(defaults: defaults)
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        let session = NotificationCenter()
        var registrations: [StubHotKey] = []
        let manager = GlobalShortcutManager(preferences: preferences,
            workspaceNotifications: workspace, applicationNotifications: application,
            sessionNotifications: session, makeHotKey: {
                let registration = StubHotKey()
                registrations.append(registration)
                return registration
            })
        manager.configure(actions: ["quickopen": {}])
        settle()
        manager.beginRecording()
        let countBeforeResume = registrations.count
        let replacement = GlobalShortcut(keyCode: UInt32(kVK_ANSI_P),
                                         modifiers: UInt32(cmdKey | optionKey), keyLabel: "P")
        XCTAssertTrue(preferences.set(replacement, for: "quickopen"))
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        application.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        settle()

        XCTAssertFalse(manager.isRegistered("quickopen"))
        XCTAssertEqual(registrations.count, countBeforeResume)
        manager.endRecording()
        XCTAssertTrue(manager.isRegistered("quickopen"))
        XCTAssertEqual(registrations.last?.modifiers, replacement.modifiers)
    }

    @MainActor private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    }

    private final class StubHotKey: GlobalShortcutRegistration {
        private(set) var isRegistered = false
        private(set) var keyCode: UInt32?
        private(set) var modifiers: UInt32?
        private var callback: (() -> Void)?
        func register(keyCode: UInt32, modifiers: UInt32, onStatus: ((OSStatus) -> Void)?,
                      callback: @escaping () -> Void) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.callback = callback
            isRegistered = true
            onStatus?(noErr)
        }
        func unregister() { isRegistered = false; callback = nil }
        func fire() { if isRegistered { callback?() } }
    }
}
