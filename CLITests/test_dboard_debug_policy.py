import unittest
import test_dboard_ai as base


class DebugPagePolicyTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown
    call = base.FeedbackTests.call
    show = base.FeedbackTests.show
    args = base.FeedbackTests.args

    def skip(self):
        self.cache.write_text(self.cache.read_text().replace(
            "### D014【fixture】锁券接口 #进行中\n",
            "### D014【fixture】锁券接口 #进行中\n" + base.module.DEBUG_PAGE_NOT_NEEDED + "\n"))

    def test_user_opt_out_overrides_both_regular_and_already_copied_debug_tasks(self):
        self.assertFalse(self.show()["debug_page_not_needed"])
        self.skip()
        self.assertTrue(self.show()["debug_page_not_needed"])
        for args in (("context", "D014"), ("context", "D014", "--task", "debug-page")):
            result = self.call(*args)
            self.assertTrue(result["item"]["debug_page_not_needed"])
            self.assertIn("接口验证与人工联调仍按需进行", result["context"])
        debug = self.call("context", "D014", "--task", "debug-page")
        self.assertIn("不创建或更新调试页", debug["context"])
        self.assertNotIn("CONSOLES", debug["debug_instructions"])

    def test_skipped_page_blocks_new_page_milestones_but_allows_backend_tests(self):
        self.call(*self.args(self.show(), "--stage", "development-complete",
            "--summary", "后端已核验。", "--details", "已核对接口及错误处理。"))
        self.skip()
        for stage in ("debug-page-ready", "testing-passed"):
            before = self.cache.read_bytes()
            result = self.call(*self.args(self.show(), "--stage", stage,
                "--debug-page", "/test-console/lock", "--summary", "试图反馈页面完成。",
                "--details", "未获得页面授权。"), success=False)
            self.assertEqual(result["error"]["code"], "DEBUG_PAGE_NOT_NEEDED")
            self.assertEqual(before, self.cache.read_bytes())
        self.call(*self.args(self.show(), "--summary", "接口定向验证通过，仍待人工联调。"))
        self.assertTrue(self.show()["debug_page_not_needed"])
        self.assertFalse(self.show()["execution_needs_review"])
        self.assertEqual(self.show()["execution"]["stage"], "development-complete")

    def test_undo_keeps_existing_page_and_damaged_policy_cannot_be_silently_ignored(self):
        self.call(*self.args(self.show(), "--stage", "development-complete",
            "--summary", "后端已核验。", "--details", "核对实际实现。"))
        self.call(*self.args(self.show(), "--stage", "debug-page-ready", "--debug-page", "/test-console/lock",
            "--summary", "页面完成，待联调。", "--details", "构建及定向测试通过。"))
        saved = self.show()["execution"]
        self.skip()
        self.assertEqual(self.show()["execution"], saved)
        self.cache.write_text(self.cache.read_text().replace(base.module.DEBUG_PAGE_NOT_NEEDED + "\n", ""))
        self.assertFalse(self.show()["debug_page_not_needed"])
        self.assertEqual(self.show()["execution"], saved)
        for record in (base.module.DEBUG_PAGE_POLICY_PREFIX + "broken -->",
                       base.module.DEBUG_PAGE_NOT_NEEDED + "\n" + base.module.DEBUG_PAGE_NOT_NEEDED):
            before = self.cache.read_text()
            self.cache.write_text(before.replace("### D014【fixture】锁券接口 #进行中\n",
                "### D014【fixture】锁券接口 #进行中\n" + record + "\n"))
            original = self.cache.read_bytes()
            self.assertEqual(self.call("show", "D014", success=False)["error"]["code"], "INVALID_DEBUG_PAGE_POLICY")
            self.call("context", "D014", "--task", "debug-page", success=False)
            self.assertEqual(self.cache.read_bytes(), original)
            self.cache.write_text(before)
