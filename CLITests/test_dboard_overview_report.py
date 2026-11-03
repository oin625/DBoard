import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
import dboard_ai as cli

class OverviewReportTests(unittest.TestCase):
    def call(self, args):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = cli.main(args)
        return code, json.loads(output.getvalue())

    def test_optional_overview_feedback_preserves_full_context_without_appending_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory) / "cache.md"
            before = "## 🟡\n### D014【ultra】锁券改造 #进行中\n- **提示词**：\n    本地完整输入\n- **进度**：\n    - 11.3: 已完成，待验收。\n"
            cache.write_text(before)
            code, read = self.call(["--cache", str(cache), "show", "D014"])
            self.assertEqual(code, 0)
            item = read["item"]
            args = ["--cache", str(cache), "report", "D014", "--expect-title", item["title"],
                    "--expect-revision", item["revision"], "--overview", "拆出锁券接口并补齐换码校验。",
                    "--event-id", "overview-fixture", "--no-sync"]
            code, result = self.call(args)
            self.assertEqual(code, 0)
            self.assertEqual(result["item"]["overview"], "拆出锁券接口并补齐换码校验。")
            self.assertEqual(result["item"]["progress_records"], item["progress_records"])
            self.assertIn("本地完整输入", cache.read_text())
            self.assertEqual(result["sync"]["status"], "skipped")
            code, result = self.call(args)
            self.assertEqual(code, 0)
            self.assertTrue(result["duplicate"])
            args[args.index("--overview") + 1] = "不同的概括。"
            code, result = self.call(args)
            self.assertEqual(code, 2)
            self.assertEqual(result["error"]["code"], "EVENT_CONFLICT")

if __name__ == "__main__":
    unittest.main()
