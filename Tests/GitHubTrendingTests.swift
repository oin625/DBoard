import XCTest
import AppKit
@testable import DBoard

final class GitHubTrendingTests: XCTestCase {
    private func row(_ name: String = "team/tool", rank: Int = 1, description: String = "Build AI agents") -> GitHubTrendingRepository {
        GitHubTrendingRepository(rank: rank, name: name, originalDescription: description,
            language: "Python", stars: 8000, gainedStars: 600)
    }

    private let fixture = """
    <article class="Box-row"><div><a href="/login?return_to=team/tool">Star</a></div>
      <h2 class="h3"><a class="Link" href="/team/tool"><svg><path d="0"/></svg>team / tool</a></h2>
      <p class="col-9">Build &quot;AI&quot; agents &amp; workflows &#x2014; fast.</p>
      <span itemprop="programmingLanguage">Python</span>
      <a href="/team/tool/stargazers"><svg><path d="000"/></svg>8,001</a>
      <span>1,234 stars this week</span>
    </article>
    <article class="Box-row"><h2><a href="/owner/library">owner/library</a></h2>
      <p>中文项目简介</p><span>25 stars this week</span>
    </article>
    """

    func testOfficialRankingDescriptionAndSeparateStarCounts() throws {
        let rows = try GitHubTrendingParser.repositories(from: fixture)
        XCTAssertEqual(rows.map(\.rank), [1, 2])
        XCTAssertEqual(rows.map(\.name), ["team/tool", "owner/library"])
        XCTAssertEqual(rows[0].originalDescription, "Build \"AI\" agents & workflows — fast.")
        XCTAssertEqual(rows[0].language, "Python")
        XCTAssertEqual(rows[0].stars, 8001)
        XCTAssertEqual(rows[0].gainedStars, 1234)
        XCTAssertEqual(rows[0].url.absoluteString, "https://github.com/team/tool")
        XCTAssertNil(rows[1].language)
        XCTAssertNil(rows[1].stars, "Missing stats must not be invented as zero")
        XCTAssertEqual(rows[1].gainedStars, 25)
        XCTAssertEqual(GitHubTrendingParser.count("1.2k"), 1200)
        XCTAssertNil(GitHubTrendingParser.count("unknown"))
    }

    func testInvalidPagesAndDuplicateOrExternalRepositoriesAreRejected() {
        XCTAssertThrowsError(try GitHubTrendingParser.repositories(from: "<h1>Sign in</h1>"))
        XCTAssertThrowsError(try GitHubTrendingParser.repositories(from: fixture + fixture))
        XCTAssertThrowsError(try GitHubTrendingParser.repositories(from:
            #"<article class="Box-row"><h2><a href="https://other.example/team/tool">tool</a></h2></article>"#))
    }

    func testChineseIntroductionsMapToSourceAndNeverAcceptEnglishOrUnknownProjects() throws {
        let input = [row(), row("other/lib", rank: 2)]
        let output = """
        JSON result:
        {"items":[
          {"name":"team/tool","summary":"用于构建 AI Agent 的工具。","useCase":"适合搭建自动化流程。"},
          {"name":"other/lib","summary":"English only","useCase":""},
          {"name":"invented/repo","summary":"这个项目不存在。","useCase":""}
        ]}
        end
        """
        let introductions = try GitHubTrendingService.decodeIntroductions(output, for: input)
        XCTAssertEqual(Set(introductions.keys), ["team/tool"])
        XCTAssertEqual(introductions["team/tool"]?.sourceDescription, "Build AI agents")
        XCTAssertThrowsError(try GitHubTrendingService.decodeIntroductions("Not logged in", for: input))
        XCTAssertThrowsError(try GitHubTrendingService.decodeIntroductions(
            #"{"items":[{"name":"team/tool","summary":"English","useCase":""}]}"#, for: input))
    }

    func testCacheIsReusableAcrossPeriodsButDescriptionChangesInvalidateIntroduction() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trending.json")
        let cache = GitHubTrendingCache(url: url)
        let repository = row()
        let snapshot = GitHubTrendingSnapshot(period: .weekly, fetchedAt: Date(), repositories: [repository])
        cache.save(snapshot)
        cache.save([repository.name: GitHubProjectIntroduction(sourceDescription: repository.originalDescription,
            summary: "构建 AI Agent 的工具。", useCase: "")])
        let restored = GitHubTrendingCache(url: url)
        XCTAssertEqual(restored.snapshot(.weekly)?.repositories, [repository])
        XCTAssertNotNil(restored.introduction(repository))
        XCTAssertNil(restored.introduction(row(description: "The project has changed")))
        XCTAssertTrue(snapshot.isFresh())
        XCTAssertFalse(snapshot.isFresh(at: Calendar.current.date(byAdding: .day, value: 1, to: snapshot.fetchedAt)!))
        XCTAssertFalse(snapshot.isFresh(at: snapshot.fetchedAt.addingTimeInterval(-1)))
        XCTAssertEqual(GitHubTrendingPeriod.monthly.url.absoluteString, "https://github.com/trending?since=monthly")
    }

    @MainActor
    func testWarmCacheShowsImmediatelyAndDoesNotRepeatNetworkOrAI() async {
        let cache = GitHubTrendingCache(url: nil)
        let repository = row()
        cache.save(GitHubTrendingSnapshot(period: .weekly, fetchedAt: Date(), repositories: [repository]))
        cache.save([repository.name: GitHubProjectIntroduction(sourceDescription: repository.originalDescription,
            summary: "构建 AI Agent。", useCase: "")])
        let vm = GitHubTrendingViewModel(cache: cache, fetcher: { _ in
            XCTFail("A fresh cache must not request GitHub again"); return []
        }, summarizer: { _ in
            XCTFail("A cached introduction must not invoke AI again"); return [:]
        })
        vm.load()
        XCTAssertEqual(vm.repositories, [repository])
        XCTAssertFalse(vm.loading)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(vm.introductions[repository.name]?.summary, "构建 AI Agent。")
        vm.cancel()
    }

    @MainActor
    func testFailedRefreshKeepsLastRankingAndFailedSummaryDoesNotExposeEnglish() async {
        let cache = GitHubTrendingCache(url: nil)
        let repository = row()
        cache.save(GitHubTrendingSnapshot(period: .weekly,
            fetchedAt: Date().addingTimeInterval(-24 * 3600), repositories: [repository]))
        let vm = GitHubTrendingViewModel(cache: cache, fetcher: { _ in
            throw GitHubTrendingParser.ReadError.invalidPage
        }, summarizer: { _ in
            throw DBoardLogAIClient.ClientError.missingToken
        })
        vm.load(force: true)
        XCTAssertEqual(vm.repositories, [repository])
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(vm.repositories, [repository])
        XCTAssertNotNil(vm.error)
        XCTAssertNotNil(vm.introductionError)
        XCTAssertTrue(vm.introductions.isEmpty)
        XCTAssertFalse(vm.loading)
        XCTAssertFalse(vm.summarizing)
        vm.cancel()
    }

    @MainActor
    func testSlowPreviousPeriodCannotOverwriteNewSelectionOrCache() async {
        let daily = row("daily/tool")
        let monthly = row("monthly/tool")
        let vm = GitHubTrendingViewModel(cache: GitHubTrendingCache(url: nil), fetcher: { period in
            if period == .daily {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { continuation.resume() }
                }
                return [daily]
            }
            return [monthly]
        }, summarizer: { rows in
            Dictionary(uniqueKeysWithValues: rows.map {
                ($0.name, GitHubProjectIntroduction(sourceDescription: $0.originalDescription, summary: "中文项目简介。", useCase: ""))
            })
        })
        vm.select(.daily)
        try? await Task.sleep(nanoseconds: 20_000_000)
        vm.select(.monthly)
        try? await Task.sleep(nanoseconds: 220_000_000)
        XCTAssertEqual(vm.period, .monthly)
        XCTAssertEqual(vm.repositories.map(\.name), [monthly.name])
        XCTAssertNil(vm.introductions[daily.name])
        XCTAssertFalse(vm.loading)
        vm.cancel()
    }

    func testOldNewsFavoritesMigrateAndTheOldModuleIsRetired() {
        let name = "GitHubMigration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["techscout", "logs"], forKey: "workspace.favorites")
        defaults.set(["techscout"], forKey: "workspace.recentModules")
        defaults.set(["techscout"], forKey: "workspace.pinnedWindows")
        let workspace = WorkspacePreferences(defaults: defaults)
        XCTAssertEqual(workspace.favorites, ["githubtrending", "logs"])
        XCTAssertEqual(workspace.recentModules, ["githubtrending"])
        XCTAssertEqual(workspace.pinnedWindows, ["githubtrending"])
        XCTAssertFalse(DBoardModule.all.contains { $0.id == "techscout" })
        XCTAssertTrue(DBoardModule.all.contains { $0.id == "githubtrending" && $0.searchText.contains("热门") })
    }

    private actor TemporaryFailure {
        private(set) var attempts = 0
        func summarize(_ rows: [GitHubTrendingRepository]) throws -> [String: GitHubProjectIntroduction] {
            attempts += 1
            if attempts == 1 { throw DBoardLogAIClient.ClientError.server("temporary") }
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0.name, GitHubProjectIntroduction(sourceDescription: $0.originalDescription, summary: "构建 AI Agent 的工具。", useCase: ""))
            })
        }
    }

    @MainActor
    func testTransientSummaryFailureRetriesOnceAndCachesSuccess() async {
        let failure = TemporaryFailure()
        let repository = row()
        let cache = GitHubTrendingCache(url: nil)
        cache.save(GitHubTrendingSnapshot(period: .weekly, fetchedAt: Date(), repositories: [repository]))
        let vm = GitHubTrendingViewModel(cache: cache,
            fetcher: { _ in [repository] },
            summarizer: { try await failure.summarize($0) })
        vm.load(force: true)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let attempts = await failure.attempts
        XCTAssertEqual(attempts, 2)
        XCTAssertNotNil(vm.introductions[repository.name])
        XCTAssertNil(vm.introductionError)
        vm.load()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let finalAttempts = await failure.attempts
        XCTAssertEqual(finalAttempts, 2, "Reopening must reuse the successful introduction")
        vm.cancel()
    }

    @MainActor
    func testWindowKeepsTwoColumnSizeAfterHostingLayout() async throws {
        _ = NSApplication.shared
        let cache = GitHubTrendingCache(url: nil)
        let rows = [row("GoogleChrome/modern-web-guidance-src", description: "给编码代理提供最新 Web 开发最佳实践。"),
                    row("backnotprop/plannotator", rank: 2, description: "用可视化工作区完成规划、代码审查和协作。")]
        cache.save(GitHubTrendingSnapshot(period: .weekly, fetchedAt: Date(), repositories: rows))
        let vm = GitHubTrendingViewModel(cache: cache, fetcher: { _ in XCTFail("Cached window must not fetch"); return [] },
            summarizer: { _ in XCTFail("Native Chinese descriptions need no translation"); return [:] })
        let controller = GitHubTrendingWindowController(viewModel: vm, activates: false)
        controller.show()
        let window = try XCTUnwrap(controller.window)
        defer { window.close(); vm.cancel() }
        try? await Task.sleep(nanoseconds: 150_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(window.frame.width, 800)
        XCTAssertGreaterThanOrEqual(window.frame.height, 650)
        XCTAssertEqual(vm.repositories.count, 2)
        if let path = ProcessInfo.processInfo.environment["DBOARD_CAPTURE_GITHUB"],
           let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    func testLiveOfficialWeeklyRankingAndChineseIntroduction() async throws {
        guard ProcessInfo.processInfo.environment["DBOARD_VERIFY_GITHUB"] == "1" else {
            throw XCTSkip("Live public-network verification is opt-in")
        }
        let rows = try await GitHubTrendingService.fetch(.weekly)
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertEqual(rows[0].rank, 1)
        let batch = Array(rows.filter { !$0.originalDescription.isEmpty }.prefix(3))
        let introductions = try await GitHubTrendingService.introductions(batch)
        XCTAssertEqual(introductions.count, batch.count)
        for row in batch {
            let introduction = try XCTUnwrap(introductions[row.name])
            XCTAssertTrue(GitHubTrendingParser.containsChinese(introduction.summary))
            print("GitHub #\(row.rank) \(row.name): \(introduction.summary)")
        }
    }
}
