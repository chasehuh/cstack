#!/usr/bin/env python3
"""Cooperative, per-host-account FIFO admission for heavy local commands."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import uuid

PROFILES = {
    "mini16": {"total": 1, "test": 1, "build": 1, "workers": 2},
    "host64": {"total": 2, "test": 2, "build": 1, "workers": 4},
}
STOP = 0


def log(message):
    print("test-gate: " + message, file=sys.stderr, flush=True)


def stopped(signum, _frame):
    global STOP
    STOP = signum


def processes():
    process = subprocess.Popen(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat=,lstart="],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True,
        env={**os.environ, "LC_ALL": "C"},
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        raise ValueError("process inspection timed out; refusing speculative capacity")
    if process.returncode:
        raise ValueError("cannot inspect process ownership: " + stderr.strip())
    rows = {}
    for line in stdout.splitlines():
        parts = line.split(None, 4)
        if len(parts) == 5:
            pid, ppid, pgid, status, start = parts
            rows[int(pid)] = {
                "parent": int(ppid), "group": int(pgid),
                "start": start.strip(), "zombie": status.startswith("Z"),
            }
    rows.pop(process.pid, None)
    return rows


def boot_id():
    if sys.platform == "darwin":
        return subprocess.check_output(["sysctl", "-n", "kern.boottime"], text=True).strip()
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def identity_alive(row, procs):
    process = procs.get(row["pid"])
    return bool(process and not process["zombie"] and process["start"] == row["start"])


def group_alive(group, procs):
    return any(p["group"] == group and not p["zombie"] for p in procs.values())


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix=".write-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


class Queue:
    def __init__(self, root):
        self.root = root
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.boot = boot_id()

    @contextlib.contextmanager
    def locked(self):
        # This inode is permanent. Never unlink a live flock mutex.
        with (self.root / "mutex").open("a+") as mutex:
            fcntl.flock(mutex, fcntl.LOCK_EX)
            path = self.root / "queue.json"
            state = json.loads(path.read_text()) if path.exists() else {
                "version": 1, "boot": self.boot, "next": 1, "jobs": [],
            }
            if state.get("version") != 1:
                raise ValueError("unsupported queue version; refusing admission")
            if state["boot"] != self.boot:
                state.update(boot=self.boot, jobs=[])
            procs = processes()
            kept = []
            for job in state["jobs"]:
                if identity_alive(job, procs):
                    kept.append(job)
                elif job["state"] == "waiting":
                    continue
                elif job.get("group"):
                    if group_alive(job["group"], procs):
                        job["state"] = "orphan"
                        kept.append(job)
                elif job["state"] == "starting":
                    # No GO byte can have been sent before group was persisted.
                    continue
                else:
                    job["state"] = "quarantined"
                    kept.append(job)
            state["jobs"] = kept
            try:
                yield state, procs
            finally:
                atomic_json(path, state)

    def profile(self):
        path = self.root / "profile.json"
        name = json.loads(path.read_text())["profile"] if path.exists() else "mini16"
        if name not in PROFILES:
            raise ValueError("invalid host profile")
        requested = os.environ.get("SUME_TEST_GATE_PROFILE")
        if requested and requested != name:
            raise ValueError("profile conflicts with host; use configure while queue is empty")
        return name

    def finish(self, ticket):
        with self.locked() as (state, procs):
            for job in list(state["jobs"]):
                if job["ticket"] == ticket:
                    if job.get("group") and group_alive(job["group"], procs):
                        job["state"] = "orphan"
                        log("ticket=%s retains capacity for surviving group=%s" % (ticket, job["group"]))
                    else:
                        state["jobs"].remove(job)


def fingerprint():
    """Hash source state, never print diff contents or environment values."""
    root = None
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL)
    try:
        root = git("rev-parse", "--show-toplevel").decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    digest = hashlib.sha256(git("diff", "HEAD", "--binary", "--no-ext-diff"))
    for raw in sorted(git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0")):
        if not raw:
            continue
        path = Path(root) / os.fsdecode(raw)
        digest.update(raw + b"\0")
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        else:
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(65536), b""):
                    digest.update(chunk)
    return {"root": root, "head": git("rev-parse", "HEAD").decode().strip(),
            "base": os.environ.get("CI_BASE_SHA", os.environ.get("GITHUB_BASE_SHA", "")),
            "digest": digest.hexdigest()}


def limited_option(args, option, ceiling):
    """Replace a known integer option, retaining a caller's smaller ceiling."""
    result = []
    value = ceiling
    index = 0
    while index < len(args):
        item = args[index]
        if item == option or item.startswith(option + "="):
            if item == option:
                index += 1
                if index == len(args):
                    raise ValueError("missing " + option + " value")
                supplied = args[index]
            else:
                supplied = item.split("=", 1)[1]
            try:
                count = int(supplied)
            except ValueError:
                raise ValueError(option + " must be a positive integer under the gate")
            if count < 1:
                raise ValueError(option + " must be a positive integer under the gate")
            value = min(value, count)
        else:
            result.append(item)
        index += 1
    return result + [option + "=" + str(value)]


def budget(command, profile):
    """Adapt directly invoked tools; wrappers must honor the inherited contract."""
    env = dict(os.environ)
    workers = min(PROFILES[profile]["workers"], os.cpu_count() or 1)
    env.update(SUME_TEST_GATE="1", SUME_TEST_GATE_PROFILE=profile,
               SUME_TEST_GATE_PACKAGE_CONCURRENCY="1",
               SUME_TEST_GATE_MAX_WORKERS=str(workers),
               npm_config_workspace_concurrency="1", VITEST_MAX_WORKERS=str(workers))
    args = list(command)
    name = Path(args[0]).name
    if name in ("pnpm", "pnpm.cjs"):
        if "--parallel" in args:
            raise ValueError("pnpm --parallel ignores the package budget; remove it")
        # Put pnpm options before the script so they are not script arguments.
        args = [args[0], "--workspace-concurrency=1", *args[1:]]
        for item in args[2:]:
            if item.startswith("--workspace-concurrency"):
                raise ValueError("remove explicit pnpm concurrency; gate supplies 1")
        if "exec" in args:
            index = args.index("exec") + 1
            if index < len(args) and args[index] in ("vitest", "turbo"):
                tail, _ = budget(args[index:], profile)
                args = args[:index] + tail
    elif name == "vitest":
        args = [args[0], *limited_option(args[1:], "--maxWorkers", workers)]
        if not any(arg in ("run", "--run") for arg in args[1:]):
            args.insert(1, "run")
    elif name == "turbo":
        if "--parallel" in args:
            raise ValueError("turbo --parallel ignores concurrency; remove it")
        args = [args[0], *limited_option(args[1:], "--concurrency", 1)]
    return args, env


def valid_lease(state, procs, kind):
    token = os.environ.get("SUME_TEST_GATE_LEASE")
    if not token:
        return None
    for job in state["jobs"]:
        if job["lease"] != token or job["state"] != "running":
            continue
        if not identity_alive(job, procs):
            break
        # Must belong to this guardian's process tree, not just know a nonce.
        pid = os.getpid()
        seen = set()
        while pid in procs and pid not in seen:
            if pid == job.get("group"):
                if kind == "build" and job["kind"] != "build":
                    raise ValueError("test lease cannot admit nested build; reserve build outside")
                return job
            seen.add(pid)
            pid = procs[pid]["parent"]
    raise ValueError("invalid or stale gate lease; refusing nested admission")


def exit_status(status):
    return os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


def guardian(read_fd, write_fd, command, env):
    """Separate group with a GO handshake and parent-death cleanup watchdog."""
    os.close(write_fd)
    os.setsid()
    parent = os.getppid()
    # No payload can start until the supervisor has durably recorded this group.
    go = os.read(read_fd, 1)
    os.close(read_fd)
    if go != b"G" or STOP or parent == 1 or os.getppid() != parent:
        os._exit(125)
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    child = os.fork()
    if child == 0:
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        try:
            os.execvpe(command[0], command, env)
        except OSError as error:
            log("cannot execute %s: %s" % (command[0], error.strerror))
            os._exit(127)
    code = None
    child_done = False
    cleanup_at = None
    while True:
        if not child_done:
            done, status = os.waitpid(child, os.WNOHANG)
            if done:
                child_done = True
                if code is None:
                    code = exit_status(status)
        if STOP or os.getppid() != parent or code is not None:
            if cleanup_at is None:
                cleanup_at = time.monotonic()
                if code is None:
                    code = 128 + (STOP or signal.SIGTERM)
                # Includes this guardian; its handler only sets STOP.
                os.killpg(os.getpgrp(), signal.SIGTERM)
            procs = processes()
            others = [pid for pid, row in procs.items()
                      if row["group"] == os.getpgrp() and pid != os.getpid() and not row["zombie"]]
            if not others:
                os._exit(code)
            if time.monotonic() - cleanup_at >= 3:
                for pid in others:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                # Keep the guardian alive until the group actually drains.
        time.sleep(0.1)


def seconds(name, default, positive=False):
    value = float(os.environ.get(name, default))
    if not math.isfinite(value) or value < 0 or (positive and value == 0):
        raise ValueError(name + " must be finite and " + ("positive" if positive else "nonnegative"))
    return value


def execute(queue, kind, command):
    profile = queue.profile()
    command, env = budget(command, profile)
    with queue.locked() as (state, procs):
        inherited = valid_lease(state, procs, kind)
        if inherited:
            log("reuse ticket=%s kind=%s" % (inherited["ticket"], kind))
    if inherited:
        os.execvpe(command[0], command, env)

    wait_limit = seconds("SUME_TEST_GATE_WAIT_SECONDS", "0")
    log_interval = seconds("SUME_TEST_GATE_LOG_SECONDS", "30", positive=True)
    source = fingerprint()
    with queue.locked() as (state, procs):
        # Configuration and admission share this mutex; a profile cannot change
        # underneath a queued job.
        if queue.profile() != profile:
            raise ValueError("host profile changed before enqueue")
        ticket = state["next"]
        state["next"] += 1
        state["jobs"].append({
            "ticket": ticket, "pid": os.getpid(), "start": procs[os.getpid()]["start"],
            "kind": kind, "profile": profile, "state": "waiting", "group": None,
            "lease": uuid.uuid4().hex, "created": time.time(), "cwd": os.getcwd(),
            "source": source,
        })
    started = time.monotonic()
    last_log = -float("inf")
    guardian_pid = None
    write_fd = None
    try:
        while True:
            elapsed = time.monotonic() - started
            if STOP:
                return 128 + STOP
            if wait_limit and elapsed >= wait_limit:
                log("ticket=%s wait deadline reached; not executed" % ticket)
                return 124
            with queue.locked() as (state, _procs):
                job = next(j for j in state["jobs"] if j["ticket"] == ticket)
                waiting = [j for j in state["jobs"] if j["state"] == "waiting"]
                active = [j for j in state["jobs"] if j["state"] != "waiting"]
                limits = PROFILES[profile]
                fits = (waiting[0]["ticket"] == ticket and len(active) < limits["total"]
                        and sum(j["kind"] == kind for j in active) < limits[kind])
                if elapsed - last_log >= log_interval:
                    log("ticket=%s kind=%s position=%s wait=%.1fs active=%s" % (
                        ticket, kind, waiting.index(job) + 1, elapsed,
                        ",".join(str(j["ticket"]) for j in active) or "none"))
                    last_log = elapsed
                if fits:
                    job["state"] = "starting"
                    env["SUME_TEST_GATE_LEASE"] = job["lease"]
            if fits:
                break
            time.sleep(0.5)
        if fingerprint() != source:
            raise ValueError("source changed while queued; rerun validation")
        if STOP:
            return 128 + STOP
        read_fd, write_fd = os.pipe()
        guardian_pid = os.fork()
        if guardian_pid == 0:
            try:
                guardian(read_fd, write_fd, command, env)
            except BaseException as error:
                log("guardian failed; reservation retained until group drains: %s" % error)
                os._exit(125)
        os.close(read_fd)
        with queue.locked() as (state, _procs):
            job = next(j for j in state["jobs"] if j["ticket"] == ticket)
            job.update(state="running", group=guardian_pid, admitted=time.time())
        os.write(write_fd, b"G")
        os.close(write_fd)
        write_fd = None
        log("start ticket=%s kind=%s profile=%s package_concurrency=1 max_workers=%s wait=%.1fs" % (
            ticket, kind, profile, env["SUME_TEST_GATE_MAX_WORKERS"], time.monotonic() - started))
        signalled = False
        while True:
            done, status = os.waitpid(guardian_pid, os.WNOHANG)
            if done:
                guardian_pid = None
                code = exit_status(status)
                break
            if STOP and not signalled:
                try:
                    os.killpg(guardian_pid, STOP)
                    signalled = True
                except ProcessLookupError:
                    pass
            time.sleep(0.1)
        if fingerprint() != source:
            log("source changed during execution; validation is stale")
            code = code or 125
        log("finish ticket=%s exit=%s" % (ticket, code))
        return code
    finally:
        if write_fd is not None:
            os.close(write_fd)
        if guardian_pid is not None:
            try:
                os.killpg(guardian_pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.waitpid(guardian_pid, 0)
        queue.finish(ticket)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test-state-dir", help=argparse.SUPPRESS)
    parser.add_argument("action", choices=["test", "build", "status", "configure", "check"])
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.action in ("test", "build") and not command:
        parser.error("test/build requires -- <command> [args...]")
    # Exact Actions escape happens before filesystem access, flag validation,
    # command adaptation, and environment changes. CI=1 alone is NOT a bypass.
    if os.environ.get("GITHUB_ACTIONS") == "true":
        if args.action in ("test", "build"):
            os.execvp(command[0], command)
        return 0
    root = Path.home() / ".cstack/state/test-gate"
    if args.test_state_dir:
        if os.environ.get("CSTACK_TEST_GATE_TESTING") != "1":
            parser.error("test-state-dir is reserved for the synthetic test harness")
        root = Path(args.test_state_dir).resolve()
        if not str(root).startswith(str(Path(tempfile.gettempdir()).resolve()) + os.sep):
            parser.error("test state must live under the system temporary directory")
    queue = Queue(root)
    if args.action == "configure":
        if len(command) != 1 or command[0] not in PROFILES:
            parser.error("configure requires mini16 or host64")
        with queue.locked() as (state, _procs):
            if state["jobs"]:
                raise ValueError("cannot configure while tickets are present")
            atomic_json(root / "profile.json", {"profile": command[0]})
        log("host profile=%s state=%s" % (command[0], root))
        return 0
    if args.action == "status":
        with queue.locked() as (state, _procs):
            # Leases and command environment are intentionally not exposed.
            print(json.dumps({"profile": queue.profile(), "limits": PROFILES[queue.profile()],
                              "state_dir": str(root), "jobs": [
                                  {k: j.get(k) for k in ("ticket", "kind", "state", "pid", "group", "cwd")}
                                  for j in state["jobs"]]}, indent=2))
        return 0
    if args.action == "check":
        if command not in (["test"], ["build"]):
            parser.error("check requires test or build")
        with queue.locked() as (state, procs):
            if not valid_lease(state, procs, command[0]):
                raise ValueError("missing lease; use cstack-test-gate %s -- <command>" % command[0])
        return 0
    return execute(queue, args.action, command)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        log(str(error))
        sys.exit(125)
