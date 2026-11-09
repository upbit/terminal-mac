import fcntl
import json
import os
from pathlib import Path
import subprocess
import signal
import tempfile
import unittest

BINARY = Path(os.environ.get("TERMINAL_MAC_TEST_BINARY", ".build/remote-observer/debug/terminal-mac")).resolve()


class ConnectCLITests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="remote-connect-cli-")
        self.root = Path(self.work.name)
        self.env = {**os.environ, "TERMINAL_MAC_HOME": str(self.root), "TERMINAL_MAC_PYTHON": "/not-installed/python"}

    def tearDown(self):
        self.work.cleanup()

    def run_cli(self, *args):
        return subprocess.run([str(BINARY), *args], env=self.env, input="", capture_output=True, text=True, timeout=10)

    def machine(self):
        directory = self.root / "machines/default"
        directory.mkdir(parents=True)
        (directory / "machine.json").write_text(json.dumps({"name": "default", "cpu": 4, "memoryGiB": 4,
            "diskGiB": 64, "width": 1280, "height": 800, "network": True, "installed": True}))
        return directory

    def test_observe_and_port_only_report_migration(self):
        for args, message in [(('observe', 'default'), "observe was removed"),
                              (('connect', 'default', '--port', '0'), "--port was removed")]:
            result = self.run_cli(*args)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(message, result.stderr)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_missing_vm_fails_before_authentication(self):
        result = self.run_cli('connect', '--server', 'https://example.net')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)
        self.assertNotIn("Authentication", result.stderr)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_lock_conflict_precedes_login_and_configuration(self):
        directory = self.machine()
        with (directory / "observer.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_cli('connect', '--server', 'https://example.net', '--force-login')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("observer.lock", result.stderr)
        self.assertFalse((directory / "remote-observer.json").exists())
        self.assertFalse((directory / "runtime.lock").exists())

    def test_noninteractive_no_server_exits_and_releases_lock(self):
        directory = self.machine()
        result = self.run_cli('connect')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Noninteractive connect requires", result.stderr)
        with (directory / "observer.lock").open() as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.assertFalse((directory / "runtime.lock").exists())

    def test_existing_commands_and_help_remain_available(self):
        result = self.run_cli('up', 'test', '--plan')
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["name"], "test")
        self.assertEqual(list(self.root.iterdir()), [])
        help_result = self.run_cli('help')
        self.assertIn("connect [NAME]", help_result.stdout)
        self.assertNotIn("observe [NAME]", help_result.stdout)

    def test_worker_frontend_eof_and_signal_release_lock(self):
        directory = self.machine()
        for use_signal in (False, True):
            process = subprocess.Popen([str(BINARY), '__observer', 'default'], env=self.env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                message = json.loads(process.stdout.readline())
                self.assertEqual(message["kind"], "locked")
                with (directory / "observer.lock").open() as lock:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                if use_signal:
                    process.send_signal(signal.SIGTERM)
                else:
                    process.stdin.close()
                    process.stdin = None
                process.communicate(timeout=5)
                with (directory / "observer.lock").open() as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_disconnect_without_worker_is_idempotent(self):
        directory = self.machine()
        result = self.run_cli('disconnect')
        self.assertEqual(result.returncode, 0)
        self.assertIn("not connected", result.stdout)
        self.assertFalse((directory / "runtime.lock").exists())


if __name__ == "__main__":
    unittest.main()
