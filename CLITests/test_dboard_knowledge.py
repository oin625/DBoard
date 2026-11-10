import json
from pathlib import Path
import subprocess
import sys
import unittest
import test_dboard_ai as base

import dboard_overview

knowledge = base.module.dboard_knowledge


class KnowledgeTests(unittest.TestCase):
    setUp = base.FeedbackTests.setUp
    tearDown = base.FeedbackTests.tearDown

    def call(self, *args, success=True):
        proc = subprocess.run([sys.executable, str(base.CLI), "--cache", str(self.cache), *args],
                              capture_output=True, text=True, timeout=20)
        result = json.loads(proc.stdout)
        self.assertEqual(proc.returncode == 0, success, proc.stdout + proc.stderr)
        return result

    def incident(self):
        self.cache.write_text(self.cache.read_text().replace("- **描述**：原始描述",
            "- **类型**：线上排查\n- **描述**：原始描述"))

    def content(self):
        return {"title": "核对登录态失效", "mechanism": "登录态失效",
                "symptoms": ["接口返回401", "响应为登录页HTML", "页面跳回登录"],
                "scopes": ["Ultra查询接口"], "procedure": "先核对原始响应和请求头；响应有业务数据时转查解析。",
                "finding": "", "confidence": "method", "boundaries": "凭证有效性和本次根因仍需证据确认。",
                "evidence": ["本次日志与record:1"], "related_ids": []}

    def args(self, decision="skip", content=None, event="event", summary=None, item_id="D014"):
        current = self.call("show", item_id)["item"]
        value = {"based_on_records": current["history_records"],
                 "sections": {"completed": summary or "已核对已有线索", "pending": "等待新增证据，无确定修复待办",
                              "decisions": "先核对原始响应，再判断解析或鉴权", "verification": "真实凭证尚待核验"},
                 "references": []}
        file = self.root / (event + "-handoff.json")
        file.write_text(json.dumps(value, ensure_ascii=False))
        args = ["report", item_id, "--expect-title", current["title"], "--expect-revision", current["revision"],
                "--handoff-file", str(file), "--compression-decision", "skip", "--compression-reason", "当前接续事实已核对",
                "--event-id", event, "--no-sync"]
        if summary:
            args += ["--summary", summary]
        if decision is not None:
            args += ["--experience-decision", decision, "--experience-reason", "已按证据判断复用价值"]
        if content is not None:
            file = self.root / (event + "-experience.json")
            file.write_text(json.dumps(content, ensure_ascii=False))
            args += ["--experience-file", str(file)]
        return args

    def create(self):
        self.incident()
        args = self.args("create", self.content(), event="create", summary="已核对原始响应，鉴权查法可复用。")
        result = self.call(*args)
        return result["experience_result"], args

    def mutate_entry(self, **values):
        lines = self.cache.read_text().splitlines()
        catalog = knowledge.read(lines)
        catalog["entries"][0].update(values)
        knowledge.write(lines, catalog)
        self.cache.write_text("\n".join(lines) + "\n")

    def update_content(self, entry):
        return dict({key: entry[key] for key in knowledge.CONTENT_FIELDS},
                    id=entry["id"], expect_revision=entry["revision"])

    def test_p_numbered_incidents_support_context_feedback_and_experience_sources(self):
        self.incident()
        self.cache.write_text(self.cache.read_text().replace("### D014【fixture】", "### P001【fixture】"))
        context = self.call("context", "P001")
        self.assertEqual(context["item"]["kind"], "线上排查")
        result = self.call(*self.args("create", self.content(), event="p-case",
                                     summary="已核对原始响应，查法可复用。", item_id="P001"))
        entry = result["experience_result"]
        self.assertEqual(entry["sources"][0]["id"], "P001")
        self.assertIn("context P001", self.call("knowledge", "read", entry["id"])["source_commands"][0]["read_command"])
        self.assertEqual(len(self.call("history", "P001")["records"]), 2)
        self.assertIn("P001", dboard_overview.render(self.cache.read_text()))
        self.cache.write_text(self.cache.read_text().replace("锁券接口 #进行中", "锁券接口 #已完成"))
        self.assertFalse(self.call("context", "P001")["experience_review"]["required"])

    def test_normal_tasks_do_not_collect_or_load_a_library(self):
        response = self.call("context", "D014")
        self.assertNotIn("experience_review", response)
        self.assertNotIn("knowledge_candidates", response)
        self.call(*self.args(None, event="ordinary", summary="正常开发反馈仍可保存。"))
        self.assertEqual(self.call("knowledge", "search")["matches"], [])
        before = self.cache.read_bytes()
        self.assertEqual(self.call(*self.args("skip", event="wrong-mode"), success=False)["error"]["code"],
                         "EXPERIENCE_TASK_REQUIRED")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_every_incident_report_requires_a_decision_but_skip_does_not_create_entries(self):
        self.incident()
        before = self.cache.read_bytes()
        response = self.call("context", "D014")
        self.assertTrue(response["experience_review"]["required"])
        self.assertEqual(response["item"]["kind"], "线上排查")
        self.assertIn("incident", response["reference_commands"])
        self.assertEqual(self.call(*self.args(None), success=False)["error"]["code"], "EXPERIENCE_REVIEW_REQUIRED")
        self.assertEqual(self.cache.read_bytes(), before)
        self.call(*self.args("skip", event="reviewed"))
        self.assertEqual(self.call("show", "D014")["item"]["experience_review"]["decision"], "skip")
        self.assertEqual(self.call("knowledge", "search")["matches"], [])

    def test_case_feedback_experience_and_retry_are_one_atomic_save(self):
        entry, args = self.create()
        self.assertEqual(entry["sources"][0]["id"], "D014")
        self.assertEqual(entry["sources"][0]["record_count"], 2)
        self.assertTrue(self.cache.read_text().startswith(knowledge.PREFIX))
        local = self.cache.read_text()
        overview = dboard_overview.render(local)
        self.assertEqual(overview, dboard_overview.render(
            "\n".join(line for line in local.splitlines() if not line.startswith(knowledge.PREFIX))))
        self.assertNotIn(knowledge.PREFIX, overview)
        self.assertNotIn(self.content()["procedure"], overview)
        saved = self.cache.read_bytes()
        self.assertTrue(self.call(*args)["duplicate"])
        self.assertEqual(self.cache.read_bytes(), saved)
        self.assertEqual(len(self.call("knowledge", "search")["matches"]), 1)
        full = self.call("knowledge", "read", entry["id"])
        self.assertEqual(full["experience"]["procedure"], self.content()["procedure"])
        self.assertTrue(full["source_commands"][0]["available"])
        self.assertIn("context D014 --full", full["source_commands"][0]["read_command"])
        self.assertIn("不许改动", self.cache.read_text())

    def test_outlines_allow_different_symptoms_and_cross_service_reuse_without_loading_details(self):
        entry, _ = self.create()
        for query in ("401", "登录页HTML", "页面跳回登录", "登录态失效"):
            matches = self.call("knowledge", "search", query, "--service", "audi")["matches"]
            self.assertEqual(matches[0]["id"], entry["id"])
            self.assertNotIn("procedure", matches[0])
        context = self.call("context", "D014")
        self.assertTrue(context["knowledge_commands"]["search"])
        self.assertTrue(context["experience_review"]["questions"])

    def test_update_merges_aliases_and_sources_instead_of_appending_duplicate_experiences(self):
        entry, _ = self.create()
        content = self.update_content(entry)
        content["symptoms"] = ["HTTP返回HTML"]
        content["scopes"] = ["Audi查询入口"]
        self.cache.write_text(self.cache.read_text() + "\n## 🔴 重要且紧急\n### D015【audi】查询异常 #进行中\n- **类型**：线上排查\n")
        self.call(*self.args("update", content, event="update", item_id="D015"))
        updated = self.call("knowledge", "read", entry["id"])["experience"]
        self.assertEqual([s["id"] for s in updated["sources"]], ["D014", "D015"])
        self.assertIn("接口返回401", updated["symptoms"])
        self.assertIn("HTTP返回HTML", updated["symptoms"])
        self.assertEqual(len(self.call("knowledge", "search")["matches"]), 1)

    def test_duplicate_bad_content_and_stale_revision_never_save_partial_feedback(self):
        entry, _ = self.create()
        variants = [
            ("duplicate", self.content(), "create", "KNOWLEDGE_EXISTS"),
            ("bad", dict(self.content(), confidence="confirmed", finding=""), "create", "INVALID_KNOWLEDGE_DATA"),
            ("stale", dict(self.update_content(entry), expect_revision="0" * 64), "update", "KNOWLEDGE_REVISION_CONFLICT"),
        ]
        for event, content, decision, error in variants:
            before = self.cache.read_bytes()
            self.assertEqual(self.call(*self.args(decision, content, event=event, summary="这一条不应被保存。"),
                                       success=False)["error"]["code"], error)
            self.assertEqual(self.cache.read_bytes(), before)

    def test_user_corrections_are_protected_but_new_aliases_and_proof_can_be_added(self):
        entry, _ = self.create()
        self.mutate_entry(updated_by="user", finding="用户纠正：尚未确认凭证过期")
        entry = self.call("knowledge", "read", entry["id"])["experience"]
        content = self.update_content(entry)
        content["finding"] = "覆盖用户纠正"
        before = self.cache.read_bytes()
        self.assertEqual(self.call(*self.args("update", content, event="overwrite"), success=False)["error"]["code"],
                         "KNOWLEDGE_USER_MAINTAINED")
        self.assertEqual(self.cache.read_bytes(), before)
        content = self.update_content(entry)
        content["symptoms"].append("网关返回登录页面")
        self.call(*self.args("update", content, event="append-proof"))
        updated = self.call("knowledge", "read", entry["id"])["experience"]
        self.assertEqual(updated["finding"], entry["finding"])
        self.assertEqual(updated["updated_by"], "user")

    def test_disabled_experiences_are_not_used_and_ai_cannot_enable_them(self):
        entry, _ = self.create()
        self.mutate_entry(active=False, updated_by="user")
        self.assertEqual(self.call("knowledge", "search", "401")["matches"], [])
        entry = self.call("knowledge", "read", entry["id"])["experience"]
        before = self.cache.read_bytes()
        self.assertEqual(self.call(*self.args("update", self.update_content(entry), event="disabled"), success=False)["error"]["code"],
                         "KNOWLEDGE_DISABLED")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_corruption_is_reported_without_erasing_the_library_or_blocking_ordinary_reads(self):
        self.cache.write_text(knowledge.PREFIX + "broken -->\n" + self.before)
        self.assertTrue(self.call("context", "D014")["success"])
        self.incident()
        before = self.cache.read_bytes()
        self.assertEqual(self.call("context", "D014", success=False)["error"]["code"], "INVALID_KNOWLEDGE_DATA")
        self.assertEqual(self.call("knowledge", "search", success=False)["error"]["code"], "INVALID_KNOWLEDGE_DATA")
        self.assertEqual(self.cache.read_bytes(), before)

    def test_completed_cases_remain_readable_and_cannot_be_reopened_by_ai_feedback(self):
        self.incident()
        self.cache.write_text(self.cache.read_text().replace("锁券接口 #进行中", "锁券接口 #已完成"))
        response = self.call("context", "D014")
        self.assertFalse(response["experience_review"]["required"])
        self.assertIn("仅供查阅", response["context"])
        self.assertEqual(self.call(*self.args("skip"), success=False)["error"]["code"], "DEMAND_COMPLETED")

    def test_type_changes_invalidate_scope_without_affecting_legacy_hashes(self):
        ordinary = self.call("show", "D014")["item"]
        self.incident()
        incident = self.call("show", "D014")["item"]
        self.assertNotEqual(ordinary["revision"], incident["revision"])
        block = ["### D014【ultra】测试 #进行中", "- **描述**：问题"]
        normal = base.module.execution_scope(block)
        self.assertEqual(normal, base.module.execution_scope(block + ["- **类型**：开发需求"]))
        self.assertNotEqual(normal, base.module.execution_scope(block + ["- **类型**：线上排查"]))


if __name__ == "__main__":
    unittest.main()
