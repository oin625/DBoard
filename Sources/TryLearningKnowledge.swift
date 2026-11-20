import Foundation

/// Optional entry fields keep old personal JSON readable without rewriting it.
struct TryLearningPreferences: Codable, Equatable {
    var teachingStyle: String
    var checkPolicy: String
    var constraints: [String]
    static let standard = Self(
        teachingStyle: "先看有来源的现象或结果，再解释指标、原因和判断；先说清对象与动作，通俗但有内容。",
        checkPolicy: "每阶段结束集中检查，或用户主动复习/复测；不逐轮出题。“懂了”只算学习反馈。",
        constraints: [])
}
struct TryLearningTopic: Codable, Equatable, Identifiable {
    var id: String
    var title: String
}
struct TryLearningUnit: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var stageIDs: [String]
    var topicIDs: [String]
    var question: String
    var materialKind: String // public_evaluation | verified_output | hypothetical
    var material: String
    var conditions: String
    var metrics: String
    var reasoning: String
    var limits: String
    var judgment: String
    var sources: [TryLearningUnitSource]
    var noteTitle: String? = nil // Stable knowledge heading, separate from the teaching question.
    var readingBody: String {
        "# " + title + "\n\n" + question + "\n\n## 现象与结果\n" + material +
        "\n\n## 指标怎么读\n" + metrics + "\n\n## 为什么会这样\n" + reasoning +
        "\n\n## 这个结果的边界\n" + limits + "\n\n## 用来做什么判断\n" + judgment
    }
}
struct TryLearningUnitSource: Codable, Equatable, Identifiable {
    var title: String
    var url: String
    var locator: String
    var id: String { url }
}
struct TryLearningStandards: Codable, Equatable {
    var objective: String
    var practice: String
    var check: String
    init(_ stage: TryLearningStage) {
        objective = stage.objective; practice = stage.practice; check = stage.check
    }
}
struct TryLearningNoteSnapshot: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var body: String
    var createdAt: Double
    var updatedAt: Double
    var learningStageID: String?
    var bookmark: TryBookmark?
    init(_ note: TryLearningNote) {
        id = note.id; title = note.title; body = note.body; createdAt = note.createdAt
        updatedAt = note.updatedAt; learningStageID = note.learningStageID; bookmark = note.bookmark
    }
    func matches(_ note: TryLearningNote) -> Bool {
        id == note.id && title == note.title && body == note.body && updatedAt == note.updatedAt &&
        learningStageID == note.learningStageID
    }
}
struct TryLearningOrganization: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var body: String
    var topicIDs: [String]
    var unitIDs: [String]
    var sourceNotes: [TryLearningNoteSnapshot]
    var explanation: String
    var createdAt: Double
    var adoptedNoteID: String? = nil
}
struct TryLearningFeedback: Codable, Equatable {
    var unitID: String?
    var stageID: String?
    var text: String
    var at: Double
}

extension TryEntry {
    var teachingPreferences: TryLearningPreferences { learningPreferences ?? .standard }
    var currentLearningUnit: TryLearningUnit? {
        let candidates = (learningUnits ?? []).filter { $0.stageIDs.contains(currentLearningStage?.id ?? "") }
        return candidates.first { $0.id == currentLearningUnitID } ?? candidates.last
    }
    var currentLearningNoteTitle: String {
        let candidates = [currentLearningUnit?.noteTitle] + currentLearningTopics.map { Optional($0.title) } +
            [currentLearningStage?.title, displayTitle]
        return candidates.compactMap { TryLearningNoteNaming.knowledgeHeading($0) }.first ?? "学习笔记"
    }
    var currentLearningTopics: [TryLearningTopic] {
        let ids = Set(currentLearningUnit?.topicIDs ?? [])
        return (learningTopics ?? []).filter { ids.contains($0.id) }
    }
    var currentTopicNotes: [TryLearningNote] {
        let ids = Set(currentLearningUnit?.topicIDs ?? [])
        return learningNotes.filter { !ids.isDisjoint(with: $0.topicIDs ?? []) }
    }
    var learningEvidenceHistory: [TryLearningStageCheck] {
        (learningCheckHistory ?? []) + (learningStageChecks ?? [])
    }
}
