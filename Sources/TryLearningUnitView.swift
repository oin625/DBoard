import SwiftUI

struct TryLearningUnitView: View {
    let unit: TryLearningUnit
    let topics: [TryLearningTopic]
    let notes: [TryLearningNote]
    let openNote: (String) -> Void
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(unit.title).dboardFont(size: 22, weight: .semibold).textSelection(.enabled)
            if !unit.question.isEmpty, unit.question != unit.title { TryStudyMarkdown(text: unit.question) }
            VStack(alignment: .leading, spacing: 12) {
                Text(unit.materialKind == "hypothetical" ? "教学假设" :
                     unit.materialKind == "verified_output" ? "已核对的实际输出" : "公开评测")
                    .dboardFont(size: 10, weight: .medium).foregroundStyle(theme.current.textSecondary)
                TryStudyMarkdown(text: unit.material)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.current.accentPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            section("指标怎么读", unit.metrics)
            section("为什么会这样", unit.reasoning)
            section("用于判断", unit.judgment)
            if !unit.conditions.isEmpty || !unit.limits.isEmpty || !unit.sources.isEmpty {
                DisclosureGroup("条件、边界与来源") {
                    VStack(alignment: .leading, spacing: 18) {
                        section("测试条件", unit.conditions)
                        section("结果的边界", unit.limits)
                        ForEach(unit.sources) { source in
                            if let url = URL(string: source.url), ["https", "http"].contains(url.scheme ?? "") {
                                Link(source.title + (source.locator.isEmpty ? "" : " · " + source.locator), destination: url)
                                    .dboardFont(size: 12).textSelection(.enabled)
                            }
                        }
                    }.padding(.top, 10)
                }.demandKeyboardID("try-unit-sources")
            }
            if !notes.isEmpty {
                Menu("相关笔记") {
                    ForEach(notes) { note in Button(note.displayTitle) { openNote(note.id) } }
                }.demandMenuStyle(TryMenuStyle())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func section(_ title: String, _ body: String) -> some View {
        if !body.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).dboardFont(size: 14, weight: .semibold)
                TryStudyMarkdown(text: body)
            }
        }
    }
}

struct TryLearningPreferencesEditor: View {
    @ObservedObject var store: TryStore
    let id: String
    let close: () -> Void
    @State private var preferences = TryLearningPreferences.standard
    @State private var constraints = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("学习偏好").font(.system(size: 20, weight: .semibold))
            TextField("怎么讲更容易理解", text: $preferences.teachingStyle, axis: .vertical).lineLimit(2...5)
            TextField("什么时候检查", text: $preferences.checkPolicy, axis: .vertical).lineLimit(2...4)
            Text("学习限制（每行一项）").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $constraints).frame(height: 100).accessibilityLabel("学习限制")
            HStack {
                Button("取消", action: close).demandButtonStyle(TryControlStyle())
                Spacer()
                Button("保存") {
                    preferences.constraints = constraints.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if store.saveLearningPreferences(id, preferences: preferences) { close() }
                }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    .disabled(preferences.teachingStyle.isEmpty || preferences.checkPolicy.isEmpty)
            }
        }.padding(24).frame(width: 480)
            .onAppear {
                preferences = store.entry(id)?.teachingPreferences ?? .standard
                constraints = preferences.constraints.joined(separator: "\n")
            }
    }
}

struct TryLearningEvidenceView: View {
    @ObservedObject var store: TryStore
    let id: String
    let copyAction: (String) -> Void
    let openNote: (String) -> Void
    var body: some View {
        if let item = store.entry(id) {
            VStack(alignment: .leading, spacing: 20) {
                Text("复习与实际证据").font(.system(size: 20, weight: .semibold))
                Text("先回看待巩固的地方；点击复测后才出题。").font(.system(size: 13)).foregroundStyle(.secondary)
                if item.learningEvidenceHistory.isEmpty {
                    Text("还没有独立答题或操作记录。").font(.system(size: 13))
                }
                ForEach(Array(item.learningEvidenceHistory.enumerated()), id: \.offset) { _, check in
                    VStack(alignment: .leading, spacing: 12) {
                        let title = item.learningPlan?.stages.first { $0.id == check.stageID }?.title ?? check.stageID
                        Text(title).font(.system(size: 15, weight: .semibold))
                        let current = item.learningStageChecks?.contains(check) == true && item.learningCheckCurrent(check)
                        Text(current ? (check.confirmedAt != nil ? "已确认" :
                            check.verdict == "ready" ? "有独立证据，待确认" : "待巩固") : "历史作答 · 当前标准尚未核清")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(check.summary).font(.system(size: 13)).textSelection(.enabled)
                        ForEach(check.gaps, id: \.self) { Text("待补： " + $0).font(.system(size: 13)) }
                        DisclosureGroup("真实回答与反馈") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(check.evidenceText).font(.system(size: 13)).textSelection(.enabled)
                                if let standard = check.standards { Text("当时的标准： " + standard.check).font(.system(size: 12)) }
                                ForEach(Array((check.practice?.attempts ?? []).enumerated()), id: \.offset) { _, attempt in
                                    Text(attempt.question + "\n" + attempt.answer + "\n" + attempt.feedback)
                                        .font(.system(size: 13)).textSelection(.enabled)
                                }
                            }.padding(.top, 8)
                        }
                        let unitIDs = Set((item.learningUnits ?? []).filter { $0.stageIDs.contains(check.stageID) }.map(\.id))
                        let evidenceNoteIDs = Set(check.evidenceVersions.keys)
                        ForEach(item.learningNotes.filter { note in
                            !unitIDs.isDisjoint(with: note.unitIDs ?? []) || evidenceNoteIDs.contains(note.id) ||
                            (note.sourceNotes ?? []).contains {
                                evidenceNoteIDs.contains($0.id) || $0.learningStageID == check.stageID
                            }
                        }) { note in
                            Button(note.displayTitle) { openNote(note.id) }.demandButtonStyle(TryControlStyle())
                        }
                        if item.learningFinishedAt == nil, item.learningConfig?.overdue == false {
                            Button("复测这一阶段") {
                                if store.switchLearningStage(id, stageID: check.stageID) { copyAction("check") }
                            }.demandButtonStyle(TryControlStyle()).demandKeyboardID("try-retest-" + check.stageID)
                        }
                    }.padding(16).workspaceSurface(radius: 8)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
