import os
import pathlib
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

HELPER = pathlib.Path(__file__).resolve().parents[1] / "Tools/audi_local_server.py"
NODE = shutil.which("node")


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def listening(value):
    with socket.socket() as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", value)) == 0


def until(predicate, seconds=6):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


@unittest.skipUnless(NODE, "Node is required for process cleanup integration tests")
class AudiSupervisorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="DBoardAudiSupervisor-")
        self.repo = pathlib.Path(self.temp.name)
        self.next = self.repo / "node_modules/next/dist/bin/next"
        self.next.parent.mkdir(parents=True)
        self.next.write_text("""
const http = require('http');
const cp = require('child_process');
const port = Number(process.argv[process.argv.indexOf('--port') + 1]);
const childPort = Number(process.env.FIXTURE_CHILD_PORT);
const worker = cp.spawn(process.execPath, ['-e',
  "require('http').createServer((req,res)=>res.end('child')).listen(" + childPort + ", '127.0.0.1', ()=>process.send('ready'))"
], {stdio: ['ignore', 'inherit', 'inherit', 'ipc']});
http.createServer((req,res)=>res.end('parent')).listen(port, '127.0.0.1');
// Exit after the worker is listening; slow Node startup must not invalidate the cleanup scenario.
if (process.env.FIXTURE_ROOT_EXIT) worker.once('message', ()=>setTimeout(()=>process.exit(3), 500));
""", encoding="utf-8")
        self.port, self.child_port = port(), port()
        self.log = (self.repo / "process.log").open("wb")
        self.processes = []
        self.env = dict(os.environ, FIXTURE_CHILD_PORT=str(self.child_port))

    def tearDown(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        self.log.close()
        self.temp.cleanup()

    def args(self, parent):
        return ["/usr/bin/python3", str(HELPER), "--repo", str(self.repo),
                "--node", NODE, "--port", str(self.port), "--parent", str(parent)]

    def start(self, env=None):
        process = subprocess.Popen(self.args(os.getpid()), env=env or self.env,
                                   stdout=self.log, stderr=self.log)
        self.processes.append(process)
        return process

    def test_stop_cleans_next_and_worker_without_touching_another_listener(self):
        with socket.socket() as unrelated:
            unrelated.bind(("127.0.0.1", 0))
            unrelated.listen()
            other_port = unrelated.getsockname()[1]
            process = self.start()
            self.assertTrue(until(lambda: listening(self.port) and listening(self.child_port)))
            self.assertEqual(os.getpgid(process.pid), process.pid)
            process.terminate()
            process.wait(timeout=5)
            self.assertTrue(until(lambda: not listening(self.port) and not listening(self.child_port)))
            self.assertTrue(listening(other_port))

    def test_next_root_exit_also_cleans_worker(self):
        process = self.start(dict(self.env, FIXTURE_ROOT_EXIT="1"))
        self.assertTrue(until(lambda: listening(self.child_port)))
        process.wait(timeout=5)
        self.assertTrue(until(lambda: not listening(self.port) and not listening(self.child_port)))

    def test_port_collision_does_not_kill_or_adopt_external_listener(self):
        with socket.socket() as unrelated:
            unrelated.bind(("127.0.0.1", self.port))
            unrelated.listen()
            process = self.start()
            process.wait(timeout=5)
            self.assertTrue(listening(self.port))
            self.assertTrue(until(lambda: not listening(self.child_port)))

    def test_parent_disappearing_cleans_entire_service(self):
        launcher = subprocess.Popen(
            ["/usr/bin/python3", "-c",
             "import os,sys,subprocess,time; "
             "p=subprocess.Popen(sys.argv[1:]+['--parent',str(os.getpid())],stdout=sys.stderr,stderr=sys.stderr); "
             "print(p.pid,flush=True); time.sleep(60)"] + self.args(os.getpid())[:-2],
            env=self.env, stdout=subprocess.PIPE, stderr=self.log)
        self.processes.append(launcher)
        supervisor_pid = int(launcher.stdout.readline())
        self.assertTrue(until(lambda: listening(self.port) and listening(self.child_port)))
        launcher.kill()
        launcher.wait(timeout=5)
        self.assertTrue(until(lambda: not listening(self.port) and not listening(self.child_port)),
                        "Service must not survive a killed DBoard parent")
        launcher.stdout.close()
        # The supervisor is reaped by launchd after its parent disappears.
        self.assertTrue(until(lambda: not self.group_exists(supervisor_pid)))

    @staticmethod
    def group_exists(pid):
        try:
            os.killpg(pid, 0)
            return True
        except ProcessLookupError:
            return False


if __name__ == "__main__":
    unittest.main()
