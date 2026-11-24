import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class SettingsAppearanceTests: XCTestCase {
    @MainActor
    func testSettingsPagesShareWindowSkinAndSwitchWithoutRecreatingWindow() throws {
        _ = NSApplication.shared
        let name = "DBoardSettingsSkin-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let theme = ThemeManager(defaults: defaults)
        let preferences = WorkspacePreferences(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 840, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView: DBoardSettingsView(theme: theme, preferences: preferences))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 840, height: 650))
        window.orderBack(nil)
        defer { window.close() }
        let output = ProcessInfo.processInfo.environment["DBOARD_SETTINGS_SNAPSHOTS"]
        if let output { try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true) }
        var lastImage: Data?
        for (palette, appearance) in [(DBoardTheme.glass, NSAppearance.Name.aqua), (.sand, .darkAqua)] {
            theme.current = palette
            window.appearance = NSAppearance(named: appearance)
            for page in SettingsPage.allCases {
                preferences.settingsPage = page
                RunLoop.main.run(until: Date().addingTimeInterval(0.2))
                XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
                XCTAssertTrue(window.titlebarAppearsTransparent)
                XCTAssertEqual(window.titlebarSeparatorStyle, .none)
                XCTAssertEqual(window.isOpaque, !palette.nativeBlur)
                XCTAssertTrue(window.contentViewController === hosting)
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(view.bounds.width, 800)
                XCTAssertGreaterThanOrEqual(view.bounds.height, 620)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                if page == .appearance {
                    if let lastImage { XCTAssertNotEqual(image, lastImage) }
                    lastImage = image
                }
                if let output {
                    try image.write(to: URL(fileURLWithPath: output + "/" + palette.id + "-" + page.rawValue + ".png"))
                }
            }
        }
    }
}
