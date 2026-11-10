import base64
import json
import unittest
import test_dboard_ai as base


class CodeReviewTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown
    call = base.FeedbackTests.call
    show = base.FeedbackTests.show
    args = base.FeedbackTests.args
    repo = base.FeedbackTests.repo

    def record_repository(self):
        path = self.repo()
        (path / "api.txt").write_text("initial implementation")
        base.subprocess.run(["git", "-C", str(path), "add", "."], check=True)
        base.subprocess.run(["git", "-C", str(path), "-c", "user.name=Test", "-c",
                             "user.email=test@example.invalid", "commit", "-qm", "测试基线"], check=True)
        self.call(*self.args(self.show(), "--repo", str(path)))
        return path

    def review_args(self, item=None, result="clear", event="cr-1"):
        item = item or self.show()
        flags = ["--task", "code-review", "--review-result", result,
                 "--summary", "[CR] 已审范围未发现确定问题，外部联调仍待用户验证。",
                 "--details", "repo：基线与终点为实际提交，已检查未提交内容和调用链；未执行外部联调。",
                 "--event-id", event]
        if item["code_revision"]:
            flags += ["--expect-code", item["code_revision"]]
        return ["report", item["id"], "--expect-title", item["title"], "--expect-revision", item["revision"], "--no-sync"] + flags

    def prepare_review_history(self, state="missing"):
        progress = "\n".join("    - 11.6: 历史概括" + str(index) +
                              "\n        明细：\n        未加载的历史细节" + str(index)
                              for index in range(1, 81))
        self.cache.write_text(self.before.replace("    - 10.1: 原有进度", progress))
        lines, newline = base.module.read_content(self.cache)
        first, last = base.module.locate(lines, "D014")
        block = lines[first:last]
        if state != "missing":
            records = base.module.progress_records(base.module.fields(block)["进度"])
            covered = records[:40]
            handoff = base.module.dboard_handoff.update(None, covered, covered,
                base.module.execution_scope(block), None, "skip", "已记录此前实现状态，后续记录尚未归纳。",
                {"based_on_records": len(covered), "sections": {
                    "completed": "已实现锁券接口。",
                    "pending": "待用户与上游联调。",
                    "decisions": "开工单后先查券再锁券。",
                    "verification": "已做本地验证，外部联调未完成。"}, "references": []})
            base.module.dboard_handoff.store(block, handoff)
            if state == "invalid":
                block = [row.replace("历史概括1", "用户纠正了旧概括1", 1) for row in block]
            lines[first:last] = block
            self.cache.write_text(newline.join(lines))

    def compact_context(self, task="code-review"):
        proc = base.subprocess.run([base.sys.executable, str(base.CLI), "--cache", str(self.cache),
                                    "context", "D014", "--task", task],
                                   capture_output=True, text=True, timeout=15)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return json.loads(proc.stdout)

    def test_review_never_requires_automatic_history_reads_or_rebuilds_summary(self):
        for state in ("missing", "outdated", "invalid"):
            with self.subTest(state=state):
                self.prepare_review_history(state)
                before = self.cache.read_bytes()
                review = self.compact_context()
                self.assertEqual(review["reading_order"],
                    ["spell-and-changes", "handoff-and-code", "related-history-if-needed"])
                self.assertEqual(review["history_read_policy"], "on-demand")
                self.assertFalse(review["history_read_required"])
                self.assertEqual(review["item"]["history_records"], 80)
                self.assertTrue(review["compression_check"]["ai_review_required"])
                self.assertIn("拆出锁券", review["context"])
                self.assertNotIn("未加载的历史细节", review["context"])
                self.assertNotIn("--all --details", review["context"])
                self.assertNotIn("先按history命令读取历史", review["context"])
                if state != "missing":
                    self.assertIn("已实现锁券接口", review["context"])
                ordinary = self.compact_context("continue")
                self.assertTrue(ordinary["history_read_required"])
                self.assertEqual(self.cache.read_bytes(), before)

    def test_review_without_handoff_preserves_unread_history_and_existing_summary_coverage(self):
        for state in ("missing", "outdated"):
            with self.subTest(state=state):
                self.prepare_review_history(state)
                before = self.show()
                args = self.review_args(before, result="limited", event="review-coverage-" + state)
                args += ["--compression-decision", "skip", "--compression-reason",
                         "本轮CR按需求和代码核对；未整理全部历史，保留原摘要及未覆盖记录。"]
                self.assertNotIn("--handoff-file", args)
                self.call(*args)
                after = self.show()
                self.assertEqual(after["progress_records"][:-1], before["progress_records"])
                self.assertEqual(len(after["progress_records"]), 81)
                if before["handoff"] is None:
                    self.assertIsNone(after["handoff"])
                else:
                    for key in ("sections", "covered_count", "progress_hash", "compacted_count", "compacted_hash"):
                        self.assertEqual(after["handoff"][key], before["handoff"][key], key)
                self.assertFalse(self.compact_context()["history_read_required"])
                self.assertTrue(self.compact_context("continue")["history_read_required"])

    def test_archived_review_can_save_without_rebuilding_summary_or_modifying_snapshot(self):
        self.prepare_review_history()
        archive = self.root / "dboard-archive-cache.md"
        self.cache.rename(archive)
        self.cache = archive
        self.cache.write_text(self.cache.read_text().replace("#进行中", "#已完成", 1))
        before = self.cache.read_bytes()
        args = self.review_args(result="limited", event="archive-without-handoff")
        args += ["--compression-decision", "skip", "--compression-reason",
                 "本轮审查不需要整体整理历史，只保留审查结论和未覆盖边界。"]
        self.call(*args)
        self.assertEqual(self.cache.read_bytes(), before)
        row = json.loads((self.root / "dboard-archive-code-reviews.json").read_text())["records"][-1]
        self.assertIsNone(row["handoff"])
        self.assertEqual(row["result"], "limited")

    def test_context_is_explicit_read_only_and_uses_latest_entire_scope(self):
        self.record_repository()
        change = [{"id": "C001", "createdAt": "2026-11-06T10:00:00Z", "intent": "查询失败不得锁券"}]
        encoded = base64.b64encode(json.dumps(change, ensure_ascii=False).encode()).decode()
        self.cache.write_text(self.cache.read_text().replace("- **进度**：",
            "- **变更咒言**：\n    <!-- dboard-changes:v1:" + encoded + " -->\n"
            "    ### C001 · 2026-11-06T10:00:00Z\n    查询失败不得锁券\n- **进度**：", 1))
        before = self.cache.read_bytes()
        result = self.call("context", "D014", "--task", "code-review")
        self.assertEqual(result["task"], "code-review")
        self.assertIn("拆出锁券", result["context"])
        self.assertIn("查询失败不得锁券", result["context"])
        self.assertIn("完整实现", result["context"])
        self.assertNotIn("先反馈 developing 并补齐", result["context"])
        self.assertNotIn("主动回退 developing", result["context"])
        self.assertNotIn("再用 report --release-add 补充", result["context"])
        self.assertIn("code-review", result["reference_commands"])
        self.assertIn("--task code-review", result["review_instructions"])
        self.assertIsNone(result["debug_instructions"])
        self.assertEqual(result["item"]["code_revision"], self.show()["code_revision"])
        self.assertTrue(result["compression_check"]["ai_review_required"])
        self.assertEqual(self.cache.read_bytes(), before)
        error = self.call("context", "D014", "--task", "code-review", "--change", "C001", success=False)
        self.assertEqual(error["error"]["code"], "INVALID_ARGUMENT")

    def test_review_feedback_preserves_business_state_and_is_idempotent(self):
        self.record_repository()
        item = self.show()
        self.call(*self.args(item, "--stage", "development-complete", "--summary", "开发已完成，待用户联调。",
                             "--details", "已按当前实现完成开发核验，外部联调未做。"))
        before = self.show()
        arguments = self.review_args(before)
        result = self.call(*arguments)["item"]
        after = self.show()
        for key in ("status", "prompt", "changes", "repositories", "execution", "release_checklist"):
            self.assertEqual(after[key], before[key], key)
        self.assertEqual(len(after["progress_records"]), len(before["progress_records"]) + 1)
        self.assertEqual(after["last_code_review"]["code_revision"], before["code_revision"])
        self.assertEqual(after["last_code_review"]["code"], before["current_code"])
        saved = self.cache.read_bytes()
        self.assertTrue(self.call(*arguments)["duplicate"])
        self.assertEqual(self.cache.read_bytes(), saved)
        self.assertEqual(result["status"], "进行中")

    def test_stale_code_and_mutating_flags_cannot_save_review(self):
        path = self.record_repository()
        before = self.show()
        arguments = self.review_args(before)
        saved = self.cache.read_bytes()
        (path / "api.txt").write_text("changed after review")
        self.assertEqual(self.call(*arguments, success=False)["error"]["code"], "CODE_REVISION_CONFLICT")
        self.assertEqual(self.cache.read_bytes(), saved)
        for flags in (["--repo", str(path)], ["--stage", "developing"], ["--release-add", "发布服务"]):
            with self.subTest(flags=flags):
                args = self.review_args(self.show()) + flags
                self.assertEqual(self.call(*args, success=False)["error"]["code"], "REVIEW_READ_ONLY")
                self.assertEqual(self.cache.read_bytes(), saved)

    def test_missing_code_only_allows_limited_and_incident_cr_does_not_collect_experience(self):
        self.assertEqual(self.call(*self.review_args(), success=False)["error"]["code"], "CODE_REVISION_CONFLICT")
        self.cache.write_text(self.cache.read_text().replace("### D014【", "### P001【", 1)
                              .replace("- **描述**：", "- **类型**：线上排查\n- **描述**：", 1))
        self.before = self.cache.read_text()
        item = self.call("show", "P001")["item"]
        args = self.review_args(item, result="limited")
        args[1] = "P001"
        result = self.call(*args)["item"]
        self.assertIsNone(result["experience_review"])
        self.assertEqual(result["last_code_review"]["result"], "limited")

    def test_completed_demand_only_accepts_read_only_review(self):
        self.record_repository()
        self.cache.write_text(self.cache.read_text().replace("#进行中", "#已完成", 1))
        item = self.show()
        ordinary = self.args(item, "--summary", "不应重新开发。")
        self.assertEqual(self.call(*ordinary, success=False)["error"]["code"], "DEMAND_COMPLETED")
        result = self.call(*self.review_args(item))["item"]
        self.assertEqual(result["status"], "已完成")
        self.assertIn("[CR]", self.show()["progress_records"][-1]["summary"])

    def test_archive_review_keeps_snapshot_identity_and_stores_details_separately(self):
        self.record_repository()
        archive = self.root / "dboard-archive-cache.md"
        self.cache.rename(archive)
        self.cache = archive
        self.cache.write_text(self.cache.read_text().replace("#进行中", "#已完成", 1))
        before = self.cache.read_bytes()
        item = self.show()
        arguments = self.review_args(item)
        self.call(*arguments)
        self.assertEqual(self.cache.read_bytes(), before)
        notes = json.loads((self.root / "dboard-archive-code-reviews.json").read_text())
        self.assertEqual(len(notes["records"]), 1)
        self.assertEqual(notes["records"][0]["source_revision"], item["revision"])
        self.assertEqual(notes["records"][0]["code_revision"], item["code_revision"])
        self.assertTrue(self.call(*arguments)["duplicate"])
        self.assertEqual(len(json.loads((self.root / "dboard-archive-code-reviews.json").read_text())["records"]), 1)
        inspect = self.call("inspect", "D014", "--section", "code")["data"]
        self.assertIn("未执行外部联调", inspect["archived_code_reviews"][-1]["details"])
        context = self.call("context", "D014", "--task", "code-review")
        self.assertIn("[CR]", context["context"])
        self.assertEqual(self.show()["revision"], item["revision"])
        self.assertEqual(self.cache.read_bytes(), before)

    def test_corrupt_archive_review_data_is_preserved(self):
        self.cache = self.root / "dboard-archive-cache.md"
        self.cache.write_text(self.before)
        path = self.root / "dboard-archive-code-reviews.json"
        path.write_text('{"version":1,"records":42}')
        before = path.read_bytes()
        result = self.call("context", "D014", "--task", "code-review", success=False)
        self.assertEqual(result["error"]["code"], "INVALID_REVIEW_DATA")
        self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
