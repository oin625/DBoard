import Foundation

struct TryLearningConfig: Codable, Equatable {
    var goal = ""
    var baseline = ""
    var minutesPerDay = 30
    var deadline: Double
    var revision = 0
    static var empty: Self {
        Self(deadline: Calendar.current.date(byAdding: .day, value: 14, to: Date())!.timeIntervalSince1970)
    }
    var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
            to: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: deadline))).day ?? 0
    }
    var overdue: Bool { daysLeft < 0 }
    var valid: Bool { !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && minutesPerDay > 0 }
    var availableMinutes: Int { max(0, daysLeft + 1) * minutesPerDay }
}
struct TryLearningStage: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var objective: String
    var resources: String
    var practice: String
    var check: String
    var estimatedMinutes: Int
    var summary: String? = nil
}
struct TryLearningPlan: Codable, Equatable, Identifiable {
    var id: String
    var configRevision: Int
    var target: String
    var startingPoint: String
    var rationale: String
    var stages: [TryLearningStage]
    var goalSummary: String? = nil
    var totalMinutes: Int { stages.map(\.estimatedMinutes).reduce(0, +) }
}
struct TryLearningStageCheck: Codable, Equatable, Identifiable {
    var stageID: String
    var planID: String
    var configRevision: Int
    var verdict: String
    var summary: String
    var gaps: [String]
    var evidenceText: String
    var outcome: String
    var evidenceVersions: [String: Double]
    var confirmedAt: Double? = nil
    var practice: TryLearningPractice? = nil
    var standards: TryLearningStandards? = nil
    var evidenceBodies: [String: String]? = nil
    var id: String { stageID }
}

struct TryLearningPractice: Codable, Equatable {
    var id: String
    var gap: String
    var question: String
    var originalAnswer: String
    var dueAt: Double
    var lastAnswer: String? = nil
    var feedback: String? = nil
    var completedAt: Double? = nil
    var attempts: [TryLearningPracticeAttempt]? = nil
}
struct TryLearningPracticeAttempt: Codable, Equatable {
    var question: String
    var answer: String
    var feedback: String
    var passed: Bool
    var at: Double
}
struct TryLearningLesson: Codable, Equatable {
    var stageID: String
    var planID: String
    var body: String
}

extension TryEntry {
    var learningConfigReady: Bool { learningConfig?.valid == true }
    var learningGoalLabel: String {
        let plan = learningPlanCurrent ? learningPlan : learningPlanProposal
        let summary = plan?.goalSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return summary.isEmpty ? (learningConfig?.goal ?? "") : summary
    }
    var learningPlanCurrent: Bool {
        learningConfigReady && learningPlan?.configRevision == learningConfig?.revision
    }
    func learningCheckCurrent(_ check: TryLearningStageCheck) -> Bool {
        guard learningPlanCurrent, let stage = learningPlan?.stages.first(where: { $0.id == check.stageID }) else { return false }
        if let standards = check.standards {
            guard standards == TryLearningStandards(stage) else { return false }
        } else {
            guard check.planID == learningPlan?.id, check.configRevision == learningConfig?.revision else { return false }
        }
        if let bodies = check.evidenceBodies {
            return bodies.allSatisfy { key, body in learningNotes.contains { $0.id == key && $0.body == body } }
        }
        return check.evidenceVersions.allSatisfy { key, version in
            learningNotes.contains { $0.id == key && ($0.contentUpdatedAt ?? $0.updatedAt) == version }
        }
    }
    var verifiedLearningStages: [String] {
        (learningStageChecks ?? []).filter { $0.confirmedAt != nil && learningCheckCurrent($0) }.map(\.stageID)
    }

    var pendingLearningPractice: TryLearningPractice? {
        (learningStageChecks ?? []).filter(learningCheckCurrent).compactMap(\.practice)
            .filter { $0.completedAt == nil }.min { $0.dueAt < $1.dueAt }
    }

    var hasDueLearningPractice: Bool {
        pendingLearningPractice.map { $0.dueAt <= Date().timeIntervalSince1970 } ?? false
    }
    var learningReviewCurrent: Bool {
        guard let review = learningReview, !review.isEmpty,
              learningReviewConfigRevision == learningConfig?.revision,
              learningReviewPlanID == learningPlan?.id else { return false }
        return (learningReviewEvidenceVersions ?? [:]).allSatisfy { key, version in
            learningNotes.contains { $0.id == key && ($0.contentUpdatedAt ?? $0.updatedAt) == version }
        }
    }
    var currentLearningStage: TryLearningStage? {
        guard learningPlanCurrent, let stages = learningPlan?.stages else { return nil }
        return stages.first { $0.id == currentLearningStageID } ??
            stages.first { !verifiedLearningStages.contains($0.id) } ?? stages.last
    }
    func learningLessonForStage(_ stageID: String) -> TryLearningLesson? {
        guard learningPlanCurrent else { return nil }
        return (learningLessons ?? []).last { $0.stageID == stageID && $0.planID == learningPlan?.id } ??
            (learningLesson?.stageID == stageID && learningLesson?.planID == learningPlan?.id ? learningLesson : nil)
    }
    var learningAction: String {
        if learningFinishedAt != nil { return "review" }
        guard learningConfigReady else { return "plan" }
        if learningConfig?.overdue == true { return "review" }
        if !learningPlanCurrent { return "plan" }
        if verifiedLearningStages.count == learningPlan?.stages.count { return "review" }
        return "lesson"
    }
    var learningActionTitle: String {
        if learningFinishedAt != nil { return "回看总结" }
        switch learningAction {
        case "plan": return learningPlan == nil ? "制定学习方案" : "调整学习方案"
        case "review": return learningConfig?.overdue == true ? "到期复盘" : "目标验收"
        default: return currentLearningStage.flatMap { learningLessonForStage($0.id) } != nil ? "继续本节" : "开始本节"
        }
    }
}
