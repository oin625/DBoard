import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

TOOLS = Path(__file__).resolve().parents[1] / "Tools"
sys.path.insert(0, str(TOOLS))
import dboard_learning
import dboard_learning_knowledge as knowledge


class LearningKnowledgeTests(unittest.TestCase):
    def item(self):
        stage = {"id": "S1", "title": "概念", "objective": "解释取舍", "practice": "比较", "check": "独立解释", "resources": "", "estimatedMinutes": 20}
        return {"id": "T001", "kind": "digestion", "title": "学习", "body": "",
                "progress": "", "nextStep": "", "aiSummary": "", "aiResult": "",
                "relatedIDs": [], "reports": [], "conversions": [], "revision": 1,
                "createdAt": 1, "updatedAt": 1, "status": "active",
                "learningConfig": {"goal": "解释取舍", "baseline": "", "revision": 1, "minutesPerDay": 60, "deadline": time.time() + 86400},
                "learningPlan": {"id": "P1", "configRevision": 1, "target": "解释取舍", "startingPoint": "基础", "rationale": "安排", "stages": [stage]},
                "currentLearningStageID": "S1",
                "notes": [{"id": "N001", "title": "", "body": "我的原文", "createdAt": 1, "updatedAt": 2, "bookmark": {"location": 2, "length": 0, "scrollY": 0}}],
                "learningTopics": [{"id": "K1", "title": "取舍"}]}

    def testAllChecksSurviveNewPlanAndChangedStandardsRemainUncovered(self):
        item = self.item()
        check = {"stageID": "S1", "planID": "P1", "configRevision": 1, "verdict": "needs_practice",
                 "summary": "理由缺项", "gaps": ["理由"], "evidenceText": "选A", "outcome": "", "evidenceVersions": {}}
        item["learningStageChecks"] = [check]
        proposal = copy.deepcopy(item["learningPlan"])
        proposal["id"] = "P2"; proposal["stages"][0]["estimatedMinutes"] = 35
        dboard_learning.activate_plan(item, proposal)
        self.assertEqual(item["learningStageChecks"][0]["evidenceText"], "选A")
        self.assertIsNone(item["learningStageChecks"][0].get("confirmedAt"))
        self.assertTrue(dboard_learning.check_current(item, check))
        proposal = copy.deepcopy(proposal); proposal["id"] = "P3"; proposal["stages"][0]["check"] = "解释更多能力"
        dboard_learning.activate_plan(item, proposal)
        self.assertFalse(dboard_learning.check_current(item, check))
        self.assertEqual(item["learningStageChecks"][0]["evidenceText"], "选A")

    def testAdoptionConflictPreservesNotesAndDraftAndCanUndoThroughCLI(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); store = root / "personal.json"
            item = self.item()
            item["learningNoteDraft"] = {"title": "", "body": "正在写的草稿"}
            original = copy.deepcopy(item["notes"][0])
            proposal = {"id": "O1", "title": "整理", "body": "整理内容", "explanation": "AI补充",
                        "topicIDs": ["K1"], "unitIDs": [], "sourceNoteIDs": ["N001"], "sourceVersions": {"N001": 2}}
            knowledge.apply(item, item["notes"], organization=proposal)
            item["notes"][0]["body"] = "刚改的原文"
            with self.assertRaises(ValueError):
                knowledge.adopt(item, "O1", item["notes"])
            self.assertEqual(len(item["notes"]), 1)
            item["notes"][0] = original
            store.write_text(json.dumps({"version": 1, "entries": [item], "projects": [], "bookmarks": {}}))
            def cli(*args):
                r = subprocess.run([sys.executable, str(TOOLS / "dboard_ai.py"), "try", "--store", str(store), *args], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                return json.loads(r.stdout)
            cli("adopt-notes", "T001", "O1", "--expected-revision", "1")
            updated = json.loads(store.read_text())["entries"][0]
            self.assertEqual(updated["notes"][0], original)
            self.assertEqual(updated["learningNoteDraft"], item["learningNoteDraft"])
            self.assertEqual(updated["notes"][1]["origin"], "ai_organized")
            cli("undo-notes", "T001", "O1", "--expected-revision", "2")
            updated = json.loads(store.read_text())["entries"][0]
            self.assertEqual(updated["notes"][0], original)
            self.assertIsNotNone(updated["notes"][1]["deletedAt"])

    def testAIOrganizedBodyCannotSupplyMasteryEvidence(self):
        item = self.item()
        item["notes"][0]["origin"] = "ai_organized"
        with self.assertRaises(ValueError):
            dboard_learning.apply_report(item, check_file={"stageID": "S1", "verdict": "ready",
                "summary": "看完了", "evidenceText": "", "outcome": "解释取舍", "noteIDs": ["N001"]})

    def testKnowledgeHeadingIsIndependentStableAndRejectsQuestionTitles(self):
        item = self.item()
        unit = {"id": "U1", "title": "为什么运行还需要内存？", "noteTitle": "权重、缓存与运行内存",
                "question": "额外空间来自什么", "stageIDs": ["S1"], "topicIDs": ["K1"],
                "materialKind": "hypothetical", "material": "教学假设", "conditions": "",
                "metrics": "定义", "reasoning": "解释", "limits": "边界", "judgment": "判断", "sources": []}
        knowledge.apply(item, item["notes"], unit=unit)
        unit.pop("noteTitle")
        unit["material"] = "补充后的教学假设"
        knowledge.apply(item, item["notes"], unit=unit)
        self.assertEqual(item["learningUnits"][0]["noteTitle"], "权重、缓存与运行内存")
        self.assertEqual(item["learningUnits"][0]["title"], "为什么运行还需要内存？")
        context = knowledge.knowledge_context(item, "S1", item["notes"])
        self.assertIn("noteTitle", context["unitFormat"])
        self.assertEqual(context["unitDirectory"][0]["noteTitle"], "权重、缓存与运行内存")
        before = copy.deepcopy(item)
        unit["noteTitle"] = "为什么运行还需要内存？"
        with self.assertRaisesRegex(ValueError, "知识标题"):
            knowledge.apply(item, item["notes"], unit=unit)
        self.assertEqual(item, before)

    def testRealMaterialsNeedSourcesAndHypotheticalExamplesHaveExplicitType(self):
        item = self.item()
        unit = {"id": "U1", "title": "观察", "question": "发生什么", "stageIDs": ["S1"], "topicIDs": ["K1"],
                "materialKind": "public_evaluation", "material": "观察结果", "conditions": "",
                "metrics": "定义", "reasoning": "解释", "limits": "边界", "judgment": "判断", "sources": []}
        with self.assertRaises(ValueError):
            knowledge.apply(item, item["notes"], unit=unit)
        self.assertNotIn("learningUnits", item)
        unit["materialKind"] = "hypothetical"
        knowledge.apply(item, item["notes"], unit=unit)
        self.assertEqual(knowledge.current_unit(item, "S1")["materialKind"], "hypothetical")


if __name__ == "__main__":
    unittest.main()
