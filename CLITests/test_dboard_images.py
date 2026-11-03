import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "Tools/dboard_ai.py"
spec = importlib.util.spec_from_file_location("dboard_ai_images", CLI)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DemandImageContextTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.cache = self.root / "cache.md"

    def tearDown(self):
        self.directory.cleanup()

    def call(self, *args):
        proc = subprocess.run([sys.executable, str(CLI), "--cache", str(self.cache), *args],
                              capture_output=True, text=True, timeout=15)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return json.loads(proc.stdout)

    def fixture(self):
        original = self.root / "原咒言 图片(1).png"
        first = self.root / "第一条变更.png"
        latest = self.root / "最新变更.png"
        for path in (original, first, latest):
            path.write_bytes(base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2WQAAAABJRU5ErkJggg=="))
        missing = self.root / "不见了的图片.png"
        changes = [
            {"id": "C001", "createdAt": "2026-11-03T01:00:00Z", "intent": "先修改此处\n![第一张](<" + str(first) + ">)"},
            {"id": "C002", "createdAt": "2026-11-03T02:00:00Z",
             "intent": "最新要求\n![最新截图](<" + str(latest) + ">)\n![待找回](<" + str(missing) + ">)"},
        ]
        encoded = base64.b64encode(json.dumps(changes, ensure_ascii=False).encode()).decode()
        body = "\n".join("### " + c["id"] + " · " + c["createdAt"] + "\n" + c["intent"] for c in changes)
        stored = "<!-- dboard-changes:v1:" + encoded + " -->\n" + body
        cache = ("## 🟡 重要\n### D014【fixture】图文需求 #进行中\n"
                 "- **提示词**：\n    先按原图实现\n    ![原图](<" + str(original) + ">)\n"
                 "- **变更咒言**：\n" + "\n".join("    " + line for line in stored.split("\n")) + "\n")
        self.cache.write_text(cache)
        return original, first, latest, missing

    def test_latest_context_includes_original_and_all_changes_with_explicit_missing_images(self):
        expected = self.fixture()
        response = self.call("context", "D014", "--change", "C002")
        self.assertEqual([i["path"] for i in response["images"]], [str(p) for p in expected])
        self.assertEqual([i["exists"] for i in response["images"]], [True, True, True, False])
        self.assertIn("本次追加变更 C002", response["context"])
        self.assertIn("逐张打开 images", response["context"])
        self.assertIn("图片文件缺失", response["context"])
        self.assertIn("连接用户本机", response["context"])
        self.assertEqual(self.call("show", "D014")["item"]["images"], response["images"])

    def test_reporting_progress_keeps_image_references_and_short_copy_contract(self):
        self.fixture()
        before = self.call("show", "D014")["item"]
        result = self.call("report", "D014", "--expect-title", before["title"],
                           "--expect-revision", before["revision"], "--summary", "图文需求已核对，待实现。",
                           "--event-id", "image-context-round", "--no-sync")
        self.assertEqual(result["item"]["images"], before["images"])
        self.assertEqual(result["item"]["prompt"], before["prompt"])
        self.assertEqual(result["item"]["changes"], before["changes"])

    def test_only_local_image_markdown_is_collected_and_duplicates_are_not_repeated(self):
        text = ("[普通链接](</tmp/file.png>)\n![远端](<https://example.com/a.png>)\n"
                "![本机](</tmp/中文 (1).png>)\n![重复](</tmp/中文 (1).png>)")
        images = module.image_references(text)
        self.assertEqual(len(images), 1)
        self.assertEqual(images[0]["path"], "/tmp/中文 (1).png")
        self.assertEqual(images[0]["label"], "本机")


if __name__ == "__main__":
    unittest.main()
