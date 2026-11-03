import Foundation
import SwiftUI

struct DemandChange: Codable, Equatable, Identifiable {
    let id: String
    let createdAt: Date
    let intent: String
}

/// Human-readable change spells are stored alongside a validated lossless payload.
enum DemandChanges {
    static let field = "- **变更咒言**"
    private static let prefix = "<!-- dboard-changes:v1:"
    private static let suffix = " -->"

    enum ReadError: LocalizedError {
        case invalid
        var errorDescription: String? { "变更咒言记录无法读取，请检查数据后重试" }
    }

    static func decode(_ stored: String) throws -> [DemandChange] {
        guard !stored.isEmpty else { return [] }
        let lines = stored.components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix(prefix), first.hasSuffix(suffix),
              let data = Data(base64Encoded: String(first.dropFirst(prefix.count).dropLast(suffix.count))) else { throw ReadError.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let changes = try decoder.decode([DemandChange].self, from: data)
        guard Set(changes.map(\.id)).count == changes.count,
              changes.allSatisfy({ $0.id.range(of: #"^C[0-9]{3,}$"#, options: .regularExpression) != nil &&
                  (Int($0.id.dropFirst()) ?? 0) > 0 && !$0.intent.trimmed.isEmpty }),
              lines.dropFirst().joined(separator: "\n") == body(changes) else { throw ReadError.invalid }
        return changes
    }

    static func stored(_ changes: [DemandChange]) throws -> String {
        guard !changes.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return prefix + (try encoder.encode(changes)).base64EncodedString() + suffix + "\n" + body(changes)
    }

    private static func body(_ changes: [DemandChange]) -> String {
        let formatter = ISO8601DateFormatter()
        return changes.map { "### " + $0.id + " · " + formatter.string(from: $0.createdAt) + "\n" + $0.intent }
            .joined(separator: "\n")
    }

    static func read(_ block: [String]) throws -> [DemandChange] {
        let matches = block.indices.filter { block[$0].hasPrefix(field) }
        guard matches.count <= 1 else { throw ReadError.invalid }
        guard let index = matches.first else { return [] }
        var lines: [String] = []
        var end = index + 1
        while end < block.count && block[end].hasPrefix("    ") {
            lines.append(String(block[end].dropFirst(4)))
            end += 1
        }
        guard !lines.joined(separator: "\n").isEmpty else { throw ReadError.invalid }
        return try decode(lines.joined(separator: "\n"))
    }

    static func set(_ block: inout [String], changes: [DemandChange]) throws {
        let replacement = [field + "："] + (try stored(changes)).components(separatedBy: "\n").map { "    " + $0 }
        if let index = block.firstIndex(where: { $0.hasPrefix(field) }) {
            var end = index + 1
            while end < block.count && block[end].hasPrefix("    ") { end += 1 }
            block.replaceSubrange(index..<end, with: replacement)
        } else {
            block.insert(contentsOf: replacement, at: 1)
        }
    }
}

struct DemandChangesEditor: View {
    @EnvironmentObject var vm: DBoardViewModel
    let item: DItem
    let cancel: () -> Void
    let imageStore: DemandImageStore
    var refreshOnAppear = true
    @State private var latest: DItem?
    @StateObject private var session: DemandChangeDraftSession
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var confirmingDiscard = false

    init(item: DItem, draftStore: DemandChangeDraftStore, cancel: @escaping () -> Void,
         refreshOnAppear: Bool = true, imageStore: DemandImageStore = .shared) {
        self.item = item
        self.cancel = cancel
        self.imageStore = imageStore
        self.refreshOnAppear = refreshOnAppear
        _session = StateObject(wrappedValue: DemandChangeDraftSession(id: item.id, changes: item.changes, store: draftStore))
    }

    private var intentBinding: Binding<String> {
        let generation = session.generation
        return Binding(get: { session.intent },
                       set: { session.updateIntent($0, generation: generation) })
    }

    private func requestClose() {
        if !session.preserve() {
            vm.showFeedback("变更草稿未写入磁盘，输入仍保留在当前 D板；请先复制备份。", failed: true)
        }
        cancel()
    }

    private func reload() {
        do {
            let current = try DItemStore.currentItem(id: item.id)
            latest = current
            session.reconcile(with: current.changes)
            loadError = nil
        } catch { loadError = error.localizedDescription }
    }

    private func save(copy: Bool) {
        session.preserve()
        guard let change = vm.appendChange(item.id, intent: session.intent) else {
            saveError = "添加变更失败，草稿输入已保留；请重试。"
            return
        }
        saveError = nil
        if !session.markAdded(change) {
            vm.showFeedback("变更已添加，草稿清理失败；下次打开会核对已添加内容。", failed: true)
        }
        reload()
        if copy { vm.copyChangeState(item.id, changeID: change.id) }
        cancel()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("追加变更咒言", systemImage: "wand.and.stars")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("关闭", action: requestClose).keyboardShortcut(.cancelAction)
            }
            Text((latest ?? item).displayTitle).font(.system(size: 13))
            Text("写这次在已有实现上要改什么。代码入口和资料沿用原咒言，有变化直接补充在这里。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("这次要改什么").font(.system(size: 13, weight: .medium))
                    DemandSpellField(text: intentBinding, title: "这次要改什么",
                                     placeholder: "例如：接口已经实现，但返回结果还要增加照片字段；未完成的联调和验收继续保留。", autofocus: true, imageStore: imageStore)
                        .id(session.generation)
                    if let latest, !latest.changes.isEmpty {
                        DisclosureGroup("已有变更（" + String(latest.changes.count) + " 条）") {
                            VStack(spacing: 8) {
                                ForEach(latest.changes.reversed()) { change in
                                    DemandChangeHistoryRow(change: change) { vm.copyChangeState(item.id, changeID: change.id) }
                                }
                            }.padding(.top, 8)
                        }
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = loadError {
                HStack {
                    Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    Spacer()
                    Button("重试", action: reload)
                }
            }
            if let error = saveError ?? session.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(session.restored
                 ? "已恢复变更草稿。关闭会保留，点击「添加变更」后生效。"
                 : "草稿自动保存在本机。关闭会保留，点击「添加变更」后生效。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if !session.intent.isEmpty {
                    Button("放弃草稿") { confirmingDiscard = true }.foregroundStyle(.secondary)
                }
                Text("复制短指令，让 AI 读取现状和本次变更。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("添加变更") { save(copy: false) }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(session.intent.trimmed.isEmpty || latest == nil || loadError != nil)
                Button("添加并复制") { save(copy: true) }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.intent.trimmed.isEmpty || latest == nil || loadError != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 640, maxWidth: 760, minHeight: 400, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("放弃变更草稿？", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃草稿", role: .destructive) {
                if session.discard() { cancel() }
                else { saveError = "放弃草稿失败，输入已保留；请先复制备份。" }
            }
        } message: { Text("这次未添加的变更将被清除，已有变更记录保留。") }
        .onExitCommand(perform: requestClose)
        .onAppear {
            vm.editingFormCount += 1
            if refreshOnAppear { reload() } else { latest = item }
        }
        .onDisappear {
            session.preserve()
            vm.editingFormCount = max(0, vm.editingFormCount - 1)
        }
    }
}

private struct DemandChangeHistoryRow: View {
    let change: DemandChange
    let copy: () -> Void

    var body: some View {
        DisclosureGroup {
            DemandSpellContentView(text: change.intent).padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(change.id).font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(change.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制这次变更", action: copy).font(.system(size: 11)).buttonStyle(.borderless)
                }
                Text(change.intent.split(separator: "\n").first.map(String.init) ?? "查看变更内容")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}
