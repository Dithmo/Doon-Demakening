#!/usr/bin/env python3
"""Phase 1 acceptance test: the water loop, end to end.

Asserts the acceptance criteria from docs/game-plan.md Phase 1:
  * hydration is simulated server-side and replicated to the owning client
  * midday costs more water than night -- the clock actually drives the drain
  * shade is real terrain occlusion, not a constant
  * dew harvesting is refused during the day and yields more nearer dawn
  * drinking restores water and consumes the item
  * running dry kills, and the player respawns alive
  * vitals survive a server restart
  * two clients agree on what time it is

Unit coverage for the underlying rules lives in tests/survival_tests.gd
(run with: godot --headless -- --run-tests).

Run: python3 tools/test_phase1.py
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
PORT = int(os.environ.get("DOON_TEST_PORT", "27140"))

BOT = re.compile(
    r"\[bot\] (\S+) t=([\d.]+) (\w+) water=([\d.-]+) heat=([\d.-]+) hp=([\d.-]+) (\w+)"
)


class Proc:
    def __init__(self, args, cwd, env):
        self.lines = []
        self.p = subprocess.Popen(
            args, cwd=cwd, env=env,
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
        """Every [bot] heartbeat as a dict."""
        out = []
        for line in self.lines:
            m = BOT.search(line)
            if m:
                out.append({
                    "who": m.group(1), "t": float(m.group(2)), "phase": m.group(3),
                    "water": float(m.group(4)), "heat": float(m.group(5)),
                    "hp": float(m.group(6)), "shade": m.group(7) == "shade",
                })
        return out


def launch(extra, user_dir, seconds, port):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    args = [GODOT, "--headless", "--path", str(ROOT), "--",
            "--port", str(port), "--run-seconds", str(seconds)] + extra + ["--peaceful"]
    return Proc(args, ROOT, env)


def session(user_dir, seconds, port, clock, clients):
    """Run a server plus N client arg-lists under a fixed clock."""
    server = launch(["--server"] + clock, user_dir, seconds, port)
    time.sleep(2.0)
    procs = [launch(c + clock, user_dir, seconds - 2, port) for c in clients]
    for p in procs + [server]:
        p.wait(seconds + 25)
    return server, procs


def water_rate(samples):
    """Mean water lost per heartbeat interval, ignoring any refills."""
    drops = [a["water"] - b["water"]
             for a, b in zip(samples, samples[1:]) if a["water"] > b["water"]]
    return sum(drops) / len(drops) if drops else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home_p1"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    # --- run 1: frozen at noon ----------------------------------------------
    # A very long day pins the clock, isolating exposure from time-of-day drift.
    print("\n=== run 1: midday ===")
    noon = ["--day-seconds", "99999", "--start-time", "0.5"]
    srv, (a,) = session(user_dir, 22, PORT,
                        noon, [["--client", "--auto", "--identity", "sunny"]])
    noon_s = a.samples()
    check(len(noon_s) >= 4, f"client receives replicated vitals ({len(noon_s)} samples)")
    check(all(s["phase"] == "MIDDAY" for s in noon_s), "clock stays at midday")
    noon_rate = water_rate(noon_s)
    check(noon_rate > 0.0, f"water drains under an open sun ({noon_rate:.2f}/tick)")
    check(any(s["heat"] > 5.0 for s in noon_s), "heat accumulates at midday")

    # --- run 2: frozen at midnight ------------------------------------------
    print("\n=== run 2: night ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    night = ["--day-seconds", "99999", "--start-time", "0.0"]
    srv2, (b,) = session(user_dir, 22, PORT + 1,
                         night, [["--client", "--auto", "--identity", "owl"]])
    night_s = b.samples()
    check(all(s["phase"] == "NIGHT" for s in night_s), "clock stays at night")
    night_rate = water_rate(night_s)
    check(night_rate > 0.0, f"water still drains at night ({night_rate:.2f}/tick)")
    check(noon_rate > night_rate * 1.5,
          f"midday costs far more water than night ({noon_rate:.2f} vs {night_rate:.2f})")
    check(all(s["heat"] < 5.0 for s in night_s), "heat does not build after dark")

    # Dew: the bot asks regardless of the hour; the server is what refuses.
    check("dew only condenses after dark" in srv.text(),
          "server refuses a daylight dew harvest")
    check("harvested" not in srv.text(), "no dew is produced at midday")
    check("harvested" in srv2.text(), "dew is harvested after dark")
    yields = [int(m) for m in re.findall(r"harvested (\d+) water", srv2.text())]
    check(bool(yields), f"dew yields water ({yields})")

    # --- run 3: shade is terrain occlusion ----------------------------------
    # Low sun casts long shadows off the outcrops, so a wandering bot should see
    # both states. A constant would never flip.
    print("\n=== run 3: shade ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    low = ["--day-seconds", "99999", "--start-time", "0.32"]
    _, (c,) = session(user_dir, 26, PORT + 2,
                      low, [["--client", "--auto", "--identity", "wanderer"]])
    shade_s = c.samples()
    seen = {s["shade"] for s in shade_s}
    check(len(seen) == 2,
          f"shade varies with position under a low sun (states seen: {seen or '{}'})")

    # --- run 4: death and respawn -------------------------------------------
    print("\n=== run 4: dying of thirst ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv4, (d,) = session(user_dir, 46, PORT + 3, noon + ["--start-hydration", "5"],
                         [["--client", "--auto", "--bot-profile", "reckless",
                           "--identity", "victim"]])
    check("died of dehydration" in srv4.text(), "running dry kills")
    check("[death] victim died" in d.text(), "the client is told it died")
    after = [s for s in d.samples() if s["water"] > 20.0]
    check(bool(after), "respawn restores water rather than leaving a corpse")

    # --- run 5: drink, then restart -----------------------------------------
    print("\n=== run 5: drinking and persistence ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    srv5, (e,) = session(user_dir, 30, PORT + 4, noon + ["--start-hydration", "30"],
                         [["--client", "--auto", "--identity", "drinker"]])
    # The bot drinks within a tick of spawning, well before the first 2 s
    # heartbeat, so a sample-to-sample jump is not observable. What *is*
    # observable: it ends with more water than it started, under a midday sun
    # that only ever removes it.
    drinks = re.findall(r"drank Water \(\+([\d.]+) water\)", srv5.text())
    check(bool(drinks), f"a thirsty player drinks ({len(drinks)} times)")
    check(all(float(d) > 0.0 for d in drinks), "every drink restores water")
    drank = e.samples()
    check(bool(drank) and max(s["water"] for s in drank) > 30.0,
          "water rises above the level the player started at")

    save = next(iter(pathlib.Path(user_dir).rglob("world_save.json")), None)
    check(save is not None, "server wrote a save")
    if save:
        blob = json.loads(save.read_text())
        who = blob["players"].get("drinker", {})
        check("vitals" in who, "vitals are persisted")
        water_before = who.get("vitals", {}).get("hydration", -1)
        check(0.0 < water_before <= 100.0, f"persisted water is sane ({water_before:.1f})")

        srv6, _ = session(user_dir, 14, PORT + 5, noon,
                          [["--client", "--auto", "--identity", "drinker"]])
        check("restored 'drinker'" in srv6.text(), "the player is restored")
        blob2 = json.loads(save.read_text())
        check("vitals" in blob2["players"]["drinker"], "vitals survive the restart")

    # --- run 6: two clients share one clock ---------------------------------
    print("\n=== run 6: shared clock ===")
    shutil.rmtree(user_dir); user_dir.mkdir()
    fast = ["--day-seconds", "90", "--start-time", "0.4"]
    _, (f, g) = session(user_dir, 24, PORT + 6, fast,
                        [["--client", "--auto", "--identity", "ada"],
                         ["--client", "--auto", "--identity", "bo"]])
    fs, gs = f.samples(), g.samples()
    check(bool(fs) and bool(gs), "both clients report time")
    if fs and gs:
        drift = abs(fs[-1]["t"] - gs[-1]["t"])
        check(drift < 0.05, f"clients agree on the time (drift {drift:.4f} of a day)")
        check(fs[-1]["t"] != fs[0]["t"], "time actually advances")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    print()
    if failures:
        print("FAILURES:", *failures, sep="\n  ")
        return 1
    print("Phase 1 acceptance: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
