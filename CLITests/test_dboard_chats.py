import importlib.util
import json
import os
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
        self.privacy = Path(self.directory.name) / ".config/dboard/privacy.json"
        self.privacy.parent.mkdir(parents=True)
        self.privacy.write_text('{"demand_chat_enabled": true}')
        self.links = {"primary": {"id": "cid-primary'quoted", "name": "主群【车点点】"},
                      "secondary": [{"id": "cid-secondary", "name": "SAAS 联调群"}]}
        self.base = "## 🟡 重要\n### D014【ultra】锁券链路 #进行中\n- **提示词**：原始开发要求\n"
        self.write(self.links)

    def tearDown(self):
        self.directory.cleanup()

    def write(self, links):
        self.cache.write_text(self.base + "- **关联群聊**：" + json.dumps(links, ensure_ascii=False) + "\n")

    def call(self, *args, success=True, full=True):
        args = list(args)
        if full and args and args[0] in ("show", "context") and "--full" not in args: args += ["--full"]
        args += feedback_flags(self.cache, args)
        result = subprocess.run([sys.executable, str(CLI), "--cache", str(self.cache), *args],
                                capture_output=True, text=True, timeout=15,
                                env={**os.environ, "HOME": self.directory.name})
        response = json.loads(result.stdout)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return response

    def test_default_closed_hides_associations_in_all_context_modes_and_full_show(self):
        self.privacy.unlink()
        before = self.cache.read_text()
        shown = self.call("show", "D014")["item"]
        self.assertIsNone(shown["chat_links"])
        for task in ("continue", "code-review", "technical-plan", "debug-page"):
            for full in (False, True):
                args = ["context", "D014", "--task", task]
                if full: args.append("--full")
                response = self.call(*args, full=full)
                self.assertFalse(response["chat_access"]["enabled"])
                self.assertIsNone(response["item"]["chat_links"])
                self.assertEqual(response["chat_sources"], [])
                self.assertIn("不得根据旧摘要", response["context"])
                self.assertIn("不得根据旧摘要", response["feedback_instructions"])
                serialized = json.dumps(response, ensure_ascii=False)
                for secret in ("cid-primary", "cid-secondary", "主群【车点点】", "SAAS 联调群",
                               "chat message list", "优先看主要群聊"):
                    self.assertNotIn(secret, serialized)
        self.assertEqual(self.cache.read_text(), before)

    def test_invalid_settings_fail_closed_and_disabled_report_preserves_links(self):
        for value in ('{}', 'invalid json', '{"demand_chat_enabled": "true"}',
                      '{"demand_chat_enabled": 1}', '{"demand_chat_enabled": false}'):
            self.privacy.write_text(value)
            response = self.call("context", "D014")
            self.assertEqual(response["chat_sources"], [])
            self.assertIsNone(response["item"]["chat_links"])
        item = self.call("show", "D014")["item"]
        self.call("report", "D014", "--expect-title", item["title"],
                  "--expect-revision", item["revision"], "--summary", "保留既有实现，待联调。",
                  "--event-id", "closed-chat-round", "--no-sync")
        self.assertIn(json.dumps(self.links, ensure_ascii=False), self.cache.read_text())
        self.privacy.write_text('{"demand_chat_enabled": true}')
        self.assertEqual(self.call("show", "D014")["item"]["chat_links"], self.links)

    def test_generated_old_version_background_omits_chat_section_only_when_disabled(self):
        from unittest.mock import patch
        version = {"background": "说明：保留改造\n原关联群聊（背景）：\n主要群聊：私密群；群 ID：cid-private\n次要群聊：私密次群；群 ID：cid-secondary\n历史进度：\n开发已完成"}
        with patch.object(module, "demand_chats_enabled", return_value=False):
            result = module.private_version_background(version)
            self.assertEqual(result["background"], "说明：保留改造\n历史进度：\n开发已完成")
            self.assertIn("cid-private", version["background"])
        with patch.object(module, "demand_chats_enabled", return_value=True):
            self.assertEqual(module.private_version_background(version), version)

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
