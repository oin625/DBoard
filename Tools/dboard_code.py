"""Read-only code fingerprints shared by DBoard and its AI feedback CLI."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


class CodeError(Exception):
    pass


def git(path, *args):
    try:
        result = subprocess.run(["git", "--no-optional-locks", "-C", str(path), *args],
                                capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        raise CodeError("无法读取代码仓库")
    if result.returncode:
        raise CodeError("无法读取代码仓库或提交")
    return result.stdout


def digest(value):
    return hashlib.sha256(value).hexdigest()


def validate_snapshots(values):
    if not isinstance(values, list) or not values:
        return False
    paths = set()
    for value in values:
        if not isinstance(value, dict):
            return False
        path, branch = value.get("path"), value.get("branch")
        if not isinstance(path, str) or not path.startswith("/") or path in paths:
            return False
        if not isinstance(branch, str) or not branch or any(ord(c) < 32 for c in path + branch):
            return False
        if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value.get("commit", "")):
            return False
        if not re.fullmatch(r"[0-9a-f]{64}", value.get("dirty_hash", "")):
            return False
        paths.add(path)
    return True


def snapshot_once(repository):
    path = Path(repository["path"]).expanduser().resolve()
    branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD").decode().strip()
    if branch != repository["branch"]:
        raise CodeError("当前分支与需求记录不一致")
    commit = git(path, "rev-parse", "--verify", "HEAD").decode().strip()
    dirty = hashlib.sha256()
    for args in (("diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--"),
                 ("diff", "--no-ext-diff", "--no-textconv", "--binary", "--cached", "HEAD", "--")):
        dirty.update(git(path, *args))
        dirty.update(b"\0")
    for name in sorted(git(path, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")):
        if not name:
            continue
        file = path / os.fsdecode(name)
        try:
            info = file.lstat()
            content = hashlib.sha256()
            if stat.S_ISLNK(info.st_mode):
                content.update(os.fsencode(os.readlink(file)))
            elif stat.S_ISREG(info.st_mode):
                with file.open("rb") as handle:
                    while True:
                        chunk = handle.read(65536)
                        if not chunk:
                            break
                        content.update(chunk)
            else:
                raise CodeError("工作区包含无法核对的未跟踪目录")
            dirty.update(name + b"\0" + str(stat.S_IFMT(info.st_mode) | (info.st_mode & 0o111)).encode() +
                         b"\0" + content.digest() + b"\0")
        except OSError:
            raise CodeError("工作区文件正在变化或无法读取")
    return {"path": str(path), "branch": branch, "commit": commit, "dirty_hash": dirty.hexdigest()}


def capture(repositories):
    if not repositories:
        raise CodeError("尚未记录实际开发仓库")
    result = []
    for repository in sorted(repositories, key=lambda value: value["path"]):
        first = snapshot_once(repository)
        if snapshot_once(repository) != first:
            raise CodeError("核对期间代码发生变化，请重试")
        result.append(first)
    if not validate_snapshots(result):
        raise CodeError("代码版本无法核实")
    return result


def revision(snapshots):
    return digest(json.dumps(sorted(snapshots, key=lambda value: value["path"]),
                             sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode())


def review(saved, repositories, current=None):
    if not saved:
        return {"needs_review": True, "reason": "旧结论未绑定代码 · 需重新核验"}
    try:
        current = capture(repositories) if current is None else current
    except (CodeError, KeyError, TypeError):
        return {"needs_review": True, "reason": "代码版本无法核实 · 需重新核验"}
    if sorted(saved, key=lambda value: value["path"]) != sorted(current, key=lambda value: value["path"]):
        return {"needs_review": True, "reason": "代码已变更 · 需重新核验"}
    return {"needs_review": False, "reason": None}


def main():
    # GUI calls this only on opening/refreshing the panel; no polling or repository writes.
    requests = json.loads(sys.argv[1])
    reviews, cache = [], {}
    for request in requests:
        repositories = request.get("repositories", [])
        key = json.dumps(repositories, sort_keys=True)
        if key not in cache:
            try:
                cache[key] = capture(repositories)
            except (CodeError, KeyError, TypeError):
                cache[key] = None
        result = (review(request.get("code"), repositories, cache[key]) if cache[key] is not None else
                  {"needs_review": True, "reason": "代码版本无法核实 · 需重新核验"})
        reviews.append(dict(id=request["id"], code_revision=revision(cache[key]) if cache[key] is not None else None, **result))
    print(json.dumps({"success": True, "reviews": reviews}, ensure_ascii=False))


if __name__ == "__main__":
    main()
