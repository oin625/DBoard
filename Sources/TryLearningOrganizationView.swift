import SwiftUI

struct TryLearningOrganizationView: View {
    @ObservedObject var store: TryStore
    let entryID: String
    let draftID: String
    let close: () -> Void
    var body: some View {
        if let item = store.entry(entryID), let draft = item.learningOrganizations?.first(where: { $0.id == draftID }) {
            VStack(alignment: .leading, spacing: 16) {
                Text(draft.title).font(.system(size: 20, weight: .semibold))
                Text(draft.explanation).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        TryStudyMarkdown(text: draft.body)
                        ForEach(draft.sourceNotes) { original in
                            DisclosureGroup("原文 " + original.id + " · " + original.title) {
                                TryStudyMarkdown(text: original.body).padding(.top, 10)
                            }
                        }
                    }
                }
                HStack {
                    Button("关闭", action: close).demandButtonStyle(TryControlStyle())
                    Spacer()
                    if draft.adoptedNoteID == nil {
                        Button("采纳整理稿") {
                            if store.adoptLearningOrganization(entryID, organizationID: draftID, expectedRevision: item.revision) { close() }
                        }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    } else if item.learningNotes.contains(where: { $0.id == draft.adoptedNoteID }) {
                        Button("撤回整理页，保留原文") {
                            if store.undoLearningOrganization(entryID, organizationID: draftID, expectedRevision: item.revision) { close() }
                        }.demandButtonStyle(TryControlStyle())
                    } else {
                        Text("整理页已撤回；可从已删除笔记恢复").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let error = store.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange) }
            }.padding(24).frame(width: 620, height: 600)
        }
    }
}
