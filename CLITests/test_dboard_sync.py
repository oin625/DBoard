import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from dboard_overview import render, digest as overview_digest, PREFIX, NODE_PREFIX

SCRIPT = ROOT / "sync_dboard.sh"
SOURCE = SCRIPT.read_text(encoding="utf-8").split(
    "python3 -I - <<'PYTHON'\n", 1)[1].rsplit("\nPYTHON", 1)[0]
BASE = "## 🟡\n### D014【fixture】接口 #进行中\n- **概括**：拆出独立接口。\n- **进度**：\n    - 11.3: 接口完成，待验收。\n"


class SyncTests(unittest.TestCase):
    def run_sync(self, stdout=b'{"success":true}', exit_code=0, edit=None, fixture=BASE, node="fixture", force=False):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            cache = home / ".claude/demand-center-cache.md"
            cache.parent.mkdir()
            cache.write_text(fixture, encoding="utf-8")
            payloads = []

            def upload(*args, **kwargs):
                command = args[0]
                file = command[command.index("--content-file") + 1]
                payloads.append(Path(file).read_text(encoding="utf-8"))
                if edit:
                    cache.write_text(fixture + edit, encoding="utf-8")
                return subprocess.CompletedProcess(command, exit_code, stdout, b"")

            output = io.StringIO()
            code = 0
            with mock.patch.object(Path, "home", return_value=home), \
                 mock.patch.dict(os.environ, {"DBOARD_NODE_ID": node, "DBOARD_SYNC_SCRIPT": str(SCRIPT),
                                              "DBOARD_SYNC_FORCE": "--force" if force else ""}), \
                 mock.patch("subprocess.run", side_effect=upload), contextlib.redirect_stdout(output):
                try:
                    exec(compile(SOURCE, str(SCRIPT), "exec"), {})
                except SystemExit as error:
                    code = error.code
            return code, json.loads(output.getvalue()), cache.read_text(encoding="utf-8"), payloads

    def receipt(self, content=BASE, node="fixture"):
        return ("<!-- synced: 2026-11-03T10:00:00 -->\n<!-- synced-hash: legacy -->\n" +
                PREFIX + overview_digest(content) + " -->\n" + NODE_PREFIX + node + " -->\n" + content)

    def test_upload_excludes_full_context_history_and_todos_while_local_data_survives(self):
        fixture = BASE + ("- **提示词**：\n    ## 资料\n    本地咒言和图片\n"
                          "- **关联群聊**：{\"id\":\"private-cid\"}\n"
                          "- **分支**：feature/private\n"
                          "<!-- dboard-version:v1:private-history -->\n"
                          "## 📝 零碎\n### 2026-11-03\n- [x] 已完成零碎\n- [ ] 本地待办\n")
        fixture = fixture.replace("    - 11.3:", "    - 11.2: 早期阻塞已排查。\n    - 11.3:")
        code, result, local, payloads = self.run_sync(fixture=fixture)
        self.assertEqual(code, 0)
        self.assertTrue(result["success"])
        self.assertEqual(len(payloads), 1)
        self.assertIn("拆出独立接口", payloads[0])
        self.assertIn("接口完成，待验收", payloads[0])
        for private in ["本地咒言", "private-cid", "feature/private", "private-history", "已完成零碎", "本地待办", "早期阻塞"]:
            self.assertNotIn(private, payloads[0])
            self.assertIn(private, local)
        self.assertTrue(local.endswith(fixture))

    def test_repeated_sync_and_hidden_edits_do_not_upload_or_advance_actual_sync_time(self):
        original = self.receipt()
        fixture = original + "- **分支**：feature/new\n- **提示词**：\n    新的本地上下文\n"
        code, result, local, payloads = self.run_sync(fixture=fixture)
        self.assertEqual(code, 0)
        self.assertEqual(result, {"success": True, "status": "unchanged"})
        self.assertEqual(payloads, [])
        self.assertIn("2026-11-03T10:00:00", local)
        self.assertIn("新的本地上下文", local)

    def test_new_progress_and_explicit_force_each_upload(self):
        for fixture, force in [(self.receipt() + "    - 11.3: 上游联调通过，待验收。\n", False),
                               (self.receipt(), True)]:
            with self.subTest(force=force):
                code, result, _, payloads = self.run_sync(fixture=fixture, force=force)
                self.assertEqual(code, 0)
                self.assertEqual(len(payloads), 1)
                self.assertTrue(result["success"])

    def test_changed_destination_and_legacy_receipt_cannot_skip_initial_cleanup(self):
        for fixture in [self.receipt(node="another-node"),
                        "<!-- synced-hash: old-whole-cache-receipt -->\n" + BASE]:
            code, _, _, payloads = self.run_sync(fixture=fixture)
            self.assertEqual(code, 0)
            self.assertEqual(len(payloads), 1)

    def test_concurrent_visible_change_preserves_new_data_and_requires_another_sync(self):
        addition = "    - 11.3: 上游联调通过，待验收。\n"
        code, result, local, payloads = self.run_sync(edit=addition)
        self.assertEqual(code, 75)
        self.assertEqual(result["status"], "changed")
        self.assertFalse(result["success"])
        self.assertIn(addition, local)
        self.assertIn(PREFIX + overview_digest(BASE), local)
        self.assertEqual(len(payloads), 1)

    def test_concurrent_hidden_change_survives_without_another_upload(self):
        addition = "- **分支**：feature/concurrent\n"
        code, result, local, _ = self.run_sync(edit=addition)
        self.assertEqual(code, 0)
        self.assertTrue(result["success"])
        self.assertIn(addition, local)
        code, _, _, payloads = self.run_sync(fixture=local)
        self.assertEqual(code, 0)
        self.assertEqual(payloads, [])

    def test_plain_and_chunked_business_success_are_recognized(self):
        for stdout in [b'{"success":true}',
                       b'[INFO] writing chunk...\n{"success":true,"summary":"partial \xf0"}\n']:
            code, result, local, _ = self.run_sync(stdout=stdout)
            self.assertEqual(code, 0)
            self.assertTrue(result["success"])
            self.assertIn(PREFIX, local)
            self.assertTrue(local.endswith(BASE))

    def test_failure_or_unverifiable_response_does_not_mark_local_data_synced(self):
        for stdout, exit_code in [(b'[INFO] {"success":true}\n{"success":false}', 0),
                                  (b'{"success":true}', 1), (b'{"success":"true"}', 0),
                                  (b'{"success":1}', 0), (b'{"success":true}\ntrailing', 0),
                                  (b'{"success":true', 0)]:
            with self.subTest(stdout=stdout):
                code, result, local, _ = self.run_sync(stdout=stdout, exit_code=exit_code)
                self.assertEqual(code, 1)
                self.assertFalse(result["success"])
                self.assertEqual(local, BASE)

    def test_unreadable_or_duplicate_demand_data_is_not_uploaded_as_an_empty_document(self):
        for fixture in [BASE + BASE, BASE.replace("#进行中", "#未知状态")]:
            code, result, local, payloads = self.run_sync(fixture=fixture)
            self.assertEqual(code, 1)
            self.assertEqual(result["status"], "invalid-overview")
            self.assertEqual(local, fixture)
            self.assertEqual(payloads, [])


if __name__ == "__main__":
    unittest.main()
