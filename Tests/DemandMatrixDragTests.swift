import XCTest
@testable import DBoard

final class DemandMatrixDragTests: XCTestCase {
    private var directory: URL!
    private var cache: URL!
    private let source = """
    ## 🔴 重要且紧急
    ## 🟡 重要
    ### D881【ultra】拖拽测试 #进行中
    - **描述**：保留完整上下文
    - **咒言**：
        原有输入和图片线索
    - **进度**：
        - 11.4: 等待联调
    ## 🟠 紧急
    ### D882【audi】其他需求 #待开始
    - **描述**：其他需求不可改变
    ## 🟢 不紧急不重要
    ### D883【ultra】已完成 #已完成
    - **描述**：完成记录
    """

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardMatrixDrag-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = directory.appendingPathComponent("cache.md")
        try source.write(to: cache, atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMovingAcrossAllQuadrantsPersistsPriorityAndPreservesFullContext() throws {
        let original = try DItemStore.currentItem(id: "D881", at: cache)
        let other = try DItemStore.currentItem(id: "D882", at: cache)
        var oldPriority = ItemPriority.p1
        for priority in [ItemPriority.p0, .p2, .p3, .p1] {
            XCTAssertTrue(DItemStore.setPriority(id: "D881", priority, at: cache, expectedPriority: oldPriority))
            let current = try DItemStore.currentItem(id: "D881", at: cache)
            XCTAssertEqual(current.priority, priority)
            XCTAssertEqual(current.status, original.status)
            XCTAssertEqual(current.prompt, original.prompt)
            XCTAssertEqual(current.title, original.title)
            let parsed = CacheParser.parse(content: try String(contentsOf: cache, encoding: .utf8)).items
            XCTAssertEqual(parsed.filter { $0.id == "D881" }.count, 1)
            XCTAssertEqual(DemandMatrix.items(parsed, in: priority).filter { $0.id == "D881" }.count, 1)
            XCTAssertEqual(try DItemStore.currentItem(id: "D882", at: cache).priority, other.priority)
            oldPriority = priority
        }
    }

    func testStaleDuplicateMissingAndCompletedDropsDoNotWrite() throws {
        XCTAssertTrue(DItemStore.setPriority(id: "D881", .p0, at: cache, expectedPriority: .p1))
        let before = try Data(contentsOf: cache)
        XCTAssertFalse(DItemStore.setPriority(id: "D881", .p2, at: cache, expectedPriority: .p1))
        XCTAssertFalse(DItemStore.setPriority(id: "D881", .p0, at: cache, expectedPriority: .p0))
        XCTAssertFalse(DItemStore.setPriority(id: "D999", .p2, at: cache, expectedPriority: .p1))
        XCTAssertFalse(DItemStore.setPriority(id: "D883", .p0, at: cache, expectedPriority: .p3))
        XCTAssertEqual(try Data(contentsOf: cache), before)
    }
}
