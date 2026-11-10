import SwiftUI
import AppKit

struct DemandTechnicalPlanBody: View {
    let markdown: String
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(markdown.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, part in
                if part.hasPrefix("#") && !part.contains("\n") {
                    Text(String(part.drop(while: { $0 == "#" || $0 == " " })))
                        .font(.system(size: part.hasPrefix("# ") ? 17 : 14, weight: .semibold))
                } else {
                    Text(.init(part)).font(.system(size: 13)).lineSpacing(5).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct DemandTechnicalPlanSection: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let item: DItem
    let cacheURL: URL
    @State private var codeReviewReason: String?
    @State private var checking = true
    var body: some View {
        HStack(spacing: 10) {
            Label("技术方案", systemImage: "doc.text").font(.system(size: 12, weight: .medium))
            if let document = item.technicalPlan {
                Text(checking ? "核对中" : (document.scopeHash != item.executionScope || codeReviewReason != nil ? "待核对" : (document.updatedBy == "user" ? "已编辑" : "已准备")))
                    .font(.system(size: 11)).foregroundStyle(document.scopeHash == item.executionScope ? Color.secondary : .orange)
                Button("查看／编辑") { vm.openDemandEditor(.technicalPlan, item: item) }.controlSize(.small)
            } else {
                Text(item.technicalPlanReadError ?? "尚未准备").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(item.technicalPlan == nil ? "复制方案指令" : "让 AI 核对更新") {
                do {
                    let latest = try DItemStore.currentItem(id: item.id, at: cacheURL)
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(DboardAITaskContext.planInstruction(item: latest, cacheURL: cacheURL.path == CacheFile.path ? nil : cacheURL), forType: .string) {
                        vm.showFeedback("技术方案指令已复制")
                    }
                } catch { vm.flash(error.localizedDescription) }
            }.controlSize(.small).accessibilityIdentifier("demand-plan-copy-" + item.id)
        }
        .task(id: (item.technicalPlan?.revision ?? "") + item.executionScope) {
            checking = true
            codeReviewReason = await Task.detached(priority: .utility) {
                item.technicalPlan?.reviewReason(item: item,
                    codeRevision: DemandTechnicalPlan.currentCodeRevision(repositories: item.executionRepositories))
            }.value
            checking = false
        }
    }
}

struct DemandTechnicalPlanEditor: View {
    @EnvironmentObject private var vm: DBoardViewModel
    let itemID: String
    let cacheURL: URL
    let close: () -> Void
    @State private var original: DemandTechnicalPlan?
    @State private var markdown = ""
    @State private var editing = false
    @State private var message: String?
    @State private var reviewReason: String?
    private var draftKey: String { "dboard-plan-draft:" + itemID + ":" + (original?.revision ?? "none") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(original?.title ?? "技术方案").font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("展示方式", selection: $editing) {
                    Text("预览").tag(false)
                    Text("编辑").tag(true)
                }.pickerStyle(.segmented).frame(width: 140)
            }
            if let reason = reviewReason {
                Label(reason, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            if editing {
                TextEditor(text: $markdown).font(.system(size: 13)).scrollContentBackground(.hidden)
                    .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView { DemandTechnicalPlanBody(markdown: markdown).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Text("编辑草稿自动保存，关闭后可继续").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("关闭", action: close).keyboardShortcut(.cancelAction)
                Button("保存修改") { save() }.demandButtonStyle(.borderedProminent)
                    .disabled(original == nil || markdown.trimmed.isEmpty || markdown == original?.markdown)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }.padding(24).frame(minWidth: 540, idealWidth: 680, maxWidth: .infinity, minHeight: 520, idealHeight: 650, maxHeight: .infinity)
        .onAppear { load() }
        .onChange(of: markdown) { _, value in
            if original != nil { UserDefaults.standard.set(value, forKey: draftKey) }
        }
    }
    private func load() {
        do {
            let item = try DItemStore.currentItem(id: itemID, at: cacheURL)
            original = item.technicalPlan
            markdown = UserDefaults.standard.string(forKey: draftKey) ?? original?.markdown ?? ""
            DispatchQueue.global(qos: .utility).async {
                let reason = item.technicalPlan?.reviewReason(item: item,
                    codeRevision: DemandTechnicalPlan.currentCodeRevision(repositories: item.executionRepositories))
                DispatchQueue.main.async { reviewReason = reason }
            }
        } catch { message = error.localizedDescription }
    }
    private func save() {
        guard let value = original else { return }
        guard DItemStore.saveTechnicalPlan(id: itemID, markdown: markdown, expectedRevision: value.revision, at: cacheURL) else {
            message = "保存失败，草稿已保留；方案可能已被更新，请关闭后重新核对。"
            return
        }
        UserDefaults.standard.removeObject(forKey: draftKey)
        vm.reload()
        vm.showFeedback("技术方案已保存")
        close()
    }
}
