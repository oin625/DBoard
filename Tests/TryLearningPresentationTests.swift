import XCTest
@testable import DBoard

final class TryLearningPresentationTests: XCTestCase {
    private func topic() -> TryEntry {
        var item = TryEntry(id: "T007", kind: .digestion, createdAt: 1, updatedAt: 1)
        var config = TryLearningConfig.empty
        config.goal = "理解模型运行配置"; config.revision = 2
        item.learningConfig = config
        item.learningPlan = TryLearningPlan(id: "plan", configRevision: 2, target: "理解配置",
            startingPoint: "入门", rationale: "先讲后练",
            stages: [TryLearningStage(id: "S004", title: "运行配置", objective: "估算内存",
                resources: "https://example.com/guide", practice: "估算7B", check: "说明额外开销", estimatedMinutes: 30),
                     TryLearningStage(id: "S005", title: "训练", objective: "解释训练",
                resources: "", practice: "", check: "", estimatedMinutes: 30)])
        item.currentLearningStageID = "S004"
        return item
    }

    func testDuplicateLectureIsOnlyReadOnceIncludingLegacyCopies() {
        var item = topic()
        let lesson = TryLearningLesson(stageID: "S004", planID: "plan", body: "参数数量乘每参数字节数。")
        item.learningLesson = lesson; item.learningLessons = [lesson]
        item.aiResult = lesson.body
        XCTAssertNil(item.standaloneLearningExplanation)
        XCTAssertEqual(item.learningReadingBody, lesson.body)
        item.currentLearningStageID = "S005"
        XCTAssertNil(item.learningReadingBody, "Previous-stage text must not leak into the next stage")
        item.aiResult = "一份独立解释"
        XCTAssertEqual(item.standaloneLearningExplanation, "一份独立解释")
    }

    func testSuggestionsExpireAfterStagePlanOrGoalChanges() {
        var item = topic()
        item.learningSuggestion = TryLearningSuggestion(configRevision: 2, planID: "plan", stageID: "S004",
            progress: "已理解权重占用")
        XCTAssertTrue(item.learningSuggestionCurrent)
        item.currentLearningStageID = "S005"
        XCTAssertFalse(item.learningSuggestionCurrent)
        item.currentLearningStageID = "S004"
        item.learningPlan?.id = "replacement"
        XCTAssertFalse(item.learningSuggestionCurrent)
        item.learningPlan?.id = "plan"
        item.learningConfig?.revision = 3
        XCTAssertFalse(item.learningSuggestionCurrent)
        item.learningConfig?.revision = 2
        item.learningSuggestion = TryLearningSuggestion(nextStep: "从S001开始")
        XCTAssertFalse(item.learningSuggestionCurrent, "An unbound legacy suggestion cannot override a current plan")
    }

    func testReferencesAreCollectedOnceWithReadableMarkdownTitles() {
        var item = topic()
        item.learningSources = "[官方指南](https://example.com/guide)\n我的资料在本地目录"
        let lesson = TryLearningLesson(stageID: "S004", planID: "plan",
            body: "资料 https://example.com/guide 和 https://example.com/cache")
        item.learningLesson = lesson; item.learningLessons = [lesson]
        XCTAssertEqual(item.learningResources.count, 2)
        XCTAssertEqual(item.learningResources.first?.title, "官方指南")
        XCTAssertEqual(item.learningSourceNotes, "我的资料在本地目录")
        item.learningLesson = nil; item.learningLessons = nil
        item.learningSources = ""; item.learningPlan?.stages[0].resources = ""
        XCTAssertTrue(item.learningResources.isEmpty)
    }

    func testLegacyAuditSectionsStayInSourceAndPureLessonsAreUnchanged() {
        let source = """
        # 工作记录
        旧方案状态
        ## 用户指令与教学
        参数量与精度一起决定基础权重占用。
        ### 一个例子
        7B、FP16的理想权重数据约14GB。
        已核对来源：
        https://example.com/guide
        ## 核对记录与边界
        工具执行和交接，不属于教学。
        ## 第二段
        内部状态
        ### 本轮讲解
        运行还需要缓存与工作空间。
        ### 本节状态与接续
        未完成核验，下一轮继续。
        """
        let reading = TryLearningReading.text(source)
        XCTAssertTrue(reading.contains("7B、FP16"))
        XCTAssertTrue(reading.contains("运行还需要缓存"))
        XCTAssertFalse(reading.contains("旧方案状态"))
        XCTAssertFalse(reading.contains("工具执行"))
        XCTAssertFalse(reading.contains("example.com"))
        XCTAssertTrue(source.contains("工具执行"), "Projection must not mutate the original record")
        let pure = "# 模型运行\n## 本轮讲解\n完整讲解\n### 示例\n一个例子"
        XCTAssertEqual(TryLearningReading.text(pure), pure)
    }
    func testStudySheetGroupsTopicsAndPreservesTablesCodeAndTeachingBoundaries() {
        let body = """
        # 运行配置
        ## 本节要点
        - 权重只是总运行占用的一部分。
        - 低位量化可能影响效果，需要实际验证。
        ## 如何估算
        先区分参数数量与每参数占用。
        ### 一个例子
        | 版本 | 理想基础数据量 |
        | --- | --- |
        | FP16 | 14GB |
        | 4bit | 3.5GB |
        ## 练习
        ```text
        ## 代码里的标题应原样保留
        ```
        ## 资料
        [官方说明](https://example.com/guide)
        ## 注意边界
        14GB不是总运行内存。
        """
        let reading = TryLearningReading.text(body)
        let document = TryStudyDocument(reading)
        XCTAssertEqual(document.title, "运行配置")
        XCTAssertEqual(document.sections.map(\.title), ["本节要点", "如何估算", "练习", "注意边界"])
        XCTAssertTrue(document.sections[0].isOverview)
        XCTAssertEqual(document.sections[1].preview, "先区分参数数量与每参数占用。")
        let blocks = TryStudyBlock.parse(document.sections[1].body)
        XCTAssertTrue(blocks.contains(.table([["版本", "理想基础数据量"], ["FP16", "14GB"], ["4bit", "3.5GB"]])))
        XCTAssertTrue(TryStudyBlock.parse(document.sections[2].body).contains(.code("## 代码里的标题应原样保留")))
        XCTAssertFalse(reading.contains("example.com"), "References have their own cards")
        XCTAssertTrue(body.contains("example.com"), "Stored sources must not be rewritten")
        XCTAssertTrue(reading.contains("14GB不是总运行内存。"), "Teaching after reference sections must remain")
    }

    func testPlainLessonsAndReferenceTitlesRemainReadable() {
        let body = "一个概念。\n\n一个例子。"
        let document = TryStudyDocument(TryLearningReading.text(body))
        XCTAssertNil(document.title)
        XCTAssertTrue(document.sections.isEmpty)
        XCTAssertEqual(document.introduction, body)
        let offline = "# 学习稿\n## 一个概念\n正文\n## 资料\n《计算机系统》纸质书，第三章。"
        XCTAssertTrue(TryLearningReading.text(offline).contains("纸质书"), "References without cards must remain accessible")
        let links = TryLearningResources.links(in: "- Hugging Face《缓存策略》：说明增长机制\nhttps://example.com/cache.md", source: "运行配置")
        XCTAssertEqual(links.first?.title, "Hugging Face《缓存策略》")
    }

}
