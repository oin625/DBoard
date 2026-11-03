import ast
import io
import json
from pathlib import Path
import unittest
from unittest import mock
import urllib.request


SCRIPT = Path(__file__).resolve().parents[1] / "sync_to_aitable.sh"
SOURCE = SCRIPT.read_text(encoding="utf-8").split("<<'PYTHON'\n", 1)[1].rsplit("\nPYTHON", 1)[0]
TREE = ast.parse(SOURCE)
FUNCTIONS = {"cell_text", "norm", "requirement_fields", "table_requirement"}
CODE = compile(ast.Module(body=[
    node for node in TREE.body
    if isinstance(node, (ast.Import, ast.ImportFrom))
    or isinstance(node, ast.FunctionDef) and node.name in FUNCTIONS
], type_ignores=[]), str(SCRIPT), "exec")


class TableRequirementStatusTests(unittest.TestCase):
    def setUp(self):
        self.record = {"recordId": "record", "cells": {"name": "fixture", "online": ""}}
        self.namespace = {"F_NAME": "name", "F_ONLINE": "online",
                          "prd": {"items": []}, "links": {}, "records": [self.record]}
        exec(CODE, self.namespace)

    def lookup(self, payload=None, error=None):
        response = io.BytesIO(json.dumps(payload).encode("utf-8"))
        with mock.patch("builtins.open", mock.mock_open(read_data="fixture-cookie")), \
             mock.patch.object(urllib.request, "urlopen", return_value=response,
                               side_effect=error) as api:
            result = self.namespace["table_requirement"](self.record)
        return result, api

    def test_current_cache_supplies_real_status_without_network(self):
        self.namespace["prd"]["items"] = [
            {"id": 42, "name": "fixture", "no": "R42", "code": "KFWC", "status": "开发完成"}]
        result, api = self.lookup()
        self.assertEqual(result["requirementStatus"], "开发完成")
        self.assertEqual(result["requirementId"], 42)
        api.assert_not_called()

    def test_historical_exact_match_reads_completed_status(self):
        result, api = self.lookup({"success": True, "total": 1, "data": [
            {"id": 43, "reqName": "fixture", "reqNo": "R43",
             "currentStatus": "XQWC", "currentStatusName": "需求完成"}]})
        self.assertEqual(result["requirementStatus"], "需求完成")
        self.assertEqual(result["requirementCode"], "XQWC")
        self.assertEqual(result["requirementId"], 43)
        self.assertIn("/list?", api.call_args.args[0].full_url)

    def test_confirmed_identity_survives_renaming(self):
        self.namespace["links"] = {"42": "record"}
        self.namespace["prd"]["items"] = [
            {"id": 42, "name": "renamed", "no": "R42", "code": "CPYSWC",
             "status": "承接人验收完成"}]
        result, api = self.lookup()
        self.assertEqual(result["requirementId"], 42)
        api.assert_not_called()

    def test_confirmed_id_lookup_rejects_wrong_detail(self):
        self.namespace["links"] = {"42": "record"}
        result, api = self.lookup({"success": True, "data": {
            "id": 99, "currentStatusName": "开发中", "currentStatus": "KFZ"}})
        self.assertEqual(result, {})
        self.assertIn("/detail/42", api.call_args.args[0].full_url)

    def test_fuzzy_duplicate_or_partial_results_are_not_associated(self):
        item = {"id": 42, "reqName": "fixture", "currentStatusName": "开发中"}
        for rows, total in [([dict(item, reqName="fixture extra")], 1),
                            ([item, dict(item, id=43)], 2), ([item], 2), ([], 0)]:
            with self.subTest(rows=rows, total=total):
                result, _ = self.lookup({"success": True, "total": total, "data": rows})
                self.assertEqual(result, {})

    def test_ambiguous_local_records_or_requirements_are_not_associated(self):
        self.namespace["prd"]["items"] = [
            {"id": 42, "name": "fixture", "status": "开发中"},
            {"id": 43, "name": "fixture", "status": "需求完成"}]
        result, api = self.lookup()
        self.assertEqual(result, {})
        api.assert_not_called()
        self.namespace["prd"]["items"] = self.namespace["prd"]["items"][:1]
        self.namespace["records"].append({"recordId": "other", "cells": {"name": "fixture"}})
        result, api = self.lookup()
        self.assertEqual(result, {})
        api.assert_not_called()

    def test_unreadable_status_remains_unknown(self):
        result, _ = self.lookup({"success": False, "data": []})
        self.assertEqual(result, {})
        result, _ = self.lookup(error=OSError("fixture"))
        self.assertEqual(result, {})

    def test_past_release_schedule_does_not_trigger_extra_query(self):
        self.record["cells"]["online"] = "2020-01-01"
        result, api = self.lookup()
        self.assertEqual(result, {})
        api.assert_not_called()


if __name__ == "__main__":
    unittest.main()
