import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
import dboard_ai as cli
import dboard_worktrees as wt


class WorktreeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.cache = self.root / "demand-center-cache.md"
        self.cache.write_text("## 重要\n### D014【ultra】锁券接口 #进行中\n- **描述**：拆出锁券\n"
                              "### D015【ultra】其他需求 #进行中\n")
        self.main = self.root / "ultra"
        self.remote = self.root / "remote.git"
        self.git(self.root, "init", "--bare", "-q", str(self.remote))
        self.git(self.root, "init", "-q", "-b", "main", str(self.main))
        self.git(self.main, "config", "user.name", "Fixture")
        self.git(self.main, "config", "user.email", "fixture@example.invalid")
        (self.main / ".gitignore").write_text("build/\nprivate/\n")
        self.git(self.main, "add", ".gitignore")
        self.git(self.main, "commit", "-qm", "初始夹具")
        self.git(self.main, "remote", "add", "origin", str(self.remote))
        self.git(self.main, "push", "-qu", "origin", "main")
        self.processes = mock.patch.object(wt, "process_directories", return_value=[])
        self.processes.start()

    def tearDown(self):
        self.processes.stop()
        self.temp.cleanup()

    def git(self, path, *args):
        return subprocess.check_output(["git", "-C", str(path), *args], stderr=subprocess.STDOUT).decode().strip()

    def tree(self, name="w1"):
        path = self.root / name
        self.git(self.main, "worktree", "add", "-qb", "feature/" + name, str(path))
        self.git(path, "push", "-qu", "origin", "HEAD")
        return path

    def complete(self):
        self.cache.write_text(self.cache.read_text().replace("锁券接口 #进行中", "锁券接口 #已完成"))

    def register(self, path, created=True, item="D014"):
        return wt.register(self.cache, item, path, created=created)

    def preview(self):
        return wt.preview(self.cache, "D014")

    def call(self, *args, success=True):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = cli.main(["--cache", str(self.cache), *args])
        value = json.loads(output.getvalue())
        self.assertEqual(code == 0, success, value)
        return value

    def test_create_registers_before_success_retry_deduplicates_and_cleaned_branch_can_resume(self):
        path = self.root / "created"
        args = ("worktree", "create", "D014", "--repo", str(self.main), "--path", str(path),
                "--new-branch", "feature/created", "--start", "origin/main")
        before = self.cache.read_bytes()
        created = self.call(*args)
        self.assertTrue(created["created"])
        self.assertTrue(created["record"]["created_by_task"])
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 1)
        self.assertTrue(self.call(*args)["duplicate"])
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(self.git(self.main, "branch", "--show-current"), "main")
        self.git(path, "push", "-qu", "origin", "HEAD")
        self.complete()
        preview = self.preview()
        self.assertEqual(wt.cleanup(self.cache, "D014", preview["preview_revision"])["removed_count"], 1)
        self.cache.write_text(self.cache.read_text().replace("锁券接口 #已完成", "锁券接口 #进行中"))
        resumed = self.call("worktree", "create", "D014", "--repo", str(self.main), "--path", str(path),
                            "--branch", "feature/created")
        self.assertTrue(resumed["created"])
        self.assertEqual(wt.summary(self.cache, "D014")["remaining"], 1)
        self.assertEqual(wt.summary(self.cache, "D014")["removed"], 1)
        self.assertEqual(self.git(path, "branch", "--show-current"), "feature/created")

    def test_create_does_not_claim_existing_directories_or_another_tasks_worktree(self):
        path = self.tree()
        self.register(path, item="D015")
        existing = self.root / "existing"
        existing.mkdir()
        (existing / "valuable").write_text("不得覆盖")
        for target in (path, existing):
            result = self.call("worktree", "create", "D014", "--repo", str(self.main), "--path", str(target),
                               "--new-branch", "feature/w1", success=False)
            self.assertEqual(result["error"]["code"], "PATH_EXISTS")
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 0)
        self.assertEqual((existing / "valuable").read_text(), "不得覆盖")

    def test_create_checks_task_title_inventory_and_start_before_any_creation(self):
        path = self.root / "new"
        args = ("worktree", "create", "D014", "--repo", str(self.main), "--path", str(path),
                "--new-branch", "feature/new")
        for extra in (("--expect-title", "错误标题"), ("--start", "missing-branch")):
            self.call(*args, *extra, success=False)
            self.assertFalse(path.exists())
            self.assertEqual(self.git(self.main, "branch", "--list", "feature/new"), "")
        wt.registry_path(self.cache).write_text("broken")
        result = self.call(*args, success=False)
        self.assertEqual(result["error"]["code"], "WORKTREE_DATA_INVALID")
        self.assertFalse(path.exists())

    def test_completed_task_only_allows_explicit_review_creation(self):
        self.complete()
        path = self.root / "review"
        args = ("worktree", "create", "D014", "--repo", str(self.main), "--path", str(path),
                "--detach", "--start", "origin/main")
        result = self.call(*args, success=False)
        self.assertEqual(result["error"]["code"], "NOT_ACTIVE")
        self.assertFalse(path.exists())
        self.assertTrue(self.call(*args, "--task", "code-review")["record"]["created_by_task"])
        self.assertEqual(self.preview()["eligible_count"], 1)
        self.assertEqual(wt.demand(self.cache, "D014")["status"], "已完成")

    def test_detached_worktrees_register_and_require_remote_commit_preservation(self):
        path = self.root / "detached"
        created = self.call("worktree", "create", "D014", "--repo", str(self.main), "--path", str(path),
                            "--detach", "--start", "origin/main")
        self.assertEqual(created["record"]["branch"], "（游离 HEAD）")
        self.complete()
        self.assertEqual(self.preview()["eligible_count"], 1)
        self.git(path, "commit", "--allow-empty", "-qm", "游离HEAD未推送")
        self.assertEqual(self.preview()["eligible_count"], 0)
        self.assertIn("先保存并推送", self.preview()["rows"][0]["reason"])
        self.git(path, "branch", "feature/saved-detached")
        self.git(path, "push", "-q", "origin", "feature/saved-detached")
        before = self.preview()
        self.assertEqual(before["eligible_count"], 1)
        commit = self.git(path, "rev-parse", "HEAD")
        self.assertEqual(wt.cleanup(self.cache, "D014", before["preview_revision"])["removed_count"], 1)
        self.assertEqual(self.git(self.main, "rev-parse", "feature/saved-detached"), commit)

    def test_inventory_save_failure_never_claims_success_and_retains_new_directory(self):
        path = self.root / "failed-registration"
        with mock.patch.object(wt, "write", side_effect=OSError("disk failure")):
            result = self.call("worktree", "create", "D014", "--repo", str(self.main), "--path", str(path),
                               "--new-branch", "feature/save-failure", success=False)
        self.assertEqual(result["error"]["code"], "WORKTREE_REGISTER_FAILED")
        self.assertIn(str(path), result["error"]["message"])
        self.assertTrue(path.exists())
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 0)
        self.register(path)
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 1)

    def test_parallel_task_creation_does_not_lose_inventory_records(self):
        from concurrent.futures import ThreadPoolExecutor
        def run(number):
            path = self.root / ("parallel-" + str(number))
            arguments = [sys.executable, str(Path(cli.__file__)), "--cache", str(self.cache),
                         "worktree", "create", "D014", "--repo", str(self.main),
                         "--path", str(path), "--new-branch", "feature/parallel-" + str(number)]
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=30)
            return result.returncode, json.loads(result.stdout)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(run, (1, 2)))
        for code, value in results:
            self.assertEqual(code, 0, value)
            self.assertTrue(value["record"]["created_by_task"])
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 2)

    def test_deduplicate_preserve_all_trees_and_explicit_ownership(self):
        one, two = self.tree("w1"), self.tree("w2")
        row = self.register(one, created=False)
        self.assertFalse(row["created_by_task"])
        self.assertEqual(self.register(one)["id"], row["id"])
        self.assertTrue(self.register(one)["created_by_task"])
        self.register(two)
        self.assertEqual(len(self.preview()["rows"]), 2)
        self.assertEqual(wt.summary(self.cache, "D014")["created"], 2)
        self.assertNotIn("W001", self.cache.read_text(), "Inventory must not add progress records")

    def test_actual_process_inspection_finds_the_test_process(self):
        self.processes.stop()
        try:
            rows = wt.process_directories()
            self.assertTrue(any(pid == str(os.getpid()) for pid, _ in rows))
        finally:
            self.processes.start()

    def test_primary_checkout_and_subdirectories_never_registered(self):
        with self.assertRaises(wt.WorktreeError) as error:
            self.register(self.main)
        self.assertEqual(error.exception.code, "PRIMARY_CHECKOUT")
        tree = self.tree()
        (tree / "sub").mkdir()
        with self.assertRaises(wt.WorktreeError):
            self.register(tree / "sub")
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 0)

    def test_not_completed_and_used_only_are_kept(self):
        tree = self.tree()
        self.register(tree)
        before = self.preview()
        self.assertEqual(before["eligible_count"], 0)
        with self.assertRaises(wt.WorktreeError) as error:
            wt.cleanup(self.cache, "D014", before["preview_revision"])
        self.assertEqual(error.exception.code, "NOT_COMPLETED")
        self.complete()
        self.register(self.tree("used"), created=False)
        rows = self.preview()["rows"]
        self.assertTrue(rows[0]["eligible"])
        self.assertIn("仅记录使用", rows[1]["reason"])
        self.assertTrue(tree.exists())

    def test_cleanup_only_eligible_preserves_branch_commit_and_main(self):
        clean, dirty = self.tree("clean"), self.tree("dirty")
        clean_head = self.git(clean, "rev-parse", "HEAD")
        self.register(clean); self.register(dirty)
        (dirty / "uncommitted.txt").write_text("不能删除")
        self.complete()
        before = self.preview()
        self.assertEqual(before["eligible_count"], 1)
        result = wt.cleanup(self.cache, "D014", before["preview_revision"])
        self.assertEqual(result["removed_count"], 1)
        self.assertFalse(clean.exists())
        self.assertTrue((dirty / "uncommitted.txt").exists())
        self.assertTrue(self.main.exists())
        self.assertEqual(self.git(self.main, "rev-parse", "feature/clean"), clean_head)
        self.assertNotIn(str(clean), self.git(self.main, "worktree", "list", "--porcelain"))
        self.assertEqual(wt.summary(self.cache, "D014")["removed"], 1)
        fresh = self.preview()
        self.assertEqual(wt.cleanup(self.cache, "D014", fresh["preview_revision"])["removed_count"], 0)

    def test_tracked_change_untracked_file_ahead_and_missing_upstream_block_cleanup(self):
        tree = self.tree()
        self.register(tree); self.complete()
        (tree / ".gitignore").write_text("改变\n")
        self.assertIn("未提交", self.preview()["rows"][0]["reason"])
        self.git(tree, "checkout", "--", ".gitignore")
        (tree / "new.txt").write_text("新文件")
        self.assertIn("未跟踪", self.preview()["rows"][0]["reason"])
        self.git(tree, "add", "new.txt"); self.git(tree, "commit", "-qm", "未推送提交")
        self.assertIn("尚未推送", self.preview()["rows"][0]["reason"])
        self.git(tree, "push", "-q")
        self.assertEqual(self.preview()["eligible_count"], 1)
        self.git(tree, "branch", "--unset-upstream")
        self.assertIn("远端跟踪", self.preview()["rows"][0]["reason"])
        self.git(tree, "branch", "--set-upstream-to=main")
        self.assertIn("远端跟踪", self.preview()["rows"][0]["reason"], "A local upstream cannot prove a push")

    def test_locked_shared_and_running_process_block_cleanup(self):
        tree = self.tree()
        self.register(tree); self.complete()
        self.git(self.main, "worktree", "lock", str(tree))
        self.assertIn("已锁定", self.preview()["rows"][0]["reason"])
        self.git(self.main, "worktree", "unlock", str(tree))
        self.register(tree, created=False, item="D015")
        self.assertIn("D015", self.preview()["rows"][0]["reason"])
        self.cache.write_text(self.cache.read_text().replace("其他需求 #进行中", "其他需求 #已完成"))
        with mock.patch.object(wt, "process_directories", return_value=[("987", str(tree / "sub"))]):
            self.assertIn("进程", self.preview()["rows"][0]["reason"])
        with mock.patch.object(wt, "process_directories", side_effect=wt.WorktreeError("PROCESS_CHECK_FAILED", "进程核对失败")):
            self.assertEqual(self.preview()["eligible_count"], 0)

    def test_another_cache_in_the_same_inventory_cannot_lose_its_worktree(self):
        tree = self.tree()
        self.register(tree); self.complete()
        other = self.root / "another-cache.md"
        other.write_text("## 重要\n### D014【ultra】另一个任务 #已完成\n")
        wt.register(other, "D014", tree, created=False)
        self.assertIn("另一份看板", self.preview()["rows"][0]["reason"])
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 1)

    def test_preview_token_rejects_changed_code_and_registry(self):
        tree = self.tree()
        self.register(tree); self.complete()
        before = self.preview()
        self.git(tree, "commit", "--allow-empty", "-qm", "预览后变动")
        with self.assertRaises(wt.WorktreeError) as error:
            wt.cleanup(self.cache, "D014", before["preview_revision"])
        self.assertEqual(error.exception.code, "PREVIEW_CHANGED")
        self.assertTrue(tree.exists())

    def test_branch_change_and_replaced_directory_block_old_identity(self):
        tree = self.tree()
        self.register(tree); self.complete()
        self.git(tree, "checkout", "-qb", "feature/changed")
        self.assertIn("已变化", self.preview()["rows"][0]["reason"])
        self.git(tree, "checkout", "-q", "feature/w1")
        moved = self.root / "moved"
        tree.rename(moved)
        self.git(self.main, "worktree", "repair", str(moved))
        self.git(self.main, "worktree", "add", "-qb", "feature/replacement", str(tree))
        self.assertIn("已变化", self.preview()["rows"][0]["reason"])
        self.assertTrue(tree.exists())
        self.assertTrue(moved.exists())

    def test_ignored_artifacts_disclosed_and_nested_repository_preserved(self):
        tree = self.tree()
        self.register(tree); self.complete()
        (tree / "build").mkdir()
        (tree / "build" / "artifact").write_text("生成物")
        before = self.preview()
        self.assertTrue(before["rows"][0]["ignored_files"])
        self.assertEqual(before["eligible_count"], 1)
        nested = tree / "private" / "local-repo"
        self.git(tree, "init", "-q", str(nested))
        (nested / "valuable").write_text("未推送本地仓库")
        self.assertIn("独立 Git", self.preview()["rows"][0]["reason"])
        self.assertTrue((nested / "valuable").exists())

    def test_journal_archive_and_reopen_preserve_inventory_without_inheritance(self):
        tree = self.tree()
        self.register(tree); self.complete()
        block = self.cache.read_text().split("### D015", 1)[0].splitlines()[1:]
        self.cache.write_text("## 重要\n")
        journal = self.root / "dboard-archive-journal.json"
        journal.write_text(json.dumps({"D014": {"state": "removed", "archived": block}}))
        self.assertEqual(self.preview()["eligible_count"], 1)
        archive = self.root / "dboard-archive-cache.md"
        archive.write_text("## 已完成\n" + "\n".join(block))
        self.assertEqual(wt.summary(archive, "D014")["registered"], 1)
        self.cache.write_text("## 重要\n### D014【ultra】锁券接口 #进行中\n"
                              "### D016【ultra】锁券2.0 #进行中\n")
        self.assertEqual(self.preview()["eligible_count"], 0, "Live reopening must take precedence over old archive")
        self.assertEqual(wt.summary(self.cache, "D016")["registered"], 0)

    def test_corrupt_inventory_retained_and_report_does_not_mutate_cache(self):
        path = wt.registry_path(self.cache)
        path.write_text("broken")
        before = path.read_bytes()
        self.assertIn("error", wt.summary(self.cache, "D014"))
        with self.assertRaises(wt.WorktreeError):
            self.preview()
        self.assertEqual(path.read_bytes(), before)

    def test_cli_report_keeps_all_worktrees_and_compact_context_has_registration_rule(self):
        one, two = self.tree("one"), self.tree("two")
        for path in (one, two):
            item = self.call("show", "D014")["item"]
            self.call("report", "D014", "--repo", str(path), "--expect-title", item["title"],
                      "--expect-revision", item["revision"], "--compression-decision", "skip",
                      "--compression-reason", "仅更新仓库记录", "--no-sync")
        value = wt.read(self.cache)
        self.assertEqual(len(value["records"]), 2)
        self.assertTrue(all(not r["created_by_task"] for r in value["records"]))
        self.call("worktree", "register", "D014", "--path", str(two), "--created")
        item = self.call("show", "D014")["item"]
        self.assertEqual(len(item["repositories"]), 1, "Current development directory still has one record per project")
        result = self.call("context", "D014")
        self.assertEqual(result["item"]["worktrees"]["registered"], 2)
        self.assertIn("立即登记", result["context"])
        self.assertIn("worktrees", result["reference_commands"])
        self.assertIn("--created", result["worktree_commands"]["register"])
        self.assertIn("compression_check", result)
        self.assertIn("工作树台账", self.call("guide", "--topic", "worktrees")["instructions"])

    def test_repository_feedback_from_subdirectory_registers_the_real_root(self):
        tree = self.tree()
        (tree / "src").mkdir()
        item = self.call("show", "D014")["item"]
        self.call("report", "D014", "--repo", str(tree / "src"), "--expect-title", item["title"],
                  "--expect-revision", item["revision"], "--compression-decision", "skip",
                  "--compression-reason", "仅记录仓库", "--no-sync")
        rows = wt.read(self.cache)["records"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["path"], str(tree))

    def test_invalid_report_title_does_not_register_and_registration_is_local_only(self):
        tree = self.tree()
        before = self.cache.read_bytes()
        item = self.call("show", "D014")["item"]
        self.call("report", "D014", "--repo", str(tree), "--expect-title", "错误名称",
                  "--expect-revision", item["revision"], "--compression-decision", "skip",
                  "--compression-reason", "仅更新仓库记录", "--no-sync", success=False)
        self.assertEqual(wt.summary(self.cache, "D014")["registered"], 0)
        self.call("worktree", "register", "D014", "--path", str(tree), "--created", "--expect-title", "锁券接口")
        self.assertEqual(self.cache.read_bytes(), before)
        summary = self.call("worktree", "summary", "D014")
        self.assertEqual(summary["summary"]["registered"], 1)
        self.complete()
        preview = self.call("worktree", "preview", "D014")
        self.call("worktree", "cleanup", "D014", "--expect-preview", preview["preview_revision"])
        self.assertFalse(tree.exists())

    def test_removing_state_recovery_and_nonforced_git_failure(self):
        tree = self.tree()
        self.register(tree); self.complete()
        registry = wt.read(self.cache)
        registry["records"][0]["state"] = "removing"
        wt.write(self.cache, registry)
        before = self.preview()
        self.assertEqual(before["eligible_count"], 1)
        original = wt.git
        def fail_remove(path, *args, **kwargs):
            if args[:2] == ("worktree", "remove"):
                self.assertNotIn("--force", args)
                raise wt.WorktreeError("GIT_FAILED", "Git拒绝移除")
            return original(path, *args, **kwargs)
        with mock.patch.object(wt, "git", side_effect=fail_remove):
            result = wt.cleanup(self.cache, "D014", before["preview_revision"])
        self.assertEqual(result["removed_count"], 0)
        self.assertTrue(tree.exists())
        self.assertEqual(wt.read(self.cache)["records"][0]["state"], "active")
        fresh = self.preview()
        self.assertEqual(wt.cleanup(self.cache, "D014", fresh["preview_revision"])["removed_count"], 1)


if __name__ == "__main__":
    unittest.main()
