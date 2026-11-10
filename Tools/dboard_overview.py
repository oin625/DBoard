"""The only public projection of a DBoard cache. Full execution context stays local."""
import hashlib
import re
from pathlib import PurePosixPath

from dboard_ai import CLIError, fields, locate, progress_records, progress_summary, demand_changes, assemble_prompt

PREFIX = "<!-- synced-overview:v1: "
NODE_PREFIX = "<!-- synced-node: "
HEADER = "# 进行时 · 需求总览\n\n> 本文只展示需求概况和当前进度；完整咒言、资料、变更、工程分支与历史记录保存在 D板本机。"
PRIORITIES = ["## 🔴 重要且紧急", "## 🟡 重要不紧急", "## 🟠 紧急不重要", "## 🟢 不紧急不重要"]


def compact(text):
    lines = [line.strip() for line in text.splitlines()
             if line.strip() and not line.strip().startswith(("#", "<!--", "![", "```"))]
    text = " ".join(lines)
    text = re.sub(r"https?://[^\s]+", "", text)
    text = re.sub(r"/(?:Users|home|tmp|work)/[^\s，。；]+", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return progress_summary(text)


def useful_progress(text):
    plain = re.sub(r"^\[C[0-9/]+\]\s*", "", text).strip()
    bookkeeping = (
        plain == "已更新开发仓库与分支。" or
        re.fullmatch(r"已记录.*(?:开发仓库与分支|工作树及开发分支|工作树及开发分支。)[。]?", plain) or
        re.fullmatch(r"已在独立工作区重放[0-9]+个文件，Luban收到[0-9]+条事件，代码及Git状态保持一致[。]?", plain)
    )
    return bool(plain) and not bookkeeping


def source_items(content):
    lines = content.replace("\r\n", "\n").split("\n")
    priority = 1
    entries = []
    seen = set()
    in_todos = False
    for index, line in enumerate(lines):
        if line.startswith("## 📝"):
            in_todos = True
        for value, prefix in enumerate(("## 🔴", "## 🟡", "## 🟠", "## 🟢")):
            if line.startswith(prefix):
                priority = value
                in_todos = False
        match = re.match(r"^### ([DP][0-9]{3,})(?=【|\s|$)", line)
        if not match or in_todos:
            continue
        item_id = match[1]
        if item_id in seen:
            raise CLIError("AMBIGUOUS_ID", "Duplicate demand IDs; overview was not uploaded")
        seen.add(item_id)
        start, end = locate(lines, item_id)
        block = lines[start:end]
        data = fields(block)
        is_incident = data.get("类型") == "线上排查"
        states = [s for s in ("待开始", "进行中", "已完成", "挂起") if "#" + s in line]
        if len(states) != 1:
            raise CLIError("INVALID_STATUS", "Demand status cannot be confirmed; overview was not uploaded")
        project_match = re.search(r"【(.*?)】", line)
        project = data.get("项目", project_match[1] if project_match else "")
        projects = []
        for value in re.split(r"[\r\n;；]", project):
            value = value.strip()
            if value:
                name = PurePosixPath(value).name if "/" in value else value
                if name not in projects:
                    projects.append(name)
        title = line.split("】", 1)[1] if "】" in line else line[len("### " + item_id):]
        for state in states:
            title = title.replace("#" + state, "")
        title = re.sub(r"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})", "", title)
        title = re.sub(r"\s*✅[0-9]{4}-[0-9]{2}-[0-9]{2}", "", title).strip()
        title = compact(title) or (compact(data.get("描述", "")) if not is_incident and data.get("描述", "") != "（待补充）" else "") or "（未命名）"
        dates = re.findall(r"[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})", line)
        period = ""
        if dates:
            period = " " + ("→".join(dates) if len(dates) > 1 else dates[0])
        heading = "### " + item_id + ("【" + "；".join(projects) + "】" if projects else " ") + title + " #" + states[0] + period
        completed = re.search(r"✅[0-9]{4}-[0-9]{2}-[0-9]{2}", line)
        if completed:
            heading += " " + completed[0]
        # Incident descriptions contain raw reports, logs and screenshots; only an explicit overview is public.
        overview = data.get("概括", "").strip() or ("" if is_incident else data.get("描述", "").strip())
        if overview in ("（待补充）", "待补充"):
            overview = ""
        if not overview and not is_incident:
            assembled = assemble_prompt(data.get("提示词", ""))
            intent = re.search(r"^## 要做什么\n(.*?)(?=^## |\Z)", assembled, re.M | re.S)
            overview = intent[1] if intent else ""
            # A fallback explains the broad goal, rather than copying the implementation plan.
            overview = re.split(r"[。！？；;\n]", compact(overview), maxsplit=1)[0].strip()
        overview = compact(overview)
        records = progress_records(data.get("进度", ""))
        for record in records:
            record["summary"] = compact(record["summary"])
        changes = demand_changes(data.get("变更咒言", ""))
        if "变更咒言" in data and not data["变更咒言"]:
            raise CLIError("INVALID_CHANGE_DATA", "Change records cannot be confirmed")
        mentioned = set(re.findall(r"\bC[0-9]{3,}\b", "\n".join(r["summary"] for r in records)))
        pending = sum(change["id"] not in mentioned for change in changes)
        progress = next((r for r in reversed(records) if useful_progress(r["summary"])), None)
        flow = data.get("需求流", "").strip()
        if flow and not re.fullmatch(r"\[[^\]\n]+\]\(https://ai\.tmallyc\.com/prd/index\.html#detail/[0-9]+\)", flow):
            raise CLIError("INVALID_LINK", "Demand association cannot be confirmed")
        entries.append({"priority": priority, "heading": heading, "overview": overview,
                        "progress": progress, "pending": pending, "flow": flow})
    # Refuse malformed demand headings rather than silently dropping a real demand.
    invalid = [line for line in lines if re.match(r"^### [DP][0-9]", line)
               and not re.match(r"^### [DP][0-9]{3,}(?=【|\s|$)", line)]
    if invalid:
        raise CLIError("INVALID_ID", "Malformed demand heading; overview was not uploaded")
    return entries


def render_item(item):
    lines = [item["heading"]]
    if item["overview"]:
        lines += ["- **概括**：" + item["overview"]]
    progress = item["progress"]
    if item["pending"]:
        text = "新增 " + str(item["pending"]) + " 项变更待处理。"
        if progress:
            text += "上次进度（" + progress["date"] + "）：" + progress["summary"]
        lines += ["- **进度**：", "    - " + (progress["date"] if progress else "待处理") + ": " + text]
    elif progress:
        lines += ["- **进度**：", "    - " + progress["date"] + ": " + progress["summary"]]
    if item["flow"]:
        lines += ["- **需求流**：" + item["flow"]]
    return "\n".join(lines)


def render(content):
    entries = source_items(content)
    lines = [HEADER, ""]
    for priority, heading in enumerate(PRIORITIES):
        group = [entry for entry in entries if entry["priority"] == priority]
        if group:
            lines += [heading, ""]
            for item in group:
                lines += [render_item(item), ""]
    if not entries:
        lines += ["暂无需求。", ""]
    return "\n".join(lines).rstrip() + "\n"


def digest(content):
    return hashlib.sha256(render(content).encode("utf-8")).hexdigest()


def receipt(content, node):
    hashes = re.findall(r"^" + re.escape(PREFIX) + r"([0-9a-f]{64}) -->$", content, re.M)
    nodes = re.findall(r"^" + re.escape(NODE_PREFIX) + r"([^\s]+) -->$", content, re.M)
    return len(hashes) == len(nodes) == 1 and nodes[0] == node and hashes[0] == digest(content)
