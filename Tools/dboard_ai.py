#!/usr/bin/env python3
"""DBoard execution feedback CLI. Only the explicitly named demand is read or updated."""
import argparse
import base64
import datetime
import fcntl
import hashlib
import json
import shlex
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import uuid

DEFAULT_CACHE = Path.home() / ".claude/demand-center-cache.md"
META_PREFIX = "<!-- dboard-ai-feedback:v1:"
META_SUFFIX = " -->"
DEBUG_PAGE_POLICY_PREFIX = "<!-- dboard-debug-page:v1:"
DEBUG_PAGE_NOT_NEEDED = DEBUG_PAGE_POLICY_PREFIX + "not-needed -->"

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dboard_code
import dboard_handoff
import dboard_knowledge
import dboard_plan
import dboard_worktrees


class CLIError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def emit(value):
    print(json.dumps(value, ensure_ascii=False))


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise CLIError("INVALID_ARGUMENT", message)


def scalar(value, label):
    if not value or any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise CLIError("INVALID_ARGUMENT", label + " must be nonempty and single-line")
    return value


def locate(lines, item_id):
    if not re.fullmatch(r"[DP][0-9]{3,}", item_id):
        raise CLIError("INVALID_ID", "Use the exact task number, for example D014 or P001")
    pattern = re.compile(r"^### " + re.escape(item_id) + r"(?=【|\s|$)")
    starts = [i for i, line in enumerate(lines) if pattern.match(line)]
    if len(starts) != 1:
        raise CLIError("NOT_FOUND" if not starts else "AMBIGUOUS_ID",
                       "Demand not found" if not starts else "Duplicate demand IDs; no update made")
    start = starts[0]
    end = start + 1
    while end < len(lines) and not (lines[end].startswith(("## ", "### ")) or lines[end] == "---"):
        end += 1
    while end > start + 1 and not lines[end - 1].strip() and not lines[end - 1].startswith("    "):
        end -= 1
    return start, end


def revision(block):
    return hashlib.sha256("\n".join(block).encode("utf-8")).hexdigest()


def fields(block):
    result = {}
    i = 1
    while i < len(block):
        match = re.match(r"^- \*\*([^*]+)\*\*\s*[：:]?\s*(.*)$", block[i])
        if match:
            key, value = match.groups()
            following = []
            i += 1
            while i < len(block) and block[i].startswith("    "):
                following.append(block[i][4:])
                i += 1
            if key in result:
                raise CLIError("AMBIGUOUS_FIELD", "Duplicate field: " + key)
            result[key] = "\n".join(([value] if value else []) + following)
        else:
            i += 1
    return result


def feedback_metadata(block):
    records = [line for line in block if line.startswith(META_PREFIX)]
    if not records:
        return {"repositories": [], "events": {}}
    try:
        if len(records) != 1 or not records[0].endswith(META_SUFFIX):
            raise ValueError()
        data = json.loads(base64.b64decode(records[0][len(META_PREFIX):-len(META_SUFFIX)],
                                          validate=True).decode("utf-8"))
        if not isinstance(data, dict) or not isinstance(data.get("repositories"), list) or not isinstance(data.get("events"), dict):
            raise ValueError()
        for repo in data["repositories"] + data.get("environment_repositories", []):
            if not isinstance(repo, dict):
                raise ValueError()
            scalar(repo["path"], "repository")
            scalar(repo["branch"], "branch")
            for key in ("git_common_dir", "name", "role"):
                if key in repo:
                    if not isinstance(repo[key], str):
                        raise ValueError()
                    scalar(repo[key], key)
        if any(not isinstance(k, str) or not isinstance(v, str) for k, v in data["events"].items()):
            raise ValueError()
        return data
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise CLIError("INVALID_FEEDBACK_DATA", "Existing feedback metadata is unreadable; no update made")


def demand_changes(value):
    if not value:
        return []
    prefix, suffix = "<!-- dboard-changes:v1:", " -->"
    try:
        first, body = value.split("\n", 1)
        if not first.startswith(prefix) or not first.endswith(suffix):
            raise ValueError()
        changes = json.loads(base64.b64decode(first[len(prefix):-len(suffix)], validate=True).decode("utf-8"))
        if not isinstance(changes, list):
            raise ValueError()
        seen = set()
        readable = []
        for change in changes:
            if not isinstance(change, dict):
                raise ValueError()
            change_id, created, intent = change["id"], change["createdAt"], change["intent"]
            if not isinstance(change_id, str) or not re.fullmatch(r"C[0-9]{3,}", change_id) or change_id in seen:
                raise ValueError()
            if not 0 < int(change_id[1:]) < 2 ** 63:
                raise ValueError()
            if not isinstance(created, str) or not isinstance(intent, str) or not intent.strip():
                raise ValueError()
            datetime.datetime.strptime(created, "%Y-%m-%dT%H:%M:%SZ")
            seen.add(change_id)
            readable.append("### " + change_id + " · " + created + "\n" + intent)
        if body != "\n".join(readable):
            raise ValueError()
        return changes
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise CLIError("INVALID_CHANGE_DATA", "Existing change spells are unreadable; no update made")


def demand_version(block):
    prefix, suffix = "<!-- dboard-version:v1:", " -->"
    records = [line for line in block if line.startswith(prefix)]
    if not records:
        return None
    try:
        if len(records) != 1 or not records[0].endswith(suffix):
            raise ValueError()
        value = json.loads(base64.b64decode(records[0][len(prefix):-len(suffix)], validate=True).decode("utf-8"))
        if not isinstance(value, dict) or type(value.get("number")) is not int or not 2 <= value["number"] < 2 ** 63 - 1:
            raise ValueError()
        for key in ("parentID", "rootID"):
            if not isinstance(value.get(key), str) or not re.fullmatch(r"[DP][0-9]{3,}", value[key]):
                raise ValueError()
        for key in ("parentTitle", "background"):
            if not isinstance(value.get(key), str) or not value[key].strip():
                raise ValueError()
        if not isinstance(value.get("sourceRevision"), str) or not re.fullmatch(r"[0-9a-f]{64}", value["sourceRevision"]):
            raise ValueError()
        if not isinstance(value.get("repositories"), list):
            raise ValueError()
        for repo in value["repositories"]:
            if not isinstance(repo, dict) or any(not isinstance(repo.get(key), str) or not repo[key].strip()
                                                  for key in ("path", "branch")):
                raise ValueError()
        return value
    except (ValueError, KeyError, TypeError, UnicodeError):
        raise CLIError("INVALID_VERSION_DATA", "Previous version background is unreadable; no update made")


def progress_summary(text):
    text = text.strip()
    if len(text) <= 120:
        return text
    sentence = re.split(r"[。！？；;\n]", text, maxsplit=1)[0].strip()
    return sentence + "。" if sentence and len(sentence) <= 80 else text[:79] + "…"


def progress_records(value):
    records = []
    for line in value.split("\n"):
        match = re.fullmatch(r"- ([0-9]{1,2}\.[0-9]{1,2}): (.*)", line)
        if match:
            date, text = match.groups()
            records.append({"date": date, "summary": progress_summary(text),
                            "details": text if progress_summary(text) != text else ""})
        elif line.startswith("    ") and records:
            detail = line[4:]
            if detail == "明细：" and not records[-1].get("_explicit"):
                records[-1]["details"] = ""
                records[-1]["_explicit"] = True
            else:
                records[-1]["details"] += detail + "\n"
    for record in records:
        record.pop("_explicit", None)
        if record["details"].endswith("\n"):
            record["details"] = record["details"][:-1]
    return records


def image_references(text):
    """Image paths are local attachments; report availability without discarding missing references."""
    images = []
    seen = set()
    for match in re.finditer(r"!\[([^\]\n]*)\]\(<(/[^>\n]+)>\)", text):
        label, path = match.groups()
        if path not in seen:
            seen.add(path)
            images.append({"label": label, "path": path, "exists": Path(path).is_file()})
    return images


def read_chat_links(block):
    tag = "- **关联群聊**"
    indices = [i for i, line in enumerate(block) if line.startswith(tag)]
    if not indices:
        return None
    try:
        if len(indices) != 1:
            raise ValueError()
        index = indices[0]
        if index + 1 < len(block) and block[index + 1].startswith("    "):
            raise ValueError()
        value = block[index][len(tag):]
        if value.startswith(("：", ":")):
            value = value[1:]
        links = json.loads(value)
        if not isinstance(links, dict) or not isinstance(links.get("secondary"), list):
            raise ValueError()
        primary = links.get("primary")
        chats = ([primary] if primary is not None else []) + links["secondary"]
        seen = set()
        for chat in chats:
            if (not isinstance(chat, dict) or not isinstance(chat.get("id"), str)
                or not chat["id"] or any(c.isspace() for c in chat["id"])
                or not isinstance(chat.get("name"), str) or not chat["name"].strip()
                or chat["id"] in seen):
                raise ValueError()
            seen.add(chat["id"])
        return {"primary": primary, "secondary": links["secondary"]} if chats else None
    except (ValueError, TypeError, KeyError):
        raise CLIError("INVALID_CHAT_LINKS", "关联群聊无法读取，原记录已保留；请检查需求数据。")


def chat_sources(links):
    if not links:
        return []
    groups = ([("primary", links["primary"])] if links["primary"] else []) + [("secondary", chat) for chat in links["secondary"]]
    now = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")
    dws = str(Path.home() / ".qoderwork/bin/dws")
    return [{"role": role, "id": chat["id"], "name": chat["name"],
             "read_command": shlex.join([dws, "chat", "message", "list", "--group", chat["id"],
                "--time", now, "--direction", "older", "--limit", "50", "--format", "json"])}
            for role, chat in groups]


EXECUTION_PREFIX = "<!-- dboard-execution:v1:"
STAGES = ("developing", "development-complete", "debug-page-ready", "testing-passed")


def execution_scope(block):
    header = block[0]
    for status in ("待开始", "进行中", "已完成", "挂起"):
        header = header.replace("#" + status, "")
    header = re.sub(r"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})", "", header)
    header = re.sub(r"\s+", " ", header).strip()
    raw = fields(block)
    values = [header] + [raw.get(key, "") for key in ("项目", "描述", "提示词", "变更咒言", "需求流", "关联群聊")]
    values += [line for line in block if line.startswith("<!-- dboard-version:v1:")]
    if raw.get("类型") not in (None, "开发需求"):
        values.append("kind=" + raw["类型"])
    return hashlib.sha256("\0".join(values).encode("utf-8")).hexdigest()


def validate_debug_page(page):
    if not isinstance(page, str) or not re.fullmatch(r"/[A-Za-z0-9][A-Za-z0-9/_-]*", page) or "//" in page:
        raise CLIError("INVALID_ARGUMENT", "Use the actual module route, for example /test-console/coupon-lock")


def validate_debug_url(url, page):
    from urllib.parse import urlsplit, unquote
    try:
        if not isinstance(url, str) or any(c.isspace() or ord(c) < 32 for c in url):
            raise ValueError()
        parts = urlsplit(url)
        if parts.scheme not in ("https", "http") or not parts.hostname or parts.username is not None or parts.password is not None:
            raise ValueError()
        if parts.port is not None and not 1 <= parts.port <= 65535:
            raise ValueError()
        if unquote(parts.path).strip("/") != page.strip("/"):
            raise ValueError()
    except (ValueError, TypeError):
        raise CLIError("INVALID_ARGUMENT", "Debug URL must be an actual HTTP(S) URL matching the module route, without credentials")


def read_execution(block):
    records = [line for line in block if line.startswith(EXECUTION_PREFIX)]
    if not records:
        return None
    try:
        if len(records) != 1 or not records[0].endswith(META_SUFFIX):
            raise ValueError()
        data = json.loads(base64.b64decode(records[0][len(EXECUTION_PREFIX):-len(META_SUFFIX)], validate=True).decode("utf-8"))
        if not isinstance(data, dict) or data.get("stage") not in STAGES or not isinstance(data.get("scope_hash"), str):
            raise ValueError()
        if not re.fullmatch(r"[0-9a-f]{64}", data["scope_hash"]):
            raise ValueError()
        scalar(data["updated_at"], "updated_at")
        if data.get("code") is not None and not dboard_code.validate_snapshots(data["code"]):
            raise ValueError()
        page, url = data.get("debug_page"), data.get("debug_url")
        if page is not None:
            validate_debug_page(page)
        if data["stage"] in ("debug-page-ready", "testing-passed") and page is None:
            raise ValueError()
        if url is not None:
            if page is None:
                raise ValueError()
            validate_debug_url(url, page)
        return data
    except (ValueError, KeyError, TypeError, UnicodeError, CLIError):
        raise CLIError("INVALID_EXECUTION_DATA", "Existing debug milestones are unreadable; no update made")


def update_execution(block, current, args):
    stage = getattr(args, "stage", None)
    page = getattr(args, "debug_page", None)
    url = getattr(args, "debug_url", None)
    if stage is None:
        return
    if current.get("debug_page_not_needed") and stage in ("debug-page-ready", "testing-passed"):
        raise CLIError("DEBUG_PAGE_NOT_NEEDED", "User opted out of debug pages; report backend verification and ordinary test progress instead")
    previous = current["execution"]
    valid_previous = previous is not None and previous["scope_hash"] == execution_scope(block)
    if stage == "debug-page-ready" and (not valid_previous or previous["stage"] == "developing"):
        raise CLIError("DEVELOPMENT_NOT_VERIFIED", "First verify backend implementation against all requirements and report development-complete")
    if stage == "testing-passed" and (not valid_previous or previous["stage"] not in ("debug-page-ready", "testing-passed")):
        raise CLIError("DEBUG_PAGE_NOT_READY", "First report a verified debug-page-ready result for the current requirements")
    old_page = previous.get("debug_page") if previous else None
    old_url = previous.get("debug_url") if previous else None
    page = page if page is not None else old_page
    if stage in ("debug-page-ready", "testing-passed") and page is None:
        raise CLIError("INVALID_ARGUMENT", "Page milestones require --debug-page with the actual module route")
    if stage == "testing-passed" and page != old_page:
        raise CLIError("DEBUG_PAGE_NOT_READY", "Changed module route must first be reported as debug-page-ready")
    url = url if url is not None else (old_url if page == old_page else None)
    if url is not None:
        validate_debug_url(url, page)
    code = None
    if stage != "developing":
        try:
            code = dboard_code.capture(current["repositories"])
        except dboard_code.CodeError as error:
            raise CLIError("CODE_NOT_VERIFIABLE", str(error) + "; record all actual development repositories before verification")
        if getattr(args, "expect_code", None) != dboard_code.revision(code):
            raise CLIError("CODE_REVISION_CONFLICT", "Code changed or --expect-code is missing; verify the current code, then use code_revision from show")
    record = {"stage": stage, "scope_hash": execution_scope(block), "debug_page": page, "debug_url": url,
              "code": code, "updated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    block[:] = [line for line in block if not line.startswith(EXECUTION_PREFIX)]
    encoded = base64.b64encode(json.dumps(record, ensure_ascii=False, sort_keys=True).encode("utf-8")).decode("ascii")
    block.insert(1, EXECUTION_PREFIX + encoded + META_SUFFIX)


def debug_page_not_needed(block):
    records = [line for line in block if line.startswith(DEBUG_PAGE_POLICY_PREFIX)]
    if len(records) > 1 or any(line != DEBUG_PAGE_NOT_NEEDED for line in records):
        raise CLIError("INVALID_DEBUG_PAGE_POLICY", "User debug-page preference is unreadable; no update made")
    return bool(records)


RELEASE_PREFIX = "<!-- dboard-release-checklist:v1:"
RELEASE_CATEGORIES = {"release": "发布", "sql": "SQL", "configuration": "配置", "permission": "权限", "other": "其他"}


def valid_release_category(category):
    if not isinstance(category, str):
        return False
    if category in RELEASE_CATEGORIES:
        return True
    if not category.startswith("custom:"):
        return False
    name = category[7:]
    return (bool(name) and name == name.strip() and len(name) <= 20
            and name not in RELEASE_CATEGORIES.values()
            and not any(ord(c) < 32 or ord(c) == 127 for c in name))


def release_category_title(category):
    return RELEASE_CATEGORIES.get(category, category[7:])


def infer_release_category(text):
    text = text.lower()
    if any(x in text for x in ("sql", "建表", "索引", "ddl", "表结构")) or (text.startswith("创建") and "表" in text):
        return "sql"
    if text.startswith(("发布", "部署")):
        return "release"
    if any(x in text for x in ("权限", "授权", "网关", "开通", "菜单")):
        return "permission"
    if any(x in text for x in ("配置", "开关", "定时", "调度", "任务", "xxl")):
        return "configuration"
    if any(x in text for x in ("发布", "部署")):
        return "release"
    return "other"


def read_release_checklist(block):
    records = [line for line in block if line.startswith(RELEASE_PREFIX)]
    empty = {"items": [], "excluded_by_user": [], "next_id": 1, "reviewed_scope": None}
    if not records:
        return empty
    try:
        if len(records) != 1 or not records[0].endswith(META_SUFFIX):
            raise ValueError()
        value = json.loads(base64.b64decode(records[0][len(RELEASE_PREFIX):-len(META_SUFFIX)], validate=True).decode("utf-8"))
        if not isinstance(value, dict) or not isinstance(value.get("items"), list) or not isinstance(value.get("excluded_by_user"), list):
            raise ValueError()
        ids, texts, numbers = set(), set(), []
        for entry in value["items"]:
            if not isinstance(entry, dict) or not isinstance(entry.get("id"), str) or not re.fullmatch(r"L[0-9]{3,}", entry["id"]):
                raise ValueError()
            number = int(entry["id"][1:])
            if number <= 0 or entry["id"] in ids or type(entry.get("done")) is not bool or entry.get("updated_by") not in ("user", "ai"):
                raise ValueError()
            text = scalar(entry.get("text"), "release item") if isinstance(entry.get("text"), str) else None
            if not text or not text.strip() or text.strip().lower() in texts:
                raise ValueError()
            details = "" if entry.get("details") is None else entry["details"]
            if not isinstance(details, str) or len(details) > 12000 or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127 for c in details):
                raise ValueError()
            entry["details"] = details
            evidence = entry.get("evidence", "")
            if not isinstance(evidence, str) or len(evidence) > 12000 or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127 for c in evidence):
                raise ValueError()
            entry["evidence"] = evidence
            category = entry.get("category")
            if category is None:
                category = infer_release_category(text)
            if not valid_release_category(category):
                raise ValueError()
            entry["category"] = category
            ids.add(entry["id"]); texts.add(text.strip().lower()); numbers.append(number)
        excluded = value["excluded_by_user"]
        if any(not isinstance(x, str) or not x.strip() or any(ord(c) < 32 or ord(c) == 127 for c in x) for x in excluded):
            raise ValueError()
        if len(set(x.strip().lower() for x in excluded)) != len(excluded):
            raise ValueError()
        if type(value.get("next_id")) is not int or not max(numbers, default=0) < value["next_id"] < sys.maxsize:
            raise ValueError()
        scope = value.get("reviewed_scope")
        if scope is not None and (not isinstance(scope, str) or not re.fullmatch(r"[0-9a-f]{64}", scope)):
            raise ValueError()
        return {"items": value["items"], "excluded_by_user": excluded, "next_id": value["next_id"], "reviewed_scope": scope}
    except (ValueError, TypeError, KeyError, CLIError):
        raise CLIError("INVALID_RELEASE_CHECKLIST", "上线前事项无法读取，原记录已保留；不要按空清单处理")


def validate_release_summary(text):
    if not isinstance(text, str):
        raise CLIError("INVALID_ARGUMENT", "上线事项概括必须是文字")
    scalar(text.strip(), "release summary")
    if len(text.strip()) > 40:
        raise CLIError("RELEASE_SUMMARY_TOO_LONG", "概括最多40字，只写发布什么或执行什么；分支、路径、配置和顺序请用 --release-item 的 details 保存")


def release_request(args):
    additions = getattr(args, "release_add", None) or []
    edits = getattr(args, "release_edit", None) or []
    removals = getattr(args, "release_remove", None) or []
    reviewed = getattr(args, "release_reviewed", False)
    structured = []
    for raw in getattr(args, "release_item", None) or []:
        try:
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError()
        except (ValueError, TypeError):
            raise CLIError("INVALID_ARGUMENT", "--release-item 需要 JSON 对象，包含 summary、category 和可选 details；修改时加 id")
        validate_release_summary(value.get("summary"))
        item = {"summary": value["summary"].strip()}
        if "id" in value:
            if not isinstance(value["id"], str) or not re.fullmatch(r"L[0-9]{3,}", value["id"]):
                raise CLIError("INVALID_ARGUMENT", "使用 show 返回的上线事项 id")
            item["id"] = value["id"]
        if "details" in value:
            details = value["details"]
            if not isinstance(details, str) or len(details) > 12000 or any((ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127 for c in details):
                raise CLIError("INVALID_ARGUMENT", "上线事项明细需为12000字以内的普通文字，可换行")
            item["details"] = details.strip()
        if "category" in value:
            category = value["category"]
            if not valid_release_category(category):
                raise CLIError("INVALID_ARGUMENT", "分类使用常用分类，或 custom:自定义名称（名称1～20字）")
            item["category"] = category
        structured.append(item)
    for text in additions:
        validate_release_summary(text)
    for edit in edits:
        item_id, separator, text = edit.partition("=")
        if not separator or not re.fullmatch(r"L[0-9]{3,}", item_id):
            raise CLIError("INVALID_ARGUMENT", "Use --release-edit 'L001=简短概括'")
        validate_release_summary(text)
    if any(not re.fullmatch(r"L[0-9]{3,}", item_id) for item_id in removals):
        raise CLIError("INVALID_ARGUMENT", "Use the item ID from show for --release-remove")
    if additions or edits or removals or reviewed or structured:
        request = {"add": additions, "edit": edits, "remove": removals, "reviewed": reviewed}
        if structured:
            request["items"] = structured
        return request
    return None


def update_release_checklist(block, request):
    if request is None:
        return None
    checklist = read_release_checklist(block)
    result = {"added": [], "edited": [], "removed": [], "skipped": []}
    def target(item_id):
        entry = next((x for x in checklist["items"] if x["id"] == item_id), None)
        if entry is None:
            raise CLIError("RELEASE_ITEM_NOT_FOUND", "事项已变化，请重新读取清单")
        if entry["updated_by"] == "user" or entry["done"]:
            raise CLIError("USER_MANAGED_RELEASE_ITEM", "保留用户维护或已完成的事项；有疑问请反馈用户")
        return entry
    def edit_entry(item_id, text, details=None, category=None):
        entry = target(item_id)
        text = text.strip()
        if any(x["id"] != item_id and x["text"].strip().lower() == text.lower() for x in checklist["items"]):
            raise CLIError("DUPLICATE_RELEASE_ITEM", "清单中已有相同事项")
        if any(x.strip().lower() == text.lower() for x in checklist["excluded_by_user"]):
            raise CLIError("USER_REMOVED_RELEASE_ITEM", "该事项已被用户删除或修正，不重复补回")
        entry["text"] = text
        if details is not None:
            entry["details"] = details
        if category is not None:
            entry["category"] = category
        result["edited"].append(item_id)
    for edit in request["edit"]:
        item_id, text = edit.split("=", 1)
        edit_entry(item_id, text)
    additions = [{"summary": x, "details": ""} for x in request["add"]]
    for item in request.get("items", []):
        if "id" in item:
            edit_entry(item["id"], item["summary"], item.get("details"), item.get("category"))
        else:
            additions.append(item)
    for item_id in request["remove"]:
        entry = target(item_id)
        checklist["items"].remove(entry)
        result["removed"].append(item_id)
    for item in additions:
        text = item["summary"].strip()
        if any(x["text"].strip().lower() == text.lower() for x in checklist["items"]):
            result["skipped"].append({"text": text, "reason": "already_present"})
            continue
        if any(x.strip().lower() == text.lower() for x in checklist["excluded_by_user"]):
            result["skipped"].append({"text": text, "reason": "user_removed_or_corrected"})
            continue
        if checklist["next_id"] >= sys.maxsize - 1:
            raise CLIError("INVALID_RELEASE_CHECKLIST", "事项编号已超出范围")
        item_id = "L" + str(checklist["next_id"]).zfill(3)
        checklist["next_id"] += 1
        checklist["items"].append({"id": item_id, "text": text, "details": item.get("details", ""),
                                   "category": item.get("category", infer_release_category(text)), "done": False, "updated_by": "ai"})
        result["added"].append(item_id)
    if request["reviewed"]:
        checklist["reviewed_scope"] = execution_scope(block)
    encoded = base64.b64encode(json.dumps(checklist, ensure_ascii=False, sort_keys=True).encode("utf-8")).decode("ascii")
    block[:] = [line for line in block if not line.startswith(RELEASE_PREFIX)]
    block.insert(1, RELEASE_PREFIX + encoded + META_SUFFIX)
    return result


def describe(block, item_id, cache, start):
    data = fields(block)
    kind = dboard_knowledge.task_kind(block)
    incident_closure = dboard_knowledge.closure(block)
    if "变更咒言" in data and not data["变更咒言"]:
        raise CLIError("INVALID_CHANGE_DATA", "Existing change spells are unreadable; no update made")
    header = block[0]
    project_match = re.search(r"【(.*?)】", header)
    # Match DBoard's displayed title, including dates interspersed with the title.
    title = header.split("】", 1)[1] if "】" in header else ""
    for state in ["待开始", "进行中", "已完成", "挂起"]:
        title = title.replace("#" + state, "")
    title = re.sub(r"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})", "", title)
    title = re.sub(r"\s*✅[0-9]{4}-[0-9]{2}-[0-9]{2}", "", title)
    title = re.sub(r"\s+", " ", title).strip()
    description = data.get("描述", "").strip()
    display_title = title or (description if description != "（待补充）" else "") or "（未命名）"
    status = next((s for s in ["进行中", "已完成", "挂起", "待开始"] if "#" + s in header), "待开始")
    prompt = data.get("提示词", "")
    if prompt.startswith("<!-- dboard-prompt:") and "\n" in prompt:
        prompt = prompt.split("\n", 1)[1]
    item = {
        "id": item_id, "title": display_title,
        "project": data.get("项目", project_match.group(1) if project_match else ""),
        "status": status,
        "branch": data.get("分支", ""), "description": data.get("描述", ""), "overview": data.get("概括", ""),
        "progress": data.get("进度", ""), "progress_records": progress_records(data.get("进度", "")), "prompt": prompt,
        "changes": demand_changes(data.get("变更咒言", "")),
        "chat_links": read_chat_links(block),
        "declared_repositories": list(dict.fromkeys(value.strip() for value in
            re.split(r"[\r\n;；]", data.get("项目", project_match.group(1) if project_match else "")) if value.strip())),
        "repositories": feedback_metadata(block)["repositories"],
        "environment_repositories": feedback_metadata(block).get("environment_repositories", []),
        "technical_plan": dboard_plan.read(block),
        "version": demand_version(block),
        "handoff": dboard_handoff.read(block),
        "context_review": feedback_metadata(block).get("context_review"),
        "handoff_notes": dboard_handoff.text(data.get("交接补充", ""), "user handoff notes"),
        "revision": revision(block),
        "worktrees": dboard_worktrees.summary(cache, item_id),
        "location": {"cache": str(cache), "heading_line": start + 1},
    }
    item["kind"] = kind
    item["incident_closure"] = incident_closure
    item["experience_review"] = feedback_metadata(block).get("experience_review")
    item["last_code_review"] = feedback_metadata(block).get("last_code_review")
    item["archived_code_reviews"] = [row for row in archived_reviews(cache)
                                     if row["id"] == item_id and row["source_revision"] == item["revision"]][-1:]
    item["release_checklist"] = read_release_checklist(block)
    item["release_checklist"]["needs_review"] = item["release_checklist"]["reviewed_scope"] != execution_scope(block)
    item["debug_page_not_needed"] = debug_page_not_needed(block)
    item["execution"] = read_execution(block)
    try:
        current_code = dboard_code.capture(item["repositories"])
        item["code_revision"] = dboard_code.revision(current_code)
        item["current_code"] = current_code
    except dboard_code.CodeError:
        current_code = None
        item["code_revision"] = None
        item["current_code"] = []
    execution = item["execution"]
    review = dboard_code.review(execution.get("code"), item["repositories"], current_code) if execution and execution["stage"] != "developing" else {"needs_review": False, "reason": None}
    if execution and execution["scope_hash"] != execution_scope(block):
        review = {"needs_review": True, "reason": "需求已变更 · 需重新核验"}
    item["technical_plan_state"] = dboard_plan.readiness(item["technical_plan"], item, execution_scope(block))
    item["execution_needs_review"] = review["needs_review"]
    item["execution_review_reason"] = review["reason"]
    image_text = [prompt] + [change["intent"] for change in item["changes"]]
    image_text.append(item["description"])
    image_text.extend(entry.get("evidence", "") for entry in item["release_checklist"]["items"])
    if item["version"]:
        image_text.append(item["version"]["background"])
    item["images"] = image_references("\n".join(image_text))
    return item


def assemble_prompt(stored):
    """Match the app's v2/v3 spell fields, preserving external edits and code whitespace."""
    sections = None
    first, separator, body = stored.partition("\n")
    for version in ("v3", "v2"):
        prefix, suffix = "<!-- dboard-prompt:" + version + ":", " -->"
        if first.startswith(prefix) and first.endswith(suffix):
            try:
                candidate = json.loads(base64.b64decode(first[len(prefix):-len(suffix)], validate=True).decode("utf-8"))
                if not isinstance(candidate, dict):
                    raise ValueError()
                for key in ("codeEntry", "materials", "intent"):
                    if not isinstance(candidate.get(key), str):
                        raise ValueError()
                for key in ("reason", "rules"):
                    if candidate.get(key) is None:
                        candidate[key] = ""
                    if not isinstance(candidate[key], str):
                        raise ValueError()
                if version == "v2":
                    expected = "\n\n".join("## " + label + "\n" + candidate[key]
                        for label, key in (("代码入口", "codeEntry"), ("需求资料", "materials"), ("改造意图", "intent"))
                        if candidate[key].strip())
                else:
                    intent = "\n".join("### " + label + "\n" + candidate[key].strip("\r\n")
                        for label, key in (("要做什么", "intent"), ("为什么改", "reason"), ("特殊规则", "rules"))
                        if candidate[key].strip())
                    expected = "\n".join("## " + label + "\n" + value
                        for label, value in (("代码入口", candidate["codeEntry"]), ("需求资料", candidate["materials"]), ("改造意图", intent))
                        if value.strip())
                if body == expected:
                    sections = candidate
                else:
                    stored = body
            except (ValueError, KeyError, TypeError, UnicodeError):
                pass
            break
    if sections is None:
        return "## 要做什么\n" + stored.strip("\r\n") if stored.strip() else ""
    parts = []
    code = sections["codeEntry"]
    if code.strip():
        instruction = ("本次为全新模块，请按新的业务模块设计与实现。" if code.strip() == "全新模块"
                       else "请根据以下服务、流程描述或代码路径，查找并阅读相关实现：")
        parts.append("## 代码入口\n" + instruction + "\n" + code.strip("\r\n"))
    if sections["materials"].strip():
        parts.append("## 可能有用的资料\n请查找并阅读以下资料，结合本次任务按需参考：\n" + sections["materials"].strip("\r\n"))
    supplement = "\n".join(sections[key] for key in ("reason", "rules") if sections[key].strip())
    for label, value in (("要做什么", sections["intent"]), ("补充说明", supplement)):
        if value.strip():
            parts.append("## " + label + "\n" + value.strip("\r\n"))
    return "\n".join(parts)


def full_task_context(block, item, cache, change_id=None, task="continue"):
    changes = item["changes"]
    change = None
    if change_id:
        if not re.fullmatch(r"C[0-9]{3,}", change_id):
            raise CLIError("INVALID_CHANGE_ID", "Use the exact change ID, for example C001")
        change = next((value for value in changes if value["id"] == change_id), None)
        if change is None:
            raise CLIError("CHANGE_NOT_FOUND", "The selected change no longer exists; reread the demand")
    if task in ("debug-page", "code-review", "technical-plan") and change_id:
        raise CLIError("INVALID_ARGUMENT", "Whole-demand tasks cover all changes; omit --change")
    raw = fields(block)
    text = ["## 接续任务",
            "请接手这张需求，先阅读原咒言、最新进度和追加变更，核对已有代码、仓库、分支和未提交改动；仅继续本次需求中明确、尚未完成的事项。",
            "追加变更与原咒言冲突时，以后续变更为准；结合最新进度和实际代码确认处理情况，不重做已完成的原需求或变更。",
            "先按下方规则核对本需求的上线前事项；完成必要的清单补充后，若没有可继续执行的待做事项，直接向用户反馈现状及待验收、阻塞等情况，不改代码、不自行扩展需求；现状未变且无新进展时，不向 D板追加重复记录。",
            "用户在复制指令后补充的联调报错属于本轮待排查事项；历史开发完成或等待人工联调不表示本轮无事可做。结合最新记录与实际证据定位、按需修复，保留已有实现和调试页；仅有空的填写区时不产生新任务。",
            "以下是本次读取时的 D板记录；未记录的现状先查代码和实际执行结果，不要猜测。"]
    if task == "debug-page" and item["debug_page_not_needed"]:
        text = ["## 调试核验任务（无需调试页）",
                "用户已在D板手动标记无需调试页，以最新选择为准；即使复制指令或旧咒言曾要求建页，本轮也不创建或更新调试页，不自行撤销设置，不删除已有页面。",
                "核对原咒言、追加变更和实际代码，按需补齐本需求实现、执行能独立完成的接口验证，记录已测及结果、未测及原因和待人工联调事项。",
                "最终内部／外部联调由用户协调进行。没有可执行事项时直接反馈，不因无需建页而跳过必要验证，也不重复开发或测试。"]
    elif task == "debug-page":
        text = ["## 调试页面任务",
                "本次明确授权核验该需求的开发完成情况，并在 audi 创建或完善可视化调试模块，挂到 /test-console。",
                "先读原咒言、全部追加变更、最新进度和实际代码；后续变更优先。开发完成后继续本次调试页任务，不因开发已完成就结束。",
                "发现后端仍有本需求的明确缺漏时，先反馈 developing 并补齐；没有新开发要求就不扩展后端。页面及AI可调部分已完成且需求、代码与条件未变时，直接反馈现状，不重复建设或测试。",
                "AI先试调能独立验证的部分，最终内部／外部联调由用户协调进行；回写已测及结果、未测及原因、待人工联调事项。剩余需要人工配合时交接并结束，不能将局部测试通过写成整体联调完成。",
                "下方是最新记录；请同时遵循返回的 debug_instructions 和反馈规则。"]
    if task == "code-review":
        text = ["## 独立代码审查任务",
                "本次是CR：审查这张需求的完整实现和相关调用链，而非继续开发。即使开发完成或需求已归档，也要执行本次独立审查。",
                "先读原咒言、全部追加变更和用户纠正，后续变更优先；历史摘要和测试结论只作线索，按当前实际代码独立核实。",
                "默认只读代码，不切换现有工作区分支、不修改代码或调试页、不更新上线清单、测试阶段及需求状态。发现问题先给出证据与建议，修复由用户另行决定。",
                "先确定各仓库本需求的真实开发分支、起始提交和审查终点，再审查整段改动、暂存/未提交/未跟踪内容及关联流程；不能只看最后一次commit或拿合并分支当开发分支。",
                "无法确认范围或无法读取代码时说明缺少什么，只给有限审查结论，不假定HEAD~1或当前分支就是需求范围。",
                "请优先阅读返回的review_instructions；只执行必要的针对性验证，不为CR默认跑全量测试。"]
    if task == "technical-plan":
        text = ["## 技术方案任务",
                "本次只准备或更新这张需求的技术方案，先读原咒言、全部追加变更、用户纠正、摘要和实际代码；有疑点再按需读相关历史。",
                "已有实现按实际代码整理，未实现的设计和待确认事项明确区分。保留用户对方案的编辑，不把旧CR、日志或过程记录直接拼入正文。",
                "核实每个工程的源开发分支和预发／发布分支用途，技术方案的projects只填写源开发分支；用途不明先反馈，不猜测。",
                "通过plan save保存本地技术方案及一句话记录，本轮不自动发布文档、不提交交付物、不改业务代码或开发阶段。"]
    if task == "continue" and raw.get("需求流", "").strip():
        text.append("本需求关联正式需求：方案确定或实现完成时，结束前核对technical_plan_state，缺失或失效则按实际代码准备技术方案；这是交付准备，不因等待验收而略过。正文按需通过plan read读取，遵循guide --topic technical-plan；不自动上传或提交。")
    if item["technical_plan"] and item["technical_plan"]["updated_by"] == "user":
        text.append("技术方案最近由用户编辑：继续实现或更新方案前通过plan read读取最新正文，保留其有效纠正。")
    version = item["version"]
    if version:
        text.extend(["## 本轮版本 " + str(version["number"]) + ".0",
                     ("本轮基于 " + version["parentID"] + "「" + version["parentTitle"] +
                      "」的已有实现；本轮咒言与追加变更是审查范围，上一版仅供背景参考。" if task == "code-review" else
                      "本轮在 " + version["parentID"] + "「" + version["parentTitle"] +
                      "」的已有实现上开发新版本。原版已归档；本轮咒言是新的改动要求，请避免重做原版。"),
                     "原需求编号：" + version["rootID"] + "；上一版本：" + version["parentID"],
                     "## 上一版本归档背景", version["background"]])
        for repo in version["repositories"]:
            text.append("上一版仓库（线索，需核对 Git）：" + repo["path"] + "；历史分支：" + repo["branch"])
        text.append("## 本轮改动要求")
    prompt = assemble_prompt(raw.get("提示词", ""))
    if prompt:
        text.append(prompt)
    text.extend(["## 当前现状", "读取时间：" + datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z"),
                 "需求：" + item["id"] + "「" + item["title"] + "」", "个人状态：" + item["status"]])
    checklist = item["release_checklist"]
    text.append("## 上线前事项")
    if checklist["items"]:
        categories = list(RELEASE_CATEGORIES)
        categories.extend(dict.fromkeys(entry["category"] for entry in checklist["items"] if entry["category"] not in RELEASE_CATEGORIES))
        for category in categories:
            title = release_category_title(category)
            entries = [entry for entry in checklist["items"] if entry["category"] == category]
            if not entries:
                continue
            text.append("### " + title)
            for entry in entries:
                owner = "用户维护，保留其调整" if entry["updated_by"] == "user" else "AI补充"
                text.append("- [" + ("x" if entry["done"] else " ") + "] " + entry["id"] + " " + entry["text"] + "（" + owner + "）")
                if entry.get("details"):
                    text.append("  明细：")
                    text.extend("  " + line for line in entry["details"].splitlines())
                if entry.get("evidence"):
                    text.append("  用户完成证据（保留原文和图片；是否完成以勾选状态为准）：")
                    text.extend("  " + line for line in entry["evidence"].splitlines())
    elif task not in ("code-review", "technical-plan"):
        text.append("清单为空：根据本需求已有实现、实际改动和资料核对上线需要的服务发布、SQL、建表、配置等事项，再用 report --release-add 补充；不能因开发已完成而跳过必要的清单核对。确实没有事项时允许保持为空，并用 --release-reviewed 记录核对结果，不凑通用条目。")
    if task in ("code-review", "technical-plan"):
        text.append("清单仅供核对发布、SQL及兼容性风险；本轮不编辑清单或代勾选。")
    elif checklist["needs_review"]:
        text.append("本次需求尚未核对清单，或需求已有新变更；需结合实际代码重新核对，保留现有勾选结果。")
    else:
        text.append("已有清单核对记录；实际代码或本轮需求改变时仍要按需更新。")
    if checklist["excluded_by_user"]:
        text.append("用户删除或修正过的旧事项（不要原样补回）：")
        text.extend("- " + value for value in checklist["excluded_by_user"])
    if task not in ("code-review", "technical-plan"):
        text.append("以本次读取的清单为准，保留用户维护和已完成的事项；只追加缺少的具体动作、更新自己维护的未完成事项。上线清单用于准备和交接，不授权自动发布服务或执行生产SQL，未完成勾选也不等于待开发需求。")
    text.append("## 代码与执行现状")
    if item["declared_repositories"]:
        text.append("代码仓库 / 项目入口（用户填写，请查找并阅读相关实现）：")
        text.extend("- " + value for value in item["declared_repositories"])
    description = item["description"].strip()
    if description and description not in ("（待补充）", item["title"]):
        text.append("描述：" + description)
    branch = item["branch"].strip()
    text.append("已记录分支：" + branch if branch and branch != "待定" else "分支：尚未记录，接手后读取 Git 确认")
    for repository in item["repositories"]:
        text.append("开发仓库：" + repository["path"] + "；开发分支：" + repository["branch"])
    for repository in item["environment_repositories"]:
        text.append("预发／发布仓库（不作为开发交付分支）：" + repository["path"] + "；分支：" + repository["branch"])
    plan_state = item["technical_plan_state"]
    text.extend(["## 技术方案", plan_state["reason"] or "已有与当前需求、代码和开发分支匹配的技术方案；正文按需读取。",
                 "读取方案：" + shlex.join([str(Path.home() / ".local/bin/dboard-ai"), "--cache", str(cache), "plan", "read", item["id"]])])
    for symbol, label in (("📅", "开始日期"), ("🎯", "计划截止")):
        found = re.search(symbol + r"([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})(?![0-9.-])", block[0])
        if found:
            text.append(label + "：" + found.group(1))
    text.append("开发 / 调试：" + (item["execution_review_reason"] if item["execution_needs_review"]
                 else (item["execution"]["stage"] if item["execution"] else "尚无结构化核验记录，不能据此认定未开发")))
    if item["execution_needs_review"]:
        text.append("旧结论仅供参考；本轮CR独立核实并反馈风险，不回写测试阶段。" if task == "code-review" else
                    "旧结论仅供参考。代码变更或测试失败时主动回退 developing，或核验受影响部分后更新可靠阶段；不凭旧通过记录结束本轮。")
    if item["code_revision"]:
        text.append("当前代码版本：" + item["code_revision"] +
                    ("；反馈前重新 show，必须与实际审查版本一致，再传 --expect-code。" if task == "code-review" else
                     "；核验后重新 show，正向阶段 report 必须传 --expect-code。"))
    if item["debug_page_not_needed"]:
        text.append("用户调试页设置：无需调试页，不创建或更新页面，也不自行撤销；仅免除建页，接口验证与人工联调仍按需进行。已有页面记录仅供参考。")
    if item["execution"]:
        if item["execution"]["stage"] == "testing-passed":
            text.append("该阶段仅表示AI可独立试调的部分通过；最终内部／外部联调与验收仍由用户进行，详情以已测、未测和待人工联调记录为准。")
        if item["execution"].get("debug_page"):
            text.append("已记录调试模块：" + item["execution"]["debug_page"])
        if item["execution"].get("debug_url"):
            text.append("已记录访问地址（需确认仍有效）：" + item["execution"]["debug_url"])
    if raw.get("需求流", "").strip():
        text.append("关联需求：" + raw["需求流"])
    sources = chat_sources(item["chat_links"])
    if sources:
        text.extend(["## 关联群聊",
                     "先根据咒言、方案和现有代码核对信息。用户明确要求参考聊天，或信息仍不明确时，优先看主要群聊的近期记录，再按需查看次要群聊。",
                     "下面的只读命令先取最近 50 条。按本需求���关键词定位；需要更多上下文时，用返回记录的边界 createTime 作为 --time 向前翻页，并阅读 quotedMessage 引用上下文和相关话题回复。",
                     "只把与本需求有关、已确认的新结论简短记回 D板进度，写明群名和消息时间；不确定的标注待确认。与咒言或追加变更冲突时先反馈用户，不据零散聊天自行扩大范围。"])
        for source in sources:
            text.extend([("主要群聊：" if source["role"] == "primary" else "次要群聊：") + source["name"] + "；群 ID：" + source["id"],
                         "读取近期聊天：" + source["read_command"]])
    text.append("进度记录（概括及本地明细，按保存顺序，后面的记录更新）：")
    text.append(item["progress"] if item["progress"].strip()
                else "尚未记录进度，请检查代码确认现状，不能据此认定尚未开发。")
    if raw.get("归档历史", "").strip():
        text.extend(["## 历史归档备注（历史完成情况，非本轮成果）", raw["归档历史"]])
    references = [value for value in changes if value["id"] != change_id]
    if references:
        text.append("## 其他追加变更（参考）" if change else "## 已记录的追加变更")
        for value in references:
            text.extend(["### " + value["id"], value["intent"]])
        text.append("各条变更的处理情况以最新进度和实际代码为准，保留此前未完成的测试与验收。")
    if change:
        text.extend(["## 本次追加变更 " + change_id,
                     "本轮在已有实现和当前分支上核对以下变更是否已处理，仅继续尚未完成的部分。原咒言用于理解背景；相关测试与验收的状态以最新进度和实际结果为准。",
                     change["intent"], "每轮写回进度时带上 [" + change_id + "]，明确本次变更的已做、待做和验证结果。"])
    images = image_references("\n".join(text))
    if images:
        text.extend(["## 需求图片",
                     "原咒言、追加变更、上线完成证据和历史背景中的图片是本机附件。请通过本机文件或图片工具逐张打开 images 中的图片，结合相邻文字理解要求；路径本身不包含图片内容。",
                     "工具若运行在远端，请通过连接用户本机的文件工具读取。图片缺失或工具无法读图时，明确反馈，不能猜测图中内容。"])
        for image in images:
            text.append("- " + image["label"] + "：" + image["path"] + ("" if image["exists"] else "（图片文件缺失）"))
    cli = str(Path.home() / ".local/bin/dboard-ai")
    text.extend(["## D板任务与执行反馈", "D板是用户的个人工作看板。本次仅处理 " + item["id"] + "。",
                 "本机 CLI：" + cli, "本机需求数据：" + str(cache),
                 "读取当前版本：" + item["revision"],
                 "请遵循返回的 feedback_instructions：每条修改记录先用 --summary 写一句话概括，再按需用 --details 写本地明细；反馈前 show 取得最新版本。"])
    if version:
        text.append("仅将本轮实际改动和验证结果写回 " + item["id"] + "，不要把历史成果记作本轮完成，也不要修改已归档的 " + version["parentID"] + "。")
    if task == "code-review":
        text.append("CR反馈使用 report --task code-review，只记录审查结论与交接，不修改开发阶段或清单。")
        if item["archived_code_reviews"]:
            text.extend(["## 该归档最近的CR结论（独立核实当前代码）",
                         item["archived_code_reviews"][-1]["summary"],
                         "明细通过 inspect --section code 按需读取。"])
        if cache.name == "dboard-archive-cache.md":
            text.append("该需求已归档。CR结果单独保存在本机归档审查记录，不改归档快照、状态及旧版本关联；不上传归档快照。")
    skill = resource_path("skills/dboard-feedback/SKILL.md")
    debug = None
    if task == "debug-page":
        if item["debug_page_not_needed"]:
            debug = ("用户已标记无需调试页，这是当前页面范围设置，只有用户撤销才恢复。"
                     "不创建或更新页面、不删除已有页面，也不回写debug-page-ready/testing-passed。"
                     "核验后端实现并按需执行可独立完成的接口验证，使用development-complete与普通summary/details记录结果；"
                     "写清已测、未测和待人工联调，最终内部／外部联调与验收由用户进行。")
        else:
            debug = resource_path("skills/dboard-feedback/references/debug-page.md").read_text(encoding="utf-8")
    review = resource_path("skills/dboard-feedback/references/code-review.md").read_text(encoding="utf-8") if task == "code-review" else None
    plan_instructions = resource_path("skills/dboard-feedback/references/technical-plan.md").read_text(encoding="utf-8") if task == "technical-plan" else None
    return {"success": True, "task": task, "debug_instructions": debug, "review_instructions": review, "plan_instructions": plan_instructions,
            "item": {key: item[key] for key in ("id", "title", "status", "revision", "location", "chat_links", "execution", "execution_needs_review", "execution_review_reason", "code_revision", "current_code", "debug_page_not_needed", "release_checklist", "environment_repositories", "technical_plan_state")},
            "chat_sources": sources,
            "change_id": change_id, "context": "\n".join(text), "images": images,
            "cli": cli, "feedback_skill_path": str(skill),
            "reference_commands": {topic: shlex.join([cli, "guide", "--topic", topic])
                                   for topic in ("handoff", "feedback", "debug-page", "technical-plan") + (("code-review",) if task == "code-review" else ()) + (("incident",) if item["kind"] == "线上排查" else ())},
            "feedback_instructions": skill.read_text(encoding="utf-8")}



def task_context(block, item, cache, change_id=None, task="continue", full=False, lines=None):
    result = full_task_context(block, item, cache, change_id, task)
    result = dboard_handoff.context(result, item, cache, execution_scope(block), full)
    result["item"]["worktrees"] = item["worktrees"]
    worktree_cli = [str(Path.home() / ".local/bin/dboard-ai"), "--cache", str(cache), "worktree"]
    result["worktree_commands"] = {
        "list": shlex.join(worktree_cli + ["list", item["id"]]),
        "register": shlex.join(worktree_cli + ["register", item["id"]]) + " --path '<工作树根目录>' --created",
        "create": shlex.join(worktree_cli + ["create", item["id"]]) + " --repo '<原仓库>' --path '<新工作树目录>' --new-branch '<新分支>'",
    }
    result["reference_commands"]["worktrees"] = shlex.join([worktree_cli[0], "guide", "--topic", "worktrees"])
    result["context"] += (
        "\n工作树台账：" + json.dumps(item["worktrees"], ensure_ascii=False) +
        "。新旧需求新建工作树统一使用worktree create，同时创建并立即登记；复用只登记使用。" +
        "已清理的旧目录不能作为开发入口，从主仓库保留的准确分支用create --branch恢复。" +
        "不要自动清理。具体操作：" +
        result["reference_commands"]["worktrees"] + "；读取本需求台账：" + result["worktree_commands"]["list"])
    if item["kind"] == "线上排查" and task not in ("code-review", "technical-plan"):
        return dboard_knowledge.context(result, item, lines if lines is not None else read_content(cache)[0], cache)
    return result


def set_field(block, key, value):
    tag = "- **" + key + "**"
    matches = [i for i, line in enumerate(block) if line.startswith(tag)]
    if len(matches) > 1:
        raise CLIError("AMBIGUOUS_FIELD", "Duplicate field: " + key)
    line = tag + "：" + value
    if matches:
        i = matches[0]
        end = i + 1
        while end < len(block) and block[end].startswith("    "):
            end += 1
        block[i:end] = [line]
    else:
        block.insert(1, line)


def append_progress(block, text, details=None):
    day = datetime.date.today()
    entry = ["    - {}.{}: {}".format(day.month, day.day, text)]
    if details and details.strip():
        entry += ["        明细："] + ["        " + line for line in details.strip("\r\n").split("\n")]
    matches = [i for i, value in enumerate(block) if value.startswith("- **进度**")]
    if len(matches) > 1:
        raise CLIError("AMBIGUOUS_FIELD", "Duplicate progress blocks")
    if matches:
        end = matches[0] + 1
        while end < len(block) and (block[end].startswith((" ", "\t")) or not block[end].strip()):
            end += 1
        block[end:end] = entry
    else:
        block.extend(["- **进度**："] + entry)


def git_project(path):
    """Repository identity stays the same across its main checkout and worktrees."""
    try:
        common = subprocess.run(["git", "-C", str(path), "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=10)
        origin = subprocess.run(["git", "-C", str(path), "remote", "get-url", "origin"],
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise CLIError("GIT_FAILED", "Cannot read repository identity")
    if common.returncode != 0:
        raise CLIError("GIT_FAILED", "Cannot read repository identity")
    common_path = Path(scalar(common.stdout.strip(), "Git common directory")).resolve()
    name = common_path.parent.name if common_path.name == ".git" else common_path.stem
    if origin.returncode == 0:
        tail = origin.stdout.strip().rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]
        candidate = tail[:-4] if tail.endswith(".git") else tail
        if re.fullmatch(r"[A-Za-z0-9_.-]+", candidate):
            name = candidate
    return {"git_common_dir": str(common_path), "name": scalar(name, "project name")}


def git_repository(path, expected_branch, role=None):
    repo = Path(scalar(path, "repository")).expanduser().resolve()
    try:
        root = subprocess.run(["git", "-C", str(repo), "rev-parse", "--show-toplevel"],
                              capture_output=True, text=True, timeout=10)
        branch = subprocess.run(["git", "-C", str(repo), "symbolic-ref", "--quiet", "--short", "HEAD"],
                                capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise CLIError("GIT_FAILED", "Cannot read the repository")
    if root.returncode != 0 or branch.returncode != 0:
        raise CLIError("NO_ACTIVE_BRANCH", "Use a Git working tree with an active branch")
    value = scalar(branch.stdout.strip(), "branch")
    if expected_branch and value != expected_branch:
        raise CLIError("BRANCH_MISMATCH", "The supplied branch is not the repository's current branch")
    if role in (None, "development") and dboard_plan.integration_branch(value):
        raise CLIError("INTEGRATION_BRANCH", "请保留源开发分支；预发／发布工作树用--repo-role integration或release单独记录")
    if role is None and re.search(r"(?:^|[/_-])(?:pre|staging|release)(?:$|[_/-])", value.lower()):
        raise CLIError("BRANCH_ROLE_REQUIRED", "请显式填写--repo-role development|integration|release，确认这是开发还是预发／发布分支")
    root_path = scalar(str(Path(root.stdout.strip()).resolve()), "repository")
    return dict(path=root_path, branch=value, **git_project(root_path))


def record_repository(meta, repo, replace_path=None):
    records = meta["repositories"]
    replacement = None
    if replace_path is not None:
        replacement = next((index for index, old in enumerate(records)
                            if str(Path(old["path"]).expanduser().resolve()) == replace_path), None)
        if replacement is None:
            raise CLIError("REPOSITORY_NOT_FOUND", "--replace-repo must name a currently recorded working directory")
    for old in records:
        # Read identity only, never replace a demand's branch with whichever branch is now checked out elsewhere.
        if not old.get("git_common_dir"):
            try:
                old.update(git_project(old["path"]))
            except CLIError:
                pass
    if replacement is not None:
        replaced = records[replacement]
        if replaced.get("git_common_dir") and replaced["git_common_dir"] != repo["git_common_dir"]:
            raise CLIError("REPOSITORY_MISMATCH", "Replacement belongs to a different Git repository")
        if not replaced.get("git_common_dir") and Path(replaced["path"]).exists():
            raise CLIError("GIT_FAILED", "Cannot identify the old repository; no replacement made")
    matches = [index for index, old in enumerate(records)
               if old.get("git_common_dir") == repo["git_common_dir"] or old["path"] == repo["path"]]
    if replacement is not None and replacement not in matches:
        matches.append(replacement)
    matches.sort()
    changed = len(matches) != 1 or any(
        records[index]["path"] != repo["path"] or records[index]["branch"] != repo["branch"] for index in matches)
    position = matches[0] if matches else len(records)
    kept = [old for index, old in enumerate(records) if index not in matches]
    kept.insert(position, repo)
    meta["repositories"] = kept
    return changed



def record_environment_repository(meta, repo, role):
    # An explicitly classified environment branch never overwrites its source development branch.
    records = meta.get("environment_repositories", [])
    value = dict(repo, role=role)
    kept = [old for old in records if not (old.get("git_common_dir") == repo["git_common_dir"]
                                           and old["branch"] == repo["branch"])]
    changed = value not in records
    kept.append(value)
    meta["environment_repositories"] = kept
    before = meta["repositories"]
    meta["repositories"] = [old for old in before if not (old["path"] == repo["path"]
                               or old.get("git_common_dir") == repo["git_common_dir"] and old["branch"] == repo["branch"])]
    return changed or before != meta["repositories"]

def branch_declaration(repositories):
    if len(repositories) == 1:
        return repositories[0]["branch"]
    names = [row.get("name") or Path(row["path"]).name for row in repositories]
    return "；".join((name if names.count(name) == 1 else row["path"]) + ":" + row["branch"]
                    for name, row in zip(names, repositories))

def atomic_write(cache, content):
    mode = stat.S_IMODE(cache.stat().st_mode) if cache.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=".dboard-ai-", dir=str(cache.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as output:
            os.fchmod(output.fileno(), mode)
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, cache)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_content(cache):
    with cache.open(encoding="utf-8", newline="") as source:
        content = source.read()
    newline = "\r\n" if "\r\n" in content else "\n"
    return content.split(newline), newline


def archived_reviews(cache):
    if cache.name != "dboard-archive-cache.md":
        return []
    path = cache.with_name("dboard-archive-code-reviews.json")
    if not path.exists():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("version") != 1 or not isinstance(data.get("records"), list):
            raise ValueError()
        for row in data["records"]:
            if not isinstance(row, dict) or not all(isinstance(row.get(k), str) for k in
                ("id", "source_revision", "summary", "details", "event_id", "request_hash")):
                raise ValueError()
        return data["records"]
    except (ValueError, TypeError, AttributeError):
        raise CLIError("INVALID_REVIEW_DATA", "归档CR记录无法读取，已保留原文件")


def report_archived_review(cache, args, current, request_hash, event_id, handoff_input, scope_hash):
    rows = archived_reviews(cache)
    previous = next((row for row in rows if row["id"] == args.id and row["event_id"] == event_id), None)
    if previous:
        if previous["request_hash"] != request_hash:
            raise CLIError("EVENT_CONFLICT", "该CR事件已用于不同结论")
        return {"event_id": event_id, "duplicate": True, "item": current}
    if current["revision"] != args.expect_revision:
        raise CLIError("REVISION_CONFLICT", "归档快照已变��，请重新读取审查范围")
    if current["code_revision"] is not None:
        if args.expect_code != current["code_revision"]:
            raise CLIError("CODE_REVISION_CONFLICT", "代码与审查版本不一致，请先核对变化")
    elif args.review_result != "limited" or args.expect_code is not None:
        raise CLIError("CODE_REVISION_CONFLICT", "无法核实全部代码版本，只能记录limited")
    handoff = dboard_handoff.update(current["handoff"], current["progress_records"], current["progress_records"],
                                   scope_hash, current["code_revision"], args.compression_decision,
                                   args.compression_reason, handoff_input)
    try:
        latest_code = dboard_code.revision(dboard_code.capture(current["repositories"]))
    except dboard_code.CodeError:
        latest_code = None
    if latest_code != current["code_revision"]:
        raise CLIError("CODE_REVISION_CONFLICT", "反馈期间代码发生变化，请重新核对")
    row = {"id": args.id, "source_revision": current["revision"], "summary": args.progress.strip(),
           "details": args.details, "event_id": event_id, "request_hash": request_hash,
           "result": args.review_result, "scope_hash": scope_hash, "code_revision": args.expect_code, "code": current["current_code"],
           "checked_at": datetime.datetime.now().astimezone().isoformat(timespec="microseconds"), "handoff": handoff}
    rows.append(row)
    # Completed snapshots are version identities; CR notes must never change their content/hash.
    atomic_write(cache.with_name("dboard-archive-code-reviews.json"),
                 json.dumps({"version": 1, "records": rows}, ensure_ascii=False, sort_keys=True))
    current["archived_code_reviews"] = [row]
    return {"event_id": event_id, "duplicate": False, "item": current}


def report(cache, args):
    is_review = getattr(args, "task", "continue") == "code-review"
    review_result = getattr(args, "review_result", None)
    release = release_request(args)
    if is_review:
        forbidden = ("repo", "repo_role", "branch", "replace_repo", "overview", "stage", "debug_page", "debug_url",
                     "experience_decision", "experience_reason", "experience_file")
        if release is not None or any(getattr(args, key, None) is not None for key in forbidden):
            raise CLIError("REVIEW_READ_ONLY", "CR只能记录审查结论和交接摘要，不能修改仓库、清单、阶段或经验")
        if review_result not in ("clear", "findings", "limited") or not args.progress or not (args.details or "").strip():
            raise CLIError("INVALID_ARGUMENT", "CR须提供--review-result、--summary和--details，明细写审查范围与问题证据")
    elif review_result is not None:
        raise CLIError("INVALID_ARGUMENT", "--review-result requires --task code-review")
    replace_path = getattr(args, "replace_repo", None)
    if replace_path is not None:
        if not args.repo:
            raise CLIError("INVALID_ARGUMENT", "--replace-repo requires --repo")
        replace_path = str(Path(scalar(replace_path, "old repository")).expanduser().resolve())
    stage = getattr(args, "stage", None)
    page = getattr(args, "debug_page", None)
    url = getattr(args, "debug_url", None)
    expect_code = getattr(args, "expect_code", None)
    if expect_code is not None:
        if (not is_review and stage in (None, "developing")) or not re.fullmatch(r"[0-9a-f]{64}", expect_code):
            raise CLIError("INVALID_ARGUMENT", "--expect-code requires a positive milestone and the code_revision from show")
    if stage is not None:
        if stage not in STAGES or args.progress is None:
            raise CLIError("INVALID_ARGUMENT", "--stage requires a valid milestone and --summary")
        if stage != "developing" and not (args.details or "").strip():
            raise CLIError("INVALID_ARGUMENT", "Verified milestones require concise actual verification evidence in --details")
    if page is not None or url is not None:
        if stage not in ("debug-page-ready", "testing-passed"):
            raise CLIError("INVALID_ARGUMENT", "Page details require --stage debug-page-ready or testing-passed")
        if page is not None:
            validate_debug_page(page)
    handoff_input = None
    if getattr(args, "handoff_file", None):
        with Path(args.handoff_file).expanduser().open(encoding="utf-8") as source:
            handoff_input = json.load(source)
    decision = getattr(args, "compression_decision", None)
    decision_reason = getattr(args, "compression_reason", None)
    if decision not in ("compact", "skip") or not decision_reason or len(decision_reason) > 500:
        raise CLIError("CONTEXT_REVIEW_REQUIRED", "每轮先读取context检查压缩判断，再传--compression-decision compact|skip和--compression-reason")
    overview = getattr(args, "overview", None)
    if overview is not None:
        scalar(overview.strip(), "overview")
        if len(overview.strip()) > 120:
            raise CLIError("INVALID_ARGUMENT", "Overview must be a concise single line within 120 characters")
    scalar(args.expect_revision, "revision")
    if not re.fullmatch(r"[0-9a-f]{64}", args.expect_revision):
        raise CLIError("INVALID_REVISION", "Use revision from show")
    scalar(args.expect_title, "title")
    if args.progress is not None:
        scalar(args.progress.strip(), "progress")
        if len(args.progress.strip()) > 120:
            raise CLIError("INVALID_ARGUMENT", "Summary must be one sentence within 120 characters; put detail in --details")
    if args.details is not None:
        if args.progress is None:
            raise CLIError("INVALID_ARGUMENT", "--details requires --summary (or --progress)")
        if len(args.details) > 12000 or any(ord(c) < 32 and c not in "\n\r\t" for c in args.details):
            raise CLIError("INVALID_ARGUMENT", "Details must be plain text within 12000 characters")
    if getattr(args, "repo_role", None) and not args.repo:
        raise CLIError("INVALID_ARGUMENT", "--repo-role requires --repo")
    if args.branch and not args.repo:
        raise CLIError("INVALID_ARGUMENT", "--branch requires --repo")
    if args.progress is not None and handoff_input is None and not is_review:
        raise CLIError("HANDOFF_REQUIRED", "有新进展时，须同时用--handoff-file更新四段交接摘要；先读取context/history")
    if decision == "compact" and handoff_input is None:
        raise CLIError("HANDOFF_REQUIRED", "整体整理须同时提供--handoff-file；原始记录完整保留")
    event_id = args.event_id or str(uuid.uuid4())
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,120}", event_id):
        raise CLIError("INVALID_EVENT_ID", "Use a stable short event ID with letters, digits, hyphens or underscores")
    # Hash the request before querying Git: an exact retry must not capture a newly changed branch.
    request = {"repo": str(Path(args.repo).expanduser().resolve()) if args.repo else None,
               "branch": args.branch, "progress": args.progress}
    if is_review:
        request.update(task="code-review", review_result=review_result, expect_code=expect_code)
    if getattr(args, "repo_role", None):
        request["repo_role"] = args.repo_role
    if replace_path is not None:
        request["replace_repo"] = replace_path
    if stage is not None:
        request.update(stage=stage, debug_page=page, debug_url=url, expect_code=getattr(args, "expect_code", None))
    if overview is not None:
        request["overview"] = overview.strip()
    if args.details is not None:
        request["details"] = args.details
    if release is not None:
        request["release_checklist"] = release
    request.update(compression_decision=decision, compression_reason=decision_reason, handoff=handoff_input)
    experience_input = None
    if getattr(args, "experience_file", None):
        try:
            experience_input = json.loads(Path(args.experience_file).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise CLIError("INVALID_KNOWLEDGE_DATA", "Experience file must contain valid UTF-8 JSON")
    experience_decision = getattr(args, "experience_decision", None)
    experience_reason = getattr(args, "experience_reason", None)
    if experience_input is not None or experience_decision is not None or experience_reason is not None:
        request.update(experience=experience_input, experience_decision=experience_decision, experience_reason=experience_reason)
    request_hash = hashlib.sha256(json.dumps(request, sort_keys=True, ensure_ascii=False).encode("utf-8")).hexdigest()
    if not cache.is_file():
        raise CLIError("CACHE_NOT_FOUND", "Demand cache does not exist")
    with open(str(cache) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        lines, newline = read_content(cache)
        start, end = locate(lines, args.id)
        block = lines[start:end]
        current = describe(block, args.id, cache, start)
        if current["title"] != args.expect_title:
            raise CLIError("TITLE_MISMATCH", "Demand title changed; read and confirm the target before updating")
        if is_review and cache.name == "dboard-archive-cache.md":
            return report_archived_review(cache, args, current, request_hash, event_id, handoff_input, execution_scope(block))
        meta = feedback_metadata(block)
        previous = meta["events"].get(event_id)
        if previous:
            if previous != request_hash:
                raise CLIError("EVENT_CONFLICT", "Event ID was already used for different feedback")
            return {"event_id": event_id, "duplicate": True, "item": current}
        if current["revision"] != args.expect_revision:
            raise CLIError("REVISION_CONFLICT", "Demand changed since show; reread it before reporting")
        if current["status"] == "已完成" and not is_review:
            raise CLIError("DEMAND_COMPLETED", "This demand is already completed; no feedback was written")
        if is_review:
            if current["code_revision"] is not None:
                if expect_code != current["code_revision"]:
                    raise CLIError("CODE_REVISION_CONFLICT", "代码与审查版本不一致，请重读并核对变化后再反馈CR结论")
            elif review_result != "limited" or expect_code is not None:
                raise CLIError("CODE_REVISION_CONFLICT", "无法核实全部代码版本，只能记录limited及未覆盖原因")
        experience_review = None if is_review else dboard_knowledge.review(current, experience_decision, experience_reason, experience_input)
        experience_result = None
        catalog = None
        if experience_review and experience_decision != "skip":
            catalog = dboard_knowledge.read(lines)
        block = [line for line in block if not line.startswith(META_PREFIX)]
        if overview is not None:
            set_field(block, "概括", overview.strip())
        if args.repo:
            role = getattr(args, "repo_role", None) or "development"
            repo = git_repository(args.repo, args.branch, getattr(args, "repo_role", None))
            previous_development = list(meta["repositories"])
            repo_changed = (record_repository(meta, repo, replace_path) if role == "development"
                            else record_environment_repository(meta, repo, role))
            if role == "development" or previous_development != meta["repositories"]:
                set_field(block, "分支", branch_declaration(meta["repositories"]))
            if repo_changed:
                append_progress(block, "已更新开发仓库与分支。" if role == "development" else "已更新预发／发布分支。",
                                "用途：{}；仓库：{}；分支：{}".format(role, repo["path"], repo["branch"]))
        verification = dict(current, repositories=meta["repositories"])
        update_execution(block, verification, args)
        release_result = update_release_checklist(block, release)
        if args.progress is not None:
            append_progress(block, args.progress.strip(), args.details)
        records_after = progress_records(fields(block).get("进度", ""))
        try:
            handoff_code = dboard_code.revision(dboard_code.capture(meta["repositories"]))
        except dboard_code.CodeError:
            handoff_code = None
        handoff = dboard_handoff.update(current["handoff"], current["progress_records"], records_after,
                                       execution_scope(block), handoff_code,
                                       decision, decision_reason, handoff_input)
        if is_review and current["code_revision"] is not None and handoff_code != expect_code:
            raise CLIError("CODE_REVISION_CONFLICT", "反馈期间代码发生变化，请核对增量后重新记录CR")
        if handoff is not None:
            dboard_handoff.store(block, handoff)
        meta["context_review"] = {"decision": decision, "reason": decision_reason.strip(),
                                  "checked_at": datetime.datetime.now().astimezone().isoformat(timespec="microseconds")}
        if is_review:
            # Keep this separate from development/test milestones; a CR is never acceptance.
            meta["last_code_review"] = {"result": review_result, "scope_hash": execution_scope(block),
                                        "code": current["current_code"], "code_revision": expect_code,
                                        "checked_at": meta["context_review"]["checked_at"]}
        if experience_review:
            if catalog is not None:
                experience_result = dboard_knowledge.apply(catalog, experience_input, experience_decision,
                                                          args.id, len(records_after), execution_scope(block))
            meta["experience_review"] = dict(experience_review,
                checked_at=datetime.datetime.now().astimezone().isoformat(timespec="microseconds"),
                record_count=len(records_after), scope_hash=execution_scope(block))
        meta["events"][event_id] = request_hash
        encoded = base64.b64encode(json.dumps(meta, ensure_ascii=False, sort_keys=True).encode("utf-8")).decode("ascii")
        block.append(META_PREFIX + encoded + META_SUFFIX)
        lines[start:end] = block
        if catalog is not None:
            dboard_knowledge.write(lines, catalog)
        actual_start, _ = locate(lines, args.id)
        if args.repo:
            # The cache EX lock is already held; do not re-acquire it inside inventory registration.
            dboard_worktrees.register(cache, args.id, repo["path"], known_task=current)
        atomic_write(cache, newline.join(lines))
        return {"event_id": event_id, "duplicate": False, "release_result": release_result,
                "experience_result": experience_result, "item": describe(block, args.id, cache, actual_start)}



def plan_command(cache, args):
    if not cache.is_file():
        raise CLIError("CACHE_NOT_FOUND", "Demand cache does not exist")
    with open(str(cache) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if args.plan_command == "save" else fcntl.LOCK_SH)
        lines, newline = read_content(cache)
        start, end = locate(lines, args.id)
        block = lines[start:end]
        item = describe(block, args.id, cache, start)
        old = item["technical_plan"]
        if args.plan_command == "read":
            return {"success": True, "id": args.id, "title": item["title"], "revision": item["revision"],
                    "code_revision": item["code_revision"], "plan": dboard_plan.view(old, item["technical_plan_state"], full=True),
                    "development_repositories": item["repositories"], "environment_repositories": item["environment_repositories"]}
        if cache.name == "dboard-archive-cache.md" or item["status"] == "已完成":
            raise CLIError("DEMAND_COMPLETED", "已完成需求的方案仅供查阅；请先恢复或开启新版本")
        if args.expect_title != item["title"] or args.expect_revision != item["revision"]:
            raise CLIError("REVISION_CONFLICT", "需求已变化，请重新读取再保存方案")
        if args.expect_plan != dboard_plan.signature(old):
            raise CLIError("PLAN_REVISION_CONFLICT", "方案已被修改，请读取最新正文并保留用户编辑")
        if args.expect_code != item["code_revision"]:
            raise CLIError("CODE_REVISION_CONFLICT", "代码已变化，请核对方案后重新保存")
        scalar(args.summary.strip(), "summary")
        if len(args.summary.strip()) > 120:
            raise CLIError("INVALID_ARGUMENT", "概括须在120字内，正文保存到技术方案")
        source = json.loads(Path(args.file).expanduser().read_text(encoding="utf-8"))
        if not isinstance(source, dict):
            raise CLIError("INVALID_TECHNICAL_PLAN", "方案文件须为包含markdown和projects的JSON对象")
        value = {"title": source.get("title") or item["title"] + " · 技术方案", "markdown": source.get("markdown"),
                 "projects": dboard_plan.projects(source.get("projects")),
                 "scope_hash": execution_scope(block), "code_revision": item["code_revision"],
                 "updated_at": datetime.datetime.now().astimezone().isoformat(timespec="microseconds"), "updated_by": "ai"}
        dboard_plan.validate(value)
        state = dboard_plan.readiness(value, item, execution_scope(block))
        if state["needs_review"] and item["code_revision"] is not None:
            raise CLIError("DEVELOPMENT_BRANCH_MISMATCH", state["reason"])
        # Exact content retries are harmless; a changed code/scope binding is a meaningful update.
        same = old and all(old.get(k) == value.get(k) for k in ("title", "markdown", "projects", "scope_hash", "code_revision"))
        if same:
            return {"success": True, "local_saved": True, "unchanged": True, "plan": dboard_plan.view(old, item["technical_plan_state"])}
        if item["code_revision"] is not None:
            try:
                final_code = dboard_code.revision(dboard_code.capture(item["repositories"]))
            except dboard_code.CodeError:
                raise CLIError("CODE_REVISION_CONFLICT", "保存过程中代码无法核实，方案未保存")
            if final_code != args.expect_code:
                raise CLIError("CODE_REVISION_CONFLICT", "保存过程中代码变化，方案未保存")
        dboard_plan.store(block, value)
        append_progress(block, args.summary.strip(), "技术方案保存在本地，提交开发交付前请核对。")
        lines[start:end] = block
        atomic_write(cache, "\n".join(lines) + ("\n" if newline else ""))
        return {"success": True, "local_saved": True, "plan": dboard_plan.view(value, state),
                "sync": {"status": "skipped", "success": None}}

INCIDENT_OUTCOMES = {
    "resolved": "已处理",
    "handed-off": "已定位并交接",
    "stopped": "结束本次排查，原因未定",
}


def close_incident(cache, args):
    """User-requested lightweight closure; never changes ordinary development tasks."""
    summary = scalar(args.summary.strip(), "summary")
    if len(summary) > 120:
        raise CLIError("INVALID_ARGUMENT", "完结概括最多120字，补充内容放在--details")
    details = args.details
    if details is not None and (len(details) > 12000 or any(
            (ord(c) < 32 and c not in "\n\r\t") or ord(c) == 127 for c in details)):
        raise CLIError("INVALID_ARGUMENT", "完结明细须为12000字以内的纯文本")
    scalar(args.expect_title, "title")
    if not re.fullmatch(r"[0-9a-f]{64}", args.expect_revision):
        raise CLIError("INVALID_REVISION", "先读取show返回的最新revision")
    if not cache.is_file():
        raise CLIError("CACHE_NOT_FOUND", "Demand cache does not exist")
    if cache.name == "dboard-archive-cache.md":
        raise CLIError("ARCHIVE_READ_ONLY", "归档快照只供查阅，请使用本机当前任务缓存")
    with open(str(cache) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        lines, newline = read_content(cache)
        start, end = locate(lines, args.id)
        block = lines[start:end]
        current = describe(block, args.id, cache, start)
        if current["kind"] != "线上排查":
            raise CLIError("INCIDENT_TASK_REQUIRED", "此命令只完结线上排查，不能完成开发需求")
        if current["title"] != args.expect_title:
            raise CLIError("TITLE_MISMATCH", "排查标题已变化，请重新读取并核对任务")
        if current["status"] == "已完成":
            return {"unchanged": True, "item": dboard_handoff.compact_item(current, execution_scope(block)),
                    "message": "排查已经完结，保留原结论，不重复添加记录。"}
        if current["revision"] != args.expect_revision:
            raise CLIError("REVISION_CONFLICT", "排查记录已变化，请重新读取并核对后完结")
        pending = [entry for entry in current["release_checklist"]["items"] if not entry["done"]]
        if pending:
            raise CLIError("RELEASE_CHECKLIST_INCOMPLETE",
                           "还有{}项上线前事项未完成：{}。请由用户核对并勾选后再完结。".format(
                               len(pending), "、".join(entry["text"] for entry in pending[:3])))
        closure = {
            "outcome": INCIDENT_OUTCOMES[args.outcome],
            "summary": summary,
            "closed_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        prefix = "<!-- dboard-incident-closure:v1:"
        block = [line for line in block if not line.startswith(prefix)]
        block[0] = re.sub(r"#(?:待开始|进行中|挂起)", "#已完成", block[0])
        if "#已完成" not in block[0]:
            block[0] += " #已完成"
        encoded = base64.b64encode(json.dumps(closure, ensure_ascii=False).encode("utf-8")).decode("ascii")
        block.append(prefix + encoded + META_SUFFIX)
        append_progress(block, summary, details)
        updated = dboard_handoff.compact_item(describe(block, args.id, cache, start), execution_scope(block))
        lines[start:end] = block
        atomic_write(cache, newline.join(lines))
        return {"unchanged": False, "item": updated,
                "message": "排查已完结，完整记录保留在「已完成」，可在D板恢复排查。"}


def resource_path(relative):
    here = Path(__file__).resolve()
    for root in [here.parent.parent, here.parent.parent / "Resources",
                 Path.home() / "Applications/DBoard.app/Contents/Resources"]:
        candidate = root / relative
        if candidate.is_file():
            return candidate
    raise CLIError("RESOURCE_NOT_FOUND", "Reinstall DBoard to restore " + relative)


def sync_cache(cache, timeout=110, force=False):
    cache = Path(cache).expanduser().resolve()
    if cache != DEFAULT_CACHE.resolve():
        return {"success": False, "status": "custom-cache-not-synced"}
    try:
        script = resource_path("sync_dboard.sh")
        process = subprocess.Popen(["/bin/bash", str(script)] + (["--force"] if force else []), stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, _ = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Stop the entire sync process tree rather than leaving its document writer running.
            import signal
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=2)
            return {"success": False, "status": "sync-timeout"}
        response = json.loads(stdout.strip())
        if not isinstance(response, dict):
            raise ValueError()
        return {"success": process.returncode == 0 and response.get("success") is True,
                "status": str(response.get("status", "sync-failed"))}
    except (CLIError, OSError, subprocess.SubprocessError, ValueError):
        return {"success": False, "status": "sync-failed"}


def main(argv=None):
    parser = Parser(description="DBoard AI CLI: read one demand, report actual branches and execution progress. JSON results.")
    parser.add_argument("--cache", default=str(DEFAULT_CACHE), help="Absolute cache path; custom caches are never remotely synced")
    sub = parser.add_subparsers(dest="command", required=True)
    guide = sub.add_parser("guide", help="Read the core Skill or one reference on demand")
    guide.add_argument("--topic", choices=("handoff", "feedback", "debug-page", "incident", "code-review", "technical-plan", "worktrees"))
    show = sub.add_parser("show", help="Read one demand and its current revision")
    show.add_argument("id")
    show.add_argument("--full", action="store_true", help="Explicitly include complete history and details")
    inspect = sub.add_parser("inspect", help="Read one authoritative source without loading unrelated history")
    inspect.add_argument("id")
    inspect.add_argument("--section", required=True, choices=("spell", "changes", "release", "code", "handoff", "background", "images", "incident", "plan"))
    history = sub.add_parser("history", help="Read preserved history on demand")
    history.add_argument("id")
    history.add_argument("--from-record", type=int, default=1)
    history.add_argument("--to-record", type=int)
    history.add_argument("--limit", type=int, default=20)
    history.add_argument("--query")
    history.add_argument("--details", action="store_true")
    history.add_argument("--all", action="store_true")
    context = sub.add_parser("context", help="Read compact handoff, live state and a fresh compression check")
    context.add_argument("id")
    context.add_argument("--full", action="store_true", help="Explicit full context; still evaluates compression")
    context.add_argument("--task", choices=("continue", "debug-page", "code-review", "technical-plan"), default="continue", help="Continue development, build the audi debug page, or independently review the entire implementation")
    context.add_argument("--change", help="Focus this handoff on one recorded change, for example C001")
    update = sub.add_parser("report", help="Update actual repository/branch and append progress to one demand")
    update.add_argument("id")
    update.add_argument("--task", choices=("continue", "code-review"), default="continue", help="Code-review mode only records findings and handoff, including completed demands; never changes development state")
    update.add_argument("--review-result", choices=("clear", "findings", "limited"), help="Required for code-review reports: no confirmed issue, confirmed issues, or incomplete coverage")
    update.add_argument("--expect-title", required=True, help="Title returned by show")
    update.add_argument("--expect-revision", required=True, help="Revision returned by show")
    update.add_argument("--overview", help="Optional concise demand scope, within 120 characters; update only when the scope changes")
    update.add_argument("--repo", help="Git working tree; current branch is detected automatically")
    update.add_argument("--replace-repo", help="Explicitly replace an old recorded working directory after relocation; requires --repo")
    update.add_argument("--branch", help="Optional assertion of the actual current branch")
    update.add_argument("--repo-role", choices=("development", "integration", "release"), help="Repository purpose; environment branches are recorded separately and never replace development branches")
    update.add_argument("--summary", "--progress", dest="progress",
                        help="One-sentence summary, at most 120 characters; --progress remains an alias")
    update.add_argument("--details", help="Optional local-only progress details")
    update.add_argument("--handoff-file", help="UTF-8 JSON: based_on_records, sections and references")
    update.add_argument("--compression-decision", choices=("compact", "skip"), help="Required each report after checking context")
    update.add_argument("--compression-reason", help="Actual decision explanation within 500 characters")
    update.add_argument("--stage", choices=STAGES, help="AI verification milestone; testing-passed covers AI-accessible checks only, human integration remains pending")
    update.add_argument("--expect-code", help="code_revision from show after verification; required for every positive --stage, binds commits and working-tree changes")
    update.add_argument("--debug-page", help="Actual audi module route registered at /test-console")
    update.add_argument("--debug-url", help="Optional confirmed HTTP(S) access URL; omit if not deployed")
    update.add_argument("--release-item", action="append", help='JSON item: {"summary":"发布 ultra 服务","category":"release","details":"分支及具体说明"}; categories: release/sql/configuration/permission/other or custom:分类名称; include id to edit an AI item; repeat for multiple items')
    update.add_argument("--release-add", action="append", help="Add one short pre-release summary within 40 characters; use --release-item for details")
    update.add_argument("--release-edit", action="append", help="Edit an uncompleted AI item, using L001=new text; preserves user edits")
    update.add_argument("--release-remove", action="append", help="Remove an uncompleted AI item by its exact ID; preserves user items")
    update.add_argument("--release-reviewed", action="store_true", help="Record that the checklist was checked against the current implementation; may remain empty")
    update.add_argument("--experience-decision", choices=("create", "update", "skip"), help="Required only for incident reports")
    update.add_argument("--experience-reason", help="Explain what is reusable, what changed, or why nothing should be collected")
    update.add_argument("--experience-file", help="Experience content JSON; update includes id and expect_revision from knowledge read")
    update.add_argument("--event-id", help="Keep this ID unchanged when retrying the same report")
    update.add_argument("--no-sync", action="store_true", help="Save locally without remote sync")
    plan = sub.add_parser("plan", help="Read or save the local AI-authored technical plan; never uploads or submits")
    plan_sub = plan.add_subparsers(dest="plan_command", required=True)
    plan_read = plan_sub.add_parser("read")
    plan_read.add_argument("id")
    plan_save = plan_sub.add_parser("save")
    plan_save.add_argument("id")
    plan_save.add_argument("--file", required=True, help="UTF-8 JSON: title, markdown, projects [{name,branch}]")
    plan_save.add_argument("--expect-title", required=True)
    plan_save.add_argument("--expect-revision", required=True)
    plan_save.add_argument("--expect-code", help="code_revision from show; omit only when code is not yet verifiable")
    plan_save.add_argument("--expect-plan", required=True, help="Technical plan revision from plan read, or none for the first save")
    plan_save.add_argument("--summary", default="技术方案已生成／更新。")
    delivery = sub.add_parser("delivery", help="Explicit development delivery; preview first, submit requires its exact revision")
    delivery_sub = delivery.add_subparsers(dest="delivery_command", required=True)
    delivery_preview = delivery_sub.add_parser("preview")
    delivery_preview.add_argument("id")
    delivery_submit = delivery_sub.add_parser("submit")
    delivery_submit.add_argument("id")
    delivery_submit.add_argument("--expect-delivery", required=True)
    incident = sub.add_parser("incident", help="Complete an incident when the user explicitly asks; ordinary demands stay unchanged")
    incident_sub = incident.add_subparsers(dest="incident_command", required=True)
    close = incident_sub.add_parser("close", help="Leave a conclusion and mark an incident completed; preserves history and experiences")
    close.add_argument("id")
    close.add_argument("--expect-title", required=True, help="Title from a fresh show")
    close.add_argument("--expect-revision", required=True, help="Revision from a fresh show")
    close.add_argument("--outcome", required=True, choices=tuple(INCIDENT_OUTCOMES),
                       help="resolved: 已处理; handed-off: 已定位并交接; stopped: 结束本次排查，原因未定")
    close.add_argument("--summary", required=True, help="One-sentence actual conclusion within 120 characters")
    close.add_argument("--details", help="Optional local-only evidence, handoff or reason")
    close.add_argument("--no-sync", action="store_true", help="Save locally without remote sync")
    knowledge = sub.add_parser("knowledge", help="Search and read local incident experiences from any AI session")
    knowledge_sub = knowledge.add_subparsers(dest="knowledge_command", required=True)
    search = knowledge_sub.add_parser("search", help="Search outlines; broaden from symptoms to candidate mechanisms")
    search.add_argument("query", nargs="?", default="")
    search.add_argument("--service")
    search.add_argument("--mechanism")
    search.add_argument("--limit", type=int, default=10)
    search.add_argument("--include-inactive", action="store_true")
    read = knowledge_sub.add_parser("read", help="Read one experience and its original case commands")
    read.add_argument("id")
    worktree = sub.add_parser("worktree", help="Register all task worktrees; preview and explicitly clean completed tasks")
    worktree_sub = worktree.add_subparsers(dest="worktree_command", required=True)
    create_tree = worktree_sub.add_parser("create", help="Create AND register a task-owned worktree; success means the inventory is saved")
    create_tree.add_argument("id")
    create_tree.add_argument("--repo", required=True, help="Existing repository used to create the worktree")
    create_tree.add_argument("--path", required=True)
    create_tree.add_argument("--start", default="HEAD", help="Start branch or commit for --new-branch / --detach")
    create_tree.add_argument("--expect-title")
    create_tree.add_argument("--task", choices=("continue", "code-review"), default="continue")
    creation_mode = create_tree.add_mutually_exclusive_group(required=True)
    creation_mode.add_argument("--new-branch", help="Create a new local branch")
    creation_mode.add_argument("--branch", help="Use the exact existing local branch, e.g. after a previous cleanup")
    creation_mode.add_argument("--detach", action="store_true", help="Temporary worktree with a detached HEAD")
    register_tree = worktree_sub.add_parser("register", help="Register a linked worktree; --created confirms task ownership")
    register_tree.add_argument("id")
    register_tree.add_argument("--path", required=True)
    register_tree.add_argument("--created", action="store_true")
    register_tree.add_argument("--expect-title")
    for mode in ("summary", "list", "preview", "cleanup"):
        tree = worktree_sub.add_parser(mode)
        tree.add_argument("id")
        if mode == "cleanup":
            tree.add_argument("--expect-preview", required=True, help="Exact token from a fresh preview; never uses --force")
    sub.add_parser("sync", help="Retry remote sync of the default cache without adding feedback again")
    try:
        args = parser.parse_args(argv)
        cache = Path(args.cache).expanduser().resolve()
        if args.command == "guide":
            relative = "skills/dboard-feedback/" + ("references/" + args.topic + ".md" if args.topic else "SKILL.md")
            path = resource_path(relative)
            emit({"success": True, "skill_path": str(path), "instructions": path.read_text(encoding="utf-8")})
        elif args.command == "knowledge":
            if not cache.is_file():
                raise CLIError("CACHE_NOT_FOUND", "Demand cache does not exist")
            with open(str(cache) + ".lock", "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                lines, _ = read_content(cache)
                catalog = dboard_knowledge.read(lines)
            if args.knowledge_command == "search":
                matches = dboard_knowledge.search(catalog, args.query, args.service, args.mechanism,
                                                  args.limit, args.include_inactive)
                emit({"success": True, "matches": matches, "read_command": shlex.join([
                    str(Path.home() / ".local/bin/dboard-ai"), "--cache", str(cache), "knowledge", "read"]) + " '<K编号>'"})
            else:
                entry = next((entry for entry in catalog["entries"] if entry["id"] == args.id), None)
                if entry is None:
                    raise CLIError("KNOWLEDGE_NOT_FOUND", "Experience not found")
                source_commands = []
                for source in entry["sources"]:
                    try:
                        locate(lines, source["id"])
                        available = True
                    except CLIError:
                        available = False
                    source_commands.append({"id": source["id"], "available": available,
                        "read_command": shlex.join([str(Path.home() / ".local/bin/dboard-ai"), "--cache", str(cache),
                                                   "context", source["id"], "--full"]) if available else None})
                emit({"success": True, "experience": dboard_knowledge.record_view(entry), "source_commands": source_commands,
                      "notice": "按本次证据核对适用范围；停用经验仅供历史追溯，不作为当前查法。"})
        elif args.command == "delivery":
            bundled = Path(__file__).resolve().parents[2] / "MacOS/DBoard"
            binary = bundled if bundled.is_file() else Path(__file__).resolve().parents[1] / ".build/debug/DBoard"
            if not binary.is_file():
                raise CLIError("APP_NOT_INSTALLED", "需要安装或构建D板后使用交付命令")
            cmd = [str(binary), "--dboard-delivery-cli", args.delivery_command, args.id, str(cache)]
            if args.delivery_command == "submit":
                cmd.append(args.expect_delivery)
            try:
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=150)
            except subprocess.TimeoutExpired:
                raise CLIError("DELIVERY_PENDING", "交付请求超时，请在D板核对已保存的结果，不重复提交")
            try:
                emit(json.loads(result.stdout))
            except ValueError:
                raise CLIError("DELIVERY_FAILED", "交付结果暂时无法读取，请在D板核对，不重复提交")
            return result.returncode
        elif args.command == "worktree":
            emit(dboard_worktrees.command(cache, args))
        elif args.command == "plan":
            emit(plan_command(cache, args))
        elif args.command in ("show", "context", "history", "inspect"):
            if not cache.is_file():
                raise CLIError("CACHE_NOT_FOUND", "Demand cache does not exist")
            with open(str(cache) + ".lock", "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                lines, _ = read_content(cache)
                start, end = locate(lines, args.id)
                block = lines[start:end]
                item = describe(block, args.id, cache, start)
            if args.command == "context":
                emit(task_context(block, item, cache, args.change, args.task, full=args.full, lines=lines))
            elif args.command == "history":
                emit(dboard_handoff.history_result(item, args))
            elif args.command == "inspect":
                emit(dboard_handoff.inspect_result(item, args.section))
            else:
                emit({"success": True, "item": item if args.full else dboard_handoff.compact_item(item, execution_scope(block))})
        elif args.command == "incident":
            result = close_incident(cache, args)
            sync = ({"success": None, "status": "skipped"} if args.no_sync or cache != DEFAULT_CACHE.resolve()
                    else sync_cache(cache))
            success = sync["success"] is not False
            emit(dict(result, success=success, local_saved=True, sync=sync))
            return 0 if success else 3
        elif args.command == "report":
            result = report(cache, args)
            current_lines, _ = read_content(cache)
            first, last = locate(current_lines, args.id)
            result["item"] = dboard_handoff.compact_item(result["item"], execution_scope(current_lines[first:last]))
            saved = True
            if args.no_sync or cache != DEFAULT_CACHE.resolve():
                sync = {"success": None, "status": "skipped"}
            else:
                sync = sync_cache(cache)
            success = sync["success"] is not False
            emit(dict(result, success=success, local_saved=saved, sync=sync))
            return 0 if success else 3
        elif args.command == "sync":
            sync = sync_cache(cache, force=True)
            emit({"success": sync["success"], "sync": sync})
            return 0 if sync["success"] else 3
        return 0
    except (CLIError, dboard_handoff.HandoffError, dboard_knowledge.KnowledgeError, dboard_plan.PlanError, dboard_worktrees.WorktreeError) as error:
        emit({"success": False, "local_saved": False, "error": {"code": error.code, "message": str(error)}})
        return 2
    except (OSError, UnicodeError, ValueError):
        emit({"success": False, "local_saved": False,
              "error": {"code": "IO_ERROR", "message": "Cannot read or update the local demand cache"}})
        return 2


if __name__ == "__main__":
    sys.exit(main())
