import base64
import json
import sys
import unittest
import test_dboard_ai as base

sys.path.insert(0, str(base.CLI.parent))
from dboard_overview import digest


class ReleaseChecklistTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown
    call = base.FeedbackTests.call
    show = base.FeedbackTests.show
    args = base.FeedbackTests.args

    def write_list(self, checklist):
        checklist = {k: v for k, v in checklist.items() if k != "needs_review"}
        encoded = base64.b64encode(json.dumps(checklist, ensure_ascii=False).encode()).decode()
        lines = [x for x in self.cache.read_text().split("\n") if not x.startswith(base.module.RELEASE_PREFIX)]
        index = lines.index("### D014【fixture】锁券接口 #进行中")
        lines.insert(index + 1, base.module.RELEASE_PREFIX + encoded + base.module.META_SUFFIX)
        self.cache.write_text("\n".join(lines))

    def test_empty_list_is_read_only_and_ai_can_add_review_and_handoff(self):
        initial = self.show()
        self.assertTrue(initial["release_checklist"]["needs_review"])
        context = self.call("context", "D014")
        self.assertEqual(context["item"]["release_checklist"]["items"], [])
        self.assertIn("清单为空", context["context"])
        self.assertEqual(self.cache.read_text(), self.before)
        original_digest = digest(self.before)
        result = self.call(*self.args(initial, "--release-add", "发布 ultra 服务",
            "--release-add", "上线前执行 V20261104__create_lock.sql", "--release-reviewed", "--event-id", "release-plan"))
        items = result["item"]["release_checklist"]["items"]
        self.assertEqual([x["id"] for x in items], ["L001", "L002"])
        self.assertTrue(all(not x["done"] and x["updated_by"] == "ai" for x in items))
        self.assertFalse(result["item"]["release_checklist"]["needs_review"])
        self.assertEqual(result["item"]["progress"], initial["progress"])
        self.assertEqual(digest(self.cache.read_text()), original_digest)
        for task in ((), ("--task", "debug-page")):
            next_ai = self.call("context", "D014", *task)
            self.assertEqual(next_ai["item"]["release_checklist"]["items"], items)
            self.assertIn("发布 ultra 服务", next_ai["context"])
        before_retry = self.cache.read_bytes()
        duplicate = self.call(*self.args(initial, "--release-add", "发布 ultra 服务",
            "--release-add", "上线前执行 V20261104__create_lock.sql", "--release-reviewed", "--event-id", "release-plan"))
        self.assertTrue(duplicate["duplicate"])
        self.assertEqual(self.cache.read_bytes(), before_retry)

    def test_human_edits_deletions_and_checks_are_seen_and_preserved(self):
        original = self.call(*self.args(self.show(), "--release-add", "发布 ultra 服务", "--release-add", "执行旧 SQL"))["item"]
        checklist = original["release_checklist"]
        checklist["items"][0].update(text="先配开关，再发布 ultra 服务", done=True, updated_by="user")
        checklist["items"].pop()
        checklist["excluded_by_user"] = ["发布 ultra 服务", "执行旧 SQL"]
        self.write_list(checklist)
        context = self.call("context", "D014")
        self.assertIn("先配开关，再发布 ultra 服务", context["context"])
        self.assertIn("用户删除或修正过", context["context"])
        self.assertTrue(context["item"]["release_checklist"]["items"][0]["done"])
        before = self.cache.read_bytes()
        stale = self.call(*self.args(original, "--release-add", "新建表"), success=False)
        self.assertEqual(stale["error"]["code"], "REVISION_CONFLICT")
        self.assertEqual(self.cache.read_bytes(), before)
        for change in (("--release-edit", "L001=改回旧文字"), ("--release-remove", "L001")):
            denied = self.call(*self.args(self.show(), *change), success=False)
            self.assertEqual(denied["error"]["code"], "USER_MANAGED_RELEASE_ITEM")
            self.assertEqual(self.cache.read_bytes(), before)
        added = self.call(*self.args(self.show(), "--release-add", "执行旧 SQL", "--release-add", "新建 lock_record 表"))
        self.assertEqual(added["release_result"]["skipped"][0]["reason"], "user_removed_or_corrected")
        self.assertEqual(added["release_result"]["added"], ["L003"])
        first = added["item"]["release_checklist"]["items"][0]
        self.assertEqual(first["text"], "先配开关，再发布 ultra 服务")
        self.assertTrue(first["done"])

    def test_ai_edits_remove_and_deduplicate_without_reusing_ids_or_events(self):
        first = self.call(*self.args(self.show(), "--release-add", "发布 ultra", "--release-add", "旧配置"))["item"]
        edited = self.call(*self.args(first, "--release-edit", "L001=发布 ultra 后端服务", "--release-remove", "L002",
            "--release-add", "补充配置项", "--event-id", "edit-release"))["item"]
        self.assertEqual([x["id"] for x in edited["release_checklist"]["items"]], ["L001", "L003"])
        result = self.call(*self.args(edited, "--release-add", "发布 ultra 后端服务", "--release-add", "补充配置项"))
        self.assertEqual(len(result["item"]["release_checklist"]["items"]), 2)
        self.assertEqual(len(result["release_result"]["skipped"]), 2)
        before = self.cache.read_bytes()
        failed = self.call(*self.args(self.show(), "--release-add", "别的任务", "--event-id", "edit-release"), success=False)
        self.assertEqual(failed["error"]["code"], "EVENT_CONFLICT")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_changed_requirements_recheck_without_unchecking_old_results(self):
        self.call(*self.args(self.show(), "--release-add", "发布 ultra", "--release-reviewed"))
        checklist = self.show()["release_checklist"]
        checklist["items"][0].update(done=True, updated_by="user")
        self.write_list(checklist)
        self.cache.write_text(self.cache.read_text().replace("拆出锁券", "拆出锁券并增加重试"))
        result = self.call("context", "D014")
        self.assertTrue(result["item"]["release_checklist"]["needs_review"])
        self.assertTrue(result["item"]["release_checklist"]["items"][0]["done"])
        changed = self.call(*self.args(self.show(), "--release-add", "[C001] 发布 ultra 重试改动", "--release-reviewed"))
        self.assertFalse(changed["item"]["release_checklist"]["needs_review"])
        self.assertTrue(changed["item"]["release_checklist"]["items"][0]["done"])

    def test_summary_details_roundtrip_and_summary_only_edit_preserves_details(self):
        detail = "开发分支：feature/release。\nSQL：doc/sql/create.sql；先执行 SQL，再发布。\n### D999 只是明细文字"
        value = json.dumps({"summary": "发布 Ultra 服务", "details": detail}, ensure_ascii=False)
        arguments = self.args(self.show(), "--release-item", value, "--event-id", "summary-details")
        result = self.call(*arguments)
        entry = result["item"]["release_checklist"]["items"][0]
        self.assertEqual(entry["text"], "发布 Ultra 服务")
        self.assertEqual(entry["details"], detail)
        context = self.call("context", "D014")
        self.assertEqual(context["item"]["release_checklist"]["items"][0]["details"], detail)
        self.assertIn(detail.split("\n")[1], context["context"])
        changed = self.call(*self.args(self.show(), "--release-edit", "L001=发布 Ultra 后端"))
        self.assertEqual(changed["item"]["release_checklist"]["items"][0]["details"], detail)
        before = self.cache.read_bytes()
        self.assertTrue(self.call(*arguments)["duplicate"])
        self.assertEqual(before, self.cache.read_bytes())
        update = json.dumps({"id": "L001", "summary": "发布 Ultra 后端", "details": "新的分支和发布说明"}, ensure_ascii=False)
        latest = self.call(*self.args(self.show(), "--release-item", update))
        self.assertEqual(latest["item"]["release_checklist"]["items"][0]["details"], "新的分支和发布说明")
        checklist = latest["item"]["release_checklist"]
        checklist["items"][0].update(done=True, updated_by="user")
        self.write_list(checklist)
        before = self.cache.read_bytes()
        denied = self.call(*self.args(self.show(), "--release-item", update), success=False)
        self.assertEqual(denied["error"]["code"], "USER_MANAGED_RELEASE_ITEM")
        self.assertEqual(before, self.cache.read_bytes())

    def test_long_ai_summary_is_rejected_and_legacy_details_are_optional(self):
        before = self.cache.read_bytes()
        result = self.call(*self.args(self.show(), "--release-add", "发布 Ultra 服务，分支路径和配置参数" * 5), success=False)
        self.assertEqual(result["error"]["code"], "RELEASE_SUMMARY_TOO_LONG")
        self.assertEqual(before, self.cache.read_bytes())
        self.write_list({"items": [{"id": "L001", "text": "旧格式事项", "done": True, "updated_by": "user"}],
                         "excluded_by_user": [], "next_id": 2})
        self.assertEqual(self.show()["release_checklist"]["items"][0]["details"], "")
        invalid = self.show()["release_checklist"]
        invalid["items"][0]["details"] = False
        self.write_list(invalid)
        before = self.cache.read_bytes()
        self.assertEqual(self.call("context", "D014", success=False)["error"]["code"], "INVALID_RELEASE_CHECKLIST")
        self.assertEqual(before, self.cache.read_bytes())

    def test_categories_roundtrip_and_human_adjustment_is_protected(self):
        payload = json.dumps({"summary": "执行预发检查", "category": "permission", "details": "检查接口授权"}, ensure_ascii=False)
        arguments = self.args(self.show(), "--release-item", payload, "--event-id", "category-roundtrip")
        result = self.call(*arguments)
        entry = result["item"]["release_checklist"]["items"][0]
        self.assertEqual(entry["category"], "permission")
        self.assertTrue(self.call(*arguments)["duplicate"])
        edited = self.call(*self.args(self.show(), "--release-edit", "L001=执行上线检查"))
        self.assertEqual(edited["item"]["release_checklist"]["items"][0]["category"], "permission")
        self.assertEqual(edited["item"]["release_checklist"]["items"][0]["details"], "检查接口授权")
        payload = json.dumps({"id": "L001", "summary": "执行上线检查", "category": "configuration"}, ensure_ascii=False)
        changed = self.call(*self.args(self.show(), "--release-item", payload))
        entry = changed["item"]["release_checklist"]["items"][0]
        self.assertEqual(entry["category"], "configuration")
        self.assertEqual(entry["details"], "检查接口授权")
        checklist = changed["item"]["release_checklist"]
        checklist["items"][0].update(category="other", updated_by="user")
        self.write_list(checklist)
        context = self.call("context", "D014")
        self.assertEqual(context["item"]["release_checklist"]["items"][0]["category"], "other")
        self.assertIn("### 其他", context["context"])
        before = self.cache.read_bytes()
        denied = self.call(*self.args(self.show(), "--release-item", payload), success=False)
        self.assertEqual(denied["error"]["code"], "USER_MANAGED_RELEASE_ITEM")
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(digest(self.before), digest(self.cache.read_text()))

    def test_legacy_category_inference_and_invalid_category_never_overwrites_data(self):
        cases = [("创建归因结果表", "sql"), ("补齐查询索引", "sql"),
                 ("发布 Ultra 服务", "release"), ("发布 nczorderweb 前端", "release"),
                 ("配置 Ultra ES 连接", "configuration"), ("启用归因定时任务", "configuration"),
                 ("开通生产查询接口", "permission"), ("配置菜单权限", "permission"), ("备份附件", "other")]
        entries = [{"id": "L" + str(i).zfill(3), "text": text, "done": False, "updated_by": "ai"}
                   for i, (text, category) in enumerate(cases, 1)]
        entries[0]["category"] = None
        self.write_list({"items": entries, "excluded_by_user": [], "next_id": len(entries) + 1})
        result = self.call("context", "D014")
        self.assertEqual([x["category"] for x in result["item"]["release_checklist"]["items"]], [c for _, c in cases])
        for invalid in ("unknown", None, False, {}, []):
            before = self.cache.read_bytes()
            payload = json.dumps({"summary": "新增事项", "category": invalid})
            failed = self.call(*self.args(self.show(), "--release-item", payload), success=False)
            self.assertEqual(failed["error"]["code"], "INVALID_ARGUMENT")
            self.assertEqual(self.cache.read_bytes(), before)
        for invalid in ("unknown", False, {}, []):
            entries[0]["category"] = invalid
            self.write_list({"items": entries, "excluded_by_user": [], "next_id": len(entries) + 1})
            before = self.cache.read_bytes()
            failed = self.call("context", "D014", success=False)
            self.assertEqual(failed["error"]["code"], "INVALID_RELEASE_CHECKLIST")
            self.assertEqual(self.cache.read_bytes(), before)


    def test_custom_categories_are_shared_with_next_ai_and_user_changes_are_protected(self):
        payload = json.dumps({"summary": "申请 ES 存储资源", "category": "custom:资源准备",
                              "details": "确认生产容量后再启用任务"}, ensure_ascii=False)
        result = self.call(*self.args(self.show(), "--release-item", payload))
        entry = result["item"]["release_checklist"]["items"][0]
        self.assertEqual(entry["category"], "custom:资源准备")
        context = self.call("context", "D014")
        self.assertIn("### 资源准备", context["context"])
        self.assertIn(entry["details"], context["context"])
        checklist = result["item"]["release_checklist"]
        checklist["items"][0].update(category="custom:容量规划", updated_by="user")
        self.write_list(checklist)
        context = self.call("context", "D014")
        self.assertIn("### 容量规划", context["context"])
        self.assertEqual(context["item"]["release_checklist"]["items"][0]["category"], "custom:容量规划")
        update = json.dumps({"id": "L001", "summary": entry["text"], "category": "custom:资源准备"})
        before = self.cache.read_bytes()
        failed = self.call(*self.args(self.show(), "--release-item", update), success=False)
        self.assertEqual(failed["error"]["code"], "USER_MANAGED_RELEASE_ITEM")
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(digest(self.before), digest(self.cache.read_text()))
        for invalid in ("custom:", "custom: SQL", "custom:SQL", "custom:换行\n分类", "custom:" + "长" * 21):
            value = json.dumps({"summary": "无效分类事项", "category": invalid})
            failed = self.call(*self.args(self.show(), "--release-item", value), success=False)
            self.assertEqual(failed["error"]["code"], "INVALID_ARGUMENT")
            self.assertEqual(self.cache.read_bytes(), before)

    def test_empty_review_is_valid_and_bad_data_is_not_replaced_with_an_empty_list(self):
        result = self.call(*self.args(self.show(), "--release-reviewed"))
        self.assertEqual(result["item"]["release_checklist"]["items"], [])
        self.assertFalse(result["item"]["release_checklist"]["needs_review"])
        for invalid in ({"items": [], "excluded_by_user": [], "next_id": True},
                        {"items": [{"id": "L001", "text": "发布", "done": 1, "updated_by": "ai"}], "excluded_by_user": [], "next_id": 2},
                        {"items": [], "excluded_by_user": ["旧项", "旧项"], "next_id": 1}):
            self.write_list(invalid)
            before = self.cache.read_bytes()
            self.assertEqual(self.call("context", "D014", success=False)["error"]["code"], "INVALID_RELEASE_CHECKLIST")
            self.call("report", "D014", "--expect-title", "锁券接口", "--expect-revision", "a" * 64,
                      "--release-add", "不能覆盖", "--no-sync", success=False)
            self.assertEqual(self.cache.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
