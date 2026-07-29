#!/usr/bin/env python3
"""Phase 4 acceptance test: the threat, over the wire.

Asserts the acceptance criteria from docs/game-plan.md Phase 4:
  * threat accrues on open sand and rouses one shared worm
  * the worm surfaces with a warning, then strikes what is still on sand
  * reaching rock during that warning actually saves you
  * a thumper pulls the worm somewhere that is not you
  * a running shield makes you measurably louder
  * hostiles fight back, and what they leave behind is water

Unit coverage for the worm, shield and blood rules lives in
tests/survival_tests.gd (run with: godot --headless -- --run-tests).

Run: python3 tools/test_phase4.py
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

GODOT = os.environ.get("GODOT", "/opt/godot/godot")
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27430"))

BOT = re.compile(r"\[bot\] (\S+) .*threat=([\d.]+) worm=(\d) on=(\w+)")


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

    def samples(self):
        return [{"who": m[0], "threat": float(m[1]), "worm": int(m[2]), "on": m[3]}
                for m in BOT.findall(self.text())]


def launch(extra, user_dir, seconds, port):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    return Proc([GODOT, "--headless", "--path", str(ROOT), "--",
                 "--port", str(port), "--run-seconds", str(seconds)] + extra, env)


def session(user_dir, seconds, port, extra, clients):
    server = launch(["--server"] + extra, user_dir, seconds, port)
    time.sleep(2.0)
    procs = [launch(c + extra, user_dir, seconds - 3, port) for c in clients]
    for p in procs + [server]:
        p.wait(seconds + 30)
    return server, procs


def threat_rate(samples):
    """Mean threat gained per heartbeat, ignoring the resets after a strike."""
    rises = [b["threat"] - a["threat"]
             for a, b in zip(samples, samples[1:]) if b["threat"] > a["threat"]]
    return sum(rises) / len(rises) if rises else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home_p4"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    # Pin the clock: this phase is about the sand, not the sun.
    clock = ["--day-seconds", "99999", "--start-time", "0.30"]

    # --- run 1: open sand gets you taken ------------------------------------
    print("\n=== run 1: crossing open sand ===")
    srv, (prey,) = session(user_dir, 74, PORT, clock,
                           [["--client", "--auto", "--bot-profile", "prey",
                             "--identity", "morsel"]])
    log = srv.text()
    s = prey.samples()
    check(bool(s), f"the client is told its own threat ({len(s)} samples)")
    check(any(x["on"] == "SAND" for x in s), "the bot reaches open sand")
    check(max((x["threat"] for x in s), default=0) > 20.0,
          f"threat builds on sand (peak {max((x['threat'] for x in s), default=0):.0f})")

    check("[worm] roused" in log, "enough noise rouses the worm")
    check("[worm] surfacing" in log, "it surfaces before it strikes")
    check("[worm] strikes" in log, "it strikes")
    check("died of Shai-Hulud" in log, "and it takes whoever is still on sand")
    # The warning has to reach the player, or the strike is not survivable.
    check(any(x["worm"] == 2 for x in s), "the client sees the surfacing warning")

    order = [log.index("[worm] roused"), log.index("[worm] surfacing"),
             log.index("[worm] strikes")]
    check(order == sorted(order), "rouse, surface, strike -- in that order")

    # --- run 2: rock saves you ----------------------------------------------
    print("\n=== run 2: running for rock ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv2, (quarry,) = session(user_dir, 60, PORT + 1, clock,
                              [["--client", "--auto", "--bot-profile", "quarry",
                                "--identity", "runner"]])
    log2 = srv2.text()
    check("[worm] roused" in log2, "the worm is roused again")
    check("[worm] loses interest" in log2, "reaching rock makes it lose interest")
    check("died of Shai-Hulud" not in log2, "and the player is not taken")
    q = quarry.samples()
    check(any(x["on"] == "ROCK" for x in q), "the bot did reach rock")

    # --- run 3: a thumper buys you somewhere else to be ---------------------
    print("\n=== run 3: thumper as bait ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv3, _ = session(user_dir, 66, PORT + 2, clock + ["--grant", "thumper:1"],
                      [["--client", "--auto", "--bot-profile", "quarry",
                        "--identity", "trapper"]])
    log3 = srv3.text()
    check("deployed Thumper" in log3, "the thumper goes down")
    check("[worm] roused" in log3, "the thumper wakes the worm on its own")
    check("died of Shai-Hulud" not in log3,
          "and the worm goes for the thumper, not the player")

    # --- run 4: a shield is loud --------------------------------------------
    print("\n=== run 4: the shield trade ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    _, (bare,) = session(user_dir, 40, PORT + 3, clock,
                         [["--client", "--auto", "--bot-profile", "prey",
                           "--identity", "bare"]])
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv5, (shielded,) = session(user_dir, 40, PORT + 4,
                                clock + ["--grant", "body_shield:1"],
                                [["--client", "--auto", "--bot-profile", "prey",
                                  "--identity", "shielded"]])
    check("equipped Holtzman Shield" in srv5.text(), "the shield is worn")
    bare_rate = threat_rate(bare.samples())
    shield_rate = threat_rate(shielded.samples())
    check(bare_rate > 0.0 and shield_rate > 0.0, "both bots make noise")
    check(shield_rate > bare_rate * 1.5,
          f"a running shield is markedly louder ({shield_rate:.1f} vs {bare_rate:.1f})")

    # --- run 5: hostiles, and the water they leave --------------------------
    print("\n=== run 5: hostiles and blood ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv6, (fighter,) = session(user_dir, 74, PORT + 5,
                               clock + ["--grant", "crysknife:1,blood_extractor:1"],
                               [["--client", "--auto", "--bot-profile", "fighter",
                                 "--identity", "blade"]])
    log6 = srv6.text()
    check("[hostiles] seeded" in log6, "camps are populated")
    hits = re.findall(r"\[combat\] blade: (.+)", log6)
    check(bool(hits), f"the bot lands hits ({len(hits)})")
    check(any("killed" in h for h in hits), "and kills something")
    check("[blood] blade drew a blood sack" in log6,
          "a body can be drawn for water")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    print()
    if failures:
        print("FAILURES:", *failures, sep="\n  ")
        return 1
    print("Phase 4 acceptance: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
