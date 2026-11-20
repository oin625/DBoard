import XCTest
@testable import DBoard

final class GitHubTrendingDailyTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date = Date()) { self.date = date }
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return date }
        func advanceDay() {
            lock.lock(); defer { lock.unlock() }
            date = Calendar.current.date(byAdding: .day, value: 1, to: date)!
        }
    }
    private actor Probe {
        private(set) var fetched: [GitHubTrendingPeriod] = []
        private(set) var summarized: [String] = []
        let fail: Bool
        init(fail: Bool = false) { self.fail = fail }
        func fetch(_ period: GitHubTrendingPeriod) throws -> [GitHubTrendingRepository] {
            fetched.append(period)
            if fail { throw GitHubTrendingParser.ReadError.invalidPage }
            return [GitHubTrendingRepository(rank: 1, name: "team/shared", originalDescription: "Build AI agents",
                language: "Python", stars: 8000, gainedStars: 600)]
        }
        func summarize(_ rows: [GitHubTrendingRepository]) -> [String: GitHubProjectIntroduction] {
            summarized += rows.map(\.name)
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0.name, GitHubProjectIntroduction(sourceDescription: $0.originalDescription,
                    summary: "用于构建 AI Agent。", useCase: ""))
            })
        }
    }
    private func repository(_ name: String = "team/cached", description: String = "Build AI agents") -> GitHubTrendingRepository {
        GitHubTrendingRepository(rank: 1, name: name, originalDescription: description,
            language: "Python", stars: 8000, gainedStars: 600)
    }

    func testSameCalendarDayIsFreshEvenAfterSixHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let morning = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 1)))
        let snapshot = GitHubTrendingSnapshot(period: .weekly, fetchedAt: morning, repositories: [repository()])
        XCTAssertTrue(snapshot.isFresh(at: morning.addingTimeInterval(18 * 3600)))
        XCTAssertFalse(snapshot.isFresh(at: calendar.date(byAdding: .day, value: 1, to: morning)!))
    }

    @MainActor
    func testStaleOrIncompleteCacheOpensRepeatedlyWithoutFetchingOrTranslating() async {
        let cache = GitHubTrendingCache(url: nil)
        let row = repository()
        for period in GitHubTrendingPeriod.allCases {
            cache.save(GitHubTrendingSnapshot(period: period, fetchedAt: Date().addingTimeInterval(-48 * 3600), repositories: [row]))
        }
        let vm = GitHubTrendingViewModel(cache: cache, fetcher: { _ in
            XCTFail("Opening cached rankings must not start a request"); return []
        }, summarizer: { _ in
            XCTFail("Opening an incomplete cache must not restart translation"); return [:]
        })
        vm.load()
        vm.cancel()
        vm.load()
        vm.select(.daily)
        vm.select(.monthly)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(vm.repositories, [row])
        XCTAssertFalse(vm.loading)
        XCTAssertFalse(vm.summarizing)
        XCTAssertFalse(vm.refreshing)
        vm.cancel()
    }

    @MainActor
    func testDailyRoundPreparesAllTabsDeduplicatesIntroductionsAndSurvivesRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("github.json")
        let cache = GitHubTrendingCache(url: url)
        let probe = Probe()
        let clock = Clock()
        let updater = GitHubTrendingDailyUpdater(cache: cache, now: { clock.read() },
            fetcher: { try await probe.fetch($0) }, summarizer: { await probe.summarize($0) })
        defer { updater.stop() }
        updater.refreshAllIfNeeded()
        updater.refreshAllIfNeeded() // wake/activation while a round is already queued
        await updater.waitUntilFinished()
        var fetched = await probe.fetched
        var summarized = await probe.summarized
        XCTAssertEqual(fetched, [.weekly, .daily, .monthly])
        XCTAssertEqual(summarized, ["team/shared"])
        for period in GitHubTrendingPeriod.allCases {
            XCTAssertEqual(cache.snapshot(period)?.period, period)
            XCTAssertFalse(cache.needsDailyUpdate(period, at: clock.read()))
        }
        updater.refreshAllIfNeeded()
        await updater.waitUntilFinished()
        fetched = await probe.fetched
        XCTAssertEqual(fetched.count, 3)

        let relaunched = GitHubTrendingDailyUpdater(cache: GitHubTrendingCache(url: url), now: { clock.read() },
            fetcher: { try await probe.fetch($0) }, summarizer: { await probe.summarize($0) })
        defer { relaunched.stop() }
        relaunched.refreshAllIfNeeded()
        await relaunched.waitUntilFinished()
        fetched = await probe.fetched
        XCTAssertEqual(fetched.count, 3, "Restarting the app on the same day must not repeat requests")

        clock.advanceDay()
        relaunched.refreshAllIfNeeded()
        await relaunched.waitUntilFinished()
        fetched = await probe.fetched
        summarized = await probe.summarized
        XCTAssertEqual(fetched.count, 6)
        XCTAssertEqual(summarized, ["team/shared"], "Unchanged descriptions reuse their Chinese introduction tomorrow")
    }

    @MainActor
    func testFailedAutomaticRoundDoesNotRetryOnOpeningButManualRefreshStillWorks() async {
        let cache = GitHubTrendingCache(url: nil)
        let row = repository(description: "已保存的中文简介")
        cache.save(GitHubTrendingSnapshot(period: .weekly, fetchedAt: Date().addingTimeInterval(-48 * 3600), repositories: [row]))
        let probe = Probe(fail: true)
        let updater = GitHubTrendingDailyUpdater(cache: cache, fetcher: { try await probe.fetch($0) },
            summarizer: { await probe.summarize($0) })
        defer { updater.stop() }
        updater.refreshAllIfNeeded()
        await updater.waitUntilFinished()
        updater.refreshAllIfNeeded()
        await updater.waitUntilFinished()
        let vm = GitHubTrendingViewModel(cache: cache, updater: updater)
        vm.load()
        vm.select(.daily) // empty cache after a failed daily attempt should not loop on reopening
        vm.select(.weekly)
        await updater.waitUntilFinished()
        var fetched = await probe.fetched
        XCTAssertEqual(fetched.count, 3)
        XCTAssertEqual(vm.repositories, [row])
        XCTAssertFalse(vm.loading)
        XCTAssertNotNil(vm.error)
        vm.load(force: true)
        await updater.waitUntilFinished()
        fetched = await probe.fetched
        XCTAssertEqual(fetched.count, 4)
        XCTAssertEqual(fetched.last, .weekly)
        XCTAssertEqual(cache.snapshot(.weekly)?.repositories, [row])
        vm.cancel()
    }

    @MainActor
    func testClosingTheWindowDoesNotCancelItsBackgroundUpdate() async {
        let cache = GitHubTrendingCache(url: nil)
        let old = repository(description: "旧的中文简介")
        let fresh = repository("team/new", description: "新的中文简介")
        cache.save(GitHubTrendingSnapshot(period: .weekly, fetchedAt: Date(), repositories: [old]))
        let updater = GitHubTrendingDailyUpdater(cache: cache, fetcher: { _ in
            try await Task.sleep(nanoseconds: 120_000_000)
            return [fresh]
        }, summarizer: { _ in XCTFail("Chinese descriptions need no translation"); return [:] })
        defer { updater.stop() }
        let vm = GitHubTrendingViewModel(cache: cache, updater: updater)
        vm.load(force: true)
        vm.cancel()
        await updater.waitUntilFinished()
        XCTAssertEqual(cache.snapshot(.weekly)?.repositories, [fresh])
        vm.load()
        XCTAssertEqual(vm.repositories, [fresh])
        XCTAssertFalse(vm.loading)
        XCTAssertFalse(vm.summarizing)
        vm.cancel()
    }

    func testLegacyCacheWithoutDailyMarkersIsKept() throws {
        struct LegacyPayload: Codable {
            let snapshots: [String: GitHubTrendingSnapshot]
            let introductions: [String: GitHubProjectIntroduction]
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.json")
        let row = repository()
        let legacy = LegacyPayload(snapshots: ["weekly": GitHubTrendingSnapshot(period: .weekly,
            fetchedAt: Date(), repositories: [row])], introductions: [row.name: GitHubProjectIntroduction(
                sourceDescription: row.originalDescription, summary: "缓存里的中文介绍。", useCase: "")])
        try JSONEncoder().encode(legacy).write(to: url)
        let cache = GitHubTrendingCache(url: url)
        XCTAssertEqual(cache.snapshot(.weekly)?.repositories, [row])
        XCTAssertEqual(cache.introduction(row)?.summary, "缓存里的中文介绍。")
        XCTAssertTrue(cache.needsDailyUpdate(.weekly, at: Date()))
    }
}
