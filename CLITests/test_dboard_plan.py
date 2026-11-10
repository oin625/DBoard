import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
import dboard_ai as cli
import dboard_plan


class TechnicalPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dboard-plan-tests-")
        self.root = Path(self.temp.name)
        self.cache = self.root / "cache.md"
        self.repo = self.root / "service"
        self.repo.mkdir()
        self.git("init", "-b", "feature/task")
        self.git("config", "user.email", "test@local")
        self.git("config", "user.name", "test")
        (self.repo / "code.txt").write_text("initial")
        self.git("add", ".")
        self.git("commit", "-m", "测试")
        self.cache.write_text("## 🟡 重要\n### D900【service】测试方案 #进行中\n- **项目**：service\n- **分支**：feature/task\n- **提示词**：要做什么：测试需求\n")
        self.run_cli("report", "D900", *self.flags(), "--repo", str(self.repo),
                     "--repo-role", "development", "--compression-decision", "skip",
                     "--compression-reason", "只记录开发入口", "--no-sync")
        self.file = self.root / "plan.json"
        self.file.write_text(json.dumps({"title": "测试技术方案", "markdown": "# 目标\n\n已有实现和待验证边界。", "projects": [
            {"name": "service", "branch": "feature/task"}]}, ensure_ascii=False))

    def tearDown(self):
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], capture_output=True, check=True).stdout.decode().strip()

    def run_cli(self, *args, ok=True):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = cli.main(["--cache", str(self.cache), *args])
        result = json.loads(out.getvalue())
        self.assertEqual(code, 0 if ok else 2, result)
        return result

    def show(self):
        return self.run_cli("show", "D900")["item"]

    def flags(self):
        item = self.show()
        return ["--expect-title", item["title"], "--expect-revision", item["revision"]]

    def save(self, ok=True, **overrides):
        item = self.show()
        state = self.run_cli("plan", "read", "D900")["plan"]
        args = ["plan", "save", "D900", "--file", str(self.file), *self.flags(),
                "--expect-plan", overrides.get("expect_plan", state["revision"])]
        if item["code_revision"]:
            args += ["--expect-code", overrides.get("expect_code", item["code_revision"])]
        return self.run_cli(*args, ok=ok)

    def test_local_plan_save_and_read_are_idempotent_and_context_defers_body(self):
        result = self.save()
        self.assertTrue(result["local_saved"])
        item = self.show()
        self.assertEqual(item["history_records"], 2)
        self.assertTrue(self.save()["unchanged"])
        self.assertEqual(self.show()["history_records"], 2)
        plan = self.run_cli("plan", "read", "D900")["plan"]
        self.assertEqual(plan["markdown"], "# 目标\n\n已有实现和待验证边界。")
        context = self.run_cli("context", "D900", "--task", "technical-plan")
        self.assertFalse(context["history_read_required"])
        self.assertTrue(context["compression_check"]["evaluated"])
        self.assertIn("plan_instructions", context)
        self.assertNotIn(plan["markdown"], context["context"])
        self.assertFalse(context["item"]["technical_plan_state"]["needs_review"])

    def test_changed_code_requirement_and_branch_invalidate_old_plan(self):
        self.save()
        (self.repo / "code.txt").write_text("changed after plan")
        self.assertTrue(self.show()["technical_plan_state"]["needs_review"])
        self.save()
        self.assertFalse(self.show()["technical_plan_state"]["needs_review"])
        self.cache.write_text(self.cache.read_text().replace("要做什么：测试需求", "要做什么：新增变更"))
        self.assertIn("需求", self.show()["technical_plan_state"]["reason"])

    def test_stale_code_or_user_plan_revision_cannot_be_overwritten(self):
        result = self.save(ok=False, expect_code="f" * 64)
        self.assertEqual(result["error"]["code"], "CODE_REVISION_CONFLICT")
        self.save()
        result = self.save(ok=False, expect_plan="none")
        self.assertEqual(result["error"]["code"], "PLAN_REVISION_CONFLICT")

    def test_environment_worktree_does_not_replace_source_development_branch(self):
        environment = self.root / "service-pre"
        self.git("worktree", "add", "-b", "feature/D900-pre", str(environment))
        args = ["report", "D900", *self.flags(), "--repo", str(environment),
                "--compression-decision", "skip", "--compression-reason", "记录预发用途", "--no-sync"]
        result = self.run_cli(*args, ok=False)
        self.assertEqual(result["error"]["code"], "BRANCH_ROLE_REQUIRED")
        self.run_cli(*args, "--repo-role", "integration")
        item = self.show()
        self.assertEqual(item["branch"], "feature/task")
        self.assertEqual(item["repositories"][0]["path"], str(self.repo.resolve()))
        self.assertEqual(item["environment_repositories"][0]["branch"], "feature/D900-pre")
        count = item["history_records"]
        self.run_cli("report", "D900", *self.flags(), "--repo", str(environment), "--repo-role", "integration",
                     "--compression-decision", "skip", "--compression-reason", "重复用途不新增", "--no-sync")
        self.assertEqual(self.show()["history_records"], count)
        self.save()
        payload = json.loads(self.file.read_text())
        payload["projects"][0]["branch"] = "feature/D900-pre"
        self.file.write_text(json.dumps(payload))
        self.assertEqual(self.save(ok=False)["error"]["code"], "DEVELOPMENT_BRANCH_MISMATCH")


    def test_progress_append_keeps_blank_lines_inside_original_details(self):
        block = ["### D900【service】测试 #进行中", "- **进度**：",
                 "    - 11.9: 原记录", "        明细：", "        第一段", "        ", "        第二段",
                 "- **分支**：feature/task"]
        cli.append_progress(block, "新记录", "新明细")
        records = cli.progress_records(cli.fields(block)["进度"])
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["details"], "第一段\n\n第二段")
        self.assertEqual(records[1]["details"], "新明细")

    def test_completed_or_corrupt_plan_is_preserved(self):
        self.save()
        self.cache.write_text(self.cache.read_text().replace("#进行中", "#已完成"))
        before = self.cache.read_bytes()
        self.assertEqual(self.save(ok=False)["error"]["code"], "DEMAND_COMPLETED")
        self.assertEqual(self.cache.read_bytes(), before)
        self.cache.write_text(self.cache.read_text().replace(dboard_plan.PREFIX, dboard_plan.PREFIX + "!"))
        before = self.cache.read_bytes()
        self.run_cli("plan", "read", "D900", ok=False)
        self.assertEqual(self.cache.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
