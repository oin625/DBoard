import base64
import json
import unittest
import test_dboard_ai as base
module = base.module


class DebugTaskTests(unittest.TestCase):
    def setUp(self):
        base.FeedbackTests.setUp(self)
        path = base.FeedbackTests.repo(self, "repo")
        base.subprocess.run(["git", "-C", str(path), "-c", "user.name=DBoard Test", "-c", "user.email=test@example.invalid",
                             "commit", "--allow-empty", "-qm", "测试初始提交"], check=True)
        self.call(*self.args(self.show(), "--repo", str(path)))
    tearDown = base.FeedbackTests.tearDown
    call = base.FeedbackTests.call
    show = base.FeedbackTests.show
    args = base.FeedbackTests.args
    repo = base.FeedbackTests.repo

    def milestone(self, stage, *extra, success=True):
        return self.call(*self.args(self.show(), "--summary", "本轮核验结果已反馈。",
            "--details", "根据真实接口核对业务步骤；测试环境与尚未验证的内容见本轮结论。",
            "--stage", stage, *extra), success=success)

    def test_debug_context_reads_latest_changes_and_explicit_page_scope(self):
        initial = self.call("context", "D014", "--task", "debug-page")
        self.assertEqual(initial["task"], "debug-page")
        self.assertIn("不因开发已完成就结束", initial["context"])
        self.assertIn("/Users/zz/work/code/audi", initial["debug_instructions"])
        self.assertIn("CONSOLES", initial["debug_instructions"])
        self.assertIn("dubboInvoke", initial["debug_instructions"])
        self.assertIn("最终内部／外部联调由用户协调进行", initial["context"])
        self.assertIn("未测及原因", initial["debug_instructions"])
        self.assertIn("不能将局部测试通过写成整体联调完成", initial["context"])
        self.milestone("development-complete")
        self.call(*self.args(self.show(), "--summary", "开发完成，待验收。"))
        change = {"id": "C001", "createdAt": "2026-11-03T10:00:00Z", "intent": "补充查询失败时不锁券"}
        # Use the existing validated change format from the CLI contract.
        changes = [change]
        encoded = base64.b64encode(json.dumps(changes, ensure_ascii=False).encode()).decode()
        text = self.cache.read_text()
        text = text.replace("- **进度**：", "- **变更咒言**：\n    <!-- dboard-changes:v1:" + encoded + " -->\n    ### C001 · 2026-11-03T10:00:00Z\n    补充查询失败时不锁券\n- **进度**：", 1)
        self.cache.write_text(text)
        latest = self.call("context", "D014", "--task", "debug-page")
        self.assertIn("补充查询失败时不锁券", latest["context"])
        self.assertTrue(latest["item"]["execution_needs_review"])
        self.assertIn("开发完成，待验收", latest["context"])
        ordinary = self.call("context", "D014")
        self.assertIn("不改代码、不自行扩展需求", ordinary["context"])
        self.assertIsNone(ordinary["debug_instructions"])
        self.assertEqual(self.call("context", "D014", "--task", "debug-page", "--change", "C001", success=False)["error"]["code"],
                         "INVALID_ARGUMENT")

    def test_fault_handoff_and_feedback_preserve_page_and_user_state(self):
        self.milestone("development-complete")
        self.milestone("debug-page-ready", "--debug-page", "/test-console/coupon")
        self.milestone("testing-passed")
        context = self.call("context", "D014")
        self.assertIn("用户在复制指令后补充的联调报错", context["context"])
        self.assertIn("填写区留空", context["feedback_instructions"])
        self.milestone("developing")
        self.assertEqual(self.show()["execution"]["debug_page"], "/test-console/coupon")
        self.assertEqual(self.show()["status"], "进行中")
        self.milestone("development-complete")
        self.milestone("debug-page-ready")
        self.assertEqual(self.show()["execution"]["debug_page"], "/test-console/coupon")

    def test_milestones_roundtrip_do_not_complete_user_state(self):
        result = self.milestone("debug-page-ready", "--debug-page", "/test-console/coupon", success=False)
        self.assertEqual(result["error"]["code"], "DEVELOPMENT_NOT_VERIFIED")
        self.milestone("development-complete")
        result = self.milestone("testing-passed", success=False)
        self.assertEqual(result["error"]["code"], "DEBUG_PAGE_NOT_READY")
        audi = self.repo("audi")
        base.subprocess.run(["git", "-C", str(audi), "-c", "user.name=DBoard Test", "-c", "user.email=test@example.invalid",
                             "commit", "--allow-empty", "-qm", "调试页初始提交"], check=True)
        self.call(*self.args(self.show(), "--repo", str(audi)))
        self.milestone("debug-page-ready", "--debug-page", "/test-console/coupon")
        result = self.milestone("testing-passed", "--debug-url", "https://audi.example/test-console/coupon")
        item = result["item"]
        self.assertEqual(item["status"], "进行中")
        self.assertEqual(item["execution"]["stage"], "testing-passed")
        self.assertEqual(item["execution"]["debug_page"], "/test-console/coupon")
        self.assertFalse(item["execution_needs_review"])
        self.assertIn("已记录调试模块", self.call("context", "D014")["context"])
        before = self.cache.read_bytes()
        invalid = self.milestone("testing-passed", "--debug-page", "/other-module", success=False)
        self.assertEqual(invalid["error"]["code"], "DEBUG_PAGE_NOT_READY")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_requirement_edits_invalidate_results_but_progress_and_git_do_not(self):
        self.milestone("development-complete")
        self.milestone("debug-page-ready", "--debug-page", "/third-test")
        self.milestone("testing-passed")
        old_hash = self.show()["execution"]["scope_hash"]
        self.call(*self.args(self.show(), "--summary", "补充交接说明，待用户验收。", "--repo", str(self.repo())))
        self.assertFalse(self.show()["execution_needs_review"])
        for before, after in (("拆出锁券", "拆出锁券并查照片"), ("原始描述", "新增需求说明")):
            with self.subTest(scope=after):
                original = self.cache.read_text()
                self.cache.write_text(original.replace(before, after))
                self.assertTrue(self.show()["execution_needs_review"])
                self.assertEqual(self.show()["execution"]["scope_hash"], old_hash)
                self.assertIn("需重新核验", self.call("context", "D014", "--task", "debug-page")["context"])
                bytes_before = self.cache.read_bytes()
                self.milestone("testing-passed", success=False)
                self.assertEqual(self.cache.read_bytes(), bytes_before)
                self.cache.write_text(original)
        self.milestone("developing")
        self.assertEqual(self.show()["execution"]["stage"], "developing")

    def test_invalid_arguments_and_corrupt_metadata_never_write(self):
        for extra in (("--stage", "development-complete"), ("--debug-page", "/page"),
                      ("--stage", "development-complete", "--summary", "无依据")):
            original = self.cache.read_bytes()
            self.call(*self.args(self.show(), *extra), success=False)
            self.assertEqual(self.cache.read_bytes(), original)
        self.milestone("development-complete")
        for page, url in (("//example/path", None), ("/valid", "file:///valid"),
                          ("/valid", "https://user:pw@example/valid"), ("/valid", "https://example/other"),
                          ("/valid", "https://example:99999/valid")):
            original = self.cache.read_bytes()
            extra = ["--debug-page", page] + (["--debug-url", url] if url else [])
            self.milestone("debug-page-ready", *extra, success=False)
            self.assertEqual(self.cache.read_bytes(), original)
        self.cache.write_text(self.cache.read_text().replace(module.EXECUTION_PREFIX, module.EXECUTION_PREFIX + "!"))
        original = self.cache.read_bytes()
        self.assertEqual(self.call("show", "D014", success=False)["error"]["code"], "INVALID_EXECUTION_DATA")
        self.call("context", "D014", "--task", "debug-page", success=False)
        self.assertEqual(self.cache.read_bytes(), original)

    def test_milestone_retry_is_idempotent_and_revision_conflicts_fail(self):
        args = self.args(self.show(), "--stage", "development-complete", "--summary", "开发已核验。",
                         "--details", "实际接口及关键错误分支均已核对。", "--event-id", "debug-verified")
        self.call(*args)
        original = self.cache.read_bytes()
        self.assertTrue(self.call(*args)["duplicate"])
        self.assertEqual(self.cache.read_bytes(), original)
        self.assertEqual(self.call(*args[:-1], "different-event", success=False)["error"]["code"], "REVISION_CONFLICT")
