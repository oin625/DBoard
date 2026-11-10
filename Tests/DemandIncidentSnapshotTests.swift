import XCTest
import SwiftUI
import AppKit
@testable import DBoard

final class DemandIncidentSnapshotTests: XCTestCase {
    @MainActor
    func testRenderIncidentCreationQuadrantAndKnowledge() throws {
        guard let directory = ProcessInfo.processInfo.environment["DBOARD_UI_SNAPSHOTS"] else { throw XCTSkip("Enable incident UI snapshots") }
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let vm = DBoardViewModel(loadCache: false)
        var draft = DItemDraft(newID: "P001", priority: .p0)
        draft.kind = .incident; draft.status = .inProgress; draft.name = "车点点照片查询为空"
        draft.desc = "锁券返回成功，照片查询没有返回数据。请核对上游响应和券的照片配置。"
        let form = DemandItemEditor(draft: draft, close: {}).environmentObject(vm).environmentObject(ThemeManager.shared)
        var item = DItem(id: draft.id, project: "ultra", title: draft.desc, headerTitle: draft.name, status: .inProgress,
                         priority: .p0, deadline: nil, branch: nil, startDate: nil, milestones: [])
        item.kind = .incident
        vm.items = [item]
        let card = ItemCardView(item: item, isolatedExpansion: true).environmentObject(vm)
            .environmentObject(ThemeManager.shared).environmentObject(FontManager.shared)
        let cache = URL(fileURLWithPath: directory).appendingPathComponent("snapshot-cache.md")
        let entry = DemandKnowledge.Entry(id: "K001", title: "核对照片查询中的空数据", mechanism: "上游数据与配置",
            symptoms: ["照片为空", "锁券成功但没有照片"], scopes: ["车点点照片查询"],
            procedure: "先核对上游原始响应，再检查券的照片配置；原始响应已有照片时转查解析与映射。",
            finding: "", confidence: "method", boundaries: "当前是核对路径，券是否应有照片仍须上游确认。",
            evidence: ["原排查日志与请求响应"], related_ids: [], sources: [.init(id: item.id, record_count: 1, scope_hash: String(repeating: "a", count: 64))],
            active: true, updated_by: "ai", updated_at: "2026-11-05T10:00:00Z")
        var lines = ["## 🔴 重要且紧急", draft.headerLine, "- **类型**：线上排查"]
        try DemandKnowledge(version: 1, next_id: 2, entries: [entry]).write(&lines)
        try lines.joined(separator: "\n").write(to: cache, atomically: true, encoding: .utf8)
        let library = DemandKnowledgeView(close: {}, cacheURL: cache).environmentObject(vm)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(form, name: "incident-create-" + name, appearance: appearance, directory: directory)
            try render(card, name: "incident-card-" + name, appearance: appearance, directory: directory)
            try render(library, name: "incident-knowledge-" + name, appearance: appearance, directory: directory)
        }
    }

    @MainActor
    private func render<V: View>(_ view: V, name: String, appearance: NSAppearance.Name, directory: String) throws {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        defer { NSApp.appearance = previous }
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, appearance == .darkAqua ? .dark : .light))
        hosting.frame = NSRect(x: 0, y: 0, width: 680, height: 740)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting; window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        XCTAssertGreaterThan(data.count, 1000)
    }
}
