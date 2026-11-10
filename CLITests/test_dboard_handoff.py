import copy
import base64
import json
from pathlib import Path
import subprocess
import sys
import unittest
import test_dboard_ai as base

handoff = base.module.dboard_handoff


class HandoffTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown

    def call(self, *args, success=True):
        proc = subprocess.run([sys.executable, str(base.CLI), "--cache", str(self.cache), *args],
                              capture_output=True, text=True, timeout=15)
        result = json.loads(proc.stdout)
        self.assertEqual(proc.returncode == 0, success, proc.stdout + proc.stderr)
        return result

    def snapshot(self):
        return self.call("show", "D014")["item"]

    def report_args(self, decision="skip", summary=None, records=None, event="event"):
        current = self.snapshot()
        args = ["report", "D014", "--expect-title", current["title"], "--expect-revision", current["revision"],
                "--compression-decision", decision, "--compression-reason", "已逐次核对历史与现状",
                "--event-id", event, "--no-sync"]
        if summary is not None:
            args += ["--summary", summary]
        value = {"based_on_records": current["history_records"] if records is None else records,
                 "sections": {"completed": summary or "已实现原需求", "pending": "待外部联调，无新增开发任务",
                              "decisions": "验券不锁券；锁券前重复查券", "verification": "本地通过，外部未测"},
                 "references": ["record:1"]}
        path = self.root / (event + "-handoff.json")
        path.write_text(json.dumps(value, ensure_ascii=False))
        args += ["--handoff-file", str(path)]
        return args

    def test_every_context_checks_without_cache_including_full_and_empty_history(self):
        for empty in (False, True):
            if empty:
                self.cache.write_text(self.before.replace("    - 10.1: 原有进度", ""))
            ids = set()
            for args in ((), (), ("--full",), ("--full",)):
                response = self.call("context", "D014", *args)
                check = response["compression_check"]
                self.assertTrue(check["evaluated"])
                self.assertTrue(check["ai_review_required"])
                self.assertTrue(check["checked_at"])
                ids.add(check["check_id"])
                self.assertEqual(check["recommended"], not empty)
            self.assertEqual(len(ids), 4)

    def test_compact_defaults_preserve_history_and_require_explicit_read_on_first_use(self):
        text = self.before.replace("原有进度", "原有概括。\n        详细历史证据" * 1)
        self.cache.write_text(text)
        before = self.cache.read_bytes()
        response = self.call("context", "D014")
        self.assertTrue(response["history_read_required"])
        self.assertEqual(response["context_mode"], "compact")
        self.assertNotIn("详细历史证据", response["context"])
        self.assertIn("详细历史证据", self.call("context", "D014", "--full")["context"])
        self.assertNotIn("progress_records", self.snapshot())
        self.assertEqual(self.call("history", "D014", "--all", "--details")["records"][0]["details"], "详细历史证据")
        self.assertEqual(before, self.cache.read_bytes())

    def test_progress_and_summary_atomic_and_compaction_checkpoint_does_not_reset_on_updates(self):
        original = self.call("history", "D014", "--all", "--details")["records"]
        result = self.call(*self.report_args("compact", event="initial"))
        self.assertNotIn("progress_records", result["item"])
        self.assertEqual(self.call("history", "D014", "--all", "--details")["records"], original)
        self.assertEqual(self.snapshot()["handoff"]["compacted_count"], 1)
        for index in range(10):
            self.call(*self.report_args(summary="本轮变化" + str(index), event="round-" + str(index)))
            check = self.call("context", "D014")["compression_check"]
            self.assertEqual(check["metrics"]["uncovered_records"], 0)
            self.assertEqual(check["metrics"]["records_since_compaction"], index + 1)
            self.assertEqual(check["recommended"], index >= 9)
        self.call(*self.report_args("compact", event="recompact"))
        check = self.call("context", "D014")["compression_check"]
        self.assertFalse(check["recommended"])
        self.assertEqual(check["metrics"]["records_since_compaction"], 0)
        self.assertEqual(self.snapshot()["history_records"], 11)

    def test_history_edits_deletions_and_reordering_never_hide_uncovered_records(self):
        self.call(*self.report_args("compact", summary="第二条进展", event="initial"))
        saved = self.cache.read_text()
        transformations = (
            lambda s: s.replace("原有进度", "用户修正原有进度"),
            lambda s: s.replace("    - 10.1: 原有进度\n", ""),
            lambda s: s.replace("原有进度", "第二条进展").replace("第二条进展", "调换记录", 1))
        for transform in transformations:
            self.cache.write_text(transform(saved))
            response = self.call("context", "D014")
            self.assertEqual(response["compression_check"]["summary_state"], "history-changed")
            self.assertEqual(response["compression_check"]["metrics"]["covered_records"], 0)
            self.assertTrue(response["history_read_required"])
            self.assertTrue(response["compression_check"]["recommended"])

    def test_latest_user_corrections_changes_and_checklist_are_not_replaced_by_snapshot(self):
        self.call(*self.report_args("compact", event="initial"))
        self.cache.write_text(self.cache.read_text().replace("- **描述**：原始描述",
                              "- **交接补充**：用户纠正：此前测试未覆盖真实退款\n    等上游提供数据\n- **描述**：原始描述"))
        response = self.call("context", "D014")
        self.assertIn("用户纠正：此前测试未覆盖真实退款\n等上游提供数据", response["context"])
        revision = self.snapshot()["revision"]
        args = ["report", "D014", "--expect-title", "锁券接口", "--expect-revision", revision,
                "--compression-decision", "skip", "--compression-reason", "仅补具体上线动作", "--no-sync",
                "--release-item", json.dumps({"summary": "发布 Ultra 服务", "category": "release", "details": "保留开发分支说明"})]
        self.call(*args)
        response = self.call("context", "D014")
        checklist = response["item"]["release_checklist"]
        self.assertTrue(checklist["items"][0]["has_details"])
        self.assertNotIn("details", checklist["items"][0])
        self.assertTrue(checklist["details_deferred"])
        complete = self.call("inspect", "D014", "--section", "release")["data"]["release_checklist"]
        self.assertEqual(complete["items"][0]["details"], "保留开发分支说明")
        self.assertIn("用户纠正", response["context"])
        self.assertEqual(self.snapshot()["context_review"]["decision"], "skip")

    def test_required_decision_summary_revision_and_record_count_fail_atomically(self):
        item = self.snapshot()
        before = self.cache.read_bytes()
        common = ["report", "D014", "--expect-title", item["title"], "--expect-revision", item["revision"], "--no-sync"]
        error = self.call(*common, "--summary", "有新进度", success=False)
        self.assertEqual(error["error"]["code"], "CONTEXT_REVIEW_REQUIRED")
        error = self.call(*common, "--summary", "有新进度", "--compression-decision", "skip",
                          "--compression-reason", "不足阈值", success=False)
        self.assertEqual(error["error"]["code"], "HANDOFF_REQUIRED")
        error = self.call(*self.report_args("compact", records=99, event="badcount"), success=False)
        self.assertEqual(error["error"]["code"], "HANDOFF_SOURCE_CONFLICT")
        self.assertEqual(before, self.cache.read_bytes())
        args = self.report_args("compact", event="stale")
        self.cache.write_text(self.cache.read_text().replace("原始描述", "用户修改描述"))
        changed = self.cache.read_bytes()
        self.assertEqual(self.call(*args, success=False)["error"]["code"], "REVISION_CONFLICT")
        self.assertEqual(changed, self.cache.read_bytes())

    def test_exact_retry_and_source_fingerprints_are_preserved(self):
        args = self.report_args("compact", summary="新结果", event="retry")
        self.call(*args)
        saved = self.cache.read_bytes()
        self.assertTrue(self.call(*args)["duplicate"])
        self.assertEqual(saved, self.cache.read_bytes())
        args[args.index("--compression-reason") + 1] = "不同判断"
        self.assertEqual(self.call(*args, success=False)["error"]["code"], "EVENT_CONFLICT")

    def test_history_pagination_and_query_return_details_only_when_requested(self):
        self.cache.write_text(self.before.replace("    - 10.1: 原有进度",
            "\n".join("    - 10.1: 记录" + str(i) + "。\n        证据" + str(i) for i in range(30))))
        first = self.call("history", "D014")
        self.assertEqual(len(first["records"]), 20)
        self.assertEqual(first["next_record"], 21)
        self.assertTrue(first["has_more"])
        self.assertNotIn("details", first["records"][0])
        second = self.call("history", "D014", "--from-record", "21", "--details")
        self.assertEqual(len(second["records"]), 10)
        self.assertFalse(second["has_more"])
        query = self.call("history", "D014", "--query", "证据29", "--all", "--details")
        self.assertEqual(query["records"][0]["index"], 30)

    def test_corrupt_snapshot_errors_instead_of_overwriting_or_omitting(self):
        self.cache.write_text(self.before.replace("- **描述**：原始描述", handoff.PREFIX + "corrupt -->\n- **描述**：原始描述"))
        before = self.cache.read_bytes()
        for args in (("show", "D014"), ("context", "D014"), ("context", "D014", "--full")):
            self.assertEqual(self.call(*args, success=False)["error"]["code"], "INVALID_HANDOFF_DATA")
        self.assertEqual(before, self.cache.read_bytes())

    def test_snapshot_uses_recorded_repository_code_and_live_test_validity(self):
        repo = base.FeedbackTests.repo(self)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "--allow-empty", "-qm", "测试初始提交"], check=True)
        args = self.report_args("compact", event="repo")
        args += ["--repo", str(repo)]
        self.call(*args)
        current = self.snapshot()
        self.assertIsNotNone(current["code_revision"])
        self.assertEqual(current["handoff"]["code_revision"], current["code_revision"])
        self.assertFalse(self.call("context", "D014")["compression_check"]["code_changed"])
        args = self.report_args(summary="已核验开发", event="verified")
        args += ["--stage", "development-complete", "--details", "实际边界测试通过",
                 "--expect-code", current["code_revision"]]
        self.call(*args)
        (repo / "new.py").write_text("later change")
        response = self.call("context", "D014")
        self.assertTrue(response["item"]["execution_needs_review"])
        self.assertTrue(response["compression_check"]["code_changed"])
        self.assertTrue(response["compression_check"]["summary_update_required"])

    def test_reference_guides_are_available_without_loading_all_details(self):
        response = self.call("context", "D014")
        self.assertTrue(response["feedback_skill_path"].endswith("SKILL.md"))
        for topic in ("handoff", "feedback", "debug-page"):
            self.assertIn("guide --topic " + topic, response["reference_commands"][topic])
            guide = self.call("guide", "--topic", topic)
            self.assertTrue(guide["skill_path"].endswith(topic + ".md"))
            self.assertTrue(guide["instructions"])

    def test_long_content_is_not_a_trigger_or_save_limit_and_new_records_remain_readable(self):
        rows = [{"date": "10.1", "summary": "概括", "details": "x" * 4000}]
        check = handoff.evaluate(None, rows, "a" * 64, None)
        self.assertGreaterEqual(check["metrics"]["chars_since_compaction"], 4000)
        args = self.report_args("compact", event="long-initial")
        path = Path(args[args.index("--handoff-file") + 1])
        value = json.loads(path.read_text())
        value["sections"]["completed"] = "保留影响接续的关键决定。" * 1200
        value["references"] = ["文档路径/" + "x" * 5000]
        path.write_text(json.dumps(value, ensure_ascii=False))
        self.call(*args)
        response = self.call("context", "D014")
        self.assertEqual(self.snapshot()["handoff"]["sections"]["completed"], value["sections"]["completed"])
        self.assertFalse(response["compression_check"]["recommended"])
        self.assertEqual(response["compression_check"]["thresholds"], {"records_since_compaction": 10})
        self.assertGreater(response["compression_check"]["metrics"]["summary_chars"], 8000)
        text = self.cache.read_text().replace("    - 10.1: 原有进度", "    - 10.1: 原有进度\n    - 10.2: 最新进展。\n        独立证据")
        self.cache.write_text(text)
        response = self.call("context", "D014")
        self.assertTrue(response["history_read_required"])
        self.assertNotIn("独立证据", response["context"])
        self.assertEqual(self.call("history", "D014", "--from-record", "2", "--all", "--details")["records"][0]["details"], "独立证据")
        self.assertEqual(response["compression_check"]["metrics"]["uncovered_records"], 1)

    def test_legacy_policy_requires_semantic_review_without_losing_original_state(self):
        self.call(*self.report_args("compact", event="initial"))
        content = self.cache.read_text()
        block = content.splitlines()
        old = handoff.read(block)
        old.pop("policy")
        encoded = []
        handoff.store(encoded, old)
        block = [encoded[0] if line.startswith(handoff.PREFIX) else line for line in block]
        self.cache.write_text("\n".join(block) + "\n")
        response = self.call("context", "D014")
        self.assertTrue(response["compression_check"]["policy_changed"])
        self.assertIn("policy-upgrade", response["compression_check"]["reason_codes"])
        self.assertEqual(self.snapshot()["handoff"]["sections"], old["sections"])
        self.call(*self.report_args("compact", event="upgrade"))
        self.assertEqual(self.snapshot()["handoff"]["policy"], handoff.POLICY)
        self.assertFalse(self.call("context", "D014")["compression_check"]["recommended"])

    def test_resources_and_complete_sources_are_retrievable_and_bad_inputs_are_atomic(self):
        args = self.report_args("compact", event="resources")
        path = Path(args[args.index("--handoff-file") + 1])
        value = json.loads(path.read_text())
        value["resources"] = [{"topic": "退款边界", "source": "record:1",
                                "when_to_read": "排查退款或修改金额计算时"}]
        path.write_text(json.dumps(value, ensure_ascii=False))
        self.call(*args)
        response = self.call("context", "D014")
        self.assertEqual(self.snapshot()["handoff"]["resources"], value["resources"])
        self.assertIn("排查退款或修改金额计算时", response["context"])
        for source in response["context_sources"]:
            self.assertIn("--cache", source["read_command"])
            self.assertIn(str(self.cache), source["read_command"])
            complete = self.call("inspect", "D014", "--section", source["section"])
            self.assertTrue(complete["data"])
            self.assertEqual(complete["revision"], response["item"]["revision"])
        before = self.cache.read_bytes()
        args = self.report_args("compact", event="invalid-resources")
        path = Path(args[args.index("--handoff-file") + 1])
        value = json.loads(path.read_text())
        value["resources"] = [{"topic": "不得丢失来源", "source": ""}]
        path.write_text(json.dumps(value, ensure_ascii=False))
        self.assertEqual(self.call(*args, success=False)["error"]["code"], "INVALID_HANDOFF_DATA")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_user_proof_is_deferred_but_never_lost_or_treated_as_completion(self):
        proof = self.root / "上线证据.png"
        proof.write_bytes(b"test image placeholder")
        requirement = self.root / "咒言.png"
        requirement.write_bytes(b"test requirement placeholder")
        image = "![发布证据](<" + str(proof) + ">)"
        spell_image = "![咒言图](<" + str(requirement) + ">)"
        self.cache.write_text(self.before.replace("- **提示词**：", "- **提示词**：" + spell_image + "\n    "))
        args = self.report_args("compact", event="proof")
        args += ["--release-item", json.dumps({"summary": "发布 Ultra 服务", "details": "真实开发分支"})]
        self.call(*args)
        # Preserve exactly the cache format written by the real checklist codec.
        current = self.cache.read_text()
        block = current.splitlines()
        checklist = base.module.read_release_checklist(block)
        checklist["items"][0]["evidence"] = image
        checklist["items"][0]["updated_by"] = "user"
        encoded = base64.b64encode(json.dumps(checklist, ensure_ascii=False).encode()).decode()
        block = [base.module.RELEASE_PREFIX + encoded + base.module.META_SUFFIX
                 if line.startswith(base.module.RELEASE_PREFIX) else line for line in block]
        self.cache.write_text("\n".join(block) + "\n")
        response = self.call("context", "D014")
        entry = response["item"]["release_checklist"]["items"][0]
        self.assertTrue(entry["has_evidence"])
        self.assertFalse(entry["done"])
        self.assertEqual(entry["updated_by"], "user")
        self.assertNotIn(str(proof), response["context"])
        self.assertNotIn(str(proof), [x["path"] for x in response["images"]])
        self.assertIn(str(requirement), [x["path"] for x in response["images"]])
        complete = self.call("inspect", "D014", "--section", "release")["data"]["release_checklist"]
        self.assertEqual(complete["items"][0]["evidence"], image)
        self.assertIn(str(proof), [x["path"] for x in self.call("inspect", "D014", "--section", "images")["data"]["images"]])
        self.assertIn(str(proof), self.call("context", "D014", "--full")["context"])


if __name__ == "__main__":
    unittest.main()
