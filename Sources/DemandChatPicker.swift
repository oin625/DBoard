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

    static func decodeConversations(_ data: Data) throws -> DemandChatPage {
        guard BusinessResponse.succeeded(data),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rows = result["conversations"] as? [[String: Any]],
              let more = result["hasMore"] as? NSNumber, CFGetTypeID(more) == CFBooleanGetTypeID() else {
            throw DemandChatDirectoryError.unreadable
        }
        let groups = try rows.compactMap { row -> DemandChat? in
            guard let single = row["singleChat"] as? NSNumber, CFGetTypeID(single) == CFBooleanGetTypeID() else {
                throw DemandChatDirectoryError.unreadable
            }
            if single.boolValue { return nil }
            guard let id = row["openConversationId"] as? String, let name = row["title"] as? String else {
                throw DemandChatDirectoryError.unreadable
            }
            let chat = DemandChat(id: id, name: name)
            guard chat.isValid else { throw DemandChatDirectoryError.unreadable }
            return chat
        }
        let cursor = (result["nextCursor"] as? NSNumber).flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.stringValue
        } ?? (result["nextCursor"] as? String)
        if more.boolValue && (cursor == nil || cursor!.isEmpty) { throw DemandChatDirectoryError.unreadable }
        return DemandChatPage(groups: groups, nextCursor: more.boolValue ? cursor : nil)
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
    typealias Search = (String, String?) async throws -> DemandChatPage
    typealias Discover = (String) async throws -> DemandChatDiscovery
    @Published private(set) var groups: [DemandChat] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published private(set) var error: String?
    @Published private(set) var searchError: String?
    @Published private(set) var restrictedGroupIDs: Set<String> = []
    private let fetch: Fetch
    private let conversations: Fetch?
    private let searchFetch: Search?
    private let discoverFetch: Discover?
    private let knownURL: URL?
    private let cacheURL: URL?
    private var loadedAt: Date?
    private var searchRequest = UUID()

    init(knownURL: URL? = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".dws/reply-daemon/known-groups.json"), fetch: Fetch? = nil,
         conversations: Fetch? = nil, search: Search? = nil, discover: Discover? = nil, cacheURL: URL? = nil) {
        self.knownURL = knownURL
        self.cacheURL = cacheURL ?? (fetch == nil ? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/dboard-chat-directory.json") : nil)
        self.fetch = fetch ?? { cursor in
            var arguments = ["chat", "group", "list-all", "--limit", "200"]
            if let cursor { arguments += ["--cursor", cursor] }
            return try DemandChatPage.decode(await Self.run(arguments))
        }
        self.conversations = conversations ?? (fetch == nil ? { cursor in
            var arguments = ["chat", "list-all-conversations", "--limit", "100"]
            if let cursor { arguments += ["--cursor", cursor] }
            return try DemandChatPage.decodeConversations(await Self.run(arguments))
        } : nil)
        self.searchFetch = search ?? (fetch == nil ? { query, cursor in
            var arguments = ["chat", "search", "--query", query, "--limit", "100"]
            if let cursor { arguments += ["--cursor", cursor] }
            return try DemandChatPage.decode(await Self.run(arguments))
        } : nil)
        self.discoverFetch = discover ?? (fetch == nil ? DemandChatDiscoveryService.discover : nil)
        if let cache = self.cacheURL, let bytes = try? Data(contentsOf: cache) {
            if let stored = try? JSONDecoder().decode(DemandChatDirectoryCache.self, from: bytes) {
                restrictedGroupIDs = stored.restrictedIDs
                merge(stored.groups.filter(\.isValid), persist: false)
            } else if let stored = try? JSONDecoder().decode([DemandChat].self, from: bytes) {
                merge(stored.filter(\.isValid), persist: false)
            }
        }
        if let knownURL, let data = try? Data(contentsOf: knownURL),
           let known = try? JSONDecoder().decode([String: String].self, from: data) {
            merge(known.map { DemandChat(id: $0.key, name: $0.value) }.filter(\.isValid), persist: false)
        }
    }

    private static func run(_ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let result = ProcessRunner.run(NSHomeDirectory() + "/.qoderwork/bin/dws",
                arguments: arguments + ["--format", "json", "--timeout", "20"],
                environment: ProcessInfo.processInfo.environment, timeout: 25)
            guard result.succeeded else { throw DemandChatDirectoryError.unavailable }
            return result.stdout
        }.value
    }

    private func merge(_ values: [DemandChat], persist: Bool = true) {
        var indexed: [String: DemandChat] = [:]
        for group in groups + values where group.isValid { indexed[group.id] = group }
        groups = indexed.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if persist, let cacheURL, let bytes = try? JSONEncoder().encode(
            DemandChatDirectoryCache(groups: groups, restrictedIDs: restrictedGroupIDs)) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? bytes.write(to: cacheURL, options: .atomic)
        }
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 300 { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        if let knownURL, let bytes = try? Data(contentsOf: knownURL),
           let known = try? JSONDecoder().decode([String: String].self, from: bytes) {
            merge(known.map { DemandChat(id: $0.key, name: $0.value) })
        }
        for source in [fetch, conversations].compactMap({ $0 }) {
            var cursor: String?
            var visited = Set<String>()
            do {
                repeat {
                    try Task.checkCancellation()
                    let page = try await source(cursor)
                    try Task.checkCancellation()
                    merge(page.groups)
                    cursor = page.nextCursor
                    if let cursor, !visited.insert(cursor).inserted { throw DemandChatDirectoryError.repeatedCursor }
                } while cursor != nil
            } catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
        if error == nil { loadedAt = Date() }
    }

    func search(_ query: String) async {
        let token = UUID()
        searchRequest = token
        searchError = nil
        let query = query.trimmed
        guard !query.isEmpty, let searchFetch else { isSearching = false; return }
        isSearching = true
        defer { if searchRequest == token { isSearching = false } }
        var cursor: String?
        var visited = Set<String>()
        do {
            repeat {
                try Task.checkCancellation()
                let page = try await searchFetch(query, cursor)
                try Task.checkCancellation()
                guard searchRequest == token else { return }
                merge(page.groups)
                cursor = page.nextCursor
                if let cursor, !visited.insert(cursor).inserted { throw DemandChatDirectoryError.repeatedCursor }
            } while cursor != nil
        } catch is CancellationError { return }
        catch { if searchRequest == token { searchError = "钉钉搜索暂时失败，当前仍可搜索已加载的群聊；请重试。" } }
        guard searchRequest == token, !Task.isCancelled, let discoverFetch,
              DemandChatSearch.normalize(query).count >= 2 else { return }
        do {
            let discovered = try await discoverFetch(query)
            try Task.checkCancellation()
            guard searchRequest == token else { return }
            let verifiedIDs = Set(discovered.groups.map(\.id))
            restrictedGroupIDs.subtract(verifiedIDs)
            restrictedGroupIDs.formUnion(discovered.restrictedIDs.intersection(verifiedIDs))
            merge(discovered.groups)
            if !discovered.groups.isEmpty { searchError = nil }
        } catch is CancellationError {}
        catch {
            if searchRequest == token {
                searchError = "钉钉扩展搜索暂时失败，当前仍可选择已加载的群聊；请重试。"
            }
        }
    }
}

enum DemandChatSearch {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).contains($0) }
            .map(String.init).joined()
    }
    static func matches(_ chat: DemandChat, query: String) -> Bool {
        let terms = query.trimmed.split(whereSeparator: \.isWhitespace)
        let name = normalize(chat.name)
        return terms.allSatisfy { term in
            let normalized = normalize(String(term))
            return !normalized.isEmpty && (name.contains(normalized) || chat.id.localizedStandardContains(String(term)))
        }
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
                Text(title).dboardFont(size: 12).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text(name).dboardFont(size: 13).foregroundStyle(associated ? .primary : .secondary)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").dboardFont(size: 11).foregroundStyle(.tertiary)
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .demandButtonStyle(.plain)
        .accessibilityIdentifier(role == .primary ? "demand-chat-primary-picker" : "demand-chat-secondary-picker").demandKeyboardID(role == .primary ? "demand-chat-primary-picker" : "demand-chat-secondary-picker")
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

    private var shown: [DemandChat] { candidates.filter { DemandChatSearch.matches($0, query: query) } }

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
                    .dboardFont(size: 16, weight: .semibold)
                Spacer()
                Button { Task {
                    await directory.load(force: true)
                    if !query.trimmed.isEmpty { await directory.search(query) }
                } } label: {
                    Label("刷新群列表", systemImage: "arrow.clockwise")
                }.controlSize(.small).disabled(directory.isLoading || directory.isSearching)
            }
            Text("选一个主要群聊，再按需添加次要群聊；都可以留空。")
                .dboardFont(size: 12).foregroundStyle(.secondary)
            selectedGroups
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索群名称或群 ID", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityIdentifier("demand-chat-search").demandKeyboardID("demand-chat-search")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .demandButtonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清空群聊搜索")
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
                                    .dboardFont(size: 24).foregroundStyle(.tertiary)
                                Text(directory.isSearching ? "正在搜索钉钉群聊…" : directory.isLoading && query.isEmpty ? "正在加载群聊…" : query.isEmpty ? "暂无可选群聊" : "钉钉未返回匹配的群聊")
                                    .dboardFont(size: 13).foregroundStyle(.secondary)
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
                if directory.isLoading || directory.isSearching { ProgressView().controlSize(.small) }
                Text(directory.isSearching ? "正在钉钉搜索群聊…"
                     : directory.isLoading ? "正在更新，已加载 \(directory.groups.count) 个群；现在就可以选择"
                     : "可选 \(candidates.count) 个群 · 已选 \(selection.all.count) 个")
                    .dboardFont(size: 11).foregroundStyle(.secondary)
                Spacer()
            }
            if let error = directory.searchError ?? directory.error {
                HStack(spacing: 8) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .dboardFont(size: 11).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { Task {
                        if query.trimmed.isEmpty { await directory.load(force: true) }
                        else { await directory.search(query) }
                    } }.controlSize(.small)
                }
            }
            if let feedbackError {
                Label(feedbackError, systemImage: "exclamationmark.circle")
                    .dboardFont(size: 12).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Text("↑↓ 浏览 · 回车选择 · ⌘↩ 保存").dboardFont(size: 11).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: cancel).keyboardShortcut(.cancelAction)
                Button("完成关联") { confirm(result) }
                    .demandButtonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("demand-chat-confirm").demandKeyboardID("demand-chat-confirm")
            }
        }
        .padding(20).frame(minWidth: 480, idealWidth: 560, maxWidth: 640, minHeight: 520, idealHeight: 620)
        .background { DemandCanvasBackground() }
        .background(WindowNumberReader { windowNumber = $0 })
        .onChange(of: query) { _, _ in highlightedID = shown.first?.id }
        .task(id: query.trimmed) {
            if !query.trimmed.isEmpty {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
            await directory.search(query)
        }
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
                Text("主要群").dboardFont(size: 12).foregroundStyle(.secondary).frame(width: 46, alignment: .leading)
                if let chat = selection.primary {
                    selectedChip(chat) { selection.setPrimary(nil) }
                } else { Text("未选择").dboardFont(size: 12).foregroundStyle(.tertiary) }
                Spacer(minLength: 0)
            }
            if !selection.secondary.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text("次要群").dboardFont(size: 12).foregroundStyle(.secondary).frame(width: 46, alignment: .leading).padding(.top, 5)
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
            Text(chat.name).dboardFont(size: 12).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").dboardFont(size: 10, weight: .semibold).padding(4)
            }.demandButtonStyle(.plain).accessibilityLabel("移除群聊：" + chat.name)
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
                    Text(chat.name).dboardFont(size: 13).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if duplicateName {
                        Text("群 ID …" + chat.id.suffix(10)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if directory.restrictedGroupIDs.contains(chat.id) {
                        Text("跨组织内部群 · 读取聊天记录需钉钉授权")
                            .dboardFont(size: 11).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if primary || secondary {
                    Text(primary ? "主要群" : "次要群").dboardFont(size: 11).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(highlightedID == chat.id ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .demandButtonStyle(.plain).disabled(disabled)
        .accessibilityIdentifier("demand-chat-row-" + chat.id).demandKeyboardID("demand-chat-row-" + chat.id)
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
