"""Local incident experiences: atomic with demand feedback, portable across AI clients."""
import base64
import datetime
import hashlib
import json
import re
import shlex
import unicodedata
from pathlib import Path

PREFIX = "<!-- dboard-knowledge:v1:"
SUFFIX = " -->"
KINDS = ("开发需求", "线上排查")
CONTENT_FIELDS = ("title", "mechanism", "symptoms", "scopes", "procedure", "finding",
                  "confidence", "boundaries", "evidence", "related_ids")
ENTRY_FIELDS = set(CONTENT_FIELDS) | {"id", "sources", "active", "updated_by", "updated_at"}
CONFIDENCE = ("confirmed", "method")


class KnowledgeError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def fail(code, message):
    raise KnowledgeError(code, message)


def plain(value, label, required=True):
    if not isinstance(value, str) or any(ord(c) < 32 and c not in "\n\r\t" or ord(c) == 127 for c in value):
        fail("INVALID_KNOWLEDGE_DATA", label + " must be plain text")
    value = value.strip()
    if required and not value:
        fail("INVALID_KNOWLEDGE_DATA", label + " cannot be empty")
    return value


def strings(value, label, required=False):
    if not isinstance(value, list):
        fail("INVALID_KNOWLEDGE_DATA", label + " must be a list")
    result = list(dict.fromkeys(plain(v, label) for v in value))
    if required and not result:
        fail("INVALID_KNOWLEDGE_DATA", label + " needs at least one item")
    return result


def normalized(value):
    return unicodedata.normalize("NFKC", value).casefold().strip()


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def task_kind(block):
    rows = [line for line in block if line.startswith("- **类型**")]
    if not rows:
        return KINDS[0]
    if len(rows) != 1:
        fail("INVALID_TASK_KIND", "Duplicate task types; original data was preserved")
    value = re.sub(r"^- \*\*类型\*\*\s*[：:]?\s*", "", rows[0]).strip()
    if value not in KINDS:
        fail("INVALID_TASK_KIND", "Unknown task type; original data was preserved")
    return value


def closure(block):
    prefix = "<!-- dboard-incident-closure:v1:"
    rows = [line for line in block if line.startswith(prefix)]
    if not rows:
        return None
    try:
        if len(rows) != 1 or not rows[0].endswith(SUFFIX):
            raise ValueError()
        value = json.loads(base64.b64decode(rows[0][len(prefix):-len(SUFFIX)], validate=True))
        if value["outcome"] not in ("已处理", "已定位并交接", "结束本次排查，原因未定"):
            raise ValueError()
        plain(value["summary"], "closure summary")
        datetime.datetime.fromisoformat(value["closed_at"].replace("Z", "+00:00"))
        return value
    except (ValueError, KeyError, TypeError):
        fail("INVALID_INCIDENT_CLOSURE", "Incident closure is unreadable; original data was preserved")


def validate_entry(value):
    if not isinstance(value, dict) or set(value) != ENTRY_FIELDS:
        fail("INVALID_KNOWLEDGE_DATA", "Unknown experience fields; original data was preserved")
    if not re.fullmatch(r"K[0-9]{3,}", value["id"]):
        fail("INVALID_KNOWLEDGE_DATA", "Invalid experience ID")
    for key in ("title", "procedure", "boundaries"):
        plain(value[key], key)
    for key in ("mechanism", "finding"):
        plain(value[key], key, False)
    for key in ("symptoms", "scopes", "evidence", "related_ids"):
        strings(value[key], key, key in ("symptoms", "evidence"))
    if value["confidence"] not in CONFIDENCE:
        fail("INVALID_KNOWLEDGE_DATA", "Use confirmed or method confidence")
    if value["confidence"] == "confirmed" and not value["finding"].strip():
        fail("INVALID_KNOWLEDGE_DATA", "Confirmed experiences need an evidenced finding")
    if type(value["active"]) is not bool or value["updated_by"] not in ("ai", "user"):
        fail("INVALID_KNOWLEDGE_DATA", "Invalid experience maintenance state")
    try:
        datetime.datetime.fromisoformat(value["updated_at"].replace("Z", "+00:00"))
    except (ValueError, TypeError):
        fail("INVALID_KNOWLEDGE_DATA", "Invalid experience timestamp")
    if not isinstance(value["sources"], list) or not value["sources"]:
        fail("INVALID_KNOWLEDGE_DATA", "An experience needs its source incident")
    for source in value["sources"]:
        if (not isinstance(source, dict) or set(source) != {"id", "record_count", "scope_hash"}
                or not re.fullmatch(r"[DP][0-9]{3,}", source.get("id", ""))
                or type(source.get("record_count")) is not int or source["record_count"] < 0
                or not re.fullmatch(r"[0-9a-f]{64}", source.get("scope_hash", ""))):
            fail("INVALID_KNOWLEDGE_DATA", "Invalid experience provenance")
    if any(not re.fullmatch(r"K[0-9]{3,}", ref) or ref == value["id"] for ref in value["related_ids"]):
        fail("INVALID_KNOWLEDGE_DATA", "Invalid related experience IDs")
    return value


def read(lines):
    rows = [line for line in lines if line.startswith(PREFIX)]
    if not rows:
        return {"version": 1, "next_id": 1, "entries": []}
    try:
        if len(rows) != 1 or not rows[0].endswith(SUFFIX):
            raise ValueError()
        result = json.loads(base64.b64decode(rows[0][len(PREFIX):-len(SUFFIX)], validate=True))
        if (set(result) != {"version", "next_id", "entries"} or result["version"] != 1
                or type(result["version"]) is not int or type(result["next_id"]) is not int
                or not isinstance(result["entries"], list)):
            raise ValueError()
        for entry in result["entries"]:
            validate_entry(entry)
        ids = [entry["id"] for entry in result["entries"]]
        if len(set(ids)) != len(ids) or result["next_id"] <= max([int(v[1:]) for v in ids] or [0]):
            raise ValueError()
        if any(ref not in ids for entry in result["entries"] for ref in entry["related_ids"]):
            raise ValueError()
        return result
    except (ValueError, TypeError, KeyError, UnicodeError) as error:
        if isinstance(error, KnowledgeError):
            raise
        fail("INVALID_KNOWLEDGE_DATA", "Experience library is unreadable; do not overwrite it")


def write(lines, catalog):
    payload = base64.b64encode(json.dumps(catalog, ensure_ascii=False, sort_keys=True).encode()).decode()
    row = PREFIX + payload + SUFFIX
    # Metadata lives before the first quadrant, outside every demand's revision and archive block.
    lines[:] = [line for line in lines if not line.startswith(PREFIX)]
    lines.insert(0, row)


def record_view(entry):
    return dict(entry, revision=fingerprint(entry))


def outline(entry):
    return {key: record_view(entry)[key] for key in
            ("id", "title", "mechanism", "symptoms", "scopes", "confidence", "boundaries",
             "sources", "active", "updated_by", "revision")}


def search(catalog, query="", service=None, mechanism=None, limit=10, include_inactive=False):
    if not 1 <= limit <= 100:
        fail("INVALID_ARGUMENT", "Search limit must be within 1..100")
    query = normalized(query)
    words = set(re.findall(r"[a-z0-9_./:-]+|[\u3400-\u9fff]+", query))
    chinese = [v for v in words if re.search(r"[\u3400-\u9fff]", v)]
    grams = {v[i:i + 2] for v in chinese for i in range(len(v) - 1)}
    results = []
    for entry in catalog["entries"]:
        if not entry["active"] and not include_inactive:
            continue
        main = normalized(" ".join([entry["title"], entry["mechanism"]] + entry["symptoms"] + entry["scopes"]))
        detail = normalized(entry["procedure"] + " " + entry["finding"] + " " + entry["boundaries"])
        score = sum(8 for word in words if word in main) + sum(2 for word in words if word in detail)
        score += sum(1 for gram in grams if gram in main)
        if service and normalized(service) in main:
            score += 6
        if mechanism and normalized(mechanism) in normalized(entry["mechanism"]):
            score += 10
        if query and score == 0:
            continue
        results.append((score, entry))
    results.sort(key=lambda value: (value[0], value[1]["updated_at"]), reverse=True)
    return [dict(outline(entry), score=score) for score, entry in results[:limit]]


def content_input(value):
    if not isinstance(value, dict) or set(value) - set(CONTENT_FIELDS) - {"id", "expect_revision"}:
        fail("INVALID_KNOWLEDGE_DATA", "Supply experience content; DBoard manages IDs, sources and maintenance")
    result = {}
    for key in ("title", "procedure", "boundaries"):
        result[key] = plain(value.get(key), key)
    for key in ("mechanism", "finding"):
        result[key] = plain(value.get(key, ""), key, False)
    for key in ("symptoms", "scopes", "evidence", "related_ids"):
        result[key] = strings(value.get(key, []), key, key in ("symptoms", "evidence"))
    result["confidence"] = value.get("confidence")
    if result["confidence"] not in CONFIDENCE or result["confidence"] == "confirmed" and not result["finding"]:
        fail("INVALID_KNOWLEDGE_DATA", "State a confirmed finding or a reusable method with an unresolved cause")
    return result


def apply(catalog, value, decision, task_id, record_count, scope_hash):
    content = content_input(value)
    existing = next((entry for entry in catalog["entries"] if entry["id"] == value.get("id")), None)
    if decision == "update":
        if existing is None:
            fail("KNOWLEDGE_NOT_FOUND", "Read the existing experience before updating")
        if value.get("expect_revision") != fingerprint(existing):
            fail("KNOWLEDGE_REVISION_CONFLICT", "Experience changed; reread and reconcile instead of overwriting")
        if not existing["active"]:
            fail("KNOWLEDGE_DISABLED", "The user disabled this experience; do not reactivate it")
        if existing["updated_by"] == "user":
            protected = ("title", "mechanism", "procedure", "finding", "confidence", "boundaries")
            if any(content[key] != existing[key] for key in protected):
                fail("KNOWLEDGE_USER_MAINTAINED", "Preserve user corrections; only append evidence, aliases and sources")
        for key in ("symptoms", "scopes", "evidence", "related_ids"):
            content[key] = list(dict.fromkeys(existing[key] + content[key]))
        result = dict(existing, **content)
    elif decision == "create":
        if value.get("id") is not None or value.get("expect_revision") is not None:
            fail("INVALID_KNOWLEDGE_DATA", "A new experience must omit ID and expect_revision")
        duplicates = [entry["id"] for entry in catalog["entries"] if normalized(entry["title"]) == normalized(content["title"])
                      or all(normalized(entry[key]) == normalized(content[key]) for key in ("procedure", "finding", "boundaries"))]
        if duplicates:
            fail("KNOWLEDGE_EXISTS", "A matching experience exists: " + ", ".join(duplicates) + "; read and update or describe a different scope")
        result = dict(content, id="K" + str(catalog["next_id"]).zfill(3), sources=[], active=True, updated_by="ai", updated_at="")
        catalog["next_id"] += 1
    else:
        fail("INVALID_ARGUMENT", "Use create or update with an experience file")
    ids = {entry["id"] for entry in catalog["entries"]}
    if any(ref not in ids or ref == result["id"] for ref in result["related_ids"]):
        fail("INVALID_KNOWLEDGE_DATA", "Related experiences must already exist and cannot reference themselves")
    result["sources"] = [source for source in result["sources"] if source["id"] != task_id] + [
        {"id": task_id, "record_count": record_count, "scope_hash": scope_hash}]
    result["updated_at"] = datetime.datetime.now().astimezone().isoformat(timespec="microseconds")
    validate_entry(result)
    if existing:
        catalog["entries"][catalog["entries"].index(existing)] = result
    else:
        catalog["entries"].append(result)
    return record_view(result)


def review(current, decision, reason, value):
    supplied = decision is not None or reason is not None or value is not None
    if current["kind"] != "线上排查":
        if supplied:
            fail("EXPERIENCE_TASK_REQUIRED", "Only incident tasks collect experiences; ordinary demands do not require this judgment")
        return None
    if decision not in ("create", "update", "skip") or not isinstance(reason, str) or not reason.strip():
        fail("EXPERIENCE_REVIEW_REQUIRED", "Each incident report needs --experience-decision create|update|skip and --experience-reason")
    if (decision == "skip") != (value is None):
        fail("EXPERIENCE_FILE_REQUIRED", "Create/update needs --experience-file; skip must omit it")
    return {"decision": decision, "reason": plain(reason, "experience reason")}


def context(result, item, lines, cache):
    if item["kind"] != "线上排查":
        return result
    cli = [str(Path.home() / ".local/bin/dboard-ai"), "--cache", str(cache), "knowledge"]
    catalog = read(lines)
    description = next((line for line in item["description"].splitlines() if line.strip()), "")
    query = item["title"] + " " + description
    result["item"]["kind"] = item["kind"]
    result["item"]["incident_closure"] = item["incident_closure"]
    result["experience_review"] = {
        "required": item["status"] != "已完成",
        "last_review": item["experience_review"],
        "questions": ["有确认的根因或已验证的查法值得复用吗？", "已有同类经验应补充还是存在不同适用边界？",
                      "证据足够吗？未确认的根因不能写成已确认；没有有效新信息就skip。"],
    }
    result["knowledge_candidates"] = search(catalog, query=query, service=item.get("project"), limit=5)
    result["knowledge_commands"] = {
        "search": shlex.join(cli + ["search"]) + " '<现象、接口或可能机制>'",
        "read": shlex.join(cli + ["read"]) + " '<经验编号>'",
    }
    result["context"] = (
        "## 线上排查任务\n本次先核对现象与证据，查询已有排查经验；原始输入和本次证据优先。"
        "不需要PRD或自动建调试页，有代码改动才按需核验与准备上线清单。"
        "每轮回写判断create/update/skip，只沉淀确认结论或经验证的查法。用户明确要求完结时可调用incident close；不自行完结，恢复仍由用户在D板操作。\n"
        + result["context"])
    if item["status"] == "已完成":
        conclusion = item["incident_closure"]
        text = ("完结结果：" + conclusion["outcome"] + "；" + conclusion["summary"] + "\n") if conclusion else ""
        result["context"] = "本次排查已由用户完结，仅供查阅；没有新授权不继续执行、不重做或回写。\n" + text + result["context"]
    else:
        result["incident_commands"] = {
            "close": shlex.join(cli[:-1] + ["incident", "close", item["id"],
                "--expect-title", item["title"], "--expect-revision", item["revision"]])
                + " --outcome '<resolved|handed-off|stopped>' --summary '<一句话完结结论>'",
        }
        result["context"] += ("\n用户明确说完结／结束本次排查时，核对最新show后用incident close留结论并完成；"
                              "有新结论需沉淀时先正常report。完结不要求新写摘要或重复经验判断，"
                              "有未勾选的上线事项会拦截。命令：" + result["incident_commands"]["close"])
    return result
