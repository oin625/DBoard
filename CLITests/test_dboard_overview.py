import base64
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tools"))
from dboard_overview import render, digest
from dboard_ai import CLIError

BASE = "## 🟡\n### D014【ultra】锁券改造 #进行中\n- **概括**：拆出锁券接口。\n- **进度**：\n    - 11.3: 接口完成，待验收。\n"


class OverviewTests(unittest.TestCase):
    def test_shared_swift_and_python_projection_fixtures(self):
        fixtures = json.loads((ROOT / "Tests/Fixtures/dboard-overview.json").read_text())
        for fixture in fixtures:
            with self.subTest(fixture=fixture["name"]):
                self.assertEqual(render(fixture["source"]), fixture["expected"])

    def test_unreported_change_changes_current_progress_without_exporting_its_original_spell(self):
        changes = [{"id": "C001", "createdAt": "2026-11-03T10:00:00Z", "intent": "不可上传的完整变更原文"}]
        encoded = base64.b64encode(json.dumps(changes, ensure_ascii=False).encode()).decode()
        source = BASE + ("- **变更咒言**：\n    <!-- dboard-changes:v1:" + encoded +
                         " -->\n    ### C001 · 2026-11-03T10:00:00Z\n    不可上传的完整变更原文\n")
        self.assertIn("新增 1 项变更待处理", render(source))
        self.assertNotIn("不可上传的完整变更原文", render(source))
        self.assertNotEqual(digest(BASE), digest(source))
        recorded = source.replace("接口完成，待验收。", "[C001] 新要求已实现，待验收。")
        self.assertNotIn("变更待处理", render(recorded))
        self.assertIn("新要求已实现，待验收", render(recorded))

    def test_only_visible_changes_invalidate_overview(self):
        for hidden in ["- **分支**：feature/another\n", "- **关联群聊**：{}\n",
                       "- **提示词**：\n    新咒言\n", "## 📝\n### 2026-11-03\n- [ ] 今日零碎\n",
                       "<!-- dboard-ai-feedback:v1:metadata -->\n"]:
            self.assertEqual(digest(BASE), digest(BASE + hidden))
        for visible in [BASE.replace("待验收", "已验收"), BASE.replace("#进行中", "#挂起"),
                        BASE.replace("拆出锁券接口", "增加换码校验"),
                        BASE.replace("【ultra】", "【tesla】")]:
            self.assertNotEqual(digest(BASE), digest(visible))

    def test_unreadable_or_duplicate_records_do_not_become_empty_cloud_snapshots(self):
        for source in [BASE + BASE, BASE.replace("#进行中", "#未知"),
                       BASE + "- **概括**：重复字段\n",
                       BASE + "- **变更咒言**：\n    unreadable\n"]:
            with self.assertRaises(CLIError):
                render(source)


if __name__ == "__main__":
    unittest.main()
