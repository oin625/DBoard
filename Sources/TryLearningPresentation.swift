import Foundation

struct TryLearningResource: Identifiable {
    let url: URL
    let title: String
    let source: String
    var id: String { url.absoluteString }
}

enum TryLearningResources {
    static func links(in text: String, source: String) -> [TryLearningResource] {
        let range = NSRange(text.startIndex..., in: text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: range) ?? []
        let markdown = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\((https?://[^\s]+)\)"#)
        var titles: [String: String] = [:]
        for match in markdown?.matches(in: text, range: range) ?? [] {
            if let labelRange = Range(match.range(at: 1), in: text),
               let urlRange = Range(match.range(at: 2), in: text) {
                titles[String(text[urlRange])] = String(text[labelRange])
            }
        }
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where index > 0 {
            let candidate = line.trimmingCharacters(in: .whitespaces)
            guard candidate.hasPrefix("http"), !candidate.contains(" ") else { continue }
            let previous = lines[index - 1].trimmingCharacters(in: .whitespaces)
            guard previous.hasPrefix("- ") || previous.hasPrefix("* ") else { continue }
            let label = String(previous.dropFirst(2)).components(separatedBy: CharacterSet(charactersIn: "：:")).first ?? ""
            if !label.isEmpty, !label.contains("http"), titles[candidate] == nil { titles[candidate] = label }
        }
        return matches.compactMap { match in
            guard let url = match.url, ["http", "https"].contains(url.scheme ?? "") else { return nil }
            let host = url.host ?? "打开资料"
            let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
            let fallback = name.isEmpty ? host : host + " · " + name
            return TryLearningResource(url: url, title: titles[url.absoluteString] ?? fallback, source: source)
        }
    }
}

/// Older AI reports mixed labelled teaching sections with handoff/audit sections.
/// Project only those known teaching blocks; retain the complete source for AI lookup.
enum TryLearningReading {
    /// References remain in the stored lesson, but the reading sheet uses the shared resource cards.
    private static func withoutResources(_ body: String) -> String {
        let sources = ["资料", "参考资料", "参考来源", "来源链接"]
        var output: [String] = []
        var hiddenLevel: Int?
        var fenced = false
        let lines = body.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            if !fenced, let heading = TryStudyDocument.heading(line) {
                if let level = hiddenLevel, heading.level <= level { hiddenLevel = nil }
                if sources.contains(heading.title) {
                    let end = lines.indices.dropFirst(index + 1).first {
                        TryStudyDocument.heading(lines[$0]).map { $0.level <= heading.level } ?? false
                    } ?? lines.count
                    let references = lines[(index + 1)..<end].joined(separator: "\n")
                    // A book name or local reference with no URL has no resource card; keep it readable.
                    if !TryLearningResources.links(in: references, source: "").isEmpty { hiddenLevel = heading.level }
                }
            }
            if hiddenLevel == nil { output.append(line) }
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func text(_ body: String) -> String {
        let reading = withoutResources(body)
        let lines = reading.components(separatedBy: .newlines)
        let teaching = ["用户指令与教学", "本轮讲解"]
        let audit = ["核对记录与边界", "证据与下一步", "硬件与资料核对", "本节笔记与真实证据",
                     "接续", "来源、假设与边界", "本节状态与接续", "核对记录", "证据与接续"]
        func heading(_ line: String) -> (level: Int, title: String)? {
            let value = line.trimmingCharacters(in: .whitespaces)
            let level = value.prefix { $0 == "#" }.count
            guard level > 0, level <= 6, value.dropFirst(level).first == " " else { return nil }
            return (level, value.dropFirst(level).trimmingCharacters(in: .whitespaces))
        }
        let headings = lines.compactMap(heading)
        guard headings.contains(where: { teaching.contains($0.title) }),
              headings.contains(where: { audit.contains($0.title) }) else { return reading }
        var chunks: [String] = []
        var current: [String] = []
        var teachingLevel: Int?
        var sources = false
        func finish() {
            var text = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // This historical label also contained an explicit workflow preface.
            if text.hasPrefix("用户真实原话："), let start = text.range(of: "好，直接讲运行配置。") {
                text = String(text[start.lowerBound...])
            }
            if !text.isEmpty { chunks.append(text) }
            current = []; teachingLevel = nil; sources = false
        }
        for line in lines {
            if let h = heading(line) {
                if teaching.contains(h.title) {
                    finish(); teachingLevel = h.level
                    continue
                }
                if audit.contains(h.title) || (teachingLevel.map { h.level < $0 } ?? false) {
                    finish()
                    continue
                }
            }
            guard teachingLevel != nil else { continue }
            if ["已核对来源：", "已核对来源:", "参考来源：", "参考资料："].contains(line.trimmingCharacters(in: .whitespaces)) {
                sources = true
                continue
            }
            if !sources { current.append(line) }
        }
        finish()
        return chunks.isEmpty ? reading : chunks.joined(separator: "\n\n---\n\n")
    }
}

extension TryEntry {
    var standaloneLearningExplanation: String? {
        let text = aiResult.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lessons = (learningLessons ?? []) + (learningLesson.map { [$0] } ?? [])
        guard !lessons.contains(where: { $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == text }) else { return nil }
        return text
    }

    var learningReadingBody: String? {
        if let stage = currentLearningStage,
           let lesson = learningLessonForStage(stage.id),
           !lesson.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return TryLearningReading.text(lesson.body) }
        return standaloneLearningExplanation.map(TryLearningReading.text)
    }

    var learningSuggestionCurrent: Bool {
        guard let suggestion = learningSuggestion, learningFinishedAt == nil else { return false }
        let hasContent = !(suggestion.progress ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !(suggestion.nextStep ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !suggestion.outcomes.isEmpty
        guard hasContent else { return false }
        if !learningConfigReady { return true }
        return suggestion.configRevision == learningConfig?.revision &&
            suggestion.planID == (learningPlanCurrent ? learningPlan?.id : nil) &&
            suggestion.stageID == currentLearningStage?.id
    }

    var learningResources: [TryLearningResource] {
        var result = TryLearningResources.links(in: learningSources ?? "", source: "补充资料")
        let plan = learningPlanCurrent ? learningPlan : learningPlanProposal
        for stage in plan?.stages ?? [] {
            result += TryLearningResources.links(in: stage.resources, source: stage.title)
        }
        let lessons = (learningLessons ?? []) + (learningLesson.map { [$0] } ?? [])
        for unit in learningUnits ?? [] {
            for source in unit.sources {
                if let url = URL(string: source.url), ["http", "https"].contains(url.scheme ?? "") {
                    result.append(TryLearningResource(url: url, title: source.title, source: unit.title))
                }
            }
        }
        for lesson in lessons where lesson.planID == plan?.id {
            let title = plan?.stages.first { $0.id == lesson.stageID }?.title ?? lesson.stageID
            result += TryLearningResources.links(in: lesson.body, source: title)
        }
        if let explanation = standaloneLearningExplanation {
            result += TryLearningResources.links(in: explanation, source: "补充讲解")
        }
        var seen: Set<String> = []
        return result.filter { seen.insert($0.id).inserted }
    }

    var learningSourceNotes: String {
        (learningSources ?? "").components(separatedBy: .newlines)
            .filter { TryLearningResources.links(in: $0, source: "").isEmpty }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
