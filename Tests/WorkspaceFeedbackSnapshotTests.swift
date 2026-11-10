import XCTest
import SwiftUI
import AppKit
@testable import DBoard

/// Render only the feedback and footer with fixture state; no demand writes or remote operations.
final class WorkspaceFeedbackSnapshotTests: XCTestCase {
    @MainActor
    func testRenderOperationErrorAndSyncFailureSeparately() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_UI_SNAPSHOTS"] else {
            throw XCTSkip("设置 DBOARD_UI_SNAPSHOTS 导出底栏错误提示检查图")
        }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let vm = DBoardViewModel(loadCache: false)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            vm.syncKind = .idle
            vm.syncText = "最近同步 09:50"
            vm.flash("R2610290014 的正式需求尚未验收完成，请在需求流完成验收后再归档。")
            try render(vm, name: "operation-error-" + name, appearance: appearance, directory: directory)
            vm.feedback = nil
            vm.syncKind = .fail
            vm.syncText = "同步失败，改动保留在本机"
            try render(vm, name: "sync-failure-" + name, appearance: appearance, directory: directory)
        }
    }

    @MainActor
    private func render(_ vm: DBoardViewModel, name: String, appearance: NSAppearance.Name, directory: String) throws {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }
        let view = VStack(spacing: 8) {
            Spacer(minLength: 0)
            if let feedback = vm.feedback {
                WorkspaceFeedbackView(feedback: feedback) { vm.feedback = nil }.padding(.horizontal, 16)
            }
            FooterView()
        }
        .environmentObject(vm).environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 200)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting; window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
    }
}
