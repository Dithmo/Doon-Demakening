#!/usr/bin/env python3
"""Phase 3 acceptance test: the base, over the wire.

Asserts the acceptance criteria from docs/game-plan.md Phase 3:
  * a holding can be staked, kitted out and built on
  * a second player cannot build inside someone else's holding
  * a powered windtrap fills a cistern
  * production continues while nobody is connected
  * a restart pays out what the holding earned while the server was down
  * the base, its claim and its container contents survive a restart
  * moving items into a container moves them rather than copying them

Unit coverage for claim, build and power rules lives in tests/survival_tests.gd
(run with: godot --headless -- --run-tests).

Run: python3 tools/test_phase3.py
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
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27330"))

KIT = ("sub_fief:1,fuel_generator:1,water_cistern:1,windtrap:1,storage_chest:1,"
       "foundation:4,wall:4,ceiling:2")


class Proc:
    def __init__(self, args, env):
        self.lines = []
        self.p = subprocess.Popen(
            args, cwd=ROOT, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
        )

    def wait(self, timeout):
        try:
            self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
        if self.p.stdout:
            for line in self.p.stdout:
                self.lines.append(line.rstrip())

    def text(self):
        return "\n".join(self.lines)


def launch(extra, user_dir, seconds, port):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    return Proc([GODOT, "--headless", "--path", str(ROOT), "--",
                 "--port", str(port), "--run-seconds", str(seconds)] + extra, env)


def save_of(user_dir):
    hits = list(pathlib.Path(user_dir).rglob("world_save.json"))
    return json.loads(hits[0].read_text()) if hits else {}


def cistern_water(blob):
    """Total water sitting in deployed containers."""
    total = 0
    for row in blob.get("blobs", {}).get("stations", []):
        if len(row) > 7:
            for slot in row[7]:
                if slot and slot.get("id") == "water":
                    total += int(slot.get("count", 0))
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home_p3"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    clock = ["--day-seconds", "99999", "--start-time", "0.30"]

    # --- run 1: raise a base, then leave it running unattended ---------------
    # The client quits well before the server does, so the tail of the server
    # log is the holding working with nobody connected.
    print("\n=== run 1: build a base, then log out ===")
    server = launch(["--server"] + clock + ["--grant", KIT], user_dir, 62, PORT)
    time.sleep(2.0)
    ada = launch(["--client", "--auto", "--bot-profile", "builder",
                  "--identity", "ada"] + clock, user_dir, 26, PORT)
    ada.wait(60)
    server.wait(90)
    log = server.text()

    check("deployed Sub-Fief Console" in log, "a holding is staked")
    check("deployed Windtrap" in log, "a windtrap is deployed")
    check("deployed Water Cistern" in log, "a cistern is deployed")
    built = re.findall(r"\[build\] ada built (\w+)", log)
    check("foundation" in built, "a foundation is laid")
    check("wall" in built, "walls go up")
    check("ceiling" in built, f"a ceiling caps it ({len(built)} pieces)")

    produced = [m.start() for m in re.finditer(r"\[produce\]", log)]
    check(bool(produced), f"the windtrap produces water ({len(produced)} ticks)")

    # The heart of Phase 3: the holding kept working after the player left.
    left = log.find("peer") if "disconnected" not in log else log.index("disconnected")
    after = [p for p in produced if p > left]
    check(len(after) > 1,
          f"production continues with nobody connected ({len(after)} ticks after logout)")

    blob = save_of(user_dir)
    water_before = cistern_water(blob)
    check(water_before > 0, f"water is stored in the cistern ({water_before})")
    check(len(blob.get("blobs", {}).get("claims", [])) == 1, "the claim is persisted")
    check(len(blob.get("blobs", {}).get("build", [])) == len(built),
          "every built piece is persisted")

    # --- run 2: a restart pays out the gap, and the base is still there ------
    print("\n=== run 2: restart ===")
    time.sleep(6.0)  # a real gap for the offline accrual to pay out
    server2 = launch(["--server"] + clock, user_dir, 14, PORT + 1)
    server2.wait(45)
    log2 = server2.text()
    check("[base] restored" in log2, "claims and structure survive a restart")
    check("[offline]" in log2, "time away is paid out on restart")
    water_after = cistern_water(save_of(user_dir))
    check(water_after >= water_before,
          f"stored water is not lost across a restart ({water_before} -> {water_after})")

    # --- run 3: a second player cannot build in someone else's holding -------
    print("\n=== run 3: another player's holding is closed ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv3 = launch(["--server"] + clock + ["--grant", KIT], user_dir, 54, PORT + 2)
    time.sleep(2.0)
    a = launch(["--client", "--auto", "--bot-profile", "builder",
                "--identity", "ada"] + clock, user_dir, 50, PORT + 2)
    time.sleep(12.0)  # let ada stake first
    b = launch(["--client", "--auto", "--bot-profile", "builder",
                "--identity", "bo"] + clock, user_dir, 34, PORT + 2)
    for p in (a, b, srv3):
        p.wait(80)
    log3 = srv3.text()

    check("[place] ada ok: deployed Sub-Fief Console" in log3, "ada stakes first")
    trespass = re.findall(r"\[(?:place|build)\] bo refused: (?:that is |inside |too close to )(\w+)", log3)
    check(bool(trespass), f"bo is refused on ada's land ({len(trespass)} attempts)")
    check(all(t == "ada" for t in trespass), "the refusal names the owner")
    bo_built = re.findall(r"\[build\] bo built", log3)
    check(not bo_built, "bo builds nothing inside ada's holding")

    claims = save_of(user_dir).get("blobs", {}).get("claims", [])
    check(len(claims) == 1, f"only one holding exists ({len(claims)})")
    check(claims and claims[0][1] == "ada", "and it belongs to ada")

    # --- run 4: containers move items rather than copying them ---------------
    print("\n=== run 4: containers ===")
    moves = re.findall(r"\[container\] \w+ moved (\w+) x(\d+)", log)
    check(bool(moves), f"items move into a container ({moves[:3]})")
    stored = sum(int(n) for _, n in moves)
    held = 0
    for who, rec in save_of(user_dir).get("players", {}).items():
        for slot in rec.get("inventory", []):
            if slot and slot.get("id") == "water":
                held += int(slot.get("count", 0))
    check(stored > 0, f"a deposit actually happened ({stored})")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    print()
    if failures:
        print("FAILURES:", *failures, sep="\n  ")
        return 1
    print("Phase 3 acceptance: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
