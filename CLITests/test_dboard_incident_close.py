import base64
import contextlib
import io
import json
import stat
import subprocess
import sys
import unittest
from unittest import mock

import test_dboard_ai as base

module = base.module


class IncidentCloseTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown

    def call(self, *args, success=True):
        proc = subprocess.run([sys.executable, str(base.CLI), "--cache", str(self.cache), *args],
                              capture_output=True, text=True, timeout=20)
        result = json.loads(proc.stdout)
        self.assertEqual(proc.returncode == 0, success, proc.stdout + proc.stderr)
        return result

    def incident(self, item_id="P001", status="进行中"):
        content = self.before.replace("### D014【fixture】", "### " + item_id + "【fixture】")
        content = content.replace("锁券接口 #进行中", "锁券接口 #" + status)
        content = content.replace("- **描述**：原始描述", "- **类型**：线上排查\n- **描述**：原始描述")
        self.cache.write_text(content)

    def args(self, item_id="P001", outcome="resolved", summary="配置已修正，问题恢复。", details=None):
        item = self.call("show", item_id)["item"]
        args = ["incident", "close", item_id, "--expect-title", item["title"],
                "--expect-revision", item["revision"], "--outcome", outcome, "--summary", summary]
        if details is not None:
            args += ["--details", details]
        return args

    def add_release(self, done=False):
        data = {"items": [{"id": "L001", "text": "发布 ultra 服务", "done": done,
                          "updated_by": "user", "category": "release", "details": "feature/fix",
                          "evidence": "用户核对的证据"}],
                "next_id": 2, "excluded_by_user": [], "reviewed_scope": None}
        self.cache.write_text(self.cache.read_text().replace("- **类型**：线上排查",
            module.RELEASE_PREFIX + base64.b64encode(json.dumps(data).encode()).decode()
            + module.META_SUFFIX + "\n- **类型**：线上排查"))
        return data

    def test_lightweight_close_keeps_sources_and_local_details_and_is_retry_safe(self):
        self.incident()
        args = self.args(details="证据：接口恢复。\n交接：继续观察。")
        before = self.cache.read_text()
        result = self.call(*args)
        self.assertTrue(result["local_saved"])
        self.assertEqual(result["sync"]["status"], "skipped")
        self.assertFalse(result["unchanged"])
        item = self.call("show", "P001", "--full")["item"]
        self.assertEqual(item["status"], "已完成")
        self.assertEqual(item["incident_closure"]["outcome"], "已处理")
        self.assertEqual(item["incident_closure"]["summary"], "配置已修正，问题恢复。")
        self.assertEqual(len(item["progress_records"]), 2)
        self.assertEqual(item["progress_records"][-1]["details"], "证据：接口恢复。\n交接：继续观察。")
        self.assertEqual(item["prompt"], "## 要做什么\n拆出锁券\n\n## 代码样例\n保留所有缩进")
        self.assertIn(before[before.index("### D0140"):], self.cache.read_text())
        self.assertEqual(stat.S_IMODE(self.cache.stat().st_mode), 0o600)
        saved = self.cache.read_bytes()
        self.assertTrue(self.call(*args)["unchanged"])  # The original revision is now stale.
        changed = args[:]
        changed[changed.index("--summary") + 1] = "不应覆写旧结论。"
        self.assertTrue(self.call(*changed)["unchanged"])
        self.assertEqual(self.cache.read_bytes(), saved)
        context = self.call("context", "P001")
        self.assertFalse(context["experience_review"]["required"])
        self.assertNotIn("incident_commands", context)
        self.assertIn("配置已修正，问题恢复。", context["context"])

    def test_all_outcomes_and_pending_suspended_or_undated_statuses(self):
        for status, outcome, label in [("待开始", "resolved", "已处理"),
                                        ("进行中🎯2026-11-10", "handed-off", "已定位并交接"),
                                        ("挂起", "stopped", "结束本次排查，原因未定"),
                                        ("", "stopped", "结束本次排查，原因未定")]:
            with self.subTest(status=status):
                self.incident(status=status)
                self.call(*self.args(outcome=outcome))
                item = self.call("show", "P001")["item"]
                self.assertEqual(item["status"], "已完成")
                self.assertEqual(item["incident_closure"]["outcome"], label)

    def test_old_d_numbered_incident_closes_but_development_even_with_p_number_does_not(self):
        self.incident(item_id="D014")
        self.call(*self.args(item_id="D014"))
        for item_id in ("D014", "P001"):
            with self.subTest(item_id=item_id):
                self.cache.write_text(self.before.replace("### D014【fixture】", "### " + item_id + "【fixture】"))
                before = self.cache.read_bytes()
                result = self.call(*self.args(item_id=item_id), success=False)
                self.assertEqual(result["error"]["code"], "INCIDENT_TASK_REQUIRED")
                self.assertEqual(self.cache.read_bytes(), before)

    def test_title_or_revision_conflict_never_closes(self):
        for field, value, code in [("--expect-title", "另一排查", "TITLE_MISMATCH"),
                                   ("--expect-revision", "0" * 64, "REVISION_CONFLICT")]:
            with self.subTest(field=field):
                self.incident()
                args = self.args()
                args[args.index(field) + 1] = value
                before = self.cache.read_bytes()
                self.assertEqual(self.call(*args, success=False)["error"]["code"], code)
                self.assertEqual(self.cache.read_bytes(), before)

    def test_open_release_items_block_close_completed_items_are_preserved(self):
        self.incident()
        self.add_release()
        before = self.cache.read_bytes()
        result = self.call(*self.args(), success=False)
        self.assertEqual(result["error"]["code"], "RELEASE_CHECKLIST_INCOMPLETE")
        self.assertEqual(self.cache.read_bytes(), before)
        self.incident()
        data = self.add_release(done=True)
        self.call(*self.args())
        checklist = self.call("show", "P001")["item"]["release_checklist"]
        self.assertEqual(checklist["items"], data["items"])

    def test_malformed_closure_or_checklist_is_not_treated_as_empty(self):
        for prefix, code in [("<!-- dboard-incident-closure:v1:", "INVALID_INCIDENT_CLOSURE"),
                             (module.RELEASE_PREFIX, "INVALID_RELEASE_CHECKLIST")]:
            with self.subTest(prefix=prefix):
                self.incident()
                self.cache.write_text(self.cache.read_text().replace("- **类型**",
                    prefix + "broken -->\n- **类型**"))
                before = self.cache.read_bytes()
                args = ["incident", "close", "P001", "--expect-title", "锁券接口",
                        "--expect-revision", "0" * 64, "--outcome", "resolved", "--summary", "完成。"]
                self.assertEqual(self.call(*args, success=False)["error"]["code"], code)
                self.assertEqual(self.cache.read_bytes(), before)

    def test_summary_validation_and_archive_snapshot_are_read_only(self):
        self.incident()
        args = self.args()
        for summary in (" ", "超" * 121, "第一行\n第二行"):
            with self.subTest(summary=summary):
                invalid = args[:]
                invalid[invalid.index("--summary") + 1] = summary
                before = self.cache.read_bytes()
                self.assertEqual(self.call(*invalid, success=False)["error"]["code"], "INVALID_ARGUMENT")
                self.assertEqual(self.cache.read_bytes(), before)
        archive = self.root / "dboard-archive-cache.md"
        self.cache.rename(archive)
        self.cache = archive
        before = self.cache.read_bytes()
        self.assertEqual(self.call(*args, success=False)["error"]["code"], "ARCHIVE_READ_ONLY")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_line_endings_and_missing_final_newline_are_preserved(self):
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=newline):
                self.incident()
                self.cache.write_bytes(self.cache.read_text().rstrip("\n").replace("\n", newline).encode())
                self.call(*self.args())
                saved = self.cache.read_bytes()
                self.assertFalse(saved.endswith(newline.encode()))
                if newline == "\r\n":
                    self.assertNotIn(b"\n", saved.replace(b"\r\n", b""))

    def test_sync_failure_reports_local_saved_and_retry_does_not_duplicate(self):
        self.incident()
        args = self.args()
        with mock.patch.object(module, "DEFAULT_CACHE", self.cache), \
                mock.patch.object(module, "sync_cache", return_value={"success": False, "status": "sync-failed"}) as sync:
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = module.main(["--cache", str(self.cache), *args])
            result = json.loads(output.getvalue())
            self.assertEqual(code, 3)
            self.assertFalse(result["success"])
            self.assertTrue(result["local_saved"])
            sync.assert_called_once()
            saved = self.cache.read_bytes()
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(module.main(["--cache", str(self.cache), *args, "--no-sync"]), 0)
            self.assertEqual(self.cache.read_bytes(), saved)
            self.assertEqual(sync.call_count, 1)

    def test_context_exposes_current_target_command_only_for_active_incidents(self):
        self.incident()
        result = self.call("context", "P001")
        command = result["incident_commands"]["close"]
        self.assertIn("incident close P001", command)
        self.assertIn(result["item"]["revision"], command)
        self.assertIn("--expect-title", command)
        self.assertNotIn("incident_commands", self.call("context", "D0140"))


if __name__ == "__main__":
    unittest.main()
