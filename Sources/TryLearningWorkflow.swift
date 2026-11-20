import SwiftUI
import AppKit

struct TryLearningConfigForm: View {
    @Binding var config: TryLearningConfig
    @FocusState private var focused: Bool
    var autofocus = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("学完希望能做到什么").dboardFont(size: 13, weight: .medium)
                TextField("例如：两周内能独立排查 Redis 内存问题，并完成一次恢复实验", text: $config.goal, axis: .vertical)
                    .textFieldStyle(.plain).dboardFont(size: 16).lineLimit(3...6).focused($focused)
                    .accessibilityLabel("学习目标").padding(14).workspaceSurface(radius: 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("现在的基础").dboardFont(size: 12).foregroundStyle(.secondary)
                TextField("会什么、不懂什么；不确定也可以直接写", text: $config.baseline, axis: .vertical)
                    .textFieldStyle(.plain).dboardFont(size: 14).lineLimit(1...3).accessibilityLabel("当前基础")
            }
            HStack(spacing: 24) {
                Stepper(value: $config.minutesPerDay, in: 5...240, step: 5) {
                    Text("每天 \(config.minutesPerDay) 分钟").dboardFont(size: 13)
                }
                DatePicker("截止", selection: Binding(get: { Date(timeIntervalSince1970: config.deadline) },
                    set: { config.deadline = $0.timeIntervalSince1970 }), in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.field).dboardFont(size: 12).accessibilityLabel("学习截止日期")
            }
        }.onAppear { if autofocus { focused = true } }
    }
}

struct TryLearningStart: View {
    @ObservedObject var store: TryStore
    let close: () -> Void
    let saved: (String) -> Void
    @State private var error: String?
    private var config: Binding<TryLearningConfig> {
        let generation = store.captureGeneration(.digestion)
        return Binding(get: { store.capture(.digestion).learningConfig ?? .empty }, set: {
            guard let data = try? JSONEncoder().encode($0), let text = String(data: data, encoding: .utf8) else { return }
            store.editCapture(.digestion, field: "learningConfig", value: text, generation: generation)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("开始一轮学习").dboardFont(size: 24, weight: .semibold)
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.demandButtonStyle(TryControlStyle()).accessibilityLabel("关闭并保留草稿")
            }
            Text("先确定目标和时间，再让 AI 根据你的起点安排学习。").dboardFont(size: 13).foregroundStyle(.secondary)
            TryLearningConfigForm(config: config, autofocus: true)
            HStack {
                Text("草稿自动保留").dboardFont(size: 10).foregroundStyle(.secondary)
                Spacer()
                Button("让 AI 制定方案") {
                    guard let id = store.submitCapture(.digestion) else { return }
                    if let text = store.learningHandoff(id, action: "plan") {
                        NSPasteboard.general.clearContents()
                        _ = NSPasteboard.general.setString(text, forType: .string)
                    }
                    saved(id)
                }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    .disabled(!config.wrappedValue.valid || config.wrappedValue.overdue)
                    .keyboardShortcut(.return, modifiers: .command).demandKeyboardID("try-capture-save")
            }
            if let error = error ?? store.error { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
        }.padding(28).demandFloatingCanvas()
            .background(TryKeyboardBridge(onEscape: close)).onDisappear { _ = store.flush() }
    }
}

struct TryLearningGoalEditor: View {
    @ObservedObject var store: TryStore
    let id: String
    let close: () -> Void
    let saved: () -> Void
    private var config: Binding<TryLearningConfig> {
        Binding(get: { store.entry(id)?.learningConfigDraft ?? store.entry(id)?.learningConfig ?? .empty },
            set: { store.editLearningConfigDraft(id, config: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("学习目标与时间").dboardFont(size: 20, weight: .semibold)
            TryLearningConfigForm(config: config, autofocus: true)
            Text("修改后重新核对方案，已有笔记与成果保留。").dboardFont(size: 11).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("稍后继续", action: close).demandButtonStyle(TryControlStyle())
                Button("保存并制定方案") {
                    if store.entry(id)?.learningConfigDraft == nil { store.editLearningConfigDraft(id, config: config.wrappedValue) }
                    if store.saveLearningConfig(id) { saved(); close() }
                }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    .disabled(!config.wrappedValue.valid || config.wrappedValue.overdue)
                    .keyboardShortcut(.return, modifiers: .command).demandKeyboardID("try-learning-config-save")
            }
            if let error = store.error { Text(error).dboardFont(size: 12).foregroundStyle(.orange) }
        }.padding(24).frame(width: 530)
    }
}

struct TryLearningPlanFeedbackEditor: View {
    @ObservedObject var store: TryStore
    let id: String
    let copy: () -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    private var feedback: Binding<String> {
        Binding(get: { store.entry(id)?.learningPlanFeedback ?? "" },
                set: { store.edit(id, field: "learningPlanFeedback", value: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("哪里需要调整").dboardFont(size: 20, weight: .semibold)
            TextField("例如：基础讲慢一点；多做实际练习；这周只有两天能学。", text: feedback, axis: .vertical)
                .textFieldStyle(.plain).dboardFont(size: 15).lineLimit(4...8).focused($focused)
                .accessibilityLabel("学习方案调整意见").padding(14).workspaceSurface(radius: 12)
            Text("你的意见随指令给到 AI，已有笔记与成果一并保留。").dboardFont(size: 12).foregroundStyle(.secondary)
            HStack {
                Button("稍后继续", action: close).demandButtonStyle(TryControlStyle())
                Spacer()
                Button("复制调整指令") {
                    if store.flush() { copy(); close() }
                }.demandButtonStyle(WorkspaceActionStyle(prominent: true))
                    .disabled(feedback.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command).demandKeyboardID("try-plan-feedback-copy")
            }
        }.padding(24).frame(width: 460).onAppear { focused = true }.onDisappear { _ = store.flush() }
    }
}

struct TryLearningJourneyPanel: View {
    @ObservedObject var store: TryStore
    let id: String
    let editGoal: () -> Void
    let writeNote: () -> Void
    let copyAction: (String) -> Void
    var openNote: (String) -> Void = { _ in }
    @State private var preferencesEditing = false
    @State private var routeExpanded = false
    @State private var detailsExpanded = false
    @State private var organization: TryLearningOrganization?
    @State private var ending = false
    @State private var adjustingPlan = false
    @State private var inspectedStage: TryLearningStage?
    @EnvironmentObject private var theme: ThemeManager
    private var item: TryEntry? { store.entry(id) }
    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 16) {
                if let config = item.learningConfig, config.valid {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(item.learningGoalLabel).dboardFont(size: 13)
                            .foregroundStyle(theme.current.textSecondary).lineLimit(3).lineSpacing(4)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) {
                                schedule(config, item: item)
                                Spacer()
                                settings(item)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                schedule(config, item: item)
                                settings(item)
                            }
                        }
                    }.padding(16).workspaceSurface(radius: 13)
                    if let practice = item.pendingLearningPractice {
                        if practice.dueAt <= Date().timeIntervalSince1970 {
                            Button("复习一道题") { copyAction("practice") }
                                .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-learning-practice")
                        } else {
                            HStack(spacing: 5) {
                                Text("下次复习")
                                Text(Date(timeIntervalSince1970: practice.dueAt), style: .date)
                            }.dboardFont(size: 12).foregroundStyle(theme.current.textSecondary)
                        }
                    }
                    if let plan = item.learningPlanCurrent ? item.learningPlan : item.learningPlanProposal {
                        DisclosureGroup(isExpanded: $routeExpanded) {
                            roadmap(plan, item: item).padding(.top, 10)
                        } label: {
                            Text("学习路线 · \(item.verifiedLearningStages.count) / \(plan.stages.count) 阶段已确认")
                                .dboardFont(size: 12, weight: .medium)
                        }
                        if item.learningPlanCurrent {
                            if item.learningFinishedAt != nil {
                                Text(item.learningGoalReached == true ? "已确认达成目标" : "本轮已结束，未掌握的部分保留")
                                    .dboardFont(size: 14, weight: .medium)
                            } else if config.overdue {
                                Text("先核对学会了什么，再决定延期、调整目标或结束本轮。")
                                    .dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                                Button("到期复盘") { copyAction("review") }
                                    .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                            } else if item.learningAction == "review" {
                                Text("各阶段已确认，下一步核对整体学习目标。").dboardFont(size: 13)
                                Button("核对学习成果") { copyAction("review") }
                                    .demandButtonStyle(WorkspaceActionStyle(prominent: true))
                            } else if let stage = item.currentLearningStage {
                                currentStage(stage, item: item)
                            }
                        } else {
                            Text("计划超过可投入的时间，或目标已变化；先调整目标、时间或安排。")
                                .dboardFont(size: 13).foregroundStyle(.orange)
                            HStack {
                                Button("调整目标与时间", action: editGoal).demandButtonStyle(TryControlStyle())
                                Button("让 AI 调整") { adjustingPlan = true }.demandButtonStyle(TryControlStyle())
                            }
                        }

                    } else {
                        Text("下一步：把「制定学习方案」的指令交给 AI，核对起点后从短试学开始。")
                            .dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                    }
                    if let review = item.learningReview, item.learningReviewCurrent, !review.isEmpty {
                        DisclosureGroup {
                            DemandSpellContentView(text: review).padding(.top, 10)
                        } label: { Text("本轮复盘").dboardFont(size: 12, weight: .medium) }
                    }
                    if item.learningFinishedAt == nil, item.learningReviewCurrent {
                        Button(item.verifiedLearningStages.count == item.learningPlan?.stages.count ? "确认达成目标" : "结束本轮") { ending = true }
                            .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-learning-finish")
                    }
                } else {
                    Text("先确定这轮学习要达到什么程度").dboardFont(size: 17, weight: .medium)
                    Text("写下目标与时间，让 AI 核对起点并安排短试学；已有笔记保留。")
                        .dboardFont(size: 13).foregroundStyle(theme.current.textSecondary)
                    Button("确定目标并制定方案", action: editGoal)
                        .demandButtonStyle(WorkspaceActionStyle(prominent: true)).demandKeyboardID("try-learning-setup")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .popover(item: $organization) { draft in
                    TryLearningOrganizationView(store: store, entryID: id, draftID: draft.id,
                        close: { organization = nil }).environmentObject(theme)
                }
                .popover(isPresented: $preferencesEditing) {
                    TryLearningPreferencesEditor(store: store, id: id, close: { preferencesEditing = false })
                }
                .popover(isPresented: $adjustingPlan) {
                    TryLearningPlanFeedbackEditor(store: store, id: id, copy: { copyAction("plan") },
                        close: { adjustingPlan = false }).environmentObject(theme)
                }
                .popover(isPresented: $detailsExpanded) {
                    if let plan = item.learningPlanCurrent ? item.learningPlan : item.learningPlanProposal {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Text("安排依据").dboardFont(size: 20, weight: .semibold)
                                planDetail("目标范围", plan.target)
                                planDetail("学习起点", plan.startingPoint)
                                planDetail("安排理由", plan.rationale)
                            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(width: 500, height: 480)
                    }
                }
                .popover(item: $inspectedStage) { stage in
                    TryLearningStageDetails(stage: stage).environmentObject(theme)
                }
                .task(id: item.learningPlanProposal?.id) {
                    if let proposal = item.learningPlanProposal, let config = item.learningConfig,
                       item.learningFinishedAt == nil, config.valid, !config.overdue,
                       proposal.configRevision == config.revision, proposal.totalMinutes <= config.availableMinutes {
                        _ = store.acceptLearningPlan(id)
                    }
                }
                .alert("结束这一轮学习？", isPresented: $ending) {
                    Button("确认结束") {
                        let reached = item.learningPlanCurrent && item.verifiedLearningStages.count == item.learningPlan?.stages.count
                        _ = store.finishLearning(id, reached: reached)
                    }
                    Button("继续学习", role: .cancel) {}
                } message: { Text("保留笔记、自测和实际成果；未通过的部分不会被标记为已掌握。") }
        }
    }
    private func feedback(_ text: String) {
        if store.recordLearningFeedback(id, text: text) { copyAction("lesson") }
    }
    private func planDetail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).dboardFont(size: 11, weight: .medium).foregroundStyle(theme.current.textSecondary)
            Text(text).dboardFont(size: 13).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func roadmap(_ plan: TryLearningPlan, item: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("学习路线").dboardFont(size: 12, weight: .medium)
                Text("\(item.verifiedLearningStages.count) / \(plan.stages.count) 阶段已掌握")
                    .dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
                Spacer()
                Button("安排依据") { detailsExpanded = true }
                    .demandButtonStyle(TryControlStyle()).dboardFont(size: 11).demandKeyboardID("try-learning-plan")
                if item.learningFinishedAt == nil {
                    Menu("切换阶段") {
                        ForEach(plan.stages) { next in
                            Button(next.title) { _ = store.switchLearningStage(id, stageID: next.id) }
                        }
                    }.demandMenuStyle(TryMenuStyle())
                    Button("调整") { adjustingPlan = true }.demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                    Button("复盘") { copyAction("review") }.demandButtonStyle(TryControlStyle()).dboardFont(size: 11)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(Array(plan.stages.enumerated()), id: \.element.id) { index, stage in
                    stageCard(stage, index: index, item: item)
                }
            }
        }
    }
    private func stageCard(_ stage: TryLearningStage, index: Int, item: TryEntry) -> some View {
        let learned = item.verifiedLearningStages.contains(stage.id)
        let current = item.learningPlanCurrent && item.learningAction == "lesson" && item.currentLearningStage?.id == stage.id
        return Button { inspectedStage = stage } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(theme.current.accentPrimary.opacity(current || learned ? 0.18 : 0.06)).frame(width: 27, height: 27)
                    if learned { Image(systemName: "checkmark").dboardFont(size: 11, weight: .medium) }
                    else { Text("\(index + 1)").dboardFont(size: 12, weight: .medium) }
                }.foregroundStyle(current || learned ? theme.current.accentPrimary : theme.current.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stage.title).dboardFont(size: 13, weight: current ? .semibold : .regular)
                        .foregroundStyle(theme.current.textPrimary).lineLimit(2).multilineTextAlignment(.leading)
                    Text(learned ? "已确认" : (current ? "正在学习" :
                        item.learningStageChecks?.contains(where: { $0.stageID == stage.id }) == true ? "有记录 · 待巩固" :
                        item.learningLessonForStage(stage.id) != nil ? "已讲过" : "待学习"))
                        .dboardFont(size: 10).foregroundStyle(current ? theme.current.accentPrimary : theme.current.textSecondary)
                }
                Spacer(minLength: 0)
            }.padding(10).frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                .background(theme.current.accentPrimary.opacity(current ? 0.12 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).stroke(theme.current.accentPrimary.opacity(current ? 0.45 : 0), lineWidth: 1) }
                .contentShape(Rectangle())
        }.demandButtonStyle(.plain).demandKeyboardID("try-stage-details-" + stage.id)
    }
    private func currentStage(_ stage: TryLearningStage, item: TryEntry) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("正在学习 · " + stage.title).dboardFont(size: 11, weight: .medium)
                    .foregroundStyle(theme.current.accentPrimary)
                Spacer()
                Text("约\(stage.estimatedMinutes)分钟").dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
            }
            if let unit = item.currentLearningUnit {
                TryLearningUnitView(unit: unit, topics: [], notes: [], openNote: openNote)
                    .id("try-current-unit")
            } else if let explanation = item.learningReadingBody {
                TryLearningStudySheet(text: explanation).demandKeyboardID("try-stage-reading")
            } else {
                Text(stage.summary ?? stage.objective).dboardFont(size: 15).lineSpacing(5)
            }
            Divider().opacity(0.3)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    studyActions
                    Spacer()
                    Button("阶段自测") { copyAction("check") }
                        .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-stage-check")
                }
                VStack(alignment: .leading, spacing: 10) {
                    studyActions
                    Button("阶段自测") { copyAction("check") }
                        .demandButtonStyle(TryControlStyle()).demandKeyboardID("try-stage-check")
                }
            }
            if let unit = item.currentLearningUnit {
                HStack {
                    Menu("换种讲法") {
                        Button("还没懂") { feedback("还没懂") }
                        Button("更具体一点") { feedback("想看更具体的解释") }
                        Button("换个例子") { feedback("想看另一个例子") }
                    }.demandMenuStyle(TryMenuStyle())
                    let units = (item.learningUnits ?? []).filter { $0.stageIDs.contains(stage.id) }
                    if units.count > 1 {
                        Menu("回看本阶段") {
                            ForEach(units) { candidate in
                                Button(candidate.title) { _ = store.selectLearningUnit(id, unitID: candidate.id) }
                            }
                        }.demandMenuStyle(TryMenuStyle())
                    }
                    Spacer()
                    Button("整理本节笔记") {
                        if store.collectLearningUnit(id) {
                            organization = store.entry(id)?.learningOrganizations?.first {
                                $0.unitIDs == [unit.id] && $0.body == unit.readingBody
                            }
                        }
                    }.demandButtonStyle(TryControlStyle()).demandKeyboardID("try-learning-collect-unit")
                }
                if !item.currentTopicNotes.isEmpty {
                    Menu("相关笔记 · \(item.currentTopicNotes.count)") {
                        ForEach(item.currentTopicNotes) { note in
                            Button(note.displayTitle) { openNote(note.id) }
                        }
                    }.demandMenuStyle(TryMenuStyle())
                }
            }
            if let check = item.learningStageChecks?.first(where: { $0.stageID == stage.id }),
               item.learningCheckCurrent(check), check.verdict == "ready", check.confirmedAt == nil {
                Button("确认已掌握") { _ = store.confirmLearningStage(id, stageID: stage.id) }
                    .demandButtonStyle(WorkspaceActionStyle(prominent: true)).demandKeyboardID("try-stage-confirm")
            }
        }.padding(24).workspaceSurface(radius: 16)
    }
    private var studyActions: some View {
        HStack(spacing: 10) {
            Button("交给 AI 继续") { copyAction("lesson") }
                .demandButtonStyle(WorkspaceActionStyle(prominent: true)).demandKeyboardID("try-stage-lesson")
            Button("记下理解或疑问", action: writeNote)
                .demandButtonStyle(WorkspaceActionStyle()).demandKeyboardID("try-stage-note")
        }
    }
    private func schedule(_ config: TryLearningConfig, item: TryEntry) -> some View {
        HStack(spacing: 8) {
            Text(Date(timeIntervalSince1970: config.deadline), format: .dateTime.month().day())
            Text("截止 · 每天\(config.minutesPerDay)分钟")
            if config.overdue, item.learningFinishedAt == nil { Text("待复盘").foregroundStyle(.orange) }
        }.dboardFont(size: 11).foregroundStyle(theme.current.textSecondary)
    }
    private func settings(_ item: TryEntry) -> some View {
        Menu("目标与安排") {
            Button(item.learningFinishedAt == nil ? "目标与时间" : "开始下一轮", action: editGoal)
            Button("学习偏好") { preferencesEditing = true }
            if item.learningFinishedAt == nil {
                Button("让 AI 调整方案") { adjustingPlan = true }
            }
        }.demandMenuStyle(TryMenuStyle()).dboardFont(size: 11)
    }

}

private func learningSourceLinks(in text: String) -> [URL] {
    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    let links = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
    var seen: Set<URL> = []
    return links.filter { ["http", "https"].contains($0.scheme ?? "") && seen.insert($0).inserted }
}

private struct TryLearningStageDetails: View {
    let stage: TryLearningStage
    @EnvironmentObject private var theme: ThemeManager
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(stage.title).dboardFont(size: 20, weight: .semibold)
                section("这一阶段要学会什么", stage.objective)
                if learningSourceLinks(in: stage.resources).isEmpty {
                    section("参考资料", stage.resources)
                }
                section("练习安排", stage.practice)
                section("如何核验", stage.check)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(width: 500, height: 530)
    }
    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).dboardFont(size: 11, weight: .medium).foregroundStyle(theme.current.textSecondary)
            Text(text).dboardFont(size: 13).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
