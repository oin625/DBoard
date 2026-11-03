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
    if not re.fullmatch(r"D[0-9]{3,}", item_id):
        raise CLIError("INVALID_ID", "Use the exact D number, for example D014")
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
        for repo in data["repositories"]:
            if not isinstance(repo, dict):
                raise ValueError()
            scalar(repo["path"], "repository")
            scalar(repo["branch"], "branch")
            for key in ("git_common_dir", "name"):
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
            if not isinstance(value.get(key), str) or not re.fullmatch(r"D[0-9]{3,}", value[key]):
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
    valid_previous = previous is not None and not current["execution_needs_review"]
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
    record = {"stage": stage, "scope_hash": execution_scope(block), "debug_page": page, "debug_url": url,
              "updated_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds")}
    block[:] = [line for line in block if not line.startswith(EXECUTION_PREFIX)]
    encoded = base64.b64encode(json.dumps(record, ensure_ascii=False, sort_keys=True).encode("utf-8")).decode("ascii")
    block.insert(1, EXECUTION_PREFIX + encoded + META_SUFFIX)


def debug_page_not_needed(block):
    records = [line for line in block if line.startswith(DEBUG_PAGE_POLICY_PREFIX)]
    if len(records) > 1 or any(line != DEBUG_PAGE_NOT_NEEDED for line in records):
        raise CLIError("INVALID_DEBUG_PAGE_POLICY", "User debug-page preference is unreadable; no update made")
    return bool(records)


def describe(block, item_id, cache, start):
    data = fields(block)
    if "变更咒言" in data and not data["变更咒言"]:
        raise CLIError("INVALID_CHANGE_DATA", "Existing change spells are unreadable; no update made")
    header = block[0]
    project_match = re.search(r"【(.*?)】", header)
    # Match DBoard's displayed title, including dates interspersed with the title.
    title = header.split("】", 1)[1] if "】" in header else ""
    for state in ["待开始", "进行中", "已完成", "挂起"]:
        title = title.replace("#" + state, "")
    title = re.sub(r"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})", "", title)
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
        "version": demand_version(block),
        "revision": revision(block),
        "location": {"cache": str(cache), "heading_line": start + 1},
    }
    item["debug_page_not_needed"] = debug_page_not_needed(block)
    item["execution"] = read_execution(block)
    item["execution_needs_review"] = bool(item["execution"] and item["execution"]["scope_hash"] != execution_scope(block))
    image_text = [prompt] + [change["intent"] for change in item["changes"]]
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


def task_context(block, item, cache, change_id=None, task="continue"):
    changes = item["changes"]
    change = None
    if change_id:
        if not re.fullmatch(r"C[0-9]{3,}", change_id):
            raise CLIError("INVALID_CHANGE_ID", "Use the exact change ID, for example C001")
        change = next((value for value in changes if value["id"] == change_id), None)
        if change is None:
            raise CLIError("CHANGE_NOT_FOUND", "The selected change no longer exists; reread the demand")
    if task == "debug-page" and change_id:
        raise CLIError("INVALID_ARGUMENT", "Debug-page verification covers the whole demand; omit --change")
    raw = fields(block)
    text = ["## 接续任务",
            "请接手这张需求，先阅读原咒言、最新进度和追加变更，核对已有代码、仓库、分支和未提交改动；仅继续本次需求中明确、尚未完成的事项。",
            "追加变更与原咒言冲突时，以后续变更为准；结合最新进度和实际代码确认处理情况，不重做已完成的原需求或变更。",
            "若没有可继续执行的待做事项，直接向用户反馈现状及待验收、阻塞等情况，不改代码、不自行扩展需求；现状未变且无新进展时，不向 D板追加重复记录。",
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
    version = item["version"]
    if version:
        text.extend(["## 本轮版本 " + str(version["number"]) + ".0",
                     "本轮在 " + version["parentID"] + "「" + version["parentTitle"] +
                     "」的已有实现上开发新版本。原版已归档；本轮咒言是新的改动要求，请避免重做原版。",
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
    if item["declared_repositories"]:
        text.append("代码仓库 / 项目入口（用户填写，请查找并阅读相关实现）：")
        text.extend("- " + value for value in item["declared_repositories"])
    description = item["description"].strip()
    if description and description not in ("（待补充）", item["title"]):
        text.append("描述：" + description)
    branch = item["branch"].strip()
    text.append("已记录分支：" + branch if branch and branch != "待定" else "分支：尚未记录，接手后读取 Git 确认")
    for repository in item["repositories"]:
        text.append("仓库：" + repository["path"] + "；分支：" + repository["branch"])
    for symbol, label in (("📅", "开始日期"), ("🎯", "计划截止")):
        found = re.search(symbol + r"([0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})(?![0-9.-])", block[0])
        if found:
            text.append(label + "：" + found.group(1))
    text.append("开发 / 调试：" + ("需求已变更，之前的结论需重新核验" if item["execution_needs_review"]
                 else (item["execution"]["stage"] if item["execution"] else "尚无结构化核验记录，不能据此认定未开发")))
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
                     "下面的只读命令先取最近 50 条。按本需求的关键词定位；需要更多上下文时，用返回记录的边界 createTime 作为 --time 向前翻页，并阅读 quotedMessage 引用上下文和相关话题回复。",
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
                     "原咒言、追加变更和历史背景中的图片是本机附件。请通过本机文件或图片工具逐张打开 images 中的图片，结合相邻文字理解要求；路径本身不包含图片内容。",
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
    return {"success": True, "task": task, "debug_instructions": debug,
            "item": {key: item[key] for key in ("id", "title", "status", "revision", "location", "chat_links", "execution", "execution_needs_review", "debug_page_not_needed")},
            "chat_sources": sources,
            "change_id": change_id, "context": "\n".join(text), "images": images,
            "cli": cli, "feedback_instructions": skill.read_text(encoding="utf-8")}


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
        while end < len(block) and block[end].startswith((" ", "\t")) and block[end].strip():
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


def git_repository(path, expected_branch):
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


def branch_declaration(repositories):
    if len(repositories) == 1:
        return repositories[0]["branch"]
    names = [row.get("name") or Path(row["path"]).name for row in repositories]
    return "；".join((name if names.count(name) == 1 else row["path"]) + ":" + row["branch"]
                    for name, row in zip(names, repositories))

def atomic_write(cache, content):
    mode = stat.S_IMODE(cache.stat().st_mode)
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


def report(cache, args):
    replace_path = getattr(args, "replace_repo", None)
    if replace_path is not None:
        if not args.repo:
            raise CLIError("INVALID_ARGUMENT", "--replace-repo requires --repo")
        replace_path = str(Path(scalar(replace_path, "old repository")).expanduser().resolve())
    stage = getattr(args, "stage", None)
    page = getattr(args, "debug_page", None)
    url = getattr(args, "debug_url", None)
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
    if args.branch and not args.repo:
        raise CLIError("INVALID_ARGUMENT", "--branch requires --repo")
    if not args.repo and args.progress is None and overview is None:
        raise CLIError("INVALID_ARGUMENT", "Supply --repo, --summary and/or --overview")
    event_id = args.event_id or str(uuid.uuid4())
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,120}", event_id):
        raise CLIError("INVALID_EVENT_ID", "Use a stable short event ID with letters, digits, hyphens or underscores")
    # Hash the request before querying Git: an exact retry must not capture a newly changed branch.
    request = {"repo": str(Path(args.repo).expanduser().resolve()) if args.repo else None,
               "branch": args.branch, "progress": args.progress}
    if replace_path is not None:
        request["replace_repo"] = replace_path
    if stage is not None:
        request.update(stage=stage, debug_page=page, debug_url=url)
    if overview is not None:
        request["overview"] = overview.strip()
    if args.details is not None:
        request["details"] = args.details
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
        meta = feedback_metadata(block)
        previous = meta["events"].get(event_id)
        if previous:
            if previous != request_hash:
                raise CLIError("EVENT_CONFLICT", "Event ID was already used for different feedback")
            return {"event_id": event_id, "duplicate": True, "item": current}
        if current["revision"] != args.expect_revision:
            raise CLIError("REVISION_CONFLICT", "Demand changed since show; reread it before reporting")
        if current["status"] == "已完成":
            raise CLIError("DEMAND_COMPLETED", "This demand is already completed; no feedback was written")
        block = [line for line in block if not line.startswith(META_PREFIX)]
        if overview is not None:
            set_field(block, "概括", overview.strip())
        if args.repo:
            repo = git_repository(args.repo, args.branch)
            repo_changed = record_repository(meta, repo, replace_path)
            set_field(block, "分支", branch_declaration(meta["repositories"]))
            if repo_changed:
                append_progress(block, "已更新开发仓库与分支。",
                                "仓库：{}；分支：{}".format(repo["path"], repo["branch"]))
        update_execution(block, current, args)
        if args.progress is not None:
            append_progress(block, args.progress.strip(), args.details)
        meta["events"][event_id] = request_hash
        encoded = base64.b64encode(json.dumps(meta, ensure_ascii=False, sort_keys=True).encode("utf-8")).decode("ascii")
        block.append(META_PREFIX + encoded + META_SUFFIX)
        lines[start:end] = block
        atomic_write(cache, newline.join(lines))
        return {"event_id": event_id, "duplicate": False,
                "item": describe(block, args.id, cache, start)}


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
    sub.add_parser("guide", help="Read the execution feedback Skill")
    show = sub.add_parser("show", help="Read one demand and its current revision")
    show.add_argument("id")
    context = sub.add_parser("context", help="Read the latest full task context and feedback instructions")
    context.add_argument("id")
    context.add_argument("--task", choices=("continue", "debug-page"), default="continue", help="Explicitly continue development or build the audi debug page")
    context.add_argument("--change", help="Focus this handoff on one recorded change, for example C001")
    update = sub.add_parser("report", help="Update actual repository/branch and append progress to one demand")
    update.add_argument("id")
    update.add_argument("--expect-title", required=True, help="Title returned by show")
    update.add_argument("--expect-revision", required=True, help="Revision returned by show")
    update.add_argument("--overview", help="Optional concise demand scope, within 120 characters; update only when the scope changes")
    update.add_argument("--repo", help="Git working tree; current branch is detected automatically")
    update.add_argument("--replace-repo", help="Explicitly replace an old recorded working directory after relocation; requires --repo")
    update.add_argument("--branch", help="Optional assertion of the actual current branch")
    update.add_argument("--summary", "--progress", dest="progress",
                        help="One-sentence summary, at most 120 characters; --progress remains an alias")
    update.add_argument("--details", help="Optional local-only handoff details; multiline plain text is supported")
    update.add_argument("--stage", choices=STAGES, help="AI verification milestone; testing-passed covers AI-accessible checks only, human integration remains pending")
    update.add_argument("--debug-page", help="Actual audi module route registered at /test-console")
    update.add_argument("--debug-url", help="Optional confirmed HTTP(S) access URL; omit if not deployed")
    update.add_argument("--event-id", help="Keep this ID unchanged when retrying the same report")
    update.add_argument("--no-sync", action="store_true", help="Save locally without remote sync")
    sub.add_parser("sync", help="Retry remote sync of the default cache without adding feedback again")
    try:
        args = parser.parse_args(argv)
        cache = Path(args.cache).expanduser().resolve()
        if args.command == "guide":
            path = resource_path("skills/dboard-feedback/SKILL.md")
            emit({"success": True, "skill_path": str(path), "instructions": path.read_text(encoding="utf-8")})
        elif args.command in ("show", "context"):
            if not cache.is_file():
                raise CLIError("CACHE_NOT_FOUND", "Demand cache does not exist")
            with open(str(cache) + ".lock", "a") as lock:
                fcntl.flock(lock, fcntl.LOCK_SH)
                lines, _ = read_content(cache)
                start, end = locate(lines, args.id)
                block = lines[start:end]
                item = describe(block, args.id, cache, start)
            if args.command == "context":
                emit(task_context(block, item, cache, args.change, args.task))
            else:
                emit({"success": True, "item": item})
        elif args.command == "report":
            result = report(cache, args)
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
    except CLIError as error:
        emit({"success": False, "local_saved": False, "error": {"code": error.code, "message": str(error)}})
        return 2
    except (OSError, UnicodeError, ValueError):
        emit({"success": False, "local_saved": False,
              "error": {"code": "IO_ERROR", "message": "Cannot read or update the local demand cache"}})
        return 2


if __name__ == "__main__":
    sys.exit(main())
