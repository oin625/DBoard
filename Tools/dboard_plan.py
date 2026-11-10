"""Local AI-authored technical plans. No model calls or remote writes at save time."""
import base64
import hashlib
import json
import re

PREFIX = "<!-- dboard-technical-plan:v1:"
SUFFIX = " -->"


class PlanError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def fail(message):
    raise PlanError("INVALID_TECHNICAL_PLAN", message)


def signature(value):
    if value is None:
        return "none"
    parts = [value["title"], value["markdown"]]
    parts.extend(p["name"] + ":" + p["branch"] for p in sorted(value["projects"], key=lambda p: p["name"]))
    parts.extend([value["scope_hash"], value.get("code_revision") or "", value["updated_at"], value["updated_by"]])
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()


def valid_branch(branch):
    return (isinstance(branch, str) and bool(branch) and branch not in ("HEAD", "待定", "待补充")
            and not any(c.isspace() or c in " ,;，；：:\\~^?*[" for c in branch)
            and ".." not in branch and "@{" not in branch
            and not branch.startswith("-") and not branch.endswith(("/", ".lock")))


def integration_branch(branch):
    branch = branch.lower()
    return branch in ("pre", "release", "staging", "integration") or branch.startswith(("merge/", "integration/", "release/"))


def projects(values):
    if not isinstance(values, list):
        fail("工程分支须为列表")
    seen = set()
    for p in values:
        if (not isinstance(p, dict) or not isinstance(p.get("name"), str)
                or not re.fullmatch(r"[A-Za-z0-9_.-]+", p["name"]) or p["name"] in seen
                or not valid_branch(p.get("branch")) or integration_branch(p["branch"])):
            fail("工程分支不完整、重复或包含合并／发布分支")
        seen.add(p["name"])
    return [{"name": p["name"], "branch": p["branch"]} for p in values]


def validate(value):
    if not isinstance(value, dict):
        fail("技术方案记录无法读取")
    for key in ("title", "markdown", "scope_hash", "updated_at", "updated_by"):
        if not isinstance(value.get(key), str) or not value[key].strip():
            fail("技术方案字段不完整：" + key)
    if len(value["title"]) > 200 or "\n" in value["title"] or len(value["markdown"]) > 60000:
        fail("技术方案标题或正文格式不正确")
    if any(ord(c) < 32 and c not in "\n\r\t" for c in value["markdown"]):
        fail("技术方案正文含无效字符")
    if not re.fullmatch(r"[0-9a-f]{64}", value["scope_hash"]):
        fail("技术方案需求版本无效")
    if value.get("code_revision") is not None and not re.fullmatch(r"[0-9a-f]{64}", value["code_revision"]):
        fail("技术方案代码版本无效")
    if value["updated_by"] not in ("ai", "user"):
        fail("技术方案作者无效")
    projects(value.get("projects"))
    return value


def read(block):
    records = [line for line in block if line.startswith(PREFIX)]
    if not records:
        return None
    try:
        if len(records) != 1 or not records[0].endswith(SUFFIX):
            fail("技术方案记录重复或损坏，原记录已保留")
        raw = base64.b64decode(records[0][len(PREFIX):-len(SUFFIX)], validate=True).decode()
        return validate(json.loads(raw))
    except (ValueError, UnicodeError, KeyError, TypeError) as e:
        if isinstance(e, PlanError):
            raise
        fail("技术方案无法读取，原记录已保留")


def store(block, value):
    validate(value)
    block[:] = [line for line in block if not line.startswith(PREFIX)]
    encoded = base64.b64encode(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).decode()
    block.insert(1, PREFIX + encoded + SUFFIX)


def declarations(item):
    branch = item["branch"].strip()
    if ":" in branch or "：" in branch:
        pairs = []
        for part in re.split(r"[;；\r\n]", branch):
            if not part.strip():
                continue
            name, sep, value = part.replace("：", ":").partition(":")
            if not sep:
                fail("请按工程:开发分支填写")
            pairs.append({"name": name.strip().rstrip("/").split("/")[-1], "branch": value.strip()})
        return projects(pairs)
    repos = item["repositories"]
    if len(repos) == 1 and branch:
        return projects([{"name": repos[0].get("name") or repos[0]["path"].rstrip("/").split("/")[-1], "branch": branch}])
    return []


def readiness(value, item, scope_hash):
    if value is None:
        return {"needs_review": True, "reason": "尚未准备技术方案", "revision": "none"}
    reason = None
    if value["scope_hash"] != scope_hash:
        reason = "需求已变化，请让 AI 核对技术方案"
    elif not item.get("code_revision") or value.get("code_revision") != item["code_revision"]:
        reason = "代码已变化或无法核实，请让 AI 核对技术方案"
    else:
        try:
            expected = declarations(item)
            actual = projects(value["projects"])
            known = {p.get("name"): p["branch"] for p in item["repositories"]}
            environment = {(p.get("name"), p["branch"]) for p in item.get("environment_repositories", [])}
            if (not actual or sorted(expected, key=lambda p: p["name"]) != sorted(actual, key=lambda p: p["name"])
                    or any(known.get(p["name"]) != p["branch"] or (p["name"], p["branch"]) in environment for p in actual)
                    or set(known) != {p["name"] for p in actual}):
                reason = "开发工程／分支已变化或未核实，请核对后更新技术方案"
        except PlanError:
            reason = "开发分支格式不正确，请核对后更新技术方案"
    return {"needs_review": reason is not None, "reason": reason, "revision": signature(value),
            "updated_by": value["updated_by"], "updated_at": value["updated_at"]}


def view(value, state, full=False):
    if value is None:
        return dict(state, exists=False)
    result = {key: value[key] for key in ("title", "projects", "updated_at", "updated_by", "scope_hash", "code_revision")}
    if full:
        result["markdown"] = value["markdown"]
    return dict(result, **state, exists=True, body_deferred=not full)
