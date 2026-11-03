import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

CLI = Path(__file__).resolve().parents[1] / "Tools/dboard_ai.py"
spec = importlib.util.spec_from_file_location("dboard_ai", CLI)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FeedbackTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.cache = self.root / "cache.md"
        self.before = (
            "## 🟡 重要\n\n### D014【fixture】锁券接口 #进行中\n"
            "- **描述**：原始描述\n- **分支**：待定\n- **提示词**：\n"
            "    ## 要做什么\n    拆出锁券\n    \n    ## 代码样例\n    保留所有缩进\n"
            "- **进度**：\n    - 10.1: 原有进度\n\n"
            "### D0140【fixture】另一个需求 #待开始\n- **描述**：不许改动\n\n"
            "## 🗓 今日零碎\n### 2026-10-30\n- [ ] 原始零碎\n"
        )
        self.cache.write_text(self.before, encoding="utf-8")
        self.cache.chmod(0o600)

    def tearDown(self):
        self.directory.cleanup()

    def call(self, *args, success=True):
        proc = subprocess.run([sys.executable, str(CLI), "--cache", str(self.cache)] + list(args),
                              capture_output=True, text=True, timeout=15)
        result = json.loads(proc.stdout)
        if success:
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
            self.assertTrue(result["success"])
        else:
            self.assertNotEqual(proc.returncode, 0)
            self.assertFalse(result["success"])
        return result

    def show(self):
        return self.call("show", "D014")["item"]

    def args(self, item, *extra):
        return ["report", "D014", "--expect-title", item["title"],
                "--expect-revision", item["revision"], "--no-sync"] + list(extra)

    def repo(self, name="repo", branch="feature/fixture"):
        path = self.root / name
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "symbolic-ref", "HEAD", "refs/heads/" + branch], check=True)
        return path

    def test_summary_and_local_details_roundtrip_and_retry(self):
        before = self.show()
        detail = "验证：3 项回归通过。\n\n### D999 是明细标题\n- **描述**：不能变成顶层字段\n    - 11.2: 保留代码缩进"
        args = self.args(before, "--summary", "接口实现完成，待联调。",
                         "--details", detail, "--event-id", "summary-detail")
        result = self.call(*args)
        record = result["item"]["progress_records"][-1]
        self.assertEqual(record, {"date": record["date"], "summary": "接口实现完成，待联调。", "details": detail})
        self.assertEqual(result["item"]["description"], "原始描述")
        context = self.call("context", "D014")["context"]
        self.assertIn(detail.split("\n")[0], context)
        self.assertIn("### D999 是明细标题", context)
        duplicate = self.call(*args)
        self.assertTrue(duplicate["duplicate"])
        self.assertEqual(len(duplicate["item"]["progress_records"]), 2)
        failed = self.call(*self.args(self.show(), "--summary", "接口实现完成，待联调。",
                                    "--details", "不同明细", "--event-id", "summary-detail"), success=False)
        self.assertEqual(failed["error"]["code"], "EVENT_CONFLICT")
        self.assertIn("不许改动", self.cache.read_text())

    def test_long_summary_and_orphan_details_are_rejected_without_writing(self):
        for args in (("--summary", "长" * 121), ("--progress", "长" * 121), ("--details", "只有明细")):
            with self.subTest(args=args):
                self.call(*self.args(self.show(), *args), success=False)
                self.assertEqual(self.cache.read_text(), self.before)

    def test_legacy_full_progress_is_preserved_with_a_short_preview(self):
        text = "实现已完成；" + "历史排查明细" * 50
        self.cache.write_text(self.before.replace("原有进度", text))
        record = self.show()["progress_records"][0]
        self.assertEqual(record["summary"], "实现已完成。")
        self.assertEqual(record["details"], text)
        self.assertIn(text, self.call("context", "D014")["context"])

    def test_show_reads_exact_id_only_and_is_read_only(self):
        result = self.show()
        self.assertEqual(result["id"], "D014")
        self.assertEqual(result["title"], "锁券接口")
        self.assertNotIn("不许改动", json.dumps(result, ensure_ascii=False))
        self.assertEqual(self.cache.read_text(), self.before)
        self.call("show", "D999", success=False)

    def test_context_returns_complete_read_only_snapshot_and_feedback_rules(self):
        output = io.StringIO()
        with mock.patch.object(module, "DEFAULT_CACHE", self.cache), \
             mock.patch.object(module, "sync_cache") as sync, contextlib.redirect_stdout(output):
            code = module.main(["--cache", str(self.cache), "context", "D014"])
        result = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        sync.assert_not_called()
        self.assertTrue(result["success"])
        self.assertEqual(result["item"]["id"], "D014")
        self.assertEqual(result["item"]["revision"], self.show()["revision"])
        self.assertEqual(result["item"]["location"]["cache"], str(self.cache.resolve()))
        self.assertEqual(result["cli"], str(Path.home() / ".local/bin/dboard-ai"))
        self.assertIsNone(result["change_id"])
        self.assertIn("拆出锁券", result["context"])
        self.assertIn("保留所有缩进", result["context"])
        self.assertIn("原始描述", result["context"])
        self.assertIn("原有进度", result["context"])
        self.assertIn("D板是用户的个人工作看板", result["context"])
        self.assertIn("每完成一轮", result["feedback_instructions"])
        self.assertIn("--expect-revision", result["feedback_instructions"])
        self.assertNotIn("不许改动", json.dumps(result, ensure_ascii=False))
        self.assertEqual(self.cache.read_text(), self.before)

    def test_context_reads_later_progress_and_actual_repository(self):
        first = self.call("context", "D014")
        repo = self.repo()
        updated = self.call(*self.args(self.show(), "--repo", str(repo),
            "--progress", "开发完成，待验收；复制后新增的进度", "--event-id", "later-context"))
        content = self.cache.read_bytes()
        latest = self.call("context", "D014")
        self.assertNotEqual(first["item"]["revision"], latest["item"]["revision"])
        self.assertEqual(latest["item"]["revision"], updated["item"]["revision"])
        self.assertIn(str(repo), latest["context"])
        self.assertIn("feature/fixture", latest["context"])
        self.assertIn("原有进度", latest["context"])
        self.assertIn("复制后新增的进度", latest["context"])
        self.assertNotIn("dboard-ai-feedback:v1:", latest["context"])
        self.assertEqual(self.cache.read_bytes(), content)

    def test_context_targets_one_change_and_preserves_pending_acceptance(self):
        changes = [
            {"id": "C001", "createdAt": "2026-10-30T12:00:00Z", "intent": "本次追加照片字段"},
            {"id": "C002", "createdAt": "2026-10-30T13:00:00Z", "intent": "此前追加重试限制"},
        ]
        encoded = base64.b64encode(json.dumps(changes, ensure_ascii=False).encode()).decode()
        value = "<!-- dboard-changes:v1:" + encoded + " -->\n" + "\n".join(
            "### " + c["id"] + " · " + c["createdAt"] + "\n" + c["intent"] for c in changes)
        field = "- **变更咒言**：\n" + "\n".join("    " + line for line in value.split("\n")) + "\n"
        content = self.before.replace("- **分支**：待定\n", "- **分支**：feature/existing\n" + field)
        content = content.replace("原有进度", "开发完成，尚未联调验收")
        self.cache.write_text(content, encoding="utf-8")
        result = self.call("context", "D014", "--change", "C001")
        self.assertEqual(result["change_id"], "C001")
        self.assertIn("## 本次追加变更 C001", result["context"])
        self.assertEqual(result["context"].count("本次追加照片字段"), 1)
        self.assertIn("此前追加重试限制", result["context"])
        self.assertIn("feature/existing", result["context"])
        self.assertIn("尚未联调验收", result["context"])
        self.assertIn("每轮写回进度时带上 [C001]", result["context"])
        self.assertNotIn("dboard-changes:v1:", result["context"])
        normal = self.call("context", "D014")
        self.assertIn("## 已记录的追加变更", normal["context"])
        self.assertEqual(normal["context"].count("本次追加照片字段"), 1)
        self.assertEqual(self.cache.read_text(), content)

    def test_context_rejects_missing_targets_and_corrupt_change_data(self):
        self.assertEqual(self.call("context", "D999", success=False)["error"]["code"], "NOT_FOUND")
        self.assertEqual(self.call("context", "D014", "--change", "C999", success=False)["error"]["code"],
                         "CHANGE_NOT_FOUND")
        self.assertEqual(self.call("context", "D014", "--change", "invalid", success=False)["error"]["code"],
                         "INVALID_CHANGE_ID")
        corrupted = self.before.replace("- **分支**：待定\n",
            "- **分支**：待定\n- **变更咒言**：\n    <!-- dboard-changes:v1:broken -->\n    user text\n")
        self.cache.write_text(corrupted, encoding="utf-8")
        self.assertEqual(self.call("context", "D014", success=False)["error"]["code"], "INVALID_CHANGE_DATA")
        self.assertEqual(self.cache.read_text(), corrupted)

    def write_prompt(self, prompt):
        content = (self.before.split("- **提示词**：", 1)[0] + "- **提示词**：\n" +
                   "\n".join("    " + line for line in prompt.split("\n")) + "\n" +
                   "- **进度**：" + self.before.split("- **进度**：", 1)[1])
        self.cache.write_text(content, encoding="utf-8")
        return content

    def test_context_assembles_v2_v3_and_preserves_user_edits(self):
        fields = {"codeEntry": "ultra里的车点点链路", "materials": "https://example.com/方案",
                  "intent": "拆出锁券\n\n    保留代码缩进", "reason": "等开单后再锁", "rules": "先查券再锁券"}
        expected = (
            "## 代码入口\n请根据以下服务、流程描述或代码路径，查找并阅读相关实现：\nultra里的车点点链路\n"
            "## 可能有用的资料\n请查找并阅读以下资料，结合本次任务按需参考：\nhttps://example.com/方案\n"
            "## 要做什么\n拆出锁券\n\n    保留代码缩进")
        bodies = {
            "v2": "## 代码入口\nultra里的车点点链路\n\n## 需求资料\nhttps://example.com/方案\n\n"
                  "## 改造意图\n拆出锁券\n\n    保留代码缩进",
            "v3": "## 代码入口\nultra里的车点点链路\n## 需求资料\nhttps://example.com/方案\n"
                  "## 改造意图\n### 要做什么\n拆出锁券\n\n    保留代码缩进\n"
                  "### 为什么改\n等开单后再锁\n### 特殊规则\n先查券再锁券",
        }
        for version in ("v2", "v3"):
            with self.subTest(version=version):
                payload = fields if version == "v3" else {k: fields[k] for k in ("codeEntry", "materials", "intent")}
                encoded = base64.b64encode(json.dumps(payload, ensure_ascii=False).encode()).decode()
                header = "<!-- dboard-prompt:" + version + ":" + encoded + " -->"
                content = self.write_prompt(header + "\n" + bodies[version])
                result = self.call("context", "D014")
                self.assertIn(expected, result["context"])
                self.assertNotIn("dboard-prompt:", result["context"])
                if version == "v3":
                    self.assertIn("## 补充说明\n等开单后再锁\n先查券再锁券", result["context"])
                self.assertEqual(self.cache.read_text(), content)
                external = "用户外部修改的需求\n\n    保留 Markdown 缩进"
                content = self.write_prompt(header + "\n" + external)
                result = self.call("context", "D014")
                self.assertIn("## 要做什么\n" + external, result["context"])
                self.assertNotIn("拆出锁券", result["context"])
                self.assertEqual(self.cache.read_text(), content)

    def test_context_handles_new_module_free_text_and_empty_progress(self):
        fields = {"codeEntry": "全新模块", "materials": "", "intent": "实现新业务", "reason": None}
        encoded = base64.b64encode(json.dumps(fields, ensure_ascii=False).encode()).decode()
        self.write_prompt("<!-- dboard-prompt:v3:" + encoded + " -->\n"
                          "## 代码入口\n全新模块\n## 改造意图\n### 要做什么\n实现新业务")
        result = self.call("context", "D014")
        self.assertIn("本次为全新模块，请按新的业务模块设计与实现。", result["context"])
        self.assertNotIn("## 补充说明", result["context"])
        for text in ("", "自由文本\n\n    code()", "<!-- dboard-prompt:v3:invalid -->\n保留损坏的原文"):
            with self.subTest(text=text):
                self.write_prompt(text)
                if text:
                    self.assertIn(text, self.call("context", "D014")["context"])
                else:
                    self.assertNotIn("## 要做什么", self.call("context", "D014")["context"])
        empty = self.before.replace("    - 10.1: 原有进度\n", "")
        self.cache.write_text(empty, encoding="utf-8")
        self.assertIn("不能据此认定尚未开发", self.call("context", "D014")["context"])
        self.assertEqual(self.cache.read_text(), empty)

    def test_report_preserves_other_demands_prompt_todos_status_and_mode(self):
        before = self.show()
        repo = self.repo()
        result = self.call(*self.args(before, "--repo", str(repo), "--progress", "实现完成，测试待执行", "--event-id", "start"))
        after = result["item"]
        self.assertEqual(after["branch"], "feature/fixture")
        self.assertEqual(after["description"], before["description"])
        self.assertEqual(after["status"], before["status"])
        self.assertEqual(after["prompt"], before["prompt"])
        self.assertIn("原有进度", after["progress"])
        self.assertIn("实现完成，测试待执行", after["progress"])
        unchanged = self.before.split("### D0140", 1)[1]
        self.assertEqual(self.cache.read_text().split("### D0140", 1)[1], unchanged)
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o600)
        self.assertTrue(result["local_saved"])
        self.assertEqual(result["sync"]["status"], "skipped")

    def test_replay_does_not_duplicate_even_after_other_updates(self):
        before = self.show()
        arguments = self.args(before, "--progress", "已完成接口", "--event-id", "done")
        first = self.call(*arguments)
        second = self.call(*self.args(first["item"], "--progress", "测试通过", "--event-id", "tests"))
        content = self.cache.read_bytes()
        retry = self.call(*arguments)
        self.assertTrue(retry["duplicate"])
        self.assertEqual(self.cache.read_bytes(), content)
        self.assertEqual(retry["item"]["revision"], second["item"]["revision"])

    def test_changed_payload_cannot_reuse_event_id(self):
        before = self.show()
        self.call(*self.args(before, "--progress", "已实现", "--event-id", "same"))
        content = self.cache.read_bytes()
        failed = self.call(*self.args(self.show(), "--progress", "改成另一条进度", "--event-id", "same"), success=False)
        self.assertEqual(failed["error"]["code"], "EVENT_CONFLICT")
        self.assertEqual(content, self.cache.read_bytes())

    def test_stale_revision_title_and_multiline_injection_fail_without_writing(self):
        before = self.show()
        self.cache.write_text(self.cache.read_text().replace("原始描述", "用户修改的描述"), encoding="utf-8")
        content = self.cache.read_bytes()
        result = self.call(*self.args(before, "--progress", "新进度"), success=False)
        self.assertEqual(result["error"]["code"], "REVISION_CONFLICT")
        latest = self.show()
        bad_title = dict(latest, title="错误需求")
        self.call(*self.args(bad_title, "--progress", "新进度"), success=False)
        self.call(*self.args(latest, "--progress", "第一行\n### D001 注入"), success=False)
        self.assertEqual(content, self.cache.read_bytes())

    def test_actual_branch_is_checked_and_multiple_repos_are_retained(self):
        before = self.show()
        repo = self.repo()
        self.call(*self.args(before, "--repo", str(repo), "--branch", "not-active"), success=False)
        self.assertEqual(self.cache.read_text(), self.before)
        first = self.call(*self.args(before, "--repo", str(repo), "--event-id", "repo1"))
        repo2 = self.repo("another", "feature/photos")
        second = self.call(*self.args(first["item"], "--repo", str(repo2), "--event-id", "repo2"))
        self.assertEqual(len(second["item"]["repositories"]), 2)
        self.assertIn("feature/fixture", second["item"]["branch"])
        self.assertIn("feature/photos", second["item"]["branch"])
        subprocess.run(["git", "-C", str(repo), "symbolic-ref", "HEAD", "refs/heads/feature/relock"], check=True)
        latest = self.call(*self.args(second["item"], "--repo", str(repo), "--event-id", "repo1-new"))
        self.assertEqual(len(latest["item"]["repositories"]), 2)
        self.assertIn("feature/relock", latest["item"]["branch"])
        self.assertNotIn("feature/fixture", latest["item"]["branch"])

    def test_exact_retry_does_not_capture_another_branch(self):
        before = self.show()
        repo = self.repo()
        arguments = self.args(before, "--repo", str(repo), "--event-id", "branch")
        first = self.call(*arguments)
        subprocess.run(["git", "-C", str(repo), "symbolic-ref", "HEAD", "refs/heads/feature/another"], check=True)
        repeated = self.call(*arguments)
        self.assertTrue(repeated["duplicate"])
        self.assertEqual(first["item"]["branch"], repeated["item"]["branch"])

    def test_parallel_reports_preserve_both_updates_or_report_conflict(self):
        initial = self.show()
        commands = [[sys.executable, str(CLI), "--cache", str(self.cache)] +
                    self.args(initial, "--progress", "阶段" + str(i), "--event-id", "parallel" + str(i))
                    for i in range(2)]
        processes = [subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for command in commands]
        results = [json.loads(p.communicate(timeout=15)[0]) for p in processes]
        self.assertEqual(sum(r["success"] for r in results), 1)
        failed = next(i for i, r in enumerate(results) if not r["success"])
        self.assertEqual(results[failed]["error"]["code"], "REVISION_CONFLICT")
        self.call(*self.args(self.show(), "--progress", "阶段" + str(failed), "--event-id", "parallel" + str(failed)))
        progress = self.show()["progress"]
        self.assertEqual(progress.count("阶段0"), 1)
        self.assertEqual(progress.count("阶段1"), 1)

    def test_completed_duplicate_ids_and_corrupt_metadata_do_not_write(self):
        for transformation in [
            lambda s: s.replace("#进行中", "#已完成"),
            lambda s: s.replace("### D0140", "### D014"),
            lambda s: s.replace("### D0140", "<!-- dboard-ai-feedback:v1:invalid -->\n\n### D0140"),
        ]:
            self.cache.write_text(transformation(self.before), encoding="utf-8")
            content = self.cache.read_bytes()
            self.call("report", "D014", "--expect-title", "锁券接口", "--expect-revision", "a" * 64,
                      "--progress", "不能覆盖", "--no-sync", success=False)
            self.assertEqual(content, self.cache.read_bytes())

    def test_sync_failure_reports_saved_locally_and_retry_is_idempotent(self):
        item = self.show()
        argv = ["--cache", str(self.cache), "report", "D014", "--expect-title", item["title"],
                "--expect-revision", item["revision"], "--progress", "验证通过", "--event-id", "sync-failure"]
        with mock.patch.object(module, "DEFAULT_CACHE", self.cache), \
             mock.patch.object(module, "sync_cache", return_value={"success": False, "status": "remote-failed"}):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = module.main(argv)
            result = json.loads(output.getvalue())
        self.assertEqual(code, 3)
        self.assertFalse(result["success"])
        self.assertTrue(result["local_saved"])
        content = self.cache.read_bytes()
        with mock.patch.object(module, "DEFAULT_CACHE", self.cache), \
             mock.patch.object(module, "sync_cache", return_value={"success": True, "status": "ok"}):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = module.main(argv)
            result = json.loads(output.getvalue())
        self.assertEqual(code, 0)
        self.assertTrue(result["duplicate"])
        self.assertEqual(content, self.cache.read_bytes())

    def test_title_matches_app_display_and_sync_checks_result(self):
        self.cache.write_text(self.before.replace("锁券接口 #进行中",
            "✅ 锁券  📅2026-10-30→🎯2026-11-10 接口 #进行中"), encoding="utf-8")
        self.assertEqual(self.show()["title"], "✅ 锁券 接口")
        script = self.root / "sync.sh"
        script.write_text("printf '%s' '{\"success\":true,\"status\":\"ok\"}'\nexit 1\n")
        with mock.patch.object(module, "DEFAULT_CACHE", self.cache), \
             mock.patch.object(module, "resource_path", return_value=script):
            self.assertFalse(module.sync_cache(self.cache)["success"])
            script.write_text("sleep 30\n")
            self.assertEqual(module.sync_cache(self.cache, timeout=0.1)["status"], "sync-timeout")

    def test_change_spells_are_read_preserved_and_invalid_data_is_rejected(self):
        changes = [{"id": "C001", "createdAt": "2026-10-30T12:00:00Z",
                    "intent": "增加照片字段\n### D999【嵌套】仅为变更内容"}]
        metadata = base64.b64encode(json.dumps(changes, ensure_ascii=False).encode("utf-8")).decode("ascii")
        value = "<!-- dboard-changes:v1:" + metadata + " -->\n### C001 · 2026-10-30T12:00:00Z\n" + changes[0]["intent"]
        field = "- **变更咒言**：\n" + "\n".join("    " + line for line in value.split("\n")) + "\n"
        self.cache.write_text(self.before.replace("- **分支**：待定\n", "- **分支**：待定\n" + field), encoding="utf-8")
        initial = self.show()
        self.assertEqual(initial["changes"], changes)
        result = self.call(*self.args(initial, "--progress", "[C001] 已做：照片查询；待做：联调", "--event-id", "change"))
        self.assertEqual(result["item"]["changes"], changes)
        self.assertIn(field, self.cache.read_text())
        corrupt = self.cache.read_text().replace("    增加照片字段", "    外部编辑后的字段")
        self.cache.write_text(corrupt, encoding="utf-8")
        self.call("show", "D014", success=False)
        failed = self.call(*self.args(result["item"], "--progress", "不应写入"), success=False)
        self.assertEqual(failed["error"]["code"], "INVALID_CHANGE_DATA")
        self.assertEqual(self.cache.read_text(), corrupt)

    def test_version_context_preserves_baseline_and_reports_new_work_only(self):
        version = {"number": 2, "parentID": "D008", "rootID": "D008", "parentTitle": "原版锁券",
                   "sourceRevision": "a" * 64, "background": "上一版已实现锁券\n    保留历史代码缩进",
                   "repositories": [{"path": "/tmp/old-repo", "branch": "feature/old"}]}
        encoded = base64.b64encode(json.dumps(version, ensure_ascii=False).encode()).decode()
        marker = "<!-- dboard-version:v1:" + encoded + " -->"
        content = self.before.replace("### D0140", marker + "\n\n### D0140")
        self.cache.write_text(content, encoding="utf-8")
        context = self.call("context", "D014")
        self.assertIn("## 本轮版本 2.0", context["context"])
        self.assertIn("D008「原版锁券」", context["context"])
        self.assertIn("上一版已实现锁券", context["context"])
        self.assertIn("/tmp/old-repo", context["context"])
        self.assertIn("仅将本轮实际改动和验证结果写回 D014", context["context"])
        self.assertNotIn("dboard-version:v1:", context["context"])
        current = self.show()
        self.assertEqual(current["version"], version)
        self.assertEqual(current["repositories"], [], "历史仓库不是本轮已核验的仓库")
        result = self.call(*self.args(current, "--progress", "2.0 新增重试，待验收", "--event-id", "v2"))
        self.assertEqual(result["item"]["version"], version)
        self.assertIn(marker, self.cache.read_text())
        self.assertNotIn("上一版已实现锁券", result["item"]["progress"])
        self.assertEqual(self.cache.read_text().split("### D0140", 1)[1], self.before.split("### D0140", 1)[1])

    def test_invalid_version_metadata_cannot_be_read_or_overwritten(self):
        valid = {"number": 2, "parentID": "D008", "rootID": "D008", "parentTitle": "原版",
                 "sourceRevision": "a" * 64, "background": "历史背景", "repositories": []}
        for change in ({"number": True}, {"number": 1}, {"parentID": "wrong"},
                       {"sourceRevision": "bad"}, {"background": ""},
                       {"repositories": [{"path": "/tmp/repo"}]}):
            with self.subTest(change=change):
                invalid = dict(valid, **change)
                encoded = base64.b64encode(json.dumps(invalid, ensure_ascii=False).encode()).decode()
                content = self.before.replace("### D0140", "<!-- dboard-version:v1:" + encoded + " -->\n\n### D0140")
                self.cache.write_text(content, encoding="utf-8")
                self.assertEqual(self.call("context", "D014", success=False)["error"]["code"], "INVALID_VERSION_DATA")
                self.assertEqual(self.call("report", "D014", "--expect-title", "锁券接口",
                    "--expect-revision", "a" * 64, "--progress", "不能覆盖", "--no-sync", success=False)["error"]["code"],
                    "INVALID_VERSION_DATA")
                self.assertEqual(self.cache.read_text(), content)

    def test_invalid_commands_return_json_and_guide_is_available(self):
        self.call("delete", "D014", success=False)
        self.call("report", "D014", success=False)
        result = self.call("guide")
        self.assertIn("dboard-feedback", result["instructions"])
        self.assertEqual(self.cache.read_text(), self.before)


if __name__ == "__main__":
    unittest.main()
