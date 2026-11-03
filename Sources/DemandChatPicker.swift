import SwiftUI
import Foundation
import CoreFoundation
import AppKit

struct DemandChatPage {
    let groups: [DemandChat]
    let nextCursor: String?

    static func decode(_ data: Data) throws -> DemandChatPage {
        guard BusinessResponse.succeeded(data),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rows = result["groups"] as? [[String: Any]],
              let more = result["hasMore"] as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID() else {
            throw DemandChatDirectoryError.unreadable
        }
        let groups = try rows.map { row -> DemandChat in
            guard let id = row["openConversationId"] as? String, let name = row["title"] as? String else {
                throw DemandChatDirectoryError.unreadable
            }
            let chat = DemandChat(id: id, name: name)
            guard chat.isValid else { throw DemandChatDirectoryError.unreadable }
            return chat
        }
        var cursor: String?
        if more.boolValue {
            cursor = result["nextCursor"] as? String
            if cursor == nil, let number = result["nextCursor"] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID() { cursor = number.stringValue }
            guard let value = cursor, !value.isEmpty else { throw DemandChatDirectoryError.unreadable }
        }
        return DemandChatPage(groups: groups, nextCursor: cursor)
    }
}

enum DemandChatDirectoryError: LocalizedError {
    case unavailable, unreadable, repeatedCursor
    var errorDescription: String? {
        switch self {
        case .unavailable: return "暂时无法读取钉钉群列表，已保留已知群聊；请稍后重试。"
        case .unreadable: return "钉钉群列表返回异常，已保留已知群聊；请重试。"
        case .repeatedCursor: return "钉钉群列表分页异常，已保留已加载的群聊；请重试。"
        }
    }
}

@MainActor
final class DemandChatDirectory: ObservableObject {
    static let shared = DemandChatDirectory()
    typealias Fetch = (String?) async throws -> DemandChatPage
    @Published private(set) var groups: [DemandChat]
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?
    private let fetch: Fetch
    private var loadedAt: Date?

    init(knownURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dws/reply-daemon/known-groups.json"), fetch: Fetch? = nil) {
        if let knownURL, let data = try? Data(contentsOf: knownURL),
           let known = try? JSONDecoder().decode([String: String].self, from: data) {
            groups = known.map { DemandChat(id: $0.key, name: $0.value) }.filter(\.isValid)
        } else { groups = [] }
        self.fetch = fetch ?? { cursor in
            try await Task.detached(priority: .utility) {
                var arguments = ["chat", "group", "list-all", "--limit", "200", "--format", "json", "--timeout", "20"]
                if let cursor { arguments += ["--cursor", cursor] }
                // Passing nil to Process.environment loses the login environment on macOS.
                let result = ProcessRunner.run(NSHomeDirectory() + "/.qoderwork/bin/dws", arguments: arguments,
                    environment: ProcessInfo.processInfo.environment, timeout: 25)
                guard result.succeeded else { throw DemandChatDirectoryError.unavailable }
                return try DemandChatPage.decode(result.stdout)
            }.value
        }
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        var cursor: String?
        var visited = Set<String>()
        do {
            repeat {
                try Task.checkCancellation()
                let page = try await fetch(cursor)
                try Task.checkCancellation()
                var indexed = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
                for chat in page.groups { indexed[chat.id] = chat }
                groups = indexed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                cursor = page.nextCursor
                if let cursor, !visited.insert(cursor).inserted { throw DemandChatDirectoryError.repeatedCursor }
            } while cursor != nil
            loadedAt = Date()
        } catch is CancellationError {
            // Closing the picker stops further pages; existing associations remain untouched.
        } catch { self.error = error.localizedDescription }
    }
}

enum DemandChatRole: String, CaseIterable, Identifiable {
    case primary, secondary
    var id: String { rawValue }
    var title: String { self == .primary ? "主要群聊" : "次要群聊" }
}

struct DemandChatLinksFields: View {
    @Binding var links: DemandChatLinks
    @State private var showingPicker = false
    @State private var initialRole: DemandChatRole = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            associationRow("主要群聊", name: links.primary?.name ?? "点击选择主要群聊",
                           associated: links.primary != nil, role: .primary)
            associationRow("次要群聊", name: links.secondary.isEmpty ? "点击添加次要群聊" : links.secondary.map(\.name).joined(separator: "、"),
                           associated: !links.secondary.isEmpty, role: .secondary)
        }
        .sheet(isPresented: $showingPicker) {
            DemandChatPicker(links: links, initialRole: initialRole, confirm: {
                links = $0
                showingPicker = false
            }, cancel: { showingPicker = false })
        }
    }

    private func associationRow(_ title: String, name: String, associated: Bool, role: DemandChatRole) -> some View {
        Button {
            initialRole = role
            showingPicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: role == .primary ? "bubble.left" : "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary).frame(width: 20)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(name).font(.system(size: 13)).foregroundStyle(associated ? .primary : .secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(role == .primary ? "demand-chat-primary-picker" : "demand-chat-secondary-picker")
        .help("选择、更换或移除关联群聊")
    }
}

/// One transaction manages both roles. Search and list updates never discard selected groups.
@MainActor
struct DemandChatPicker: View {
    let links: DemandChatLinks
    let confirm: (DemandChatLinks) -> Void
    let cancel: () -> Void
    let feedbackError: String?
    @StateObject private var directory: DemandChatDirectory
    @State private var query = ""
    @State private var selection: DemandChatLinks
    @State private var role: DemandChatRole
    @State private var highlightedID: String?
    @State private var windowNumber: Int?
    @State private var keyMonitor: Any?
    @FocusState private var searchFocused: Bool

    init(links: DemandChatLinks, initialRole: DemandChatRole = .primary, directory: DemandChatDirectory? = nil,
         feedbackError: String? = nil, confirm: @escaping (DemandChatLinks) -> Void, cancel: @escaping () -> Void) {
        self.links = links
        self.confirm = confirm
        self.cancel = cancel
        self.feedbackError = feedbackError
        _directory = StateObject(wrappedValue: directory ?? DemandChatDirectory.shared)
        _selection = State(initialValue: links)
        _role = State(initialValue: initialRole)
    }

    private var candidates: [DemandChat] {
        var indexed = Dictionary(uniqueKeysWithValues: links.all.map { ($0.id, $0) })
        for chat in directory.groups { indexed[chat.id] = chat }
        // Preserve row positions while selecting; the summary above shows live selections.
        return indexed.values.sorted { lhs, rhs in
            let order = links.all.map(\.id)
            let first = order.firstIndex(of: lhs.id) ?? Int.max
            let second = order.firstIndex(of: rhs.id) ?? Int.max
            if first != second { return first < second }
            if lhs.name == rhs.name { return lhs.id < rhs.id }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var shown: [DemandChat] {
        let terms = query.trimmed.split(whereSeparator: \.isWhitespace)
        return candidates.filter { chat in
            terms.allSatisfy { chat.name.localizedStandardContains(String($0)) || chat.id.localizedStandardContains(String($0)) }
        }
    }

    private var result: DemandChatLinks {
        let indexed = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return DemandChatLinks(primary: selection.primary.map { indexed[$0.id] ?? $0 },
            secondary: selection.secondary.map { indexed[$0.id] ?? $0 })
    }

    private func choose(_ chat: DemandChat) {
        highlightedID = chat.id
        if role == .primary { selection.setPrimary(chat) }
        else if selection.primary?.id == chat.id { return }
        else if selection.secondary.contains(where: { $0.id == chat.id }) {
            selection.secondary.removeAll { $0.id == chat.id }
        } else { selection.setSecondary(selection.secondary + [chat]) }
    }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let index = highlightedID.flatMap { id in shown.firstIndex { $0.id == id } }
        let next = min(max((index ?? (delta > 0 ? -1 : shown.count)) + delta, 0), shown.count - 1)
        highlightedID = shown[next].id
    }

    var body: some View {
        let duplicateNames = Set(Dictionary(grouping: candidates, by: \.name).filter { $0.value.count > 1 }.keys)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("关联群聊", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { Task { await directory.load(force: true) } } label: {
                    Label("刷新群列表", systemImage: "arrow.clockwise")
                }.controlSize(.small).disabled(directory.isLoading)
            }
            Text("选一个主要群聊，再按需添加次要群聊；都可以留空。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            selectedGroups
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索群名称或群 ID", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("demand-chat-search")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清空群聊搜索")
                }
            }
            .padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            Picker("点击群聊后的操作", selection: $role) {
                Text("设为主要群").tag(DemandChatRole.primary)
                Text("添加次要群").tag(DemandChatRole.secondary)
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("demand-chat-role")
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(shown) { chat in
                            groupRow(chat, duplicateName: duplicateNames.contains(chat.name)).id(chat.id)
                        }
                        if shown.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: query.isEmpty ? "bubble.left" : "magnifyingglass")
                                    .font(.system(size: 24)).foregroundStyle(.tertiary)
                                Text(directory.isLoading && query.isEmpty ? "正在加载群聊…" : query.isEmpty ? "暂无可选群聊" : "没有匹配的群聊")
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                if !query.isEmpty { Button("清空搜索") { query = "" }.controlSize(.small) }
                            }.frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }.padding(4)
                }
                .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                if directory.isLoading { ProgressView().controlSize(.small) }
                Text(directory.isLoading ? "正在更新，已加载 \(directory.groups.count) 个群；现在就可以选择"
                     : "可选 \(candidates.count) 个群 · 已选 \(selection.all.count) 个")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            if let error = directory.error {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task { await directory.load(force: true) } }.controlSize(.small)
                }
            }
            if let feedbackError {
                Label(feedbackError, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("↑↓ 浏览 · 回车选择 · ⌘↩ 保存").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("完成关联") { confirm(result) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("demand-chat-confirm")
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 560, maxWidth: 640, minHeight: 520, idealHeight: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(WindowNumberReader { windowNumber = $0 })
        .onChange(of: query) { _, _ in highlightedID = shown.first?.id }
        .onAppear {
            searchFocused = true
            installKeyboard()
            // The shared directory finishes loading even if this picker is closed.
            Task { await directory.load() }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        }
    }

    private var selectedGroups: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("主要群").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                if let chat = selection.primary {
                    selectedChip(chat) { selection.setPrimary(nil) }
                } else { Text("未选择").font(.system(size: 12)).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
            }
            if !selection.secondary.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("次要群").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 46, alignment: .leading).padding(.top, 5)
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(selection.secondary) { chat in
                                selectedChip(chat) { selection.secondary.removeAll { $0.id == chat.id } }
                            }
                        }
                    }.scrollIndicators(.hidden)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private func selectedChip(_ chat: DemandChat, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(chat.name).font(.system(size: 12)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).padding(4)
            }.buttonStyle(.plain).accessibilityLabel("移除群聊：" + chat.name)
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func groupRow(_ chat: DemandChat, duplicateName: Bool) -> some View {
        let primary = selection.primary?.id == chat.id
        let secondary = selection.secondary.contains { $0.id == chat.id }
        let disabled = role == .secondary && primary
        return Button { choose(chat) } label: {
            HStack(spacing: 10) {
                Image(systemName: primary || secondary ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(primary || secondary ? Color.accentColor : Color.secondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 3) {
                    Text(chat.name).font(.system(size: 13)).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if duplicateName {
                        Text("群 ID …" + chat.id.suffix(10)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if primary || secondary {
                    Text(primary ? "主要群" : "次要群").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(highlightedID == chat.id ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(disabled)
        .accessibilityIdentifier("demand-chat-row-" + chat.id)
        .accessibilityLabel(chat.name + (primary ? "，主要群" : secondary ? "，次要群" : ""))
    }

    private func installKeyboard() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window?.windowNumber == windowNumber, event.window?.attachedSheet == nil else { return event }
            if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command && event.keyCode == 36 { confirm(result); return nil }
            guard modifiers.isEmpty else { return event }
            switch event.keyCode {
            case 53: cancel(); return nil
            case 125: move(1); return nil
            case 126: move(-1); return nil
            case 36:
                if let chat = shown.first(where: { $0.id == highlightedID }) ?? shown.first { choose(chat) }
                return nil
            default: return event
            }
        }
    }
}
