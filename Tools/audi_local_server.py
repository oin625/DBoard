#!/usr/bin/env python3
"""Own one Next dev process group; clean up when DBoard stops or disappears."""
import argparse
import errno
import os
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--parent", type=int, required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--node", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("Invalid local port")

    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        os.setsid()
    except OSError as error:
        # Foundation Process may already create a separate process group.
        if error.errno != errno.EPERM or os.getpgrp() != os.getpid():
            raise
    if os.getpgrp() != os.getpid():
        raise RuntimeError("Refusing to run without an owned process group")

    child = None
    try:
        if stopping or os.getppid() != args.parent:
            return
        child = subprocess.Popen(
            [args.node, os.path.join(args.repo, "node_modules/next/dist/bin/next"),
             "dev", "--hostname", "127.0.0.1", "--port", str(args.port)],
            cwd=args.repo, stdin=subprocess.DEVNULL)
        while not stopping and os.getppid() == args.parent:
            if child.poll() is not None:
                print("Next dev exited: {}".format(child.returncode), flush=True)
                break
            time.sleep(0.2)
    finally:
        if child is not None and os.getpgrp() == os.getpid():
            # The group leader stays alive until the final group kill, so its PGID
            # cannot be reused. Never signal a saved PID or another process group.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            os.killpg(os.getpid(), signal.SIGTERM)
            deadline = time.monotonic() + 1.2
            while time.monotonic() < deadline:
                child.poll()  # Reap the immediate child; descendants share our group.
                time.sleep(0.1)
            os.killpg(os.getpid(), signal.SIGKILL)


if __name__ == "__main__":
    main()
