#!/usr/bin/env python3
"""Offline subprocess tests: no product tests, installs, network, or builds."""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

GATE = Path(__file__).with_name("cstack-test-gate.py").resolve()


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cstack-gate-test-")
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith("SUME_TEST_GATE") and k != "GITHUB_ACTIONS"}
        self.env["CSTACK_TEST_GATE_TESTING"] = "1"
        self.clients = []
        self.streams = []

    def tearDown(self):
        for client in self.clients:
            if client.poll() is None:
                client.terminate()
                try:
                    client.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=3)
        for stream in self.streams:
            stream.close()
        self.temp.cleanup()

    def prefix(self):
        return [sys.executable, str(GATE), "--test-state-dir", str(self.state)]

    def run_gate(self, *args, env=None, cwd=None):
        return subprocess.run(self.prefix() + list(args), env=env or self.env,
                              cwd=cwd or self.root, capture_output=True, text=True, timeout=12)

    def spawn(self, kind, script, env=None, cwd=None):
        index = len(self.clients)
        output = self.root / ("out-%s" % index)
        stream = output.open("w")
        self.streams.append(stream)
        client = subprocess.Popen(self.prefix() + [kind, "--", sys.executable, "-c", script],
                                  env=env or self.env, cwd=cwd or self.root,
                                  stdout=stream, stderr=stream)
        self.clients.append(client)
        return client, output

    def eventually(self, predicate, seconds=8):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(0.05)
        self.fail("condition did not become true; outputs=" + "\n".join(
            p.read_text() for p in self.root.glob("out-*")))

    def jobs(self):
        path = self.state / "queue.json"
        return json.loads(path.read_text())["jobs"] if path.exists() else []

    def hold(self, name):
        return ("from pathlib import Path; import time; "
                "Path(%r).touch();\nwhile not Path(%r).exists(): time.sleep(.05)\n" %
                (str(self.root / (name + ".started")), str(self.root / (name + ".release"))))

    def test_fifo_test_xor_build(self):
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        second, second_log = self.spawn("build", self.hold("b"))
        self.eventually(lambda: len(self.jobs()) == 2)
        third, _ = self.spawn("test", self.hold("c"))
        self.eventually(lambda: len(self.jobs()) == 3)
        self.assertFalse((self.root / "b.started").exists())
        self.assertFalse((self.root / "c.started").exists())
        (self.root / "a.release").touch()
        self.assertEqual(first.wait(timeout=8), 0)
        self.eventually(lambda: (self.root / "b.started").exists())
        self.assertFalse((self.root / "c.started").exists())
        (self.root / "b.release").touch()
        self.assertEqual(second.wait(timeout=8), 0)
        self.eventually(lambda: (self.root / "c.started").exists())
        (self.root / "c.release").touch()
        self.assertEqual(third.wait(timeout=8), 0)
        self.assertIn("position=1", second_log.read_text())
        self.assertEqual(self.jobs(), [])

    def test_nested_lease_reuses_single_ticket_and_checks(self):
        inner = self.prefix() + ["test", "--", sys.executable, "-c", "print('nested-ok')"]
        check = self.prefix() + ["check", "test"]
        script = "import subprocess; subprocess.run(%r, check=True); subprocess.run(%r, check=True)" % (check, inner)
        result = self.run_gate("test", "--", sys.executable, "-c", script)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nested-ok", result.stdout)
        self.assertIn("reuse ticket=1", result.stderr)
        self.assertEqual(json.loads((self.state / "queue.json").read_text())["next"], 2)

    def test_nested_test_cannot_upgrade_to_build(self):
        inner = self.prefix() + ["build", "--", sys.executable, "-c", "raise Exception('must not run')"]
        result = self.run_gate("test", "--", sys.executable, "-c",
                               "import subprocess,sys; sys.exit(subprocess.call(%r))" % inner)
        self.assertEqual(result.returncode, 125)
        self.assertIn("cannot admit nested build", result.stderr)

    def test_stolen_lease_from_unrelated_process_rejected(self):
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        stolen = self.jobs()[0]["lease"]
        result = self.run_gate("test", "--", sys.executable, "-c", "print('bad')",
                               env={**self.env, "SUME_TEST_GATE_LEASE": stolen})
        self.assertEqual(result.returncode, 125)
        self.assertNotIn("bad", result.stdout)
        (self.root / "a.release").touch()
        self.assertEqual(first.wait(timeout=8), 0)

    def test_sigterm_cleans_grandchild_and_releases(self):
        terminated = self.root / "terminated"
        marker = self.root / "grandchild"
        child = ("import signal,time; from pathlib import Path; "
                 "signal.signal(signal.SIGTERM, lambda *_: (Path(%r).touch(), exit(0))); "
                 "Path(%r).touch(); time.sleep(60)" % (str(terminated), str(marker)))
        script = "import subprocess,time; subprocess.Popen(%r); time.sleep(60)" % [sys.executable, "-c", child]
        first, _ = self.spawn("test", script)
        self.eventually(marker.exists)
        first.terminate()
        self.assertEqual(first.wait(timeout=8), 143)
        self.assertTrue(terminated.exists())
        self.assertEqual(self.jobs(), [])
        result = self.run_gate("build", "--", sys.executable, "-c", "print('next-ok')")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_supervisor_sigkill_watchdog_cleans_group(self):
        terminated = self.root / "terminated"
        script = ("import signal,time; from pathlib import Path; "
                  "signal.signal(signal.SIGTERM, lambda *_: (Path(%r).touch(), exit(0))); "
                  "Path(%r).touch(); time.sleep(60)" %
                  (str(terminated), str(self.root / "started")))
        first, _ = self.spawn("test", script)
        self.eventually(lambda: (self.root / "started").exists())
        first.kill()
        first.wait(timeout=5)
        self.eventually(terminated.exists)
        result = self.run_gate("test", "--", sys.executable, "-c", "print('recovered')")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.jobs(), [])

    def test_wait_deadline_cancels_without_execution(self):
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        result = self.run_gate("build", "--", sys.executable, "-c", "print('should-not-run')",
                               env={**self.env, "SUME_TEST_GATE_WAIT_SECONDS": ".1"})
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(self.jobs()), 1)
        (self.root / "a.release").touch()
        first.wait(timeout=8)

    def test_orphan_payload_retains_capacity_if_guardian_is_killed(self):
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        group = self.jobs()[0]["group"]
        os.kill(group, signal.SIGKILL)  # Kill guardian PID only, leave payload.
        self.assertEqual(first.wait(timeout=8), 137)
        result = self.run_gate("build", "--", sys.executable, "-c", "print('bad')",
                               env={**self.env, "SUME_TEST_GATE_WAIT_SECONDS": ".1"})
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.jobs()[0]["state"], "orphan")
        (self.root / "a.release").touch()
        result = self.run_gate("build", "--", sys.executable, "-c", "print('after-orphan')")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_periodic_wait_logging(self):
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        second, output = self.spawn("test", "print('second')",
                                    env={**self.env, "SUME_TEST_GATE_LOG_SECONDS": ".1"})
        self.eventually(lambda: output.read_text().count("position=") >= 2)
        (self.root / "a.release").touch()
        self.assertEqual(first.wait(timeout=8), 0)
        self.assertEqual(second.wait(timeout=8), 0)

    def test_waiting_sigterm_removes_ticket(self):
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        second, _ = self.spawn("build", "print('bad')")
        self.eventually(lambda: len(self.jobs()) == 2)
        second.terminate()
        self.assertEqual(second.wait(timeout=8), 143)
        self.assertEqual(len(self.jobs()), 1)
        (self.root / "a.release").touch()
        first.wait(timeout=8)

    def test_actions_exact_bypass_no_state_no_budget_changes(self):
        env = {**self.env, "GITHUB_ACTIONS": "true", "SUME_TEST_GATE_PROFILE": "invalid"}
        result = self.run_gate("test", "--", sys.executable, "-c",
                               "import os,sys; print(os.getenv('SUME_TEST_GATE_MAX_WORKERS')); sys.exit(7)", env=env)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout.strip(), "None")
        self.assertFalse(self.state.exists())

    def test_budget_env_and_ci_flag_does_not_bypass(self):
        result = self.run_gate("test", "--", sys.executable, "-c",
                               "import os,json; print(json.dumps({k:os.getenv(k) for k in "
                               "['SUME_TEST_GATE_MAX_WORKERS','npm_config_workspace_concurrency','CI']}))",
                               env={**self.env, "CI": "1", "SUME_TEST_GATE": "0"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"SUME_TEST_GATE_MAX_WORKERS": "2",
                                                    "npm_config_workspace_concurrency": "1", "CI": "1"})

    def test_direct_tool_arguments_and_smaller_worker_cap(self):
        for name, arguments, expected in [
            ("vitest", ["run", "--maxWorkers=8"], "--maxWorkers=2"),
            ("vitest", ["run", "--maxWorkers=1"], "--maxWorkers=1"),
            ("turbo", ["run", "build", "--concurrency=9"], "--concurrency=1"),
            ("pnpm", ["--filter", "pkg", "test"], "--workspace-concurrency=1"),
        ]:
            tool = self.root / name
            tool.write_text("#!%s\nimport json,sys; print(json.dumps(sys.argv[1:]))\n" % sys.executable)
            tool.chmod(0o755)
            result = self.run_gate("test", "--", str(tool), *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(expected, json.loads(result.stdout))
        result = self.run_gate("test", "--", str(self.root / "turbo"), "run", "test", "--parallel")
        self.assertEqual(result.returncode, 125)

    def test_profile_conflict_and_busy_reconfigure(self):
        self.assertEqual(self.run_gate("configure", "mini16").returncode, 0)
        result = self.run_gate("test", "--", "true", env={**self.env, "SUME_TEST_GATE_PROFILE": "host64"})
        self.assertEqual(result.returncode, 125)
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        self.assertEqual(self.run_gate("configure", "host64").returncode, 125)
        (self.root / "a.release").touch()
        first.wait(timeout=8)

    def test_host64_two_tests_but_only_one_build(self):
        self.assertEqual(self.run_gate("configure", "host64").returncode, 0)
        first, _ = self.spawn("test", self.hold("a"))
        second, _ = self.spawn("test", self.hold("b"))
        self.eventually(lambda: (self.root / "a.started").exists() and (self.root / "b.started").exists())
        (self.root / "a.release").touch()
        (self.root / "b.release").touch()
        self.assertEqual(first.wait(timeout=8), 0)
        self.assertEqual(second.wait(timeout=8), 0)
        third, _ = self.spawn("build", self.hold("c"))
        self.eventually(lambda: (self.root / "c.started").exists())
        fourth, _ = self.spawn("build", self.hold("d"))
        self.eventually(lambda: len(self.jobs()) == 2)
        self.assertFalse((self.root / "d.started").exists())
        (self.root / "c.release").touch()
        self.assertEqual(third.wait(timeout=8), 0)
        self.eventually(lambda: (self.root / "d.started").exists())
        (self.root / "d.release").touch()
        self.assertEqual(fourth.wait(timeout=8), 0)

    def test_source_change_while_waiting_rejected(self):
        repo = self.root / "repo"
        repo.mkdir()
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "source").write_text("before")
        subprocess.run(["git", "-C", str(repo), "add", "source"], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
                        "commit", "-qm", "fixture"], check=True)
        first, _ = self.spawn("test", self.hold("a"))
        self.eventually(lambda: (self.root / "a.started").exists())
        second, output = self.spawn("test", "print('bad')", cwd=repo)
        self.eventually(lambda: len(self.jobs()) == 2)
        (repo / "source").write_text("after")
        (self.root / "a.release").touch()
        first.wait(timeout=8)
        self.assertEqual(second.wait(timeout=8), 125)
        self.assertIn("source changed while queued", output.read_text())

    def test_command_failure_preserved(self):
        result = self.run_gate("test", "--", sys.executable, "-c", "raise SystemExit(23)")
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(self.jobs(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
