import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

CLI = Path(__file__).resolve().parents[1] / "Tools/dboard_ai.py"


class PersonalWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.store = self.root / "personal.json"
        self.cache = self.root / "demand-center-cache.md"
        self.cache.write_text("工作需求不可修改", encoding="utf-8")

    def tearDown(self):
        self.directory.cleanup()

    def call(self, *args, success=True):
        process = subprocess.run([sys.executable, str(CLI), "try", "--store", str(self.store), *args],
                                 text=True, capture_output=True, timeout=15)
        value = json.loads(process.stdout)
        self.assertEqual(value["success"], success, process.stdout + process.stderr)
        self.assertEqual(process.returncode, 0 if success else 2)
        self.assertEqual(self.cache.read_text(encoding="utf-8"), "工作需求不可修改")
        return value

    def file(self, name, text):
        path = self.root / name
        path.write_text(text, encoding="utf-8")
        return str(path)

    def create(self, kind="task", **kwargs):
        args = ["create", "--kind", kind, "--title", "次 Try 编辑器"]
        for k, v in kwargs.items():
            args.extend(["--" + k.replace("_", "-"), v])
        return self.call(*args)["item"]

    def testSharedContextImagesRelatedNotesAndCompactHistory(self):
        shared = self.file("context.md", "代码入口 /repo/DBoard\n设计约定：不改主 Main")
        project = self.call("project", "create", "--name", "D板", "--context-file", shared)["project"]
        body = self.file("body.md", "![资料](</tmp/example.png>)\n用户原始理解和目标")
        idea = self.create("idea", body_file=body, project=project["id"])
        learning = self.create("digestion", related=idea["id"], project=project["id"])
        for index in range(6):
            ctx = self.call("context", idea["id"])
            self.call("report", idea["id"], "--expected-revision", str(ctx["item"]["revision"]),
                      "--summary", "澄清想法 " + str(index), "--details-file", self.file("detail.md", "明细" * 1000),
                      "--handoff-file", self.file("handoff.md", "已决定改正文编辑器；保留资料；下一步实施"))
        ctx = self.call("context", idea["id"])
        self.assertIsNone(ctx["project"], "Learning and ideas are independent of the retired project workspace")
        self.assertEqual(ctx["item"]["body"], Path(body).read_text())
        self.assertEqual(ctx["item"]["reportCount"], 6)
        self.assertEqual(len(ctx["item"]["recentReports"]), 3)
        self.assertNotIn("reports", ctx["item"])
        self.assertNotIn("明细明细", json.dumps(ctx, ensure_ascii=False))
        self.assertEqual(ctx["images"][0]["path"], "/tmp/example.png")
        self.assertEqual(ctx["related"][0]["id"], learning["id"])
        self.assertIn("未经用户明确指令，不自行实施", ctx["feedback_instructions"])
        self.assertEqual(len(self.call("history", idea["id"])["reports"]), 6)

    def testFeedbackDoesNotReplaceBodyAndRequiresFreshRevision(self):
        body = self.file("body.md", "我的理解")
        item = self.create("digestion", body_file=body)
        result = self.file("result.md", "供用户采纳的说明")
        handoff = self.file("handoff.md", "已弄懂图片粘贴，仍需验证撤销")
        self.call("report", item["id"], "--expected-revision", "1", "--summary", "解释了图片粘贴",
                  "--result-file", result, "--handoff-file", handoff, "--progress", "正在理解", "--next-step", "验证撤销")
        before = self.store.read_bytes()
        self.call("report", item["id"], "--expected-revision", "1", "--summary", "旧版本", success=False)
        self.assertEqual(self.store.read_bytes(), before)
        ctx = self.call("context", item["id"])
        self.assertEqual(ctx["item"]["currentNote"]["body"], "我的理解")
        self.assertEqual(ctx["item"]["aiResult"], "供用户采纳的说明")
        self.assertEqual(ctx["item"]["aiSummary"], Path(handoff).read_text())
        self.assertEqual(ctx["item"]["status"], "active")
        self.assertIn("不能把读过、听完讲解或笔记篇数等同于掌握", ctx["feedback_instructions"])

    def testCompletedAndShelvedEntriesStopAndCannotBeReopenedByReport(self):
        item = self.create()
        value = json.loads(self.store.read_text())
        value["entries"][0]["status"] = "done"
        self.store.write_text(json.dumps(value), encoding="utf-8")
        self.assertEqual(self.call("context", item["id"])["action"], "wait_for_user")
        self.assertEqual(self.call("list")["items"], [])
        self.assertEqual(len(self.call("list", "--all")["items"]), 1)
        before = self.store.read_bytes()
        self.call("report", item["id"], "--expected-revision", "1", "--summary", "重复开干", success=False)
        self.assertEqual(self.store.read_bytes(), before)

    def testBrokenAndFutureSchemaAreNeverOverwritten(self):
        for content in ('{"version": 2}', '{', '{"version":1,"entries":[{}],"projects":[]}'):
            self.store.write_text(content, encoding="utf-8")
            self.call("create", "--kind", "idea", "--title", "不要覆盖", success=False)
            self.assertEqual(self.store.read_text(), content)

    def testIndependentNumberingAndConcurrentCreations(self):
        processes = [subprocess.Popen(
            [sys.executable, str(CLI), "try", "--store", str(self.store), "create", "--kind", "task", "--title", "并行" + str(i)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for i in range(8)]
        ids = set()
        for process in processes:
            output, error = process.communicate(timeout=20)
            self.assertEqual(process.returncode, 0, output + error)
            ids.add(json.loads(output)["item"]["id"])
        self.assertEqual(ids, {"T" + str(i).zfill(3) for i in range(1, 9)})
        self.assertEqual(os.stat(self.store).st_mode & 0o777, 0o600)
        self.call("context", "D014", success=False)

    def testProjectUpdatesNeedFreshRevisionAndDoNotDuplicateName(self):
        project = self.call("project", "create", "--name", "D板")["project"]
        duplicate = self.call("project", "create", "--name", "D板")
        self.assertTrue(duplicate["existing"])
        self.assertEqual(len(self.call("project", "list")["projects"]), 1)
        self.call("project", "set", project["id"], "--expected-revision", "1",
                  "--context-file", self.file("project.md", "新的代码入口"))
        before = self.store.read_bytes()
        self.call("project", "set", project["id"], "--expected-revision", "1", "--name", "旧名字", success=False)
        self.assertEqual(self.store.read_bytes(), before)

    def testIdempotentFeedbackAndNewlineSummaryRejected(self):
        item = self.create()
        args = ["report", item["id"], "--expected-revision", "1", "--summary", "已完成界面", "--event-id", "round-1"]
        self.call(*args)
        self.assertTrue(self.call(*args)["duplicate"])
        self.assertEqual(len(self.call("history", item["id"])["reports"]), 1)
        before = self.store.read_bytes()
        self.call(*args, "--progress", "同事件编号的不同内容", success=False)
        self.call("report", item["id"], "--expected-revision", "2", "--summary", "概括\n不能多行", success=False)
        self.assertEqual(before, self.store.read_bytes())


if __name__ == "__main__":
    unittest.main()
