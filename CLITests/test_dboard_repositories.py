import base64
import json
import subprocess
import unittest
import test_dboard_ai as base


class RepositoryIdentityTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown
    call = base.FeedbackTests.call
    show = base.FeedbackTests.show
    args = base.FeedbackTests.args
    repo = base.FeedbackTests.repo

    def worktree(self, repo):
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "--allow-empty", "-qm", "fixture"], check=True)
        path = self.root / "ultra-worktree"
        subprocess.run(["git", "-C", str(repo), "worktree", "add", "-qb", "feature/cdd-lock", str(path)], check=True)
        return path

    def legacy(self, repositories):
        meta = {"repositories": repositories, "events": {"legacy": "preserved"}}
        encoded = base64.b64encode(json.dumps(meta).encode()).decode()
        self.cache.write_text(self.before.replace("### D0140", base.module.META_PREFIX + encoded + " -->\n\n### D0140"))

    def test_main_checkout_and_worktree_share_one_current_record_with_project_labels(self):
        ultra = self.repo("ultra")
        subprocess.run(["git", "-C", str(ultra), "remote", "add", "origin", "git@example.invalid:backend/ultra.git"], check=True)
        audi = self.repo("audi", "feature/debug")
        self.call(*self.args(self.show(), "--repo", str(ultra)))
        self.call(*self.args(self.show(), "--repo", str(audi)))
        worktree = self.worktree(ultra)
        result = self.call(*self.args(self.show(), "--repo", str(worktree)))["item"]
        self.assertEqual(len(result["repositories"]), 2)
        self.assertEqual(result["branch"], "ultra:feature/cdd-lock；audi:feature/debug")
        self.assertEqual(result["repositories"][0]["path"], str(worktree.resolve()))
        self.assertEqual(result["repositories"][0]["name"], "ultra")
        self.assertIn(str(worktree.resolve()), self.call("context", "D014")["context"])
        self.assertNotIn(str(worktree.resolve()), result["branch"])
        self.assertEqual(subprocess.check_output(["git", "-C", str(ultra), "branch", "--show-current"], text=True).strip(),
                         "feature/fixture", "Reporting another worktree must not switch the main checkout")

    def test_legacy_duplicate_directories_merge_without_adopting_an_unrelated_checked_out_branch(self):
        ultra = self.repo("ultra", "feature/unrelated")
        worktree = self.worktree(ultra)
        self.legacy([{"path": str(ultra), "branch": "feature/cdd-lock"},
                     {"path": str(worktree), "branch": "feature/cdd-lock"}])
        result = self.call(*self.args(self.show(), "--repo", str(worktree)))["item"]
        self.assertEqual(len(result["repositories"]), 1)
        self.assertEqual(result["branch"], "feature/cdd-lock")
        self.assertEqual(result["repositories"][0]["path"], str(worktree.resolve()))
        block = self.cache.read_text().split("### D0140", 1)[0].splitlines()
        self.assertEqual(base.module.feedback_metadata(block)["events"]["legacy"], "preserved")
        self.assertIn("原有进度", result["progress"])

    def test_missing_legacy_directory_requires_explicit_replacement_and_retry_is_stable(self):
        audi = self.repo("audi", "feature/vibe")
        missing = self.root / "gone" / "debug-worktree"
        self.legacy([{"path": str(missing), "branch": "feature/old-debug"}])
        args = self.args(self.show(), "--repo", str(audi), "--replace-repo", str(missing),
                         "--event-id", "relocated")
        result = self.call(*args)["item"]
        self.assertEqual(len(result["repositories"]), 1)
        self.assertEqual(result["repositories"][0]["path"], str(audi.resolve()))
        self.assertEqual(result["branch"], "feature/vibe")
        self.assertEqual(result["status"], "进行中")
        before = self.cache.read_bytes()
        subprocess.run(["git", "-C", str(audi), "symbolic-ref", "HEAD", "refs/heads/feature/later"], check=True)
        retry = self.call(*args)
        self.assertTrue(retry["duplicate"])
        self.assertEqual(self.cache.read_bytes(), before)
        self.assertEqual(retry["item"]["branch"], "feature/vibe")

    def test_merge_checkout_cannot_overwrite_development_branch_but_progress_can_be_saved(self):
        ultra = self.repo("ultra", "feature/cdd-lock")
        self.call(*self.args(self.show(), "--repo", str(ultra)))
        subprocess.run(["git", "-C", str(ultra), "checkout", "-qb", "merge/pre_1013"], check=True)
        before = self.cache.read_bytes()
        rejected = self.call(*self.args(self.show(), "--repo", str(ultra),
                                      "--summary", "合入预发，待发布。"), success=False)
        self.assertEqual(rejected["error"]["code"], "INTEGRATION_BRANCH")
        self.assertEqual(self.cache.read_bytes(), before)
        result = self.call(*self.args(self.show(), "--summary", "合入预发，待发布。",
                                    "--details", "merge/pre_1013 已包含开发提交，未部署。"))["item"]
        self.assertEqual(result["repositories"][0]["branch"], "feature/cdd-lock")
        self.assertEqual(result["branch"], "feature/cdd-lock")
        self.assertIn("合入预发，待发布。", result["progress"])
        self.assertEqual(subprocess.check_output(["git", "-C", str(ultra), "branch", "--show-current"],
                                               text=True).strip(), "merge/pre_1013")

    def test_replacement_cannot_remove_a_different_live_repository_or_an_unknown_target(self):
        old = self.repo("ultra")
        new = self.repo("audi")
        self.legacy([{"path": str(old), "branch": "feature/fixture"}])
        for extra in (("--replace-repo", str(old)),
                      ("--repo", str(new), "--replace-repo", str(old)),
                      ("--repo", str(new), "--replace-repo", str(self.root / "unknown"))):
            before = self.cache.read_bytes()
            self.call(*self.args(self.show(), *extra), success=False)
            self.assertEqual(self.cache.read_bytes(), before)
