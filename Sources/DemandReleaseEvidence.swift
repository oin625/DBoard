import SwiftUI
import AppKit

struct DemandReleaseEvidenceDraft {
    var text: String
    var expected: String
}

extension DBoardViewModel {
    func updateReleaseEvidence(_ itemID: String, entry: DemandReleaseChecklist.Entry, text: String, at url: URL? = nil) {
        let key = itemID + ":" + entry.id
        if releaseEvidenceDrafts[key] == nil {
            releaseEvidenceDrafts[key] = .init(text: entry.evidence, expected: entry.evidence)
        }
        releaseEvidenceDrafts[key]?.text = text
        // Keep the live draft local to the editor; typing must not write and refresh its presenter.
    }

    func saveReleaseEvidenceDrafts(_ itemID: String, at url: URL? = nil) -> Bool {
        for key in releaseEvidenceDrafts.keys.filter({ $0.hasPrefix(itemID + ":") }).sorted() {
            let entryID = String(key.dropFirst(itemID.count + 1))
            if !saveReleaseEvidence(itemID, entryID: entryID, at: url) { return false }
        }
        return true
    }

    @discardableResult
    func saveReleaseEvidence(_ itemID: String, entryID: String, at url: URL? = nil) -> Bool {
        let key = itemID + ":" + entryID
        guard let draft = releaseEvidenceDrafts[key] else { return true }
        guard draft.text != draft.expected else { releaseEvidenceErrors[key] = nil; return true }
        var savedChecklist: DemandReleaseChecklist?
        guard DItemStore.updateReleaseChecklist(id: itemID, at: url, { checklist in
            guard checklist.setEvidence(entryID, text: draft.text, expected: draft.expected) else { return false }
            savedChecklist = checklist
            return true
        }) else {
            releaseEvidenceErrors[key] = "证据未保存，草稿已保留；请核对最新记录后重试"
            return false
        }
        releaseEvidenceDrafts[key]?.expected = draft.text
        releaseEvidenceErrors[key] = nil
        if url == nil { markSelfWrite() }
        // Update this checklist only, preserving the open editor and avoiding remote/code refreshes.
        if let savedChecklist, let index = items.firstIndex(where: { $0.id == itemID }) {
            items[index].releaseChecklist = savedChecklist
        }
        return true
    }
}

/// Opened explicitly from a checklist row. Closing flushes pending edits; failed drafts stay in memory.
struct DemandReleaseEvidenceEditor: View {
    @EnvironmentObject var vm: DBoardViewModel
    let itemID: String
    let entry: DemandReleaseChecklist.Entry
    var readOnly = false
    let close: () -> Void
    var imageStore: DemandImageStore = .shared
    var cacheURL: URL? = nil
    @StateObject private var inputController = DemandSpellInputController()
    private var key: String { itemID + ":" + entry.id }
    private var text: String { readOnly ? entry.evidence : vm.releaseEvidenceDrafts[key]?.text ?? entry.evidence }
    private var images: [DemandImageReference] { DemandImageMarkdown.references(in: text) }
    private var plainText: String {
        var value = text
        for image in images { value = value.replacingOccurrences(of: image.markdown, with: "") }
        return value.trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("完成证据").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !images.isEmpty || !plainText.isEmpty {
                    Menu {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                            Button("复制图片 " + String(index + 1)) { copyImage(image) }
                        }
                        if !plainText.isEmpty {
                            Button("复制文字") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(plainText, forType: .string)
                            }
                        }
                    } label: {
                        Label("复制证据", systemImage: "doc.on.doc").font(.system(size: 11))
                    }.demandMenuStyle(.borderlessButton).fixedSize()
                }
                Button("关闭") { if finish() { close() } }.controlSize(.small)
            }
            Text(entry.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            if readOnly {
                ScrollView { DemandSpellContentView(text: text) }.frame(maxHeight: 240)
            } else {
                DemandSpellField(text: Binding(
                    get: { text },
                    set: { vm.updateReleaseEvidence(itemID, entry: entry, text: $0, at: cacheURL) }),
                    title: "完成证据", placeholder: "粘贴截图，也可以补一句说明",
                    autofocus: true, imageStore: imageStore, height: 170, showPasteButton: true,
                    onEditingEnded: { _ = vm.saveReleaseEvidence(itemID, entryID: entry.id, at: cacheURL) },
                    controller: inputController)
            }
            if let error = vm.releaseEvidenceErrors[key], !readOnly {
                HStack {
                    Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Button("重试") { _ = finish() }.demandButtonStyle(.borderless)
                }.font(.system(size: 11))
            } else if !readOnly {
                Text(vm.releaseEvidenceDrafts[key].map { $0.text != $0.expected } == true ? "草稿已保留；结束编辑或关闭时自动保存" : "已保存；不影响事项的勾选状态")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14).frame(width: 440)
        .onDisappear {
            if finish() && !readOnly { vm.releaseEvidenceDrafts[key] = nil }
        }
        .accessibilityIdentifier("release-evidence-editor-" + itemID + "-" + entry.id).demandKeyboardID("release-evidence-editor-" + itemID + "-" + entry.id)
    }

    private func finish() -> Bool {
        guard !readOnly else { return true }
        inputController.endEditing()
        return vm.saveReleaseEvidence(itemID, entryID: entry.id, at: cacheURL)
    }

    private func copyImage(_ reference: DemandImageReference) {
        guard let image = NSImage(contentsOfFile: reference.path) else {
            vm.showFeedback("图片无法读取，未复制", failed: true); return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([image]) { vm.showFeedback("证据图片已复制") }
        else { vm.showFeedback("图片复制失败", failed: true) }
    }
}
