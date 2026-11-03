#!/bin/bash
# Sync only the public overview; full context and local edits are never reconstructed from cloud.
set -euo pipefail
export PATH="$HOME/.qoderwork/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export DBOARD_SYNC_SCRIPT="${BASH_SOURCE[0]}"
export DBOARD_SYNC_FORCE="${1:-}"
python3 -I - <<'PYTHON'
import datetime, fcntl, hashlib, json, os, re, subprocess, sys, tempfile
from pathlib import Path

script_dir = Path(os.environ['DBOARD_SYNC_SCRIPT']).resolve().parent
module_dir = script_dir / ('Tools' if (script_dir / 'Tools/dboard_overview.py').is_file() else 'CLI')
sys.path.insert(0, str(module_dir))
from dboard_overview import render, digest as overview_digest, receipt, PREFIX, NODE_PREFIX
from dboard_ai import CLIError

cache = Path.home() / '.claude/demand-center-cache.md'

def body(content):
    return '\n'.join(line for line in content.split('\n')
                     if not line.startswith(('<!-- synced:', '<!-- synced-hash:', PREFIX, NODE_PREFIX)))

def digest(content):
    return hashlib.sha256(body(content).encode('utf-8')).hexdigest()

def emit(status, success=False):
    print(json.dumps({'success': success, 'status': status}, ensure_ascii=False))

def business_response(output):
    text = output.decode('utf-8', errors='replace')
    decoder = json.JSONDecoder()
    for match in re.finditer(r'\{', text):
        try:
            value, end = decoder.raw_decode(text, match.start())
        except ValueError:
            continue
        if isinstance(value, dict) and not text[end:].strip():
            return value
    return {}

def save_receipt(current, node, sent_hash, stamp):
    updated = ('<!-- synced: ' + stamp + ' -->\n<!-- synced-hash: ' + digest(current) +
               ' -->\n' + PREFIX + sent_hash + ' -->\n' + NODE_PREFIX + node + ' -->\n' + body(current))
    fd, temporary = tempfile.mkstemp(prefix='dboard-cache-', dir=cache.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            os.fchmod(output.fileno(), cache.stat().st_mode & 0o777)
            output.write(updated); output.flush(); os.fsync(output.fileno())
        os.replace(temporary, cache)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

try:
    with open(str(cache) + '.sync.lock', 'a') as sync_lock:
        fcntl.flock(sync_lock, fcntl.LOCK_EX)
        node = os.environ.get('DBOARD_NODE_ID', '')
        if not node:
            zshrc = Path.home() / '.zshrc'
            if zshrc.exists():
                for line in zshrc.read_text().splitlines():
                    m = re.fullmatch(r'''export DBOARD_NODE_ID=["']?([^"'\s]+)["']?''', line.strip())
                    if m:
                        node = m.group(1)
        if not node:
            emit('missing-node'); sys.exit(1)
        if not re.fullmatch(r'[A-Za-z0-9_-]+', node):
            emit('invalid-node'); sys.exit(1)
        with open(str(cache) + '.lock', 'a') as cache_lock:
            fcntl.flock(cache_lock, fcntl.LOCK_EX)
            snapshot = cache.read_text()
        payload = render(snapshot)
        sent_hash = overview_digest(snapshot)
        skip = os.environ.get('DBOARD_SYNC_FORCE') != '--force' and receipt(snapshot, node)
        if skip:
            stamp_match = re.search(r'^<!-- synced: ([^\n]+) -->$', snapshot, re.M)
            stamp = stamp_match[1] if stamp_match else datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
        else:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.md', encoding='utf-8') as upload:
                upload.write(payload); upload.flush()
                result = subprocess.run(['dws', 'doc', 'update', '--node', node,
                    '--content-file', upload.name, '--mode', 'overwrite', '--yes', '--format', 'json'],
                    capture_output=True, timeout=90)
                response = business_response(result.stdout)
                if result.returncode != 0 or response.get('success') is not True:
                    emit('remote-failed'); sys.exit(1)
            stamp = datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
        with open(str(cache) + '.lock', 'a') as cache_lock:
            fcntl.flock(cache_lock, fcntl.LOCK_EX)
            current = cache.read_text()
            changed = overview_digest(current) != sent_hash
            # Record what the server actually received without replacing concurrent local edits.
            save_receipt(current, node, sent_hash, stamp)
        if changed:
            emit('changed'); sys.exit(75)
        emit('unchanged' if skip else 'ok', True)
except CLIError:
    emit('invalid-overview'); sys.exit(1)
except (OSError, subprocess.SubprocessError, ValueError):
    emit('sync-failed'); sys.exit(1)
PYTHON
