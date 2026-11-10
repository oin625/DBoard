import base64
import json
import subprocess
import unittest
import test_dboard_ai as base
import test_dboard_debug as debug


class CodeVersionTests(unittest.TestCase):
    setUp = debug.DebugTaskTests.setUp
    tearDown = base.FeedbackTests.tearDown
    call = base.FeedbackTests.call
    show = base.FeedbackTests.show
    args = base.FeedbackTests.args
    repo = base.FeedbackTests.repo
    milestone = debug.DebugTaskTests.milestone

    def commit(self, repository):
        subprocess.run(["git", "-C", str(repository), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repository), "-c", "user.name=DBoard Test", "-c", "user.email=test@example.invalid",
                        "commit", "--allow-empty", "-qm", "代码核验测试提交"], check=True)

    def ready(self):
        self.milestone("development-complete")
        self.milestone("debug-page-ready", "--debug-page", "/test-console/fixture")
        self.milestone("testing-passed")

    def test_tracked_code_change_invalidates_results_and_stale_report_cannot_rebind(self):
        code = self.root / "repo" / "service.txt"
        code.write_text("original")
        self.commit(code.parent)
        self.ready()
        verified = self.show()
        stale_request = self.args(verified, "--stage", "testing-passed", "--summary", "试调通过。",
                                  "--details", "已验证当前实现。")
        code.write_text("later implementation")
        changed = self.show()
        self.assertEqual(changed["revision"], verified["revision"])
        self.assertEqual(changed["execution"]["scope_hash"], verified["execution"]["scope_hash"])
        self.assertTrue(changed["execution_needs_review"])
        self.assertIn("代码已变更", changed["execution_review_reason"])
        before = self.cache.read_bytes()
        rejected = self.call(*stale_request, success=False)
        self.assertEqual(rejected["error"]["code"], "CODE_REVISION_CONFLICT")
        self.assertEqual(before, self.cache.read_bytes())
        self.call(*self.args(self.show(), "--summary", "发现新改动，待重新测试。"))
        self.assertTrue(self.show()["execution_needs_review"])
        self.milestone("developing")
        self.assertEqual(self.show()["execution"]["debug_page"], "/test-console/fixture")
        self.ready()
        self.assertFalse(self.show()["execution_needs_review"])

    def test_staged_untracked_and_new_commits_are_bound_but_ignored_build_outputs_are_not(self):
        repository = self.root / "repo"
        (repository / "service.txt").write_text("original")
        (repository / ".gitignore").write_text("ignored/\n")
        self.commit(repository)
        self.ready()
        clean = self.show()["code_revision"]
        ignored = repository / "ignored"
        ignored.mkdir()
        (ignored / "build.log").write_text("generated")
        self.assertEqual(self.show()["code_revision"], clean)
        self.assertFalse(self.show()["execution_needs_review"])
        extra = repository / "new.sql"
        extra.write_text("create table first")
        self.assertTrue(self.show()["execution_needs_review"])
        first = self.show()["code_revision"]
        extra.write_text("create table second")
        self.assertNotEqual(self.show()["code_revision"], first)
        extra.unlink()
        self.assertFalse(self.show()["execution_needs_review"])
        (repository / "service.txt").write_text("staged change")
        subprocess.run(["git", "-C", str(repository), "add", "service.txt"], check=True)
        self.assertTrue(self.show()["execution_needs_review"])
        self.commit(repository)
        self.assertTrue(self.show()["execution_needs_review"])

    def test_all_reported_repositories_including_debug_page_are_checked(self):
        audi = self.repo("audi")
        (audi / "page.jsx").write_text("first page")
        self.commit(audi)
        self.call(*self.args(self.show(), "--repo", str(audi)))
        self.ready()
        self.assertEqual(len(self.show()["execution"]["code"]), 2)
        (audi / "page.jsx").write_text("changed page")
        self.assertTrue(self.show()["execution_needs_review"])
        self.assertIn("需重新核验", self.call("context", "D014")["context"])
        subprocess.run(["git", "-C", str(audi), "checkout", "-qb", "feature/other"], check=True)
        self.assertIsNone(self.show()["code_revision"])
        self.assertTrue(self.show()["execution_needs_review"])

    def test_legacy_results_are_readable_but_not_current_and_corrupt_binding_is_rejected(self):
        self.ready()
        lines = self.cache.read_text().splitlines()
        index = next(i for i, line in enumerate(lines) if line.startswith(base.module.EXECUTION_PREFIX))
        original = lines[index]
        record = json.loads(base64.b64decode(original[len(base.module.EXECUTION_PREFIX):-len(base.module.META_SUFFIX)]))
        record.pop("code")
        lines[index] = base.module.EXECUTION_PREFIX + base64.b64encode(json.dumps(record).encode()).decode() + base.module.META_SUFFIX
        self.cache.write_text("\n".join(lines))
        self.assertTrue(self.show()["execution_needs_review"])
        self.assertIn("未绑定代码", self.show()["execution_review_reason"])
        record["code"] = [{"path": "/wrong", "commit": "bad"}]
        lines[index] = base.module.EXECUTION_PREFIX + base64.b64encode(json.dumps(record).encode()).decode() + base.module.META_SUFFIX
        self.cache.write_text("\n".join(lines))
        before = self.cache.read_bytes()
        self.assertEqual(self.call("show", "D014", success=False)["error"]["code"], "INVALID_EXECUTION_DATA")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_exact_retry_after_code_changes_keeps_old_result_invalid(self):
        args = self.args(self.show(), "--stage", "development-complete", "--summary", "开发已核验。",
                         "--details", "核验接口签名及失败分支。", "--event-id", "bound-result")
        self.call(*args)
        (self.root / "repo" / "later.txt").write_text("new code")
        before = self.cache.read_bytes()
        retry = self.call(*args)
        self.assertTrue(retry["duplicate"])
        self.assertTrue(retry["item"]["execution_needs_review"])
        self.assertEqual(self.cache.read_bytes(), before)
