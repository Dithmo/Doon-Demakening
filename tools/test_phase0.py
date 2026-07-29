#!/usr/bin/env python3
"""Phase 0 acceptance test: server + two bot clients, headless.

Asserts the acceptance criteria from docs/game-plan.md Phase 0:
  * two clients connect and handshake
  * both move under server authority
  * pickups are exclusive -- the same entity cannot be banked twice
  * a removed entity disappears for the *other* client too
  * inventories survive a server restart

Run: python3 tools/test_phase0.py
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

GODOT = os.environ.get("GODOT", "/opt/godot/godot")

# What World._on_peer_joined hands a brand-new player. Stated explicitly so
# that adding to the starting kit fails loudly here instead of silently
# skewing the "gathered off the ground" arithmetic.
STARTING_KIT = {"water": 3, "cutteray": 1, "dew_harvester": 1,
                "survival_fabricator": 1}
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27099"))


class Proc:
    def __init__(self, name, args, cwd, env):
        self.name = name
        self.lines = []
        self.p = subprocess.Popen(
            args, cwd=cwd, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )

    def drain(self):
        # Non-blocking-ish: the process exits on its own --run-seconds budget,
        # so just read to EOF after wait().
        if self.p.stdout:
            for line in self.p.stdout:
                self.lines.append(line.rstrip())

    def wait(self, timeout):
        try:
            self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self.drain()

    def text(self):
        return "\n".join(self.lines)


def launch(name, extra, user_dir, seconds):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    args = [GODOT, "--headless", "--path", str(ROOT)]
    args += ["--", "--port", str(PORT), "--run-seconds", str(seconds)] + extra + ["--peaceful"]
    return Proc(name, args, ROOT, env)


def save_file(user_dir):
    hits = list(pathlib.Path(user_dir).rglob("world_save.json"))
    return hits[0] if hits else None


def run_session(user_dir, seconds, label):
    server = launch("server", ["--server"], user_dir, seconds)
    time.sleep(2.0)
    # Forager bots ignore resource nodes, so this harness keeps testing ground
    # pickups rather than whatever later phases made more attractive to walk to.
    bot = ["--client", "--auto", "--bot-profile", "forager", "--identity"]
    a = launch("alice", bot + ["alice"], user_dir, seconds - 2)
    b = launch("bob", bot + ["bob"], user_dir, seconds - 2)
    for p in (a, b, server):
        p.wait(seconds + 25)
    print(f"--- {label}: server ---")
    print(server.text())
    return server, a, b


def inventory_totals(proc):
    """Last [inv] line per identity -> {item: count}."""
    last = {}
    for line in proc.lines:
        m = re.match(r"\[inv\] (\S+) \| (.*)$", line)
        if m:
            who, body = m.group(1), m.group(2).strip()
            items = {}
            if body:
                for part in body.split(", "):
                    pm = re.match(r"(\w+) x(\d+)$", part.strip())
                    if pm:
                        items[pm.group(1)] = int(pm.group(2))
            last[who] = items
    return last


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=14.0)
    ap.add_argument("--keep", action="store_true", help="keep the temp user dir")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    # --- run 1: fresh world --------------------------------------------------
    print("\n=== run 1: fresh world ===")
    server, a, b = run_session(user_dir, args.seconds, "run 1")

    check("server listening" in server.text(), "server binds its port")
    check(server.text().count("handshook as") >= 2, "both clients complete handshake")
    check("seeded" in server.text(), "fresh world seeds pickup entities")

    inv1 = inventory_totals(a) | inventory_totals(b)
    check("alice" in inv1, "alice reports inventory state")
    check("bob" in inv1, "bob reports inventory state")

    picked = {}
    for who, items in inv1.items():
        for k, v in items.items():
            picked[k] = picked.get(k, 0) + v
    # Anything held beyond the starting kit was picked up off the ground under
    # server validation.
    n_players = len(inv1)
    gathered = sum(max(0, v - STARTING_KIT.get(k, 0) * n_players)
                   for k, v in picked.items())
    check(gathered > 0, f"clients gathered items off the ground (total {gathered})")

    # Exclusivity: two clients racing the same ground item must not both bank
    # it. This is the concurrency property server authority exists to provide.
    picks = re.findall(r"\[pickup\] (\S+) took (\w+) x(\d+) entity=(\d+)", server.text())
    ids = [p[3] for p in picks]
    check(len(picks) > 0, f"server logged pickups ({len(picks)})")
    check(len(ids) == len(set(ids)), "no entity was picked up twice")
    banked = sum(int(p[2]) for p in picks)
    check(gathered == banked,
          f"items banked ({gathered}) match entities removed ({banked})")

    # Despawn must reach the client that did NOT do the picking up.
    remaining = re.search(r"server saw (\d+) entity", server.text())
    mirrors = dict(re.findall(r"\[mirror\] (\S+) entities=(\d+)", a.text() + "\n" + b.text()))
    check(remaining is not None and len(mirrors) == 2, "both clients reported a final mirror")
    if remaining and len(mirrors) == 2:
        want = remaining.group(1)
        check(all(v == want for v in mirrors.values()),
              f"both clients agree with the server on entity count ({want}; got {mirrors})")

    sf = save_file(user_dir)
    check(sf is not None, "server wrote a save file")
    if sf is None:
        print("\nFAILURES:", *failures, sep="\n  ")
        return 1

    saved = json.loads(sf.read_text())
    check(set(saved.get("players", {})) >= {"alice", "bob"}, "save holds both identities")
    before = {w: saved["players"][w]["inventory"] for w in ("alice", "bob")}
    n_entities_before = len(saved.get("entities", []))
    check(n_entities_before < 24, f"picked-up entities left the world ({n_entities_before} of 24 remain)")

    # --- run 2: restart against the same save --------------------------------
    print("\n=== run 2: restart, same save ===")
    server2, a2, b2 = run_session(user_dir, args.seconds, "run 2")

    check("restored" in server2.text(), "server restores persisted state")
    check("seeded" not in server2.text(), "server does not re-seed an existing world")

    saved2 = json.loads(save_file(user_dir).read_text())
    for who in ("alice", "bob"):
        kept = saved2["players"][who]["inventory"]
        had = {s["id"]: s["count"] for s in before[who] if s}
        now = {s["id"]: s["count"] for s in kept if s}
        ok = all(now.get(k, 0) >= v for k, v in had.items())
        check(ok, f"{who} keeps everything held before the restart")

    # --- run 3: a client whose terrain does not match must be refused ---------
    print("\n=== run 3: terrain mismatch is rejected ===")
    alt = ROOT / "data/regions/synthetic_alt"
    if not alt.exists():
        subprocess.run([sys.executable, "tools/gen_synthetic_region.py",
                        "--out", str(alt), "--seed", "99", "--outcrops", "18"],
                       cwd=ROOT, check=True, capture_output=True)
    server3 = launch("server", ["--server"], user_dir, 10)
    time.sleep(2.0)
    mallory = launch("mallory", ["--client", "--identity", "mallory",
                                 "--region", "res://data/regions/synthetic_alt"], user_dir, 6)
    for p in (mallory, server3):
        p.wait(35)
    check("rejecting peer" in server3.text(), "server refuses a mismatched client")
    check("handshook as 'mallory'" not in server3.text(), "mismatched client never joins")
    check("rejected by server" in mallory.text(), "client is told why it was refused")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    print()
    if failures:
        print("FAILURES:", *failures, sep="\n  ")
        return 1
    print("Phase 0 acceptance: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
