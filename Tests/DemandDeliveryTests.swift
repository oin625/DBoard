import XCTest
@testable import DBoard

final class DemandDeliveryTests: XCTestCase {
    private let documentURL = "https://alidocs.dingtalk.com/i/nodes/test-document"

    private func item(project: String = "ultra", branch: String? = "feature/cdd-lock", milestones: [Milestone]? = nil) -> DItem {
        DItem(id: "D900", project: project, title: "锁券链路调整", headerTitle: "锁券改造", status: .inProgress,
            priority: .p1, deadline: nil, branch: branch, startDate: nil,
            milestones: milestones ?? [Milestone(date: "11.3", content: "锁券改造已完成，待联调验收，尚未部署。")],
            reqFlow: ReqFlowLink(id: 42, no: "R42"), prompt: "要做什么：锁券移到开单之后")
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

    func testFingerprintIgnoresItsOwnReceiptButTracksRealDevelopmentChanges() throws {
        let original = try plan()
        let records = item().milestones + [Milestone(date: "11.3", content: DemandDeliveryPlan.feedbackSummary,
            details: "技术说明：" + documentURL)]
        XCTAssertEqual(try plan(item(milestones: records)).key, original.key)
        XCTAssertNotEqual(try plan(item(milestones: records + [Milestone(date: "11.3", content: "上游联调通过，待验收。")])).key, original.key)
        XCTAssertNotEqual(try plan(item(branch: "feature/new")).key, original.key)
    }

    func testDocumentKeepsActualProgressAndDoesNotInventVerification() throws {
        let plan = try self.plan()
        let text = plan.document()
        XCTAssertTrue(text.contains("待联调验收，尚未部署"))
        XCTAssertTrue(text.contains("ultra：`feature/cdd-lock`"))
        XCTAssertTrue(text.contains("提交交付物不代表验收或上线"))
        XCTAssertFalse(text.contains("## 代码入口"))
        XCTAssertLessThan(text.count, 1000)
        let unverified = try self.plan(item(milestones: []))
        XCTAssertTrue(unverified.document().contains("完成情况待确认"))
    }


    func testDeliveryReadsCompleteDetailsIncludingParametersAndExceptionAtTheEnd() throws {
        let detail = "新增独立接口，接收验券流水号和券码，完成归属校验后调用三方服务。" +
            "同一流水的请求需要校验商品、价格、税点和使用条件，任何不一致都不能更新券码。" +
            "成功仅返回needImageSlots和imageSlots，失败区分LOCK_FAILED、LOCK_RESULT_UNKNOWN、PHOTO_QUERY_FAILED，不自动重试。"
        let text = try plan(item(milestones: [Milestone(date: "11.3",
            content: "接口开发完成，待验收。", details: detail)])).document()
        XCTAssertTrue(text.contains("接收验券流水号和券码"))
        XCTAssertTrue(text.contains("任何不一致都不能更新券码"))
        XCTAssertTrue(text.contains("PHOTO_QUERY_FAILED，不自动重试。"))
        XCTAssertFalse(text.contains("…"))
        XCTAssertTrue(text.contains("。\n\n- "))
    }

    func testEveryChangeUsesLatestImplementationInsteadOfObsoleteOriginalPlanOrOldBlockers() throws {
        var value = item(milestones: [
            Milestone(date: "11.1", content: "[C001] 锁券接口调整完成。",
                details: "删除重复查券，成功仅返回照片配置；失败返回LOCK_FAILED和PHOTO_QUERY_FAILED。"),
            Milestone(date: "11.2", content: "[C002] 归属校验受字段契约阻塞，未改代码。",
                details: "需确认三方订单号；确认前不能修改券码。"),
            Milestone(date: "11.3", content: "[C002] 换码校验开发完成，41项测试通过。",
                details: "新增couponCode；改按商品、条件、价格及税点校验，通过后更新券码与快照。41项测试通过。代码未提交推送或部署，三方固定错误码仍待确认。"),
            Milestone(date: "11.3", content: "[C001/C002] 改动已提交推送，待联调验收，尚未部署。",
                details: "提交029f包含C001/C002代码和文档；沿用41项定向测试结果，未重跑测试；下一步上游适配双入参并联调。")
        ])
        value.prompt = DemandPromptSections(intent: "拆出专属锁券接口。避免开单前改变券状态。原流程需要重复查券。").stored
        value.changes = [
            DemandChange(id: "C001", createdAt: Date(), intent: "删除重复查券并处理照片失败。"),
            DemandChange(id: "C002", createdAt: Date(), intent: "新增券码，必须按三方订单号校验。")
        ]
        let text = try plan(value).document()
        XCTAssertTrue(text.contains("### C001")); XCTAssertTrue(text.contains("### C002"))
        XCTAssertTrue(text.contains("成功仅返回照片配置"))
        XCTAssertTrue(text.contains("新增couponCode"))
        XCTAssertTrue(text.contains("改按商品、条件、价格及税点校验"))
        XCTAssertTrue(text.contains("已提交推送"))
        XCTAssertTrue(text.contains("未重跑测试"))
        XCTAssertTrue(text.contains("三方固定错误码仍待确认"))
        XCTAssertFalse(text.contains("字段契约阻塞"))
        XCTAssertFalse(text.contains("原流程需要重复查券"))
        XCTAssertFalse(text.contains("必须按三方订单号校验"))
        XCTAssertFalse(text.contains("代码未提交推送"))
    }

    func testUnimplementedChangesAndSupplementKeepAllRequirementsWithoutClaimingCompletion() throws {
        var value = item(milestones: [Milestone(date: "11.3", content: "[C002] 字段契约阻塞，未改代码。",
            details: "需确认跨券码稳定的归属字段。")])
        value.prompt = DemandPromptSections(intent: "新增服务。保留原入口。异常必须可恢复。",
            reason: "只允许已有登录态调用。", rules: "权限不足不得读取或修改订单。").stored
        value.changes = [DemandChange(id: "C002", createdAt: Date(),
            intent: "新增券码入参。检查券码归属。失败不得更新验券流水中的券码，且要返回明确原因。")]
        let text = try plan(value).document()
        XCTAssertTrue(text.contains("异常必须可恢复。"))
        XCTAssertTrue(text.contains("权限不足不得读取或修改订单。"))
        XCTAssertTrue(text.contains("失败不得更新验券流水中的券码，且要返回明确原因。"))
        XCTAssertTrue(text.contains("尚无可用的实现明细"))
        XCTAssertTrue(text.contains("未改代码"))
        XCTAssertFalse(text.contains("开发完成"))
    }

    func testDocumentPreservesCodeSpansAndRepeatedLinesInsideExamples() throws {
        let example = "接口接收\u{60}request(a;b)\u{60}。\n```json\n{\n  \"params\": {\n  }\n}\n```"
        let text = try plan(item(milestones: [Milestone(date: "11.3", content: "接口完成，待验收。",
            details: example)])).document()
        XCTAssertTrue(text.contains("\u{60}request(a;b)\u{60}"))
        XCTAssertTrue(text.contains("```json\n{\n  \"params\": {\n  }\n}\n```"))
        XCTAssertFalse(text.contains("- ```"))
    }

    func testTechnicalReferenceKeepsContractAndSkipsExamplesAndHistoricalStatus() throws {
        let source = """
        # 接口说明
        ## 调用方式
        ```java
        Result<Response> execute(String voucher, String code);
        ```
        两个参数必填，开单后调用。
        成功仅返回照片配置。
        ## 失败返回
        | 类型 | 含义 |
        | --- | --- |
        | RESULT_UNKNOWN | 先核实，不重试。 |
        **失败示例**
        ```json
        { "code": -110, "data": null }
        ```
        所有失败停止后续流程。
        ## 测试记录
        旧版本未发布。
        """
        let reference = try XCTUnwrap(DemandDeliveryReference.excerpt(source))
        let text = try plan().includingReference(reference).document()
        XCTAssertTrue(text.contains("execute(String voucher, String code)"))
        XCTAssertTrue(text.contains("两个参数必填，开单后调用"))
        XCTAssertTrue(text.contains("成功仅返回照片配置"))
        XCTAssertTrue(text.contains("| RESULT_UNKNOWN |"))
        XCTAssertTrue(text.contains("所有失败停止后续流程"))
        XCTAssertFalse(text.contains("```json"))
        XCTAssertFalse(text.contains("旧版本未发布"))
        XCTAssertNotEqual(try plan().key, try plan().includingReference(reference).key)
    }

    func testTechnicalReferenceUsesDeliveryBranchWhileRepositoryIsOnAnotherDemand() throws {
        try temporary { directory in
            let root = directory.appendingPathComponent("ultra")
            let file = root.appendingPathComponent("doc/api/Delivery.md")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            func git(_ arguments: [String]) throws {
                let result = ProcessRunner.run("/usr/bin/git", arguments: ["-C", root.path] + arguments,
                    environment: ProcessInfo.processInfo.environment, timeout: 5)
                guard result.succeeded else { throw DemandDeliveryError.message("Git fixture failed") }
            }
            try git(["init", "-b", "feature/delivery"])
            try "## 调用方式\n交付分支接口的参数必填，成功返回照片配置。\n".write(to: file, atomically: true, encoding: .utf8)
            try git(["add", "."])
            try git(["-c", "user.name=DBoard Test", "-c", "user.email=dboard-test@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "-m", "delivery fixture"])
            try git(["checkout", "-b", "feature/another-demand"])
            try "## 调用方式\n另一个需求的接口，不能作为当前交付。\n".write(to: file, atomically: true, encoding: .utf8)
            let value = item(project: root.path, branch: "feature/delivery", milestones: [
                Milestone(date: "11.3", content: "开发完成，待验收。", details: "接口说明见doc/api/Delivery.md。")])
            let reference = DemandDeliveryReference.read(item: value, repositories: [],
                projects: [DemandDeliveryProject(name: "ultra", branch: "feature/delivery")])
            XCTAssertTrue(reference.contains("交付分支接口的参数必填"))
            XCTAssertFalse(reference.contains("另一个需求的接口"))
            // Document lookup is read-only; it must not switch the user's checkout.
            XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("另一个需求"))
        }
    }

    func testReferenceDoesNotHideUnimplementedChangeOrTurnAPlanIntoImplementation() throws {
        var value = item(milestones: [Milestone(date: "11.3", content: "[C003] 计划新增权限校验。",
            details: "新增管理员校验，拒绝无权限调用。")])
        value.changes = [DemandChange(id: "C003", createdAt: Date(), intent: "必须拒绝无权限调用，且不泄露订单信息。")]
        let text = try plan(value).includingReference("#### 调用方式\n已有接口接收流水号。").document()
        XCTAssertTrue(text.contains("C003 · 追加要求"))
        XCTAssertTrue(text.contains("必须拒绝无权限调用，且不泄露订单信息。"))
        XCTAssertTrue(text.contains("计划新增权限校验"))
        XCTAssertFalse(text.contains("新增管理员校验"))
    }

    func testSuccessAndRepeatedClicksReuseDocumentAndDoNotAppendAgain() throws {
        try temporary { directory in
            let plan = try self.plan()
            var created = 0, submitted = 0, generatedCount = 0, present = false
            let services = DemandDeliveryServices(generate: { _ in generatedCount += 1; return plan.document() },
                validate: { _ in }, findDocument: { _ in nil },
                createDocument: { _, _ in created += 1; return self.documentURL }, verifyDocument: { _, _ in },
                listDeliverables: { _ in try self.response(plan, present: present) },
                submit: { _, _ in submitted += 1; present = true })
            let workflow = DemandDeliveryWorkflow(store: DemandDeliveryStore(url: directory.appendingPathComponent("receipts.json")), services: services)
            XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
            XCTAssertTrue(try workflow.run(plan, stillCurrent: { true }).confirmed)
            XCTAssertEqual(created, 1); XCTAssertEqual(submitted, 1); XCTAssertEqual(generatedCount, 1)
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

    func testReadsLatestSavedProjectBranchAndDoesNotUseAnUnsavedCard() throws {
        try temporary { directory in
            let cache = directory.appendingPathComponent("cache.md")
            try "## 🟡 重要\n".write(to: cache, atomically: true, encoding: .utf8)
            var draft = DItemDraft(from: item())
            XCTAssertTrue(DItemStore.create(draft, at: cache))
            let old = try DemandDeliveryPlan.load(id: draft.id, at: cache, repositoryName: { _ in "ultra" })
            let original = try DItemStore.currentItem(id: draft.id, at: cache)
            draft.branch = "feature/new"
            XCTAssertTrue(DItemStore.save(draft, original: original, at: cache))
            let latest = try DemandDeliveryPlan.load(id: draft.id, at: cache, repositoryName: { _ in "ultra" })
            XCTAssertNotEqual(latest.key, old.key)
            XCTAssertEqual(latest.projects.first?.branch, "feature/new")
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
