"""Explicit full-history fixtures for legacy business regressions; compact behavior has separate tests."""
import hashlib
import json
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Tools"))
import dboard_ai as cli


def feedback_flags(cache, arguments):
    arguments = list(arguments)
    if not arguments or arguments[0] != "report" or "--compression-decision" in arguments:
        return []
    flags = ["--compression-decision", "skip", "--compression-reason", "测试夹具：增量反馈，无需整体整理"]
    summary_key = next((k for k in ("--summary", "--progress") if k in arguments), None)
    if not summary_key:
        return flags
    filename = Path(cache).parent / ("handoff-" + hashlib.sha256(json.dumps(arguments).encode()).hexdigest() + ".json")
    if not filename.exists():
        try:
            lines, _ = cli.read_content(Path(cache))
            start, end = cli.locate(lines, arguments[1])
            current = cli.describe(lines[start:end], arguments[1], Path(cache), start)
            records = current["progress_records"]
        except cli.CLIError:
            records = []
        completed = "\n".join(r["summary"] + "\n" + r["details"] for r in records)
        completed += "\n" + arguments[arguments.index(summary_key) + 1]
        detail = arguments[arguments.index("--details") + 1] if "--details" in arguments else ""
        filename.write_text(json.dumps({"based_on_records": len(records), "sections": {
            "completed": completed, "pending": "测试夹具，待人工验收", "decisions": "",
            "verification": detail}, "references": []}, ensure_ascii=False))
    return flags + ["--handoff-file", str(filename)]
