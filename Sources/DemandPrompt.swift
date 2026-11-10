import SwiftUI

/// Indented Markdown keeps arbitrary AI input separate from top-level cache fields.
/// Preserve every character, including blank lines and code indentation.
enum DemandPrompt {
    private static let tag = "- **提示词**"

    private static func range(_ block: [String]) -> Range<Int>? {
        guard let start = block.firstIndex(where: { $0.hasPrefix(tag) }) else { return nil }
        var end = start + 1
        while end < block.count && block[end].hasPrefix("    ") { end += 1 }
        return start..<end
    }

    static func read(_ block: [String]) -> String {
        guard let range = range(block) else { return "" }
        var inline = String(block[range.lowerBound].dropFirst(tag.count))
        if inline.first == "：" || inline.first == ":" { inline.removeFirst() }
        let lines = (inline.isEmpty ? [] : [inline]) + block[(range.lowerBound + 1)..<range.upperBound].map { String($0.dropFirst(4)) }
        return lines.joined(separator: "\n")
    }

    static func set(_ block: inout [String], value: String) {
        let replacement = value.trimmed.isEmpty ? [] : [tag + "："] + value.components(separatedBy: "\n").map { "    " + $0 }
        if let range = range(block) { block.replaceSubrange(range, with: replacement) }
        else { block.append(contentsOf: replacement) }
    }
}

/// The encoded metadata preserves field boundaries even when pasted code contains the same headings.
/// The assembled Markdown remains readable in the local cache and archive.
struct DemandPromptSections: Codable, Equatable {
    var codeEntry: String = ""
    var materials: String = ""
    // Keep the original intent as the main goal so old free-form content stays intact.
    var intent: String = ""
    var reason: String = ""
    var rules: String = ""

    // Keep legacy keys and their persisted body stable. Editing the merged field replaces both,
    // so old rules cannot reappear after the user clears or rewrites the supplemental text.
    var supplement: String {
        get { [reason, rules].filter { !$0.trimmed.isEmpty }.joined(separator: "\n") }
        set { reason = newValue; rules = "" }
    }

    private static let prefix = "<!-- dboard-prompt:v3:"
    private static let legacyPrefix = "<!-- dboard-prompt:v2:"
    private static let suffix = " -->"

    init(codeEntry: String = "", materials: String = "", intent: String = "",
         reason: String = "", rules: String = "") {
        self.codeEntry = codeEntry
        self.materials = materials
        self.intent = intent
        self.reason = reason
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey { case codeEntry, materials, intent, reason, rules }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codeEntry = try values.decode(String.self, forKey: .codeEntry)
        materials = try values.decode(String.self, forKey: .materials)
        intent = try values.decode(String.self, forKey: .intent)
        reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? ""
        rules = try values.decodeIfPresent(String.self, forKey: .rules) ?? ""
    }

    init(stored: String) {
        let lines = stored.components(separatedBy: "\n")
        if let first = lines.first,
           (first.hasPrefix(Self.prefix) || first.hasPrefix(Self.legacyPrefix)),
           first.hasSuffix(Self.suffix) {
            let prefix = first.hasPrefix(Self.legacyPrefix) ? Self.legacyPrefix : Self.prefix
            let encoded = String(first.dropFirst(prefix.count).dropLast(Self.suffix.count))
            if let data = Data(base64Encoded: encoded),
               let sections = try? JSONDecoder().decode(Self.self, from: data) {
                let body = lines.dropFirst().joined(separator: "\n")
                let expectedBody = prefix == Self.legacyPrefix ? sections.legacyStorageBody : sections.storageBody
                if body == expectedBody { self = sections }
                else { self.init(intent: body) } // Preserve external edits to the readable Markdown.
                return
            }
        }
        // Legacy prompts remain intact; opening alone never rewrites user data.
        self.init(intent: stored)
    }

    var isEmpty: Bool {
        [codeEntry, materials, intent, reason, rules].allSatisfy { $0.trimmed.isEmpty }
    }

    var validationError: String? {
        !isEmpty && intent.trimmed.isEmpty ? "请填写「要做什么」；补充说明可以留空。" : nil
    }

    // Compare old persisted bodies separately; copying and saving must not discard v2 fields.
    private var legacyStorageBody: String {
        [("代码入口", codeEntry), ("需求资料", materials), ("改造意图", intent)]
            .filter { !$0.1.trimmed.isEmpty }
            .map { "## " + $0.0 + "\n" + $0.1 }
            .joined(separator: "\n\n")
    }

    private var intentBody: String {
        [("要做什么", intent), ("为什么改", reason), ("特殊规则", rules)]
            .filter { !$0.1.trimmed.isEmpty }
            .map { "### " + $0.0 + "\n" + $0.1.trimmingCharacters(in: .newlines) }
            .joined(separator: "\n")
    }

    private var storageBody: String {
        // The encoded payload retains exact whitespace; the body remains readable and editable.
        [("代码入口", codeEntry), ("需求资料", materials), ("改造意图", intentBody)]
            .filter { !$0.1.trimmed.isEmpty }
            .map { "## " + $0.0 + "\n" + $0.1 }
            .joined(separator: "\n")
    }

    var assembled: String {
        var parts: [String] = []
        if !codeEntry.trimmed.isEmpty {
            let instruction = codeEntry.trimmed == "全新模块"
                ? "本次为全新模块，请按新的业务模块设计与实现。"
                : "请根据以下服务、流程描述或代码路径，查找并阅读相关实现："
            parts.append("## 代码入口\n" + instruction + "\n" + codeEntry.trimmingCharacters(in: .newlines))
        }
        if !materials.trimmed.isEmpty {
            parts.append("## 可能有用的资料\n请查找并阅读以下资料，结合本次任务按需参考：\n" + materials.trimmingCharacters(in: .newlines))
        }
        // Copy headings can change independently of the stable persisted body.
        parts.append(contentsOf: [("要做什么", intent), ("补充说明", supplement)]
            .filter { !$0.1.trimmed.isEmpty }
            .map { "## " + $0.0 + "\n" + $0.1.trimmingCharacters(in: .newlines) })
        return parts.joined(separator: "\n")
    }

    var stored: String {
        guard !isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return assembled }
        return Self.prefix + data.base64EncodedString() + Self.suffix + "\n" + storageBody
    }
}

struct DemandPromptFields: View {
    @Binding var sections: DemandPromptSections
    var compact = false
    var imageStore: DemandImageStore = .shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow(alignment: .top) {
                    label("代码入口")
                    contextInput(text: $sections.codeEntry, title: "代码入口",
                                 placeholder: "服务、流程的中文描述或工程路径")
                }
                GridRow(alignment: .top) {
                    label("可能有用的资料")
                    contextInput(text: $sections.materials, title: "可能有用的资料",
                                 placeholder: "资料名称、链接或路径（可选）")
                }
            }
            .font(.system(size: 13)).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("要做什么").font(.system(size: 13, weight: .semibold))
                    Text("必填").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                DemandSpellField(text: $sections.intent, title: "要做什么",
                                 placeholder: "把什么改成什么？改完后怎么用？", autofocus: !compact, imageStore: imageStore)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow(alignment: .top) {
                    optionalLabel("补充说明")
                    contextInput(text: $sections.supplement, title: "补充说明",
                                 placeholder: "文档没写清，或本次需要额外交代的内容")
                }
            }
        }
    }

    private func contextInput(text: Binding<String>, title: String, placeholder: String) -> some View {
        PromptContextInput(text: text, title: title)
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 8).padding(.vertical, 4).allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }

    private func optionalLabel(_ title: String) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 12))
            Text("选填").font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
        .frame(width: 80, alignment: .leading).padding(.top, 5)
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(width: 88, alignment: .leading).padding(.top, 5)
    }
}

struct DemandPromptEditor: View {
    @EnvironmentObject var vm: DBoardViewModel
    let item: DItem
    let cancel: () -> Void
    let imageStore: DemandImageStore
    @StateObject private var session: DemandPromptDraftSession
    @State private var error: String?
    @State private var confirmingDiscard = false

    private var externalChange: Bool {
        (vm.items.first { $0.id == item.id }?.prompt ?? item.prompt) != session.originalPrompt
    }

    init(item: DItem, draftStore: DemandPromptDraftStore, cancel: @escaping () -> Void,
         imageStore: DemandImageStore = .shared) {
        self.item = item
        self.cancel = cancel
        self.imageStore = imageStore
        _session = StateObject(wrappedValue: DemandPromptDraftSession(id: item.id, prompt: item.prompt, store: draftStore))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("咒言", systemImage: "wand.and.stars").font(.system(size: 15, weight: .semibold))
            Text("\(item.id) · \(item.displayTitle)")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
            ScrollView {
                DemandPromptFields(sections: $session.sections, imageStore: imageStore)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = error ?? session.error {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if externalChange {
                Label("已保存的咒言在编辑期间发生变化；草稿已保留，请先核对，避免覆盖新内容。",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(session.restored
                 ? "已恢复咒言草稿。关闭会保留草稿，点击「保存」后生效。"
                 : "草稿自动保存在本机。关闭会保留草稿，点击「保存」后生效。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if session.changed {
                    Button("放弃草稿") { confirmingDiscard = true }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭", action: requestClose).keyboardShortcut(.cancelAction)
                Button("保存") { save(copy: false) }.keyboardShortcut("s", modifiers: .command)
                Button("保存并复制") { save(copy: true) }
                    .demandButtonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(24).frame(minWidth: 480, idealWidth: 640, maxWidth: 800, minHeight: 480, idealHeight: 640)
        .background { DemandCanvasBackground() }
        .alert("放弃咒言草稿？", isPresented: $confirmingDiscard) {
            Button("继续编辑", role: .cancel) {}
            Button("放弃草稿", role: .destructive) {
                if session.discard() { cancel() }
                else { error = "放弃草稿失败，输入已保留，请先复制备份。" }
            }
        } message: { Text("这份未保存的编辑将被清除，已保存的咒言保留。") }
        .onExitCommand(perform: requestClose)
        .onAppear { vm.editingFormCount += 1 }
        .onDisappear {
            session.preserve()
            vm.editingFormCount = max(0, vm.editingFormCount - 1)
        }
    }

    private func requestClose() {
        if !session.preserve() {
            vm.showFeedback("咒言草稿未写入磁盘，输入仍保留在当前 D板；请先复制备份。", failed: true)
        }
        cancel()
    }

    private func save(copy: Bool) {
        if let validationError = session.sections.validationError {
            error = validationError
            return
        }
        session.preserve()
        guard vm.savePrompt(item, text: session.sections.stored, expected: session.originalPrompt) else {
            error = "保存失败，草稿输入已保留；请核对已保存的咒言后重试。"
            return
        }
        if !session.markSaved() {
            vm.showFeedback("咒言已保存，草稿清理失败；下次打开会核对已保存内容。", failed: true)
        }
        if copy { vm.copyCurrentState(item.id) }
        cancel()
    }
}
