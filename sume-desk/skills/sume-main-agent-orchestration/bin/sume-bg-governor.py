#!/usr/bin/env python3
import fcntl
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time

USAGE = """sume-bg-governor.py <command>

  daemon                 run the supervisor loop (launchd agent; one instance)
  once                   one decision tick, then exit
  status [--json]        load, mode, running / paused / queued jobs, quota
  admit --name N [--priority P] [--model M] [--effort E] [--resume U] [--fork] [--now]
                         admission decision for a new job (prints JSON)
  pause <job> | resume <job>      manual SIGSTOP / SIGCONT of a job's process tree
  start <job>                     start a queued job now
  pin <job> | unpin <job>         a pinned job is never paused
  mode observe|enforce|off        observe logs what it would do; enforce acts
  notify <line>          queue a one-line Slack note (batched)
  swap <email> [--wait S]         ask the daemon (GUI session, keychain) to run `tokenmaxxing switch <email>`
  install | uninstall    launchd agent com.cstack.sume-bg-governor (Mini)

Docs: docs/MINI-WORKER-HOST.md (Governor)."""

HOME = os.path.expanduser("~")
STATE_ROOT = os.environ.get("CSTACK_STATE") or os.path.join(HOME, ".cstack/state")
JOBS_DIR = os.environ.get("SUME_BG_REMOTE_JOBS_DIR") or os.path.join(STATE_ROOT, "remote-jobs")
GOV_DIR = os.environ.get("GOV_DIR") or os.path.join(STATE_ROOT, "governor")
BIN = os.path.dirname(os.path.realpath(__file__))
REMOTE_BIN = os.environ.get("GOV_REMOTE_BIN") or os.path.join(BIN, "sume-bg-remote.sh")
QUOTA_BIN = os.path.join(BIN, "cstack-quota.py")
SLACK_BIN = os.environ.get("SUME_BG_SLACK_POST_BIN") or os.path.join(BIN, "cstack-slack-post.sh")
LABEL = "com.cstack.sume-bg-governor"
NCPU = os.cpu_count() or 8
RANK = {"low": 0, "normal": 1, "high": 2, "critical": 3}

CRIT_PROC = re.compile(
    r"(\bgit\s+(push|commit|rebase|merge|cherry-pick|am)(\s|$)|\bgit\s+tag\s+v[0-9]|\bgh\s+(stack\s+(submit|merge|sync|push)|pr\s+(merge|create|ready)|release\b|workflow\s+run|run\s+watch)"
    r"|cstack-gt-wait-merge|\bgt\s+(submit|merge|sync)\b|/release-[a-z0-9-]+|\bvercel\b.*\b(deploy|--prod|promote)\b"
    r"|\brailway\s+(up|deploy|redeploy)\b|\b(npm|pnpm|bun)\s+publish\b|cstack-slack-post|cstack-gate|sume-bg-remote(\.sh)?\s+(start|kill))"
)
CRIT_LOG = re.compile(r"cstack-gt-wait-merge|gh stack (submit|merge)|gh pr merge|gh workflow run .*release|git push|git tag v[0-9]")
NAME_CRITICAL = re.compile(r"(^|-)(release|hotfix|deploy|rollback|prod)(-|\d|$)")
NAME_HIGH = re.compile(r"(^|-)(rca|sentry|incident|outage|sev[0-9]?|errors|alerts?|money|security|signin)(-|\d|$)")
NAME_LOW = re.compile(r"(^|-)(research|study|audit|ideas|explore|dogfood|survey|eval|loop|iter|sweep|polish|review|probe|bench)(-|\d|$)|-100[a-z]?(-|$)|(^|-)r\d+(-|$)")


def env_f(name, default):
    v = os.environ.get(name)
    try:
        return float(v) if v not in (None, "") else float(default)
    except ValueError:
        return float(default)


def config():
    high = env_f("GOV_HIGH_LOAD5", round(1.22 * NCPU))
    low = env_f("GOV_LOW_LOAD5", round(0.67 * NCPU))
    return {
        "interval_s": env_f("GOV_INTERVAL_S", 30),
        "high_load5": high,
        "low_load5": low,
        "start_load5": env_f("GOV_START_LOAD5", (high + low) / 2.0),
        "low_hold_min": env_f("GOV_LOW_HOLD_MIN", 5),
        "cooldown_s": env_f("GOV_COOLDOWN_S", 180),
        "max_pause_min": env_f("GOV_MAX_PAUSE_MIN", 30),
        "heavy_cpu": env_f("GOV_HEAVY_CPU", 15),
        "ssh_slow_ms": env_f("GOV_SSH_SLOW_MS", 3000),
        "mem_free_low": env_f("GOV_MEM_FREE_LOW", 10),
        "swap_high_mb": env_f("GOV_SWAP_HIGH_MB", 4096),
        "fable_stagger_pct": env_f("GOV_FABLE_STAGGER_PCT", 25),
        "fable_heavy_max": env_f("GOV_FABLE_HEAVY_MAX", 2),
        "notify_min": env_f("GOV_NOTIFY_MIN", 10),
    }


def now():
    v = os.environ.get("GOV_FAKE_NOW")
    return float(v) if v else time.time()


def iso(ts):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))


def kst(ts):
    return time.strftime("%m/%d %H:%M", time.gmtime(ts + 9 * 3600)) + " KST"


def ensure_dirs():
    for d in (GOV_DIR, os.path.join(GOV_DIR, "notify")):
        os.makedirs(d, exist_ok=True)


class Locked:
    def __enter__(self):
        ensure_dirs()
        self.f = open(os.path.join(GOV_DIR, "state.lock"), "a+")
        fcntl.flock(self.f, fcntl.LOCK_EX)
        return self

    def __exit__(self, *a):
        fcntl.flock(self.f, fcntl.LOCK_UN)
        self.f.close()


def load_state():
    try:
        with open(os.path.join(GOV_DIR, "state.json"), encoding="utf-8") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    st.setdefault("paused", {})
    st.setdefault("gov_stopped", {})
    st.setdefault("pinned", [])
    st.setdefault("last_action", 0)
    st.setdefault("low_since", None)
    st.setdefault("last_post", 0)
    st.setdefault("warned", {})
    return st


def save_state(st):
    p = os.path.join(GOV_DIR, "state.json")
    tmp = p + ".tmp.%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=1, sort_keys=True)
    os.replace(tmp, p)


def mode_of(st):
    return st.get("mode") or os.environ.get("GOV_MODE") or "observe"


def log(msg):
    ensure_dirs()
    line = "%s %s" % (iso(now()), msg)
    with open(os.path.join(GOV_DIR, "log"), "a", encoding="utf-8") as f:
        f.write(line + "\n")
    if os.environ.get("GOV_ECHO") == "1":
        print(line)


def notify(line):
    ensure_dirs()
    p = os.path.join(GOV_DIR, "notify", "%d-%d.line" % (int(now() * 1000), os.getpid()))
    with open(p, "w", encoding="utf-8") as f:
        f.write(line.strip() + "\n")


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.TimeoutExpired):
        return ""


def sysctl(name):
    return run(["sysctl", "-n", name], 5).strip()


def probe_ssh():
    v = os.environ.get("GOV_FAKE_SSH_MS")
    if v is not None:
        return None if v == "down" else float(v)
    t0 = time.time()
    try:
        s = socket.create_connection(("127.0.0.1", 22), timeout=10)
        s.settimeout(10)
        s.recv(64)
        s.close()
    except OSError:
        return None
    return (time.time() - t0) * 1000.0


def sample():
    fake = os.environ.get("GOV_FAKE_LOAD")
    if fake:
        l1, l5, l15 = (float(x) for x in fake.split(","))
    else:
        l1, l5, l15 = os.getloadavg()
    mem = os.environ.get("GOV_FAKE_MEMFREE")
    if mem is None:
        mem = sysctl("kern.memorystatus_level") or "100"
    swap = os.environ.get("GOV_FAKE_SWAP_MB")
    if swap is None:
        m = re.search(r"used = ([0-9.]+)M", sysctl("vm.swapusage"))
        swap = m.group(1) if m else "0"
    return {"load1": l1, "load5": l5, "load15": l15, "mem_free": float(mem), "swap_mb": float(swap), "ssh_ms": probe_ssh()}


def pressure(s, cfg):
    why = []
    if s["load5"] >= cfg["high_load5"] and s["load1"] >= 0.9 * cfg["high_load5"]:
        why.append("load %.1f/%.1f over %.0f" % (s["load1"], s["load5"], cfg["high_load5"]))
    if s["ssh_ms"] is None or s["ssh_ms"] >= cfg["ssh_slow_ms"]:
        why.append("sshd %s" % ("down" if s["ssh_ms"] is None else "%.0f ms" % s["ssh_ms"]))
    if s["mem_free"] < cfg["mem_free_low"]:
        why.append("memory free %.0f%%" % s["mem_free"])
    if s["swap_mb"] >= cfg["swap_high_mb"]:
        why.append("swap %.0f MB" % s["swap_mb"])
    low = (not why) and s["load5"] <= cfg["low_load5"] and s["load1"] <= 1.2 * cfg["low_load5"]
    return why, low


def read_env(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    out[k] = v.strip("'\"")
    except OSError:
        pass
    return out


def default_priority(name):
    n = (name or "").lower()
    if NAME_CRITICAL.search(n):
        return "critical"
    if NAME_HIGH.search(n):
        return "high"
    if NAME_LOW.search(n):
        return "low"
    return "normal"


def norm_priority(p, name):
    p = (p or "").strip().lower()
    if p in RANK:
        return p
    if p.isdigit():
        return {0: "low", 1: "normal", 2: "high"}.get(int(p), "critical")
    return default_priority(name)


def procs():
    out = run(["ps", "-axo", "pid=,ppid=,pgid=,stat=,%cpu=,command="], 15)
    rows = {}
    for line in out.splitlines():
        parts = line.split(None, 5)
        if len(parts) < 6:
            continue
        try:
            pid, ppid, pgid = int(parts[0]), int(parts[1]), int(parts[2])
            cpu = float(parts[4])
        except ValueError:
            continue
        rows[pid] = {"pid": pid, "ppid": ppid, "pgid": pgid, "stat": parts[3], "cpu": cpu, "cmd": parts[5]}
    return rows


def lstart(pid):
    return run(["ps", "-o", "lstart=", "-p", str(pid)], 5).strip()


def tree(rows, root, pgid):
    kids = {}
    for r in rows.values():
        kids.setdefault(r["ppid"], []).append(r["pid"])
    seen, stack = set(), [root]
    while stack:
        p = stack.pop()
        if p in seen or p not in rows:
            continue
        seen.add(p)
        stack.extend(kids.get(p, []))
    for r in rows.values():
        if pgid and r["pgid"] == pgid:
            seen.add(r["pid"])
    seen.discard(os.getpid())
    return sorted(seen)


def session_id(d):
    try:
        with open(os.path.join(d, "worker.log"), encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                m = re.match(r"📎 session_id=([0-9a-fA-F-]{36})", line)
                if m:
                    return m.group(1)
                if i > 4000:
                    break
    except OSError:
        pass
    return ""


def log_tail_critical(d):
    p = os.path.join(d, "worker.log")
    try:
        size = os.path.getsize(p)
        with open(p, "rb") as f:
            f.seek(max(0, size - 200000))
            lines = f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return ""
    cmds = [l for l in lines if l.startswith("🤖 $ ")][-12:]
    for l in reversed(cmds):
        m = CRIT_LOG.search(l)
        if m:
            return "recent `%s`" % m.group(0)
    return ""


def model_effort(env, cmd, extra=None):
    m = env.get("MODEL", "")
    e = env.get("EFFORT", "")
    extra = extra or []
    for i, a in enumerate(extra[:-1]):
        if a == "--model" and not m:
            m = extra[i + 1]
        if a == "--effort" and not e:
            e = extra[i + 1]
    if not m:
        mm = re.search(r"--model\s+(\S+)", cmd or "")
        m = mm.group(1) if mm else ""
    if not e:
        ee = re.search(r"--effort\s+(\S+)", cmd or "")
        e = ee.group(1) if ee else ""
    return m, e


def is_fable(model):
    m = re.sub(r"[^a-z0-9]", "", (model or "").lower())
    m = m[len("claude"):] if m.startswith("claude") else m
    return m.startswith(("fable", "fabel", "fabl", "fabe")) or "fable" in m


def scan(st, rows=None):
    rows = rows if rows is not None else procs()
    jobs = []
    try:
        names = sorted(os.listdir(JOBS_DIR))
    except OSError:
        names = []
    for job in names:
        d = os.path.join(JOBS_DIR, job)
        if not os.path.isdir(d):
            continue
        env = read_env(os.path.join(d, "job.env"))
        name = env.get("NAME") or job
        info = {"job": job, "dir": d, "name": name, "env": env,
                "priority": norm_priority(env.get("PRIORITY"), name),
                "started": env.get("STARTED", ""), "cpu": 0.0, "pids": [], "critical": ""}
        if os.path.exists(os.path.join(d, "queued")) and not os.path.exists(os.path.join(d, "pid")):
            info["state"] = "queued"
            info["model"], info["effort"] = model_effort(env, "", read_extra(d))
            jobs.append(info)
            continue
        if os.path.exists(os.path.join(d, "exit_code")):
            continue
        try:
            pid = int(open(os.path.join(d, "pid")).read().strip())
        except (OSError, ValueError):
            continue
        if pid not in rows:
            continue
        want = ""
        try:
            want = open(os.path.join(d, "pid_start")).read().strip()
        except OSError:
            pass
        if want and lstart(pid) != want:
            continue
        if not want and ("--job " + job) not in rows[pid]["cmd"]:
            continue
        try:
            pgid = int(open(os.path.join(d, "pgid")).read().strip())
        except (OSError, ValueError):
            pgid = rows[pid]["pgid"]
        pids = tree(rows, pid, pgid)
        info.update(pid=pid, pgid=pgid, pids=pids, cpu=sum(rows[p]["cpu"] for p in pids if p in rows))
        cmd = rows[pid]["cmd"]
        info["model"], info["effort"] = model_effort(env, " ".join(rows[p]["cmd"] for p in pids if p in rows), read_extra(d))
        info["state"] = "paused" if job in st["paused"] else "running"
        reasons = []
        if info["priority"] == "critical":
            reasons.append("critical priority")
        if env.get("CRITICAL") == "1" or os.path.exists(os.path.join(d, "critical")):
            reasons.append("marked critical")
        if job in st["pinned"]:
            reasons.append("pinned")
        for p in pids:
            m = CRIT_PROC.search(rows[p]["cmd"]) if p in rows else None
            if m and "sume-bg-governor" not in rows[p]["cmd"]:
                reasons.append("running `%s`" % m.group(0).strip())
                break
        lt = log_tail_critical(d)
        if lt:
            reasons.append(lt)
        info["critical"] = "; ".join(reasons)
        info["cmd"] = cmd
        jobs.append(info)
    return jobs


def started_ts(j):
    try:
        return time.mktime(time.strptime(j["started"], "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
    except (ValueError, OverflowError):
        return 0.0


def signal_pids(pids, sig):
    ok = []
    for p in pids:
        try:
            os.kill(p, sig)
            ok.append(p)
        except OSError:
            pass
    return ok


def do_pause(st, j, reason, actor):
    pids = signal_pids(j["pids"], signal.SIGSTOP)
    st["paused"][j["job"]] = {"at": now(), "pids": pids, "reason": reason, "priority": j["priority"], "name": j["name"], "by": actor}
    with open(os.path.join(j["dir"], "governor-paused"), "w", encoding="utf-8") as f:
        json.dump(st["paused"][j["job"]], f)
    log("PAUSE %s prio=%s pids=%d by=%s: %s" % (j["job"], j["priority"], len(pids), actor, reason))
    notify("⏸ `%s` 일시정지 (%s, 우선순위 %s)" % (j["name"], reason, j["priority"]))


def do_resume(st, job, actor, rows=None):
    rec = st["paused"].pop(job, None) or {}
    rows = rows if rows is not None else procs()
    d = os.path.join(JOBS_DIR, job)
    pids = set(rec.get("pids") or [])
    try:
        pid = int(open(os.path.join(d, "pid")).read().strip())
        pgid = int(open(os.path.join(d, "pgid")).read().strip())
        pids.update(tree(rows, pid, pgid))
    except (OSError, ValueError):
        pass
    sent = signal_pids(sorted(pids), signal.SIGCONT)
    try:
        os.remove(os.path.join(d, "governor-paused"))
    except OSError:
        pass
    held = (now() - rec["at"]) / 60.0 if rec.get("at") else 0
    log("RESUME %s pids=%d by=%s after %.0f min" % (job, len(sent), actor, held))
    notify("▶️ `%s` 재개 (%.0f분 멈춤)" % (rec.get("name") or job, held))


def do_convert(st, job):
    rec = st["paused"].get(job) or {}
    d = os.path.join(JOBS_DIR, job)
    env = read_env(os.path.join(d, "job.env"))
    sid = session_id(d)
    if not sid:
        log("CONVERT-SKIP %s: no session id; keeping it paused" % job)
        return False
    signal_pids(rec.get("pids") or [], signal.SIGCONT)
    out = run([REMOTE_BIN, "kill", "--job", job], 60)
    st["paused"].pop(job, None)
    meta = {"at": now(), "sid": sid, "name": env.get("NAME") or job, "backend": env.get("BACKEND", "claude"),
            "cwd": env.get("CWD") or HOME, "priority": rec.get("priority") or norm_priority(env.get("PRIORITY"), env.get("NAME")),
            "extra": read_extra(d), "slack_report": env.get("SLACK_REPORT", "1"), "same_thread": env.get("SAME_THREAD", "0"),
            "paused_at": rec.get("at")}
    st["gov_stopped"][job] = meta
    with open(os.path.join(d, "governor-stopped"), "w", encoding="utf-8") as f:
        json.dump(meta, f)
    try:
        os.remove(os.path.join(d, "governor-paused"))
    except OSError:
        pass
    log("CONVERT %s: paused too long, stopped cleanly (%s); will resume session %s" % (job, out.strip().splitlines()[0] if out.strip() else "kill sent", sid))
    notify("⏹ `%s` 오래 멈춰서 깔끔히 정지 → 여유 생기면 세션 `%s`로 자동 재개" % (meta["name"], sid[:8]))
    return True


def relaunch(st, job):
    meta = st["gov_stopped"].pop(job)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now()))
    label = re.sub(r"[^a-zA-Z0-9._-]", "_", meta["name"])
    new = "%s-%s-resume-%s" % (stamp, label, meta["sid"][:8])
    nd = os.path.join(JOBS_DIR, new)
    os.makedirs(nd, exist_ok=True)
    paused_for = ""
    if meta.get("paused_at"):
        paused_for = " (paused %s, stopped cleanly %s)" % (iso(meta["paused_at"]), iso(meta["at"]))
    with open(os.path.join(nd, "prompt.md"), "w", encoding="utf-8") as f:
        f.write("PAUSED BY GOVERNOR, continue: the Mini governor paused your previous run of this job (Mini job %s)%s because the Mini was overloaded. "
                "Nothing failed and nobody stopped the task. Continue the same task from where you left off. "
                "First check what already happened (git branch, PRs, merge queue, Slack posts) so nothing runs twice. "
                "Background commands and watchers from before are gone; restart only the ones you still need.\n" % (job, paused_for))
    args = [REMOTE_BIN, "start", "--job", new, "--backend", meta["backend"], "--name", meta["name"], "--cwd", meta["cwd"],
            "--resume", meta["sid"], "--priority", meta["priority"], "--now"]
    if meta.get("slack_report") == "0":
        args.append("--no-slack-report")
    if meta.get("same_thread") == "1":
        args.append("--same-thread")
    extra = meta.get("extra") or []
    if extra:
        args += ["--"] + extra
    env = dict(os.environ, SUME_BG_GOVERNOR_RESUME_OF=job)
    for k in ("SUME_BG_REMOTE_JOB", "SUME_WORKER_SESSION", "AGENT_HUMAN_STREAM_PID", "AGENT_HUMAN_STREAM_NAME", "AGENT_HUMAN_STREAM_LIVE_LOG"):
        env.pop(k, None)
    try:
        out = subprocess.run(args, capture_output=True, text=True, timeout=60, env=env)
        ok = out.returncode == 0
        msg = (out.stdout + out.stderr).strip().splitlines()[-1:] or [""]
    except (OSError, subprocess.TimeoutExpired) as e:
        ok, msg = False, [str(e)]
    if not ok:
        st["gov_stopped"][job] = meta
        log("RELAUNCH-FAIL %s: %s" % (job, msg[0]))
        return False
    log("RELAUNCH %s as %s (session %s)" % (job, new, meta["sid"]))
    notify("▶️ `%s` 세션 재개 → `%s`" % (meta["name"], new))
    return True


def read_extra(d):
    try:
        with open(os.path.join(d, "extra.args"), encoding="utf-8") as f:
            return [line.rstrip("\n") for line in f if line.rstrip("\n") != ""]
    except OSError:
        return []


def start_queued(j):
    out = run([REMOTE_BIN, "start-queued", "--job", j["job"]], 60)
    ok = "started job=" in out
    log("%s %s: %s" % ("START-QUEUED" if ok else "START-QUEUED-FAIL", j["job"], (out.strip().splitlines() or [""])[-1]))
    if ok:
        notify("🚀 대기열 `%s` 시작 (우선순위 %s)" % (j["name"], j["priority"]))
    return ok


def quota_pool(running_fable):
    out = run([sys.executable, QUOTA_BIN, "status", "--json", "--running-fable", str(running_fable)], 20)
    try:
        return json.loads(out)["pool"]
    except (ValueError, KeyError):
        return None


def heavy_fable(j):
    return is_fable(j.get("model")) and (j.get("effort") or "high").lower() in ("max", "xhigh", "maximum")


def fable_stagger_reason(jobs, cfg, model, effort):
    if not (is_fable(model) and (effort or "high").lower() in ("max", "xhigh", "maximum")):
        return ""
    running_fable = [j for j in jobs if j["state"] in ("running", "paused") and is_fable(j.get("model"))]
    heavy = [j for j in running_fable if heavy_fable(j)]
    if len(heavy) < cfg["fable_heavy_max"]:
        return ""
    p = quota_pool(len(running_fable))
    if p is None or p["projected_pct"] >= cfg["fable_stagger_pct"]:
        return ""
    return "fable-stagger: Fable headroom projected %.0f%% (< %.0f%%) with %d heavy Fable workers running" % (
        p["projected_pct"], cfg["fable_stagger_pct"], len(heavy))


def flush_notify(st, force=False):
    cfg = config()
    nd = os.path.join(GOV_DIR, "notify")
    try:
        files = sorted(f for f in os.listdir(nd) if f.endswith(".line"))
    except OSError:
        return
    if not files:
        return
    if not force and now() - st.get("last_post", 0) < cfg["notify_min"] * 60:
        return
    lines = []
    for f in files:
        try:
            with open(os.path.join(nd, f), encoding="utf-8") as fh:
                lines.append(fh.read().strip())
        except OSError:
            pass
    text = "*Mini 거버너* (%s)" % kst(now())
    used = len(text)
    kept = 0
    for l in lines:
        if used + len(l) + 1 > 560:
            text += "\n…전체: ~/.cstack/state/governor/log"
            break
        text += "\n" + l
        used += len(l) + 1
        kept += 1
    tf = os.path.join(GOV_DIR, "post.md")
    with open(tf, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")
    with open(os.path.join(GOV_DIR, "notify.log"), "a", encoding="utf-8") as fh:
        fh.write(text + "\n")
    if os.environ.get("GOV_NOTIFY", "1") == "1":
        out = run([SLACK_BIN, "--job", "mini-governor", "--title", "Mini 거버너", "--text-file", tf], 180)
        log("NOTIFY posted %d line(s): %s" % (kept, (out.strip().splitlines() or ["(no output)"])[-1]))
    for f in files:
        try:
            os.remove(os.path.join(nd, f))
        except OSError:
            pass
    st["last_post"] = now()


def tick(st, actor="governor"):
    cfg = config()
    t = now()
    mode = mode_of(st)
    if mode == "off":
        return {"mode": mode, "actions": []}
    rows = procs()
    s = sample()
    jobs = scan(st, rows)
    alive = {j["job"] for j in jobs if j["state"] in ("running", "paused")}
    for job in list(st["paused"]):
        if job not in alive:
            st["paused"].pop(job, None)
            log("DROP %s: no longer running" % job)
    why, low = pressure(s, cfg)
    if low:
        st["low_since"] = st.get("low_since") or t
    else:
        st["low_since"] = None
    act = mode == "enforce"
    can_act = t - st.get("last_action", 0) >= cfg["cooldown_s"]
    actions = []

    for job, rec in list(st["paused"].items()):
        if t - rec.get("at", t) >= cfg["max_pause_min"] * 60:
            actions.append(("convert", job, "paused %.0f min" % ((t - rec["at"]) / 60)))
            if act:
                do_convert(st, job)
                st["last_action"] = t

    running = [j for j in jobs if j["state"] == "running"]
    if why and can_act:
        cands = [j for j in running if not j["critical"] and j["cpu"] >= cfg["heavy_cpu"]]
        cands.sort(key=lambda j: (RANK[j["priority"]], -started_ts(j)))
        if cands:
            j = cands[0]
            actions.append(("pause", j["job"], ", ".join(why)))
            if act:
                do_pause(st, j, ", ".join(why), actor)
                st["last_action"] = t
        else:
            key = "nopause"
            if t - st["warned"].get(key, 0) > 1800:
                st["warned"][key] = t
                busy = sorted(running, key=lambda j: -j["cpu"])[:3]
                log("HIGH %s but no pausable heavy job (%s)" % (", ".join(why), ", ".join("%s cpu=%.0f%s" % (j["job"], j["cpu"], " critical" if j["critical"] else "") for j in busy) or "no jobs"))
    elif not why and can_act:
        held_low = st.get("low_since") and t - st["low_since"] >= cfg["low_hold_min"] * 60
        paused = sorted(st["paused"].items(), key=lambda kv: (-RANK.get(kv[1].get("priority", "normal"), 1), kv[1].get("at", 0)))
        stopped = sorted(st["gov_stopped"].items(), key=lambda kv: (-RANK.get(kv[1].get("priority", "normal"), 1), kv[1].get("at", 0)))
        queued = sorted((j for j in jobs if j["state"] == "queued"), key=lambda j: (-RANK[j["priority"]], j["job"]))
        if held_low and paused:
            job = paused[0][0]
            actions.append(("resume", job, "load %.1f below %.0f for %.0f min" % (s["load5"], cfg["low_load5"], cfg["low_hold_min"])))
            if act:
                do_resume(st, job, actor, rows)
                st["last_action"] = t
        elif held_low and stopped:
            job = stopped[0][0]
            actions.append(("relaunch", job, "load %.1f" % s["load5"]))
            if act:
                relaunch(st, job)
                st["last_action"] = t
        elif not paused and not stopped and queued and s["load5"] < cfg["start_load5"]:
            for j in queued:
                stag = fable_stagger_reason(jobs, cfg, j.get("model"), j.get("effort"))
                if stag:
                    continue
                actions.append(("start", j["job"], "load %.1f below %.0f" % (s["load5"], cfg["start_load5"])))
                if act:
                    start_queued(j)
                    st["last_action"] = t
                break
    for a in actions:
        if not act:
            log("WOULD %s %s: %s" % (a[0].upper(), a[1], a[2]))
    flush_notify(st)
    st["last_tick"] = t
    st["last_sample"] = s
    return {"mode": mode, "sample": s, "pressure": why, "low": low, "actions": actions}


def admit(argv, st):
    cfg = config()
    name = arg(argv, "--name", "")
    prio = norm_priority(arg(argv, "--priority", ""), name)
    model, effort = arg(argv, "--model", ""), arg(argv, "--effort", "")
    steer = bool(arg(argv, "--resume", "")) and "--fork" not in argv
    mode = mode_of(st)
    if "--now" in argv or prio == "critical" or steer or mode == "off":
        return {"decision": "start", "reason": "now" if "--now" in argv else ("critical" if prio == "critical" else ("steer" if steer else "governor off")), "priority": prio}
    s = sample()
    why, _ = pressure(s, cfg)
    reason = ""
    if why:
        reason = "load: " + ", ".join(why)
    elif s["load5"] >= cfg["high_load5"]:
        reason = "load: 5-min load %.1f over %.0f" % (s["load5"], cfg["high_load5"])
    else:
        reason = fable_stagger_reason(scan(st), cfg, model, effort)
    if not reason:
        return {"decision": "start", "reason": "capacity ok", "priority": prio}
    if mode != "enforce":
        log("WOULD QUEUE %s (%s): %s" % (name, prio, reason))
        return {"decision": "start", "reason": "observe mode; would queue: " + reason, "priority": prio}
    log("QUEUE %s (%s): %s" % (name, prio, reason))
    notify("⏳ `%s` 대기열 (%s)" % (name, reason))
    return {"decision": "queue", "reason": reason, "priority": prio}


def arg(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def fmt_age(started):
    try:
        ts = time.mktime(time.strptime(started, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
    except (ValueError, OverflowError):
        return "-"
    d = max(0, now() - ts)
    return "%dh%02d" % (d // 3600, d % 3600 // 60) if d >= 3600 else "%dm" % (d // 60)


def short_model(m, e):
    m = (m or "").replace("claude-", "")
    return ("%s %s" % (m, e)).strip() or "-"


def tm_bin():
    return (os.environ.get("SUME_BG_TOKENMAXXING_BIN") or shutil.which("tokenmaxxing")
            or os.path.join(HOME, ".config/tokenmaxxing/bin/tokenmaxxing"))


def swap_dir():
    return os.path.join(GOV_DIR, "swap")


def serve_swaps():
    try:
        reqs = sorted(f for f in os.listdir(swap_dir()) if f.endswith(".req"))
    except OSError:
        return
    for f in reqs:
        p = os.path.join(swap_dir(), f)
        try:
            with open(p, encoding="utf-8") as fh:
                target = fh.read().strip()
        except OSError:
            continue
        if not re.match(r"^[^\s/@]+@[^\s/@]+$", target):
            rc, last = 2, "bad account %r" % target
        else:
            try:
                r = subprocess.run([tm_bin(), "switch", target], capture_output=True, text=True, timeout=90)
                rc, last = r.returncode, ((r.stdout + r.stderr).strip().splitlines() or [""])[-1]
            except subprocess.TimeoutExpired:
                rc, last = 124, "tokenmaxxing switch timed out"
            except OSError as e:
                rc, last = 127, str(e)
        tmp = p[:-4] + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump({"rc": rc, "out": last[:300]}, fh)
        os.rename(tmp, p[:-4] + ".done")
        try:
            os.remove(p)
        except OSError:
            pass
        log("SWAP %s rc=%d: %s" % (target, rc, last[:200]))


def swap_request(argv):
    if not argv:
        print("error: swap needs an account email", file=sys.stderr)
        return 2
    target = argv[0]
    wait = float(arg(argv, "--wait", "90") or 90)
    if daemon_pid() is None:
        print("sume-bg-governor: daemon not running; cannot switch from this session")
        return 3
    os.makedirs(swap_dir(), exist_ok=True)
    base = os.path.join(swap_dir(), "%d-%d" % (int(time.time() * 1000), os.getpid()))
    with open(base + ".tmp", "w", encoding="utf-8") as fh:
        fh.write(target + "\n")
    os.rename(base + ".tmp", base + ".req")
    deadline = time.time() + wait
    while time.time() < deadline:
        if os.path.exists(base + ".done"):
            try:
                with open(base + ".done", encoding="utf-8") as fh:
                    res = json.load(fh)
            except (OSError, ValueError):
                res = {"rc": 1, "out": "unreadable result"}
            os.remove(base + ".done")
            print("sume-bg-governor: tokenmaxxing switch %s rc=%s: %s" % (target, res.get("rc"), res.get("out", "")))
            return 0 if res.get("rc") == 0 else 1
        time.sleep(0.5)
    try:
        os.remove(base + ".req")
    except OSError:
        pass
    print("sume-bg-governor: no answer from the daemon in %.0f s" % wait)
    return 124


def daemon_pid():
    p = os.path.join(GOV_DIR, "daemon.pid")
    try:
        pid = int(open(p).read().strip())
        os.kill(pid, 0)
        return pid
    except (OSError, ValueError):
        return None


def status(argv):
    cfg = config()
    ensure_dirs()
    st = load_state()
    rows = procs()
    s = sample()
    jobs = scan(st, rows)
    why, low = pressure(s, cfg)
    running_fable = sum(1 for j in jobs if j["state"] in ("running", "paused") and is_fable(j.get("model")))
    p = quota_pool(running_fable)
    if "--json" in argv:
        print(json.dumps({"mode": mode_of(st), "daemon_pid": daemon_pid(), "sample": s, "pressure": why, "config": cfg,
                          "quota": p, "jobs": [{k: v for k, v in j.items() if k not in ("env", "pids", "dir")} for j in jobs],
                          "gov_stopped": st["gov_stopped"], "pinned": st["pinned"]}, indent=1))
        return 0
    dp = daemon_pid()
    print("Mini governor: mode=%s  daemon=%s  load %.1f/%.1f/%.1f (%d cores; pause above %.0f, resume below %.0f, start queued below %.0f)" % (
        mode_of(st), "running (pid %d)" % dp if dp else "not running", s["load1"], s["load5"], s["load15"], NCPU,
        cfg["high_load5"], cfg["low_load5"], cfg["start_load5"]))
    print("  memory free %.0f%%  swap %.0f MB  sshd %s  pressure: %s" % (
        s["mem_free"], s["swap_mb"], "down" if s["ssh_ms"] is None else "%.0f ms" % s["ssh_ms"], ", ".join(why) or ("low" if low else "normal")))
    if p:
        print("  quota: Fable headroom %.0f%% of pool, projected %.0f%% with %d Fable worker(s); %d/%d accounts with Fable headroom (sume-bg-launch --quota)" % (
            p["fable_headroom_pct"], p["projected_pct"], running_fable, p["fable_ok_accounts"], p["usable"]))
    order = {"paused": 0, "running": 1, "queued": 2}
    print("%-58s %-8s %-7s %5s  %-18s %6s  %s" % ("JOB", "PRIO", "STATE", "CPU%", "MODEL", "AGE", "NOTE"))
    for j in sorted(jobs, key=lambda j: (order.get(j["state"], 3), -RANK[j["priority"]], j["job"])):
        note = j["critical"] and ("never paused: " + j["critical"]) or ""
        if j["state"] == "paused":
            rec = st["paused"].get(j["job"], {})
            note = "paused %.0f min: %s" % ((now() - rec.get("at", now())) / 60, rec.get("reason", ""))
        print("%-58s %-8s %-7s %5.0f  %-18s %6s  %s" % (j["job"][:58], j["priority"], j["state"], j["cpu"],
                                                       short_model(j.get("model"), j.get("effort"))[:18], fmt_age(j["started"]), note[:90]))
    for job, meta in st["gov_stopped"].items():
        print("%-58s %-8s %-7s %5s  %-18s %6s  %s" % (job[:58], meta.get("priority", "?"), "stopped", "-", "-", "-",
                                                     "stopped by governor; resumes session %s when load drops" % meta.get("sid", "")[:8]))
    if st["pinned"]:
        print("pinned (never paused): " + ", ".join(st["pinned"]))
    return 0


def find_job(jobs, key):
    for j in jobs:
        if j["job"] == key:
            return j
    m = [j for j in jobs if key in j["job"]]
    return m[0] if len(m) == 1 else None


def manual(cmd, argv):
    if not argv:
        print("error: %s needs a job id" % cmd, file=sys.stderr)
        return 2
    key = argv[0]
    with Locked():
        st = load_state()
        if cmd in ("pin", "unpin"):
            if cmd == "pin" and key not in st["pinned"]:
                st["pinned"].append(key)
            if cmd == "unpin" and key in st["pinned"]:
                st["pinned"].remove(key)
            save_state(st)
            log("%s %s (manual)" % (cmd.upper(), key))
            print("%sned %s" % (cmd, key))
            return 0
        jobs = scan(st)
        j = find_job(jobs, key)
        if cmd == "start":
            if not j or j["state"] != "queued":
                print("error: no queued job matches %s" % key, file=sys.stderr)
                return 1
            return 0 if start_queued(j) else 1
        if cmd == "resume":
            job = j["job"] if j else key
            if job not in st["paused"]:
                print("job %s is not paused by the governor" % job)
                return 1
            do_resume(st, job, "manual")
            st["paused"].pop(job, None)
            save_state(st)
            print("resumed %s" % job)
            return 0
        if not j or j["state"] != "running":
            print("error: no running job matches %s" % key, file=sys.stderr)
            return 1
        if j["critical"] and "--force" not in argv:
            print("error: %s is in a critical phase (%s); add --force to pause anyway" % (j["job"], j["critical"]), file=sys.stderr)
            return 3
        do_pause(st, j, "manual pause", "manual")
        save_state(st)
        print("paused %s (%d processes)" % (j["job"], len(st["paused"][j["job"]]["pids"])))
        return 0


def daemon():
    ensure_dirs()
    lockf = open(os.path.join(GOV_DIR, "daemon.lock"), "a+")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("sume-bg-governor: another daemon holds %s; exiting" % os.path.join(GOV_DIR, "daemon.lock"))
        return 0
    with open(os.path.join(GOV_DIR, "daemon.pid"), "w") as f:
        f.write(str(os.getpid()))
    stop = {"flag": False}

    def on_term(*_):
        stop["flag"] = True

    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    with Locked():
        st = load_state()
    log("DAEMON start pid=%d mode=%s paused=%d" % (os.getpid(), mode_of(st), len(st["paused"])))
    code = os.path.realpath(__file__)
    code_mtime = os.stat(code).st_mtime
    while not stop["flag"]:
        try:
            if os.stat(code).st_mtime != code_mtime:
                log("DAEMON code changed on disk; exiting so launchd starts the new version")
                break
        except OSError:
            pass
        try:
            with Locked():
                st = load_state()
                tick(st)
                save_state(st)
        except Exception as e:
            log("ERROR tick: %r" % (e,))
        slept = 0.0
        while slept < config()["interval_s"] and not stop["flag"]:
            try:
                serve_swaps()
            except Exception as e:
                log("ERROR swap: %r" % (e,))
            time.sleep(1)
            slept += 1
    log("DAEMON stop pid=%d (paused jobs stay paused until the next daemon resumes them)" % os.getpid())
    return 0


def plist_text():
    py = "/usr/bin/python3" if os.path.exists("/usr/bin/python3") else sys.executable
    script = os.path.realpath(__file__)
    path = ":".join([os.path.join(HOME, ".config/tokenmaxxing/bin"), os.path.join(HOME, ".local/bin"), os.path.join(HOME, ".local/node/bin"),
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    return """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>%s</string>
  <key>ProgramArguments</key>
  <array><string>%s</string><string>%s</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>%s</string><key>HOME</key><string>%s</string></dict>
  <key>StandardOutPath</key><string>%s</string>
  <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
""" % (LABEL, py, script, path, HOME, os.path.join(GOV_DIR, "daemon.out"), os.path.join(GOV_DIR, "daemon.out"))


def install():
    ensure_dirs()
    dest = os.path.join(HOME, "Library/LaunchAgents", LABEL + ".plist")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, "w", encoding="utf-8") as f:
        f.write(plist_text())
    dom = "gui/%d" % os.getuid()
    run(["launchctl", "bootout", "%s/%s" % (dom, LABEL)], 20)
    time.sleep(1)
    r = subprocess.run(["launchctl", "bootstrap", dom, dest], capture_output=True, text=True)
    if r.returncode != 0:
        print("error: launchctl bootstrap %s %s failed: %s" % (dom, dest, (r.stderr or r.stdout).strip()), file=sys.stderr)
        return 1
    with Locked():
        st = load_state()
    print("installed %s (%s); mode=%s" % (dest, dom, mode_of(st)))
    return 0


def uninstall():
    with Locked():
        st = load_state()
        for job in list(st["paused"]):
            do_resume(st, job, "uninstall")
        save_state(st)
    dom = "gui/%d" % os.getuid()
    run(["launchctl", "bootout", "%s/%s" % (dom, LABEL)], 20)
    dest = os.path.join(HOME, "Library/LaunchAgents", LABEL + ".plist")
    try:
        os.remove(dest)
    except OSError:
        pass
    print("uninstalled %s (paused jobs resumed)" % LABEL)
    return 0


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0
    cmd, rest = argv[0], argv[1:]
    if cmd == "daemon":
        return daemon()
    if cmd == "once":
        with Locked():
            st = load_state()
            res = tick(st, "once")
            save_state(st)
        print(json.dumps({"mode": res["mode"], "pressure": res.get("pressure"), "actions": res["actions"]}))
        return 0
    if cmd == "status":
        return status(rest)
    if cmd == "admit":
        ensure_dirs()
        res = admit(rest, load_state())
        print(json.dumps(res))
        return 0
    if cmd in ("pause", "resume", "start", "pin", "unpin"):
        return manual(cmd, rest)
    if cmd == "mode":
        if not rest or rest[0] not in ("observe", "enforce", "off"):
            print("error: mode observe|enforce|off", file=sys.stderr)
            return 2
        with Locked():
            st = load_state()
            st["mode"] = rest[0]
            save_state(st)
        log("MODE %s (manual)" % rest[0])
        print("governor mode: %s" % rest[0])
        return 0
    if cmd == "notify":
        notify(" ".join(rest))
        return 0
    if cmd == "swap":
        ensure_dirs()
        return swap_request(rest)
    if cmd == "flush":
        with Locked():
            st = load_state()
            flush_notify(st, force=True)
            save_state(st)
        return 0
    if cmd == "install":
        return install()
    if cmd == "uninstall":
        return uninstall()
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
