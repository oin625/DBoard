import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
from handoff_fixture import feedback_flags

CLI = Path(__file__).resolve().parents[1] / "Tools/dboard_ai.py"
spec = importlib.util.spec_from_file_location("dboard_ai_chats", CLI)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class DemandChatContextTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.cache = Path(self.directory.name) / "cache.md"
        self.links = {"primary": {"id": "cid-primary'quoted", "name": "主群【车点点】"},
                      "secondary": [{"id": "cid-secondary", "name": "SAAS 联调群"}]}
        self.base = "## 🟡 重要\n### D014【ultra】锁券链路 #进行中\n- **提示词**：原始开发要求\n"
        self.write(self.links)

    def tearDown(self):
        self.directory.cleanup()

    def write(self, links):
        self.cache.write_text(self.base + "- **关联群聊**：" + json.dumps(links, ensure_ascii=False) + "\n")

    def call(self, *args, success=True):
        args = list(args)
        if args and args[0] in ("show", "context") and "--full" not in args: args += ["--full"]
        args += feedback_flags(self.cache, args)
        result = subprocess.run([sys.executable, str(CLI), "--cache", str(self.cache), *args],
                                capture_output=True, text=True, timeout=15)
        response = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return response

    def test_context_contains_priority_ids_read_only_commands_and_progress_rules(self):
        before = self.cache.read_text()
        response = self.call("context", "D014")
        self.assertEqual(response["item"]["chat_links"], self.links)
        sources = response["chat_sources"]
        self.assertEqual([s["role"] for s in sources], ["primary", "secondary"])
        for source in sources:
            args = shlex.split(source["read_command"])
            self.assertEqual(args[1:4], ["chat", "message", "list"])
            self.assertEqual(args[args.index("--group") + 1], source["id"])
            self.assertEqual(args[args.index("--direction") + 1], "older")
            self.assertEqual(args[args.index("--limit") + 1], "50")
            self.assertEqual(args[args.index("--format") + 1], "json")
        context = response["context"]
        self.assertIn("信息仍不明确时", context)
        self.assertIn("优先看主要群聊", context)
        self.assertIn("群名和消息时间", context)
        self.assertIn("与咒言或追加变更冲突", context)
        self.assertEqual(self.cache.read_text(), before)

    def test_empty_or_only_secondary_links_and_existing_demands_are_supported(self):
        self.cache.write_text(self.base)
        empty = self.call("context", "D014")
        self.assertIsNone(empty["item"]["chat_links"])
        self.assertEqual(empty["chat_sources"], [])
        self.assertNotIn("## 关联群聊", empty["context"])
        self.write({"secondary": self.links["secondary"]})
        secondary = self.call("context", "D014")
        self.assertIsNone(secondary["item"]["chat_links"]["primary"])
        self.assertEqual(len(secondary["chat_sources"]), 1)
        self.assertEqual(secondary["chat_sources"][0]["role"], "secondary")

    def test_report_preserves_associations_and_new_context_sees_latest_change(self):
        item = self.call("show", "D014")["item"]
        result = self.call("report", "D014", "--expect-title", item["title"],
                           "--expect-revision", item["revision"], "--summary", "已核对群聊结论，待联调。",
                           "--event-id", "chat-round", "--no-sync")
        self.assertEqual(result["item"]["chat_links"], self.links)
        self.write({"primary": {"id": "cid-new", "name": "新主群"}, "secondary": []})
        updated = self.call("context", "D014")
        self.assertEqual(updated["chat_sources"][0]["id"], "cid-new")
        self.assertNotIn("cid-primary", updated["context"])

    def test_corrupt_duplicate_or_ambiguous_links_are_not_silently_omitted(self):
        for links in ({}, {"primary": self.links["primary"], "secondary": [self.links["primary"]]},
                      {"primary": {"id": "", "name": "无ID"}, "secondary": []}):
            self.write(links)
            response = self.call("context", "D014", success=False)
            self.assertEqual(response["error"]["code"], "INVALID_CHAT_LINKS")
        self.write(self.links)
        original = self.cache.read_text()
        self.cache.write_text(original + "- **关联群聊**：" + json.dumps(self.links) + "\n")
        self.assertEqual(self.call("show", "D014", success=False)["error"]["code"], "AMBIGUOUS_FIELD")
        self.cache.write_text(original.rstrip("\n") + "\n    无效续行\n")
        self.assertEqual(self.call("context", "D014", success=False)["error"]["code"], "INVALID_CHAT_LINKS")


if __name__ == "__main__":
    unittest.main()
