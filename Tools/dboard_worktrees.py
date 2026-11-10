"""Task-owned Git worktrees: durable local inventory and previewed, non-forced cleanup."""
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


class WorktreeError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def _hash(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(",", ":")).encode()).hexdigest()


def _time():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def primary_cache(cache):
    cache = Path(cache).expanduser().resolve()
    return cache.with_name("demand-center-cache.md") if cache.name == "dboard-archive-cache.md" else cache


def registry_path(cache):
    return primary_cache(cache).with_name("dboard-worktrees.json")


@contextlib.contextmanager
def locked(path, exclusive=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(str(path) + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield


def read(cache):
    path = registry_path(cache)
    if not path.exists():
        return {"version": 1, "records": []}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict) or value.get("version") != 1 or not isinstance(value.get("records"), list):
            raise ValueError()
        ids = set()
        for row in value["records"]:
            if not isinstance(row, dict) or row["id"] in ids or not re.fullmatch(r"W[0-9]{3,}", row["id"]):
                raise ValueError()
            ids.add(row["id"])
            if not re.fullmatch(r"[DP][0-9]{3,}", row["demand_id"]):
                raise ValueError()
            for key in ("cache", "path", "common_dir", "git_dir", "branch", "name"):
                if not isinstance(row[key], str) or not row[key] or any(ord(c) < 32 for c in row[key]):
                    raise ValueError()
            if not isinstance(row["created_by_task"], bool) or not isinstance(row["identity"], list):
                raise ValueError()
            if len(row["identity"]) != 4 or any(type(n) is not int for n in row["identity"]):
                raise ValueError()
            if any(not Path(row[k]).is_absolute() for k in ("cache", "path", "common_dir", "git_dir")):
                raise ValueError()
            if row["state"] not in ("active", "removing", "removed"):
                raise ValueError()
        return value
    except (OSError, ValueError, TypeError, KeyError):
        raise WorktreeError("WORKTREE_DATA_INVALID", "工作树台账无法读取，已停止操作并保留原文件")


def write(cache, value):
    path = registry_path(cache)
    fd, temporary = tempfile.mkstemp(prefix=".dboard-worktrees-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            json.dump(value, output, ensure_ascii=False, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def git(path, *args, required=True):
    try:
        result = subprocess.run(["git", "--no-optional-locks", "-C", str(path), *args],
                                capture_output=True, timeout=120 if args[:2] in (("worktree", "remove"), ("worktree", "add")) else 12)
    except (OSError, subprocess.SubprocessError):
        raise WorktreeError("GIT_UNAVAILABLE", "Git 核对失败或超时")
    if result.returncode and required:
        raise WorktreeError("GIT_FAILED", "无法核对工作树：" + os.fsdecode(result.stderr).strip()[:200])
    return result.stdout if result.returncode == 0 else None


def _identity(path, git_dir):
    result = []
    for value in (path, git_dir):
        info = Path(value).stat()
        result.extend([info.st_dev, info.st_ino])
    return result


def worktree_info(path):
    path = Path(path).expanduser().resolve()
    if any(ord(c) < 32 for c in str(path)):
        raise WorktreeError("INVALID_PATH", "工作树路径含控制字符")
    root = Path(os.fsdecode(git(path, "rev-parse", "--show-toplevel")).strip()).resolve()
    if root != path:
        raise WorktreeError("WORKTREE_ROOT_REQUIRED", "请选择工作树根目录")
    common = Path(os.fsdecode(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).strip()).resolve()
    git_dir = Path(os.fsdecode(git(path, "rev-parse", "--absolute-git-dir")).strip()).resolve()
    if common == git_dir:
        raise WorktreeError("PRIMARY_CHECKOUT", "这是主仓库目录，不能登记为可清理的工作树")
    parts = git(path, "worktree", "list", "--porcelain", "-z").split(b"\0")
    records, current = [], {}
    for part in parts:
        if not part:
            if current:
                records.append(current)
                current = {}
            continue
        key, _, value = os.fsdecode(part).partition(" ")
        current[key] = value
    if current:
        records.append(current)
    match = next((r for r in records if Path(r.get("worktree", "/")).resolve() == path), None)
    if not match or match.get("bare") is not None:
        raise WorktreeError("NOT_REGISTERED_WITH_GIT", "该目录不是 Git 登记的独立工作树")
    branch = os.fsdecode(git(path, "symbolic-ref", "--quiet", "--short", "HEAD", required=False) or b"").strip()
    branch = branch or "（游离 HEAD）"
    head = os.fsdecode(git(path, "rev-parse", "--verify", "HEAD")).strip()
    return {"path": str(path), "common_dir": str(common), "git_dir": str(git_dir),
            "branch": branch, "head": head, "name": common.parent.name if common.name == ".git" else common.stem,
            "identity": _identity(path, git_dir), "locked": "locked" in match,
            "primary_path": records[0].get("worktree") if records else None}


def _blocks(path, item_id):
    if not path.exists():
        return []
    lines = path.read_text(encoding="utf-8").splitlines()
    starts = [i for i, line in enumerate(lines) if re.match(r"^### " + re.escape(item_id) + r"(?=【|\s|$)", line)]
    result = []
    for start in starts:
        end = start + 1
        while end < len(lines) and not (lines[end].startswith(("### ", "## ")) or lines[end] == "---"):
            end += 1
        result.append(lines[start:end])
    return result


def demand(cache, item_id):
    if not re.fullmatch(r"[DP][0-9]{3,}", item_id):
        raise WorktreeError("INVALID_ID", "请使用准确的需求或排查编号")
    primary = primary_cache(cache)
    blocks = _blocks(primary, item_id)
    if len(blocks) > 1:
        raise WorktreeError("AMBIGUOUS_ID", "需求编号重复，已停止操作")
    if not blocks:
        journal_path = primary.with_name("dboard-archive-journal.json")
        if journal_path.exists():
            try:
                journal = json.loads(journal_path.read_text(encoding="utf-8"))
                if not isinstance(journal, dict):
                    raise ValueError()
                row = journal.get(item_id)
                if row is not None and not isinstance(row, dict):
                    raise ValueError()
                if row and row.get("state") == "removed":
                    block = row["archived"]
                    if not isinstance(block, list) or not block or any(not isinstance(line, str) for line in block):
                        raise ValueError()
                    blocks = [block]
            except (ValueError, TypeError, KeyError):
                raise WorktreeError("ARCHIVE_INVALID", "完成记录无法读取，已停止操作")
        if not blocks:
            archived = _blocks(primary.with_name("dboard-archive-cache.md"), item_id)
            blocks = archived[-1:]
    if not blocks:
        raise WorktreeError("NOT_FOUND", "找不到需求的本机记录，请刷新已完成列表")
    block = blocks[0]
    header = block[0]
    status = next((state for state in ("已完成", "进行中", "待开始", "挂起") if "#" + state in header), None)
    if status is None:
        raise WorktreeError("INVALID_STATUS", "需求状态无法确认")
    title = header.split("】", 1)[-1]
    title = re.sub(r"#(?:已完成|进行中|待开始|挂起)|\s*✅[0-9-]+", "", title)
    title = re.sub(r"→?[📅🎯](?:[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\.[0-9]{1,2})", "", title)
    title = re.sub(r"\s+", " ", title).strip()
    return {"id": item_id, "title": title, "status": status, "revision": _hash(block)}


def register(cache, item_id, path, created=False, expected_title=None, known_task=None):
    task = known_task or demand(cache, item_id)
    if expected_title and task["title"] != expected_title:
        raise WorktreeError("TITLE_MISMATCH", "需求名称已变化，请重新核对")
    try:
        info = worktree_info(path)
    except WorktreeError as error:
        if known_task and error.code == "PRIMARY_CHECKOUT":
            return None
        raise
    with locked(registry_path(cache), True):
        return _register(cache, item_id, info, created, read(cache))


def _register(cache, item_id, info, created, value):
    scope = str(primary_cache(cache))
    row = next((r for r in value["records"] if r["cache"] == scope and r["demand_id"] == item_id
                and r["path"] == info["path"] and r["identity"] == info["identity"]), None)
    if row:
        if row["state"] == "removed":
            raise WorktreeError("WORKTREE_REPLACED", "原工作树已清理，请重新登记当前目录")
        changed = row["branch"] != info["branch"] or (created and not row["created_by_task"])
        row.update(branch=info["branch"], head=info["head"], state="active",
                   created_by_task=row["created_by_task"] or created)
    else:
        number = max((int(r["id"][1:]) for r in value["records"]), default=0) + 1
        row = {k: info[k] for k in ("path", "common_dir", "git_dir", "branch", "head", "name", "identity")}
        row.update(id="W%03d" % number, cache=scope, demand_id=item_id, created_by_task=created,
                   state="active", registered_at=_time())
        value["records"].append(row)
        changed = True
    # Save HEAD changes too: this is a local inventory, not a new progress record.
    write(cache, value)
    return dict(row, changed=changed)


def create(cache, args):
    path = Path(args.path).expanduser().resolve()
    repo = Path(args.repo).expanduser().resolve()
    if any(ord(c) < 32 for c in str(path)) or str(path) in ("/", str(Path.home())):
        raise WorktreeError("INVALID_PATH", "请使用独立工作树的准确目录")
    branch = args.new_branch or args.branch
    if branch:
        if branch.startswith("-") or any(ord(c) < 32 for c in branch):
            raise WorktreeError("INVALID_BRANCH", "请使用准确的 Git 分支名")
        git(repo, "check-ref-format", "--branch", branch)
    desired = branch or "（游离 HEAD）"
    with locked(primary_cache(cache)), locked(registry_path(cache), True):
        task = demand(cache, args.id)
        if args.expect_title and task["title"] != args.expect_title:
            raise WorktreeError("TITLE_MISMATCH", "需求名称已变化，请重新核对")
        if task["status"] == "已完成" and args.task != "code-review":
            raise WorktreeError("NOT_ACTIVE", "需求已完成，普通开发不能创建工作树；明确CR使用--task code-review")
        value = read(cache)  # Validate the inventory before any Git mutation.
        common = Path(os.fsdecode(git(repo, "rev-parse", "--path-format=absolute", "--git-common-dir")).strip()).resolve()
        if os.path.lexists(path):
            row = next((r for r in value["records"] if r["cache"] == str(primary_cache(cache))
                        and r["demand_id"] == args.id and r["path"] == str(path)
                        and r["state"] == "active" and r["created_by_task"]), None)
            if not row:
                raise WorktreeError("PATH_EXISTS", "目标目录已存在；不会覆盖或声称由本次创建，复用请用register")
            info = worktree_info(path)
            if row["identity"] == info["identity"] and info["branch"] == desired and info["common_dir"] == str(common):
                return {"success": True, "id": args.id, "created": False, "duplicate": True,
                        "record": _register(cache, args.id, info, True, value)}
            raise WorktreeError("PATH_EXISTS", "目标目录已存在；不会覆盖或声称由本次创建，复用请用register")
        if args.branch and args.start != "HEAD":
            raise WorktreeError("INVALID_ARGUMENT", "--branch复用已有本地分支，不同时指定--start")
        start = "refs/heads/" + args.branch if args.branch else args.start
        if not start or start.startswith("-") or any(ord(c) < 32 for c in start):
            raise WorktreeError("INVALID_START", "请使用准确的起点分支或提交")
        commit = os.fsdecode(git(repo, "rev-parse", "--verify", "--end-of-options", start + "^{commit}")).strip()
        options = ["-b", args.new_branch] if args.new_branch else (["--detach"] if args.detach else [])
        target = args.branch if args.branch else commit
        git(repo, "worktree", "add", *options, "--", str(path), target)
        try:
            info = worktree_info(path)
            record = _register(cache, args.id, info, True, value)
        except (OSError, WorktreeError) as error:
            raise WorktreeError("WORKTREE_REGISTER_FAILED",
                                "工作树已创建但登记失败，目录保留在 " + str(path) +
                                "；先修复台账并register --created，未登记前停止开发：" + str(error))
        return {"success": True, "id": args.id, "created": True, "duplicate": False, "record": record}


def summary(cache, item_id):
    try:
        with locked(registry_path(cache)):
            rows = [r for r in read(cache)["records"] if r["cache"] == str(primary_cache(cache))
                    and r["demand_id"] == item_id]
        return {"registered": len(rows), "remaining": sum(r["state"] != "removed" for r in rows),
                "created": sum(r["created_by_task"] and r["state"] != "removed" for r in rows),
                "removed": sum(r["state"] == "removed" for r in rows)}
    except WorktreeError as error:
        return {"error": str(error)}


def process_directories():
    try:
        result = subprocess.run(["/usr/sbin/lsof" if Path("/usr/sbin/lsof").exists() else "lsof",
                                 "-nP", "-a", "-u", str(os.getuid()), "-d", "cwd", "-F", "pn"],
                                capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise WorktreeError("PROCESS_CHECK_FAILED", "无法核对工作树中的运行进程")
    if result.returncode not in (0, 1):
        raise WorktreeError("PROCESS_CHECK_FAILED", "无法核对工作树中的运行进程")
    rows, pid = [], None
    for line in os.fsdecode(result.stdout).splitlines():
        if line.startswith("p"):
            pid = line[1:]
        elif line.startswith("n") and pid:
            rows.append((pid, line[1:]))
    if not rows:
        raise WorktreeError("PROCESS_CHECK_FAILED", "进程核对未返回目录，已停止清理")
    return rows


def _preview(cache, item_id, value, task, only_id=None):
    own = [r for r in value["records"] if r["cache"] == str(primary_cache(cache)) and r["demand_id"] == item_id
           and (only_id is None or r["id"] == only_id)]
    rows = []
    processes = None
    for record in own:
        row = dict(record, eligible=False, reason="", ignored_files=False)
        if record["state"] == "removed":
            row["reason"] = "已清理"
        elif not Path(record["path"]).exists():
            row["reason"] = "目录已不存在，无需删除"
        else:
            try:
                info = worktree_info(record["path"])
                row["current"] = info
                if any(info[k] != record[k] for k in ("identity", "git_dir", "common_dir", "branch")):
                    raise WorktreeError("IDENTITY_CHANGED", "目录或分支已变化，请核对后重新登记")
                if not record["created_by_task"]:
                    raise WorktreeError("OWNERSHIP_UNKNOWN", "仅记录使用，尚未确认由本需求创建")
                if task["status"] != "已完成":
                    raise WorktreeError("NOT_COMPLETED", "需求尚未完结")
                if info["locked"]:
                    raise WorktreeError("LOCKED_WORKTREE", "Git 工作树已锁定")
                for other in value["records"]:
                    if other["state"] != "removed" and other["path"] == record["path"] and (
                            other["cache"] != record["cache"] or other["demand_id"] != item_id):
                        if other["cache"] != record["cache"]:
                            raise WorktreeError("SHARED_WORKTREE", "另一份看板缓存仍关联此目录，暂不清理")
                        try:
                            other_task = demand(cache, other["demand_id"])
                        except WorktreeError:
                            other_task = {"status": "未知"}
                        if other_task["status"] != "已完成":
                            raise WorktreeError("SHARED_WORKTREE", "仍被 " + other["demand_id"] + " 使用，暂不清理")
                status = git(record["path"], "status", "--porcelain=v1", "--untracked-files=all")
                if status:
                    raise WorktreeError("DIRTY_WORKTREE", "有未提交或未跟踪文件，先保存后再清理")
                upstream_ref = git(record["path"], "rev-parse", "--symbolic-full-name", "@{upstream}", required=False)
                if info["branch"] != "（游离 HEAD）" and (not upstream_ref or not upstream_ref.startswith(b"refs/remotes/")):
                    raise WorktreeError("NO_REMOTE_UPSTREAM", "未设置远端跟踪分支，尚不能确认代码已推送")
                # Inspect ignored directory ancestry once, even with thousands of build artifacts.
                ignored = git(record["path"], "ls-files", "--others", "--ignored", "--exclude-standard", "-z")
                row["ignored_files"] = bool(ignored)
                checked = set()
                root = Path(record["path"])
                for entry in ignored.split(b"\0"):
                    if not entry:
                        continue
                    candidate = root / os.fsdecode(entry)
                    if candidate.name == ".git":
                        raise WorktreeError("NESTED_REPOSITORY", "包含独立 Git 仓库，暂不清理")
                    parent = candidate if entry.endswith(b"/") else candidate.parent
                    while parent != root and root in parent.parents:
                        if parent in checked:
                            break
                        checked.add(parent)
                        if (parent / ".git").exists():
                            raise WorktreeError("NESTED_REPOSITORY", "包含独立 Git 仓库，暂不清理")
                        parent = parent.parent
                if info["branch"] == "（游离 HEAD）":
                    saved_refs = git(record["path"], "for-each-ref", "--contains=" + info["head"],
                                     "--format=%(refname)", "refs/remotes/")
                    if not saved_refs.strip():
                        raise WorktreeError("UNSAVED_DETACHED_HEAD", "游离HEAD的提交未包含在远端分支中，先保存并推送")
                    row["remote_containing_refs"] = os.fsdecode(saved_refs).splitlines()
                else:
                    upstream = git(record["path"], "rev-parse", "--verify", "@{upstream}", required=False)
                    if not upstream:
                        raise WorktreeError("NO_UPSTREAM", "未设置跟踪分支，尚不能确认代码已推送")
                    ahead = git(record["path"], "rev-list", "--count", "@{upstream}..HEAD")
                    if int(ahead.strip()) != 0:
                        raise WorktreeError("UNPUSHED_COMMITS", "存在尚未推送的提交")
                    row["upstream_commit"] = os.fsdecode(upstream).strip()
                if processes is None:
                    processes = process_directories()
                if any(cwd == record["path"] or cwd.startswith(record["path"] + "/") for _, cwd in processes):
                    raise WorktreeError("RUNNING_PROCESS", "仍有进程使用该工作树，停止后再清理")
                row.update(eligible=True, reason="可清理")
            except (WorktreeError, OSError, ValueError) as error:
                row["reason"] = str(error)
        rows.append(row)
    token = _hash({"task": task, "registry": value, "rows": rows})
    return {"success": True, "id": item_id, "task": task, "rows": rows,
            "eligible_count": sum(r["eligible"] for r in rows), "preview_revision": token}


def preview(cache, item_id):
    with locked(primary_cache(cache)), locked(registry_path(cache)):
        return _preview(cache, item_id, read(cache), demand(cache, item_id))


def cleanup(cache, item_id, expected):
    # Same lock order as feedback: cache, then inventory. Each row is rechecked before Git removal.
    with locked(primary_cache(cache)), locked(registry_path(cache), True):
        value = read(cache)
        task = demand(cache, item_id)
        if task["status"] != "已完成":
            raise WorktreeError("NOT_COMPLETED", "需求未完结，不能清理工作树")
        before = _preview(cache, item_id, value, task)
        if before["preview_revision"] != expected:
            raise WorktreeError("PREVIEW_CHANGED", "需求、台账或工作树已变化，请重新预览")
        results = []
        for row in before["rows"]:
            if not row["eligible"]:
                results.append({"id": row["id"], "removed": False, "reason": row["reason"]})
                continue
            record = next(r for r in value["records"] if r["id"] == row["id"])
            fresh = _preview(cache, item_id, value, task, only_id=row["id"])
            current = next(r for r in fresh["rows"] if r["id"] == row["id"])
            if not current["eligible"] or current.get("current") != row.get("current"):
                results.append({"id": row["id"], "removed": False, "reason": "执行前状态已变化，已跳过"})
                continue
            record["state"] = "removing"
            write(cache, value)
            try:
                # Git refuses dirty/locked trees; never use --force, rm -rf or delete branches.
                git(row["common_dir"], "worktree", "remove", "--", row["path"])
                record.update(state="removed", removed_at=_time())
                results.append({"id": row["id"], "removed": True, "reason": "已清理"})
            except WorktreeError as error:
                record["state"] = "active" if Path(record["path"]).exists() else "removed"
                results.append({"id": row["id"], "removed": record["state"] == "removed", "reason": str(error)})
            write(cache, value)
        return {"success": True, "id": item_id, "results": results,
                "removed_count": sum(r["removed"] for r in results), "rows": _preview(cache, item_id, value, task)["rows"]}


def command(cache, args):
    mode = args.worktree_command
    if mode == "create":
        return create(cache, args)
    if mode == "summary":
        return dict(success=True, id=args.id, summary=summary(cache, args.id))
    if mode == "register":
        with locked(primary_cache(cache)):
            row = register(cache, args.id, args.path, args.created, args.expect_title)
        return {"success": True, "id": args.id, "record": row}
    if mode == "cleanup":
        return cleanup(cache, args.id, args.expect_preview)
    return preview(cache, args.id)
