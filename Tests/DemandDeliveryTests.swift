import XCTest
@testable import DBoard

final class DemandDeliveryTests: XCTestCase {
    private let documentURL = "https://alidocs.dingtalk.com/i/nodes/test-document"

    private func item(project: String = "ultra", branch: String? = "feature/cdd-lock", milestones: [Milestone]? = nil) -> DItem {
        var value = DItem(id: "D900", project: project, title: "锁券链路调整", headerTitle: "锁券改造", status: .inProgress,
            priority: .p1, deadline: nil, branch: branch, startDate: nil,
            milestones: milestones ?? [Milestone(date: "11.3", content: "锁券改造已完成，待联调验收，尚未部署。")],
            reqFlow: ReqFlowLink(id: 42, no: "R42"), prompt: "要做什么：锁券移到开单之后")
        value.executionScope = String(repeating: "a", count: 64)
        var mappings: [DemandDeliveryProject] = []
        if let branch, branch.contains(":") {
            for entry in branch.components(separatedBy: "；") {
                let parts = entry.split(separator: ":", maxSplits: 1)
                if parts.count == 2 { mappings.append(DemandDeliveryProject(name: URL(fileURLWithPath: String(parts[0])).lastPathComponent, branch: String(parts[1]))) }
            }
        } else {
            mappings = [DemandDeliveryProject(name: project.hasPrefix("/") ? "ultra" : project, branch: branch ?? "")]
        }
        value.technicalPlan = DemandTechnicalPlan(title: "锁券改造 · 技术方案", markdown: "# 技术方案\n\n锁券移到开单后，聚合查券、锁券与照片查询；旧验券仅查券。",
            projects: mappings, scopeHash: value.executionScope, codeRevision: String(repeating: "b", count: 64),
            updatedAt: "2026-11-09T09:00:00Z", updatedBy: "ai")
        return value
    }
    private func plan(_ item: DItem? = nil) throws -> DemandDeliveryPlan {
        try DemandDeliveryPlan.make(item: item ?? self.item(), repositoryName: { _ in "ultra" })
    }
    private func temporary(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DBoardDeliveryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
    private func response(_ plan: DemandDeliveryPlan, present: Bool) throws -> DevelopmentDeliverables.Response {
        let rows: [[String: Any]] = present ? [["deliverableContent": documentURL,
            "deliverableDevProject": plan.projects.map(\.declaration).joined(separator: ",")]] : []
        return try DevelopmentDeliverables.decode(JSONSerialization.data(withJSONObject: ["success": true, "data": ["3": rows]]))
    }
    private func writeLinkedCache(for plan: DemandDeliveryPlan, in directory: URL) throws -> URL {
        let cache = directory.appendingPathComponent("cache.md")
        let content = "## 🟡 重要\n### \(plan.item.id)【ultra】锁券改造 #进行中\n- **需求流**：\(plan.link.markdown)\n"
        try content.write(to: cache, atomically: true, encoding: .utf8)
        return cache
    }

    func testMissingPlanAutomaticallyCopiesInstructionWithoutRemoteCalls() throws {
        try temporary { directory in
            let cache = directory.appendingPathComponent("cache.md")
            // No branch yet: preparing the missing plan should not require another click.
            let content = "## 🟡 重要\n### D900【ultra】最新需求标题 #进行中\n- **项目**：ultra\n- **需求流**：\(ReqFlowLink(id: 42, no: "R42").markdown)\n"
            try content.write(to: cache, atomically: true, encoding: .utf8)
            var copied: [String] = [], remoteCalls = 0
            let services = DemandDeliveryServices(generate: { _ in remoteCalls += 1; return "" },
                validate: { _ in remoteCalls += 1 }, findDocument: { _ in remoteCalls += 1; return nil },
                createDocument: { _, _ in remoteCalls += 1; return self.documentURL },
                verifyDocument: { _, _ in remoteCalls += 1 },
                listDeliverables: { _ in remoteCalls += 1; return try self.response(self.plan(), present: false) },
                submit: { _, _ in remoteCalls += 1 })
            let coordinator = DemandDeliveryCoordinator(
                workflow: DemandDeliveryWorkflow(store: DemandDeliveryStore(url: directory.appendingPathComponent("receipts.json")), services: services),
                cacheURL: cache, copyPlanInstruction: { copied.append($0); return true })
            let prepared = expectation(description: "Missing plan instruction copied")
            coordinator.prepare(id: "D900") { plan in
                XCTAssertNil(plan)
                prepared.fulfill()
            }
            wait(for: [prepared], timeout: 5)
            XCTAssertEqual(copied.count, 1)
            XCTAssertTrue(copied.first?.contains("D900") == true)
            XCTAssertTrue(copied.first?.contains("最新需求标题") == true)
            XCTAssertTrue(copied.first?.contains("--task technical-plan") == true)
            XCTAssertTrue(copied.first?.contains("--cache") == true)
            XCTAssertEqual(coordinator.states["D900"]?.message, "技术方案尚未准备，生成指令已复制，发给 AI 即可。")
            XCTAssertEqual(coordinator.states["D900"]?.running, false)
            XCTAssertEqual(remoteCalls, 0)
            XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), content)
        }
    }

    func testFailedClipboardWriteDoesNotClaimInstructionWasCopied() throws {
        try temporary { directory in
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n### D900【ultra】缺少方案 #进行中\n".write(to: cache, atomically: true, encoding: .utf8)
            let coordinator = DemandDeliveryCoordinator(cacheURL: cache, copyPlanInstruction: { _ in false })
            let prepared = expectation(description: "Clipboard failure reported")
            coordinator.prepare(id: "D900") { plan in
                XCTAssertNil(plan)
                prepared.fulfill()
            }
            wait(for: [prepared], timeout: 5)
            XCTAssertTrue(coordinator.states["D900"]?.message.contains("复制指令失败") == true)
            XCTAssertFalse(coordinator.states["D900"]?.message.contains("已复制") == true)
            XCTAssertEqual(coordinator.states["D900"]?.running, false)
        }
    }

    func testUnreadablePlanDoesNotOverwriteClipboard() throws {
        try temporary { directory in
            let cache = directory.appendingPathComponent("cache.md")
            try ("## 🟡 重要\n### D900【ultra】损坏方案 #进行中\n- **项目**：ultra\n- **分支**：feature/cdd-lock\n- **需求流**：\(ReqFlowLink(id: 42, no: "R42").markdown)\n" +
                DemandTechnicalPlan.prefix + "bad -->\n").write(to: cache, atomically: true, encoding: .utf8)
            let latest = try DItemStore.currentItem(id: "D900", at: cache)
            XCTAssertEqual(latest.reqFlow, ReqFlowLink(id: 42, no: "R42"))
            XCTAssertNotNil(latest.technicalPlanReadError)
            var copied = 0
            let coordinator = DemandDeliveryCoordinator(cacheURL: cache, copyPlanInstruction: { _ in copied += 1; return true })
            let prepared = expectation(description: "Other error preserved")
            coordinator.prepare(id: "D900") { plan in
                XCTAssertNil(plan)
                prepared.fulfill()
            }
            wait(for: [prepared], timeout: 5)
            XCTAssertEqual(copied, 0)
            XCTAssertFalse(coordinator.states["D900"]?.message.isEmpty ?? true)
            XCTAssertEqual(coordinator.states["D900"]?.failed, true)
        }
    }

    func testRequiresExplicitLinkedDemandAndBranches() throws {
        var value = item()
        value.reqFlow = nil
        XCTAssertThrowsError(try plan(value))
        XCTAssertThrowsError(try plan(item(branch: nil)))
        XCTAssertThrowsError(try plan(item(branch: "待定")))
        XCTAssertThrowsError(try plan(item(project: "ultra；tesla", branch: "feature/common")))
        XCTAssertThrowsError(try plan(item(project: "", branch: "feature/a")))
        XCTAssertThrowsError(try plan(item(branch: "feature/a,other")))
    }

    func testMapsEachRepositoryToItsOwnExplicitBranchAndRejectsPartialMappings() throws {
        let value = item(project: "ultra；tesla", branch: "/work/ultra:feature/cdd；/work/tesla:feature/saas")
        let plan = try DemandDeliveryPlan.make(item: value, repositoryName: { URL(fileURLWithPath: $0).lastPathComponent })
        XCTAssertEqual(plan.projects, [
            DemandDeliveryProject(name: "ultra", branch: "feature/cdd"),
            DemandDeliveryProject(name: "tesla", branch: "feature/saas")
        ])
        XCTAssertThrowsError(try self.plan(item(project: "ultra；tesla", branch: "ultra:feature/cdd")))
        XCTAssertThrowsError(try self.plan(item(project: "ultra", branch: "ultra:feature/a；ultra:feature/b")))
    }

    func testManualBranchOverridesOldMetadataAndWorktreeNameComesFromGit() throws {
        let old = [DemandVersion.Repository(path: "/work/ultra", branch: "feature/old")]
        let manual = try DemandDeliveryPlan.make(item: item(branch: "feature/new"), repositories: old,
            repositoryName: { _ in "ultra" })
        XCTAssertEqual(manual.projects.first?.branch, "feature/new")
        let worktree = try DemandDeliveryPlan.make(item: item(project: "/work/ultra-tmp-branch"),
            repositoryName: { _ in "ultra" })
        XCTAssertEqual(worktree.projects.first?.name, "ultra")
        XCTAssertThrowsError(try DemandDeliveryPlan.make(item: item(project: "tesla"), repositories: old,
            repositoryName: { _ in "ultra" }))
    }

    func testIntegrationBranchesAreRejectedBeforePreparingDelivery() throws {
        for branch in ["merge/pre_1013", "integration/pre", "MERGE/pre"] {
            XCTAssertThrowsError(try plan(item(branch: branch))) { error in
                XCTAssertTrue(error.localizedDescription.contains("合并分支"))
            }
            XCTAssertThrowsError(try plan(item(branch: "ultra:" + branch + "；audi:feature/vibe")))
        }
        XCTAssertEqual(try plan(item(branch: "feature/cdd-lock-code")).projects.first?.branch, "feature/cdd-lock-code")
        XCTAssertEqual(try plan(item(branch: "hotfix/cdd-serialization")).projects.first?.branch, "hotfix/cdd-serialization")
        XCTAssertEqual(try plan(item(branch: "custom/cdd")).projects.first?.branch, "custom/cdd")
    }

    func testPreparedDocumentIsUsedExactlyAndProgressDoesNotRegenerateIt() throws {
        let original = try plan()
        var value = item(milestones: item().milestones + [Milestone(date: "11.9", content: "旧CR", details: "旧实现流水与日志不得拼入技术方案")])
        XCTAssertEqual(try plan(value).key, original.key)
        XCTAssertEqual(try plan(value).document(), value.technicalPlan?.markdown)
        value.technicalPlan?.markdown += "\n\n新增兼容说明"
        XCTAssertNotEqual(try plan(value).key, original.key)
    }

    func testMissingStaleOrEnvironmentPlanCannotPrepareDelivery() throws {
        var value = item()
        value.technicalPlan = nil
        XCTAssertThrowsError(try plan(value))
        value = item()
        value.technicalPlan?.scopeHash = String(repeating: "c", count: 64)
        XCTAssertThrowsError(try plan(value))
        value = item()
        value.technicalPlan?.projects = [DemandDeliveryProject(name: "ultra", branch: "feature/old")]
        XCTAssertThrowsError(try plan(value))
        value = item(branch: "feature/D019-pre")
        value.environmentRepositories = [.init(path: "/work/ultra-pre", branch: "feature/D019-pre", role: "integration")]
        XCTAssertThrowsError(try plan(value))
    }

    func testSuccessAndRepeatedClicksReuseDocumentAndDoNotAppendAgain() throws {
        try temporary { directory in
            let plan = try self.plan()
            let cache = try writeLinkedCache(for: plan, in: directory)
            var created = 0, submitted = 0, generatedCount = 0, present = false
            let services = DemandDeliveryServices(generate: { _ in generatedCount += 1; return plan.document() },
                validate: { _ in }, findDocument: { _ in nil },
                createDocument: { _, _ in created += 1; return self.documentURL }, verifyDocument: { _, _ in },
                listDeliverables: { _ in try self.response(plan, present: present) },
                submit: { _, _ in submitted += 1; present = true })
            let url = directory.appendingPathComponent("receipts.json")
            let store = DemandDeliveryStore(url: url)
            let workflow = DemandDeliveryWorkflow(store: store, services: services)
            let receipt = try workflow.run(plan, cacheURL: cache, stillCurrent: { true })
            XCTAssertTrue(receipt.confirmed)
            XCTAssertTrue(receipt.progressRecorded)
            let restarted = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: url), services: services)
            XCTAssertTrue(try restarted.run(plan, cacheURL: cache, stillCurrent: { true }).progressRecorded)
            XCTAssertEqual(created, 1); XCTAssertEqual(submitted, 1); XCTAssertEqual(generatedCount, 1)
            let latest = try DItemStore.currentRecord(id: plan.item.id, at: cache)
            XCTAssertEqual(latest.milestones.map(\.content), [DemandDeliveryPlan.feedbackSummary])
            XCTAssertEqual(latest.milestones.first?.details,
                "技术说明：\(documentURL)\n工程与分支：ultra:feature/cdd-lock\n仅提交开发交付物，需求状态未改变。")
        }
    }

    func testConcurrentWorkflowUsingSameStoreFailsBusyBeforeServiceCalls() throws {
        try temporary { directory in
            let plan = try self.plan()
            let otherPlan = try self.plan(item(branch: "feature/other"))
            XCTAssertNotEqual(plan.key, otherPlan.key)
            let cache = try writeLinkedCache(for: plan, in: directory)
            let url = directory.appendingPathComponent("receipts.json")
            var present = false, competingValidations = 0, submissions = 0
            var services = DemandDeliveryServices(generate: { $0.document() },
                validate: { _ in competingValidations += 1; throw DemandDeliveryError.message("意外进入远端校验") },
                findDocument: { _ in nil }, createDocument: { _, _ in self.documentURL }, verifyDocument: { _, _ in },
                listDeliverables: { _ in try self.response(plan, present: present) }, submit: { _, _ in })
            let competing = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: url), services: services)
            services.validate = { _ in }
            services.submit = { _, _ in
                submissions += 1
                // A separate workflow opens the same lock while this one is submitting.
                XCTAssertThrowsError(try competing.run(otherPlan, cacheURL: cache, stillCurrent: { true })) { error in
                    XCTAssertEqual(error.localizedDescription, "另一个开发交付正在处理，请稍后重试。")
                }
                present = true
            }
            let store = DemandDeliveryStore(url: url)
            let workflow = DemandDeliveryWorkflow(store: store, services: services)
            XCTAssertTrue(try workflow.run(plan, cacheURL: cache, stillCurrent: { true }).progressRecorded)
            XCTAssertEqual(competingValidations, 0)
            XCTAssertEqual(submissions, 1)
            XCTAssertEqual(Set(try store.read().keys), [plan.key])
        }
    }

    func testRecoversProgressCheckpointFromEitherHistoricalFormat() throws {
        let plan = try self.plan(item(project: "ultra；tesla", branch: "ultra:feature/cdd；tesla:feature/saas"))
        let projects = plan.projects.reversed().map(\.declaration).joined(separator: "；")
        for details in ["技术说明：\(documentURL)\n工程与分支：\(projects)\n仅提交开发交付物，需求状态未改变。",
                        "技术方案：\(documentURL)\n开发分支：\(projects)"] {
            try temporary { directory in
                let cache = try writeLinkedCache(for: plan, in: directory)
                XCTAssertTrue(DItemStore.appendProgress(id: plan.item.id, text: DemandDeliveryPlan.feedbackSummary,
                    details: details, at: cache))
                let before = try Data(contentsOf: cache)
                let store = DemandDeliveryStore(url: directory.appendingPathComponent("receipts.json"))
                try store.save(DemandDeliveryReceipt(key: plan.key, itemID: plan.item.id, reqID: plan.link.id,
                    title: "已有交付", markdown: plan.document(), documentURL: documentURL, confirmed: true))
                let services = DemandDeliveryServices(generate: { _ in XCTFail("重复生成"); return plan.document() },
                    validate: { _ in }, findDocument: { _ in nil }, createDocument: { _, _ in XCTFail("重复创建"); return self.documentURL },
                    verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: true) },
                    submit: { _, _ in XCTFail("重复提交") })
                let workflow = DemandDeliveryWorkflow(store: store, services: services)
                XCTAssertTrue(try workflow.run(plan, cacheURL: cache, stillCurrent: { true }).progressRecorded)
                XCTAssertEqual(try store.read()[plan.key]?.progressRecorded, true)
                XCTAssertEqual(try Data(contentsOf: cache), before)
            }
        }
    }

    func testRejectedSubmissionRetainsDocumentAndCanRetryAfterLoginOrPermissionRecovery() throws {
        try temporary { directory in
            let plan = try self.plan()
            var created = 0, posts = 0, present = false
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in created += 1; return self.documentURL },
                verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: present) },
                submit: { _, _ in
                    posts += 1
                    if posts == 1 { throw DemandDeliverySubmissionRejected(message: "登录过期") }
                    present = true
                })
            let store = DemandDeliveryStore(url: directory.appendingPathComponent("receipts.json"))
            let workflow = DemandDeliveryWorkflow(store: store, services: services)
            XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { true }))
            XCTAssertEqual(try store.read()[plan.key]?.documentURL, documentURL)
            XCTAssertEqual(try store.read()[plan.key]?.submitting, false)
            XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
            XCTAssertEqual(created, 1); XCTAssertEqual(posts, 2)
        }
    }

    func testLostUploadResponseIsReconciledFromServerAfterRestartWithoutPostingAgain() throws {
        try temporary { directory in
            let plan = try self.plan()
            var posts = 0, present = false, created = 0
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in created += 1; return self.documentURL },
                verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: present) },
                submit: { _, _ in posts += 1; present = true; throw URLError(.timedOut) })
            let path = directory.appendingPathComponent("receipts.json")
            XCTAssertThrowsError(try DemandDeliveryWorkflow(store: DemandDeliveryStore(url: path), services: services)
                .run(plan, stillCurrent: { true }))
            let restarted = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: path), services: services)
            XCTAssertTrue(try restarted.run(plan, stillCurrent: { true }).confirmed)
            XCTAssertEqual(posts, 1); XCTAssertEqual(created, 1)
        }
    }

    func testUncertainUploadIsNeverBlindlyRepeated() throws {
        try temporary { directory in
            let plan = try self.plan()
            var posts = 0
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in self.documentURL }, verifyDocument: { _, _ in },
                listDeliverables: { _ in try self.response(plan, present: false) },
                submit: { _, _ in posts += 1; throw URLError(.timedOut) })
            let workflow = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: directory.appendingPathComponent("r.json")), services: services)
            XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { true }))
            XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { true }))
            XCTAssertEqual(posts, 1)
        }
    }

    func testLostDocumentResponseRecoversByExactTitleWithoutCreatingAgain() throws {
        try temporary { directory in
            let plan = try self.plan()
            var creates = 0, exists = false, present = false
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in exists ? self.documentURL : nil },
                createDocument: { _, _ in creates += 1; exists = true; throw URLError(.timedOut) },
                verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: present) },
                submit: { _, _ in present = true })
            let workflow = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: directory.appendingPathComponent("r.json")), services: services)
            XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { true }))
            XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
            XCTAssertEqual(creates, 1)
        }
    }

    func testChangedDemandStopsBeforeCreatingOrPosting() throws {
        try temporary { directory in
            let plan = try self.plan()
            var current = true, creates = 0, posts = 0
            let services = DemandDeliveryServices(generate: { _ in current = false; return plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in creates += 1; return self.documentURL },
                verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: false) },
                submit: { _, _ in posts += 1 })
            let workflow = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: directory.appendingPathComponent("r.json")), services: services)
            XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { current }))
            XCTAssertEqual(creates, 0); XCTAssertEqual(posts, 0)
        }
    }

    func testChangedDemandAfterDocumentCreationStopsSubmissionAndKeepsDocument() throws {
        try temporary { directory in
            let plan = try self.plan()
            var current = true, posts = 0
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in self.documentURL },
                verifyDocument: { _, _ in current = false }, listDeliverables: { _ in try self.response(plan, present: false) },
                submit: { _, _ in posts += 1 })
            let store = DemandDeliveryStore(url: directory.appendingPathComponent("r.json"))
            XCTAssertThrowsError(try DemandDeliveryWorkflow(store: store, services: services).run(plan, stillCurrent: { current }))
            XCTAssertEqual(try store.read()[plan.key]?.documentURL, documentURL)
            XCTAssertEqual(posts, 0)
        }
    }

    func testCheckpointWriteFailureAndCorruptLedgerPreventRemoteCreation() throws {
        try temporary { directory in
            let plan = try self.plan()
            var creates = 0
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in creates += 1; return self.documentURL },
                verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: false) }, submit: { _, _ in })
            let path = directory.appendingPathComponent("r.json")
            try Data("corrupt".utf8).write(to: path)
            XCTAssertThrowsError(try DemandDeliveryWorkflow(store: DemandDeliveryStore(url: path), services: services).run(plan, stillCurrent: { true }))
            let blocker = directory.appendingPathComponent("blocker")
            try Data("file".utf8).write(to: blocker)
            XCTAssertThrowsError(try DemandDeliveryWorkflow(store: DemandDeliveryStore(url: blocker.appendingPathComponent("r.json")), services: services).run(plan, stillCurrent: { true }))
            XCTAssertEqual(creates, 0)
        }
    }

    func testDifferentBranchesAndNonDevelopmentLinksDoNotCountAsSameDelivery() throws {
        let plan = try self.plan()
        let wrong = try DevelopmentDeliverables.decode(JSONSerialization.data(withJSONObject: ["success": true, "data": [
            "1": [["deliverableContent": documentURL, "deliverableDevProject": "ultra:feature/cdd-lock"]],
            "3": [["deliverableContent": documentURL, "deliverableDevProject": "ultra:feature/old"]]
        ]]))
        XCTAssertFalse(plan.matches(wrong, url: documentURL))
        XCTAssertTrue(plan.matches(try response(plan, present: true), url: documentURL))
    }
    func testExplicitlyRejectedDocumentCreationCanRetryWithoutBecomingPermanentlyUncertain() throws {
        try temporary { directory in
            let plan = try self.plan()
            var creates = 0, present = false
            let services = DemandDeliveryServices(generate: { _ in plan.document() }, validate: { _ in },
                findDocument: { _ in nil }, createDocument: { _, _ in
                    creates += 1
                    if creates == 1 { throw DemandDeliveryDocumentRejected(message: "登录过期，未创建") }
                    return self.documentURL
                }, verifyDocument: { _, _ in }, listDeliverables: { _ in try self.response(plan, present: present) },
                submit: { _, _ in present = true })
            let workflow = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: directory.appendingPathComponent("r.json")), services: services)
            XCTAssertThrowsError(try workflow.run(plan, stillCurrent: { true }))
            XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
            XCTAssertEqual(creates, 2)
        }
    }

    func testLoadChecksLiveCodeAndLatestSavedPlan() throws {
        try temporary { directory in
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            let draft = DItemDraft(from: item())
            XCTAssertTrue(DItemStore.create(draft, at: cache))
            XCTAssertThrowsError(try DemandDeliveryPlan.load(id: draft.id, at: cache, repositoryName: { _ in "ultra" }))
            XCTAssertTrue(DItemStore.mutate(at: cache) { lines in
                let range = DItemStore.blockRange(lines, id: draft.id)!
                var block = Array(lines[range])
                var document = self.item().technicalPlan!
                document.scopeHash = DemandExecution.scopeHash(block)
                try! DemandTechnicalPlan.set(&block, value: document)
                lines.replaceSubrange(range, with: block)
                return true
            })
            let plan = try DemandDeliveryPlan.load(id: draft.id, at: cache, repositoryName: { _ in "ultra" },
                codeRevision: { _ in String(repeating: "b", count: 64) })
            XCTAssertEqual(plan.projects.first?.branch, "feature/cdd-lock")
            XCTAssertThrowsError(try DemandDeliveryPlan.load(id: draft.id, at: cache, repositoryName: { _ in "ultra" },
                codeRevision: { _ in String(repeating: "c", count: 64) }))
        }
    }

    func testNewPlanReusesOwnedDocumentAndRefusesExternalEdits() throws {
        try temporary { directory in
            let first = try self.plan()
            let store = DemandDeliveryStore(url: directory.appendingPathComponent("r.json"))
            try store.save(DemandDeliveryReceipt(key: first.key, itemID: first.item.id, reqID: first.link.id,
                title: "旧技术交付", markdown: first.document(), documentURL: self.documentURL, confirmed: true))
            var value = self.item()
            value.technicalPlan?.markdown += "\n\n新方案正文"
            let next = try self.plan(value)
            var remote = first.document(), updates = 0, creates = 0, present = false
            let services = DemandDeliveryServices(generate: { $0.document() }, validate: { _ in }, findDocument: { _ in nil },
                createDocument: { _, _ in creates += 1; return self.documentURL },
                verifyDocument: { _, expected in XCTAssertEqual(remote, expected) },
                listDeliverables: { _ in try self.response(next, present: present) }, submit: { _, _ in present = true },
                readDocument: { _ in remote }, updateDocument: { _, markdown in updates += 1; remote = markdown })
            let flow = DemandDeliveryWorkflow(store: store, services: services)
            XCTAssertTrue(try flow.run(next, stillCurrent: { true }).confirmed)
            XCTAssertEqual(updates, 1); XCTAssertEqual(creates, 0)
            value.technicalPlan?.markdown += "\n\n再更新"
            let latest = try self.plan(value)
            remote = "别人修改的内容"
            XCTAssertThrowsError(try flow.run(latest, stillCurrent: { true }))
            XCTAssertEqual(updates, 1); XCTAssertEqual(remote, "别人修改的内容")
        }
    }

    func testDingtalkDocumentLinkUsesReturnedIdentifiersAndRejectsInvalidURLs() throws {
        XCTAssertEqual(try DemandDeliveryRemote.documentURL(["nodeId": "node123"]),
            "https://alidocs.dingtalk.com/i/nodes/node123")
        XCTAssertEqual(try DemandDeliveryRemote.documentURL(["docUrl": "https://alidocs.dingtalk.com/i/nodes/node123?utm_scene=team_space"]),
            "https://alidocs.dingtalk.com/i/nodes/node123")
        XCTAssertThrowsError(try DemandDeliveryRemote.documentURL(["docUrl": "https://example.com/test"]))
        XCTAssertThrowsError(try DemandDeliveryRemote.documentURL(["nodeId": "bad/path"]))
    }

}
