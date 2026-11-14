#!/usr/bin/env python3
import json
import os
import re
import sys
import time

USAGE = """cstack-quota.py status [--json] [--running-fable N]
cstack-quota.py fable-plan
cstack-quota.py launch-check --model <m> [--effort <e>] [--running-fable N]
cstack-quota.py model-info --model <m> [--effort <e>]

Reads tokenmaxxing state (CSTACK_TOKENMAXXING_DIR, default ~/.config/tokenmaxxing).
Never prints credentials."""

FABLE_OK_MAX = float(os.environ.get("SUME_BG_FABLE_OK_MAX", "95"))
FIVE_OK_MAX = float(os.environ.get("SUME_BG_FIVE_OK_MAX", "95"))
LOW_HEADROOM = float(os.environ.get("SUME_BG_FABLE_LOW_HEADROOM", "10"))
RESERVE_PER_JOB = float(os.environ.get("SUME_BG_FABLE_RESERVE_PER_JOB", "3"))
LIVE_MAX_AGE_S = float(os.environ.get("SUME_BG_QUOTA_LIVE_MAX_AGE_S", "1800"))
EFFORTS = ("max", "xhigh", "high", "medium", "low")


def tm_dir():
    return os.environ.get("CSTACK_TOKENMAXXING_DIR") or os.path.expanduser("~/.config/tokenmaxxing")


def now_s():
    v = os.environ.get("CSTACK_QUOTA_NOW")
    return float(v) if v else time.time()


def load(name):
    try:
        with open(os.path.join(tm_dir(), name), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def secs(ts):
    if not ts:
        return None
    ts = float(ts)
    return ts / 1000.0 if ts > 1e12 else ts


def window(rec, now):
    if not isinstance(rec, dict):
        return 0.0, None
    used = rec.get("usedPercentage")
    reset = secs(rec.get("resetsAt"))
    if used is None:
        return 0.0, reset
    if reset is not None and reset <= now:
        return 0.0, None
    return float(used), reset


def is_fable(model):
    if not model:
        return False
    m = re.sub(r"[^a-z0-9]", "", model.lower())
    m = m[len("claude"):] if m.startswith("claude") else m
    return m.startswith(("fable", "fabel", "fabl", "fabe")) or "fable" in m


def effort_of(model, effort):
    if effort:
        e = effort.lower()
        return "max" if e == "maximum" else e
    for w in re.split(r"[^a-z]+", (model or "").lower()):
        if w in EFFORTS:
            return w
        if w == "maximum":
            return "max"
    return "high" if is_fable(model) else ""


def accounts(now):
    data = load("accounts.json") or {}
    active = data.get("activeAccountUuid")
    live_model = load("model-usage.json") or {}
    live_usage = load("usage.json") or {}
    out = []
    for a in data.get("accounts") or []:
        is_active = a.get("accountUuid") == active
        last_usage = a.get("lastUsage") or {}
        per_model = a.get("lastPerModel") or {}
        sampled = secs(a.get("lastPerModelAt") or a.get("lastUsageAt"))
        source = "cached"
        fable_rec = per_model.get("Fable")
        five_rec = last_usage.get("fiveHour")
        week_rec = last_usage.get("sevenDay")
        org = a.get("organizationUuid")
        if is_active:
            lts = secs(live_model.get("ts") or live_model.get("sampledAt"))
            if live_model.get("org") == org and lts and now - lts <= LIVE_MAX_AGE_S:
                fable_rec = (live_model.get("perModel") or {}).get("Fable", fable_rec)
                sampled = lts
                source = "live"
            uts = secs(live_usage.get("ts"))
            if live_usage.get("org") == org and uts and now - uts <= LIVE_MAX_AGE_S:
                five_rec = live_usage.get("fiveHour", five_rec)
                week_rec = live_usage.get("sevenDay", week_rec)
                source = "live"
        fable, fable_reset = window(fable_rec, now)
        five, five_reset = window(five_rec, now)
        week, week_reset = window(week_rec, now)
        reauth = bool(a.get("needsReauth"))
        headroom = 0.0 if reauth else max(0.0, 100.0 - max(fable, week))
        out.append({
            "email": a.get("email") or a.get("label") or "?",
            "active": is_active,
            "needs_reauth": reauth,
            "five": five, "five_reset": five_reset,
            "week": week, "week_reset": week_reset,
            "fable": fable, "fable_reset": fable_reset,
            "fable_headroom": headroom,
            "fable_ok": (not reauth) and max(fable, week) < FABLE_OK_MAX and five < FIVE_OK_MAX,
            "any_ok": (not reauth) and week < FABLE_OK_MAX and five < FIVE_OK_MAX,
            "source": source,
            "sampled_at": sampled,
        })
    return out


def pool(accts, running_fable=0):
    usable = [a for a in accts if not a["needs_reauth"]]
    pct = 100.0 * sum(a["fable_headroom"] for a in usable) / (100.0 * len(usable)) if usable else 0.0
    projected = max(0.0, pct - RESERVE_PER_JOB * running_fable)
    return {
        "accounts": len(accts),
        "usable": len(usable),
        "fable_ok_accounts": sum(1 for a in accts if a["fable_ok"]),
        "fable_headroom_pct": round(pct, 1),
        "running_fable": running_fable,
        "projected_pct": round(projected, 1),
        "low_threshold_pct": LOW_HEADROOM,
    }


def fable_plan(accts, now):
    active = next((a for a in accts if a["active"]), None)
    if active and active["fable_ok"]:
        return {"action": "fable", "target": active["email"], "reason": "active account has Fable headroom"}
    ok = sorted((a for a in accts if a["fable_ok"]), key=lambda a: -a["fable_headroom"])
    if ok:
        return {"action": "swap", "target": ok[0]["email"], "reason": "active account is out of Fable; %s has %.0f%%" % (ok[0]["email"], ok[0]["fable_headroom"])}
    any_ok = sorted((a for a in accts if a["any_ok"]), key=lambda a: a["week"])
    if active and active["any_ok"]:
        return {"action": "opus", "target": active["email"], "reason": "no account has Fable headroom"}
    if any_ok:
        return {"action": "opus", "target": any_ok[0]["email"], "reason": "no account has Fable headroom; %s has weekly headroom" % any_ok[0]["email"]}
    resets = [r for a in accts if not a["needs_reauth"] for r in (a["week_reset"], a["five_reset"]) if r]
    soonest = min(resets) if resets else None
    return {"action": "wait", "target": "", "reason": "every account is out of weekly quota", "reset": soonest}


def fmt_reset(ts, now):
    if not ts:
        return "-"
    d = ts - now
    if d <= 0:
        return "now"
    h, m = int(d // 3600), int(d % 3600 // 60)
    return "%dd%dh" % (h // 24, h % 24) if h >= 24 else "%dh%02dm" % (h, m)


def fmt_age(ts, now):
    if not ts:
        return "never"
    d = max(0, now - ts)
    if d < 3600:
        return "%dm ago" % (d // 60)
    if d < 86400:
        return "%dh ago" % (d // 3600)
    return "%dd ago" % (d // 86400)


def status_text(accts, p, now):
    lines = ["tokenmaxxing pool: %d accounts (%d usable, %d with Fable headroom) · Fable headroom %.0f%% of pool, projected %.0f%% with %d Fable worker(s) · warn below %.0f%%" % (
        p["accounts"], p["usable"], p["fable_ok_accounts"], p["fable_headroom_pct"], p["projected_pct"], p["running_fable"], p["low_threshold_pct"])]
    for a in sorted(accts, key=lambda a: (not a["active"], a["needs_reauth"], -a["fable_headroom"])):
        flag = "needs-reauth" if a["needs_reauth"] else ("Fable ok" if a["fable_ok"] else ("Opus only" if a["any_ok"] else "exhausted"))
        lines.append("%s %-28s 5h %3.0f%%  week %3.0f%% (resets %s)  Fable %3.0f%% (resets %s)  %-12s %s %s" % (
            "●" if a["active"] else "○", a["email"][:28], a["five"], a["week"], fmt_reset(a["week_reset"], now),
            a["fable"], fmt_reset(a["fable_reset"], now), flag, a["source"], fmt_age(a["sampled_at"], now)))
    return "\n".join(lines)


def arg(argv, name, default=None):
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return default


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0
    cmd, rest = argv[0], argv[1:]
    now = now_s()
    running = int(arg(rest, "--running-fable", "0") or 0)
    if cmd == "model-info":
        model = arg(rest, "--model", "")
        print(json.dumps({"fable": is_fable(model), "effort": effort_of(model, arg(rest, "--effort"))}))
        return 0
    accts = accounts(now)
    if cmd == "status":
        p = pool(accts, running)
        if "--json" in rest:
            print(json.dumps({"pool": p, "accounts": accts}, indent=1))
        elif not accts:
            print("tokenmaxxing pool: no accounts found in %s" % tm_dir())
        else:
            print(status_text(accts, p, now))
        return 0
    if cmd == "fable-plan":
        print(json.dumps(fable_plan(accts, now)))
        return 0
    if cmd == "launch-check":
        model = arg(rest, "--model", "")
        if not is_fable(model) or not accts:
            return 0
        p = pool(accts, running)
        if p["fable_ok_accounts"] == 0:
            print("quota: no tokenmaxxing account has Fable headroom (pool %.0f%%); a Fable worker will stop at its first limit" % p["fable_headroom_pct"])
            return 10
        if p["projected_pct"] < LOW_HEADROOM:
            print("quota: Fable headroom is low: %.0f%% of the pool now, projected %.0f%% with %d Fable worker(s) running (warn below %.0f%%)" % (
                p["fable_headroom_pct"], p["projected_pct"], running, LOW_HEADROOM))
            return 10
        return 0
    print(USAGE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
