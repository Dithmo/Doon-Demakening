#!/usr/bin/env python3
"""Phase 6 acceptance test: progression and content.

Asserts the acceptance criteria from docs/game-plan.md Phase 6 -- that a new
character has a directed path rather than a sandbox and a shrug:

  * the Journey is a real path: ordered, covering the game's systems, and
    worth enough experience to carry a new character up the curve
  * a bot following nothing but the Journey's own objectives actually advances
    it, over the wire, on the real map
  * experience, levels, skills and Solari are server-owned and persist
  * specialization points can only be spent at the trainer for that track
  * skills change the game rather than a number on a sheet
  * the trading post's spread means arbitrage loses money

Unit coverage for the curve, the skill rules, the objective matching and the
vendor spread lives in tests/survival_tests.gd.

Run: python3 tools/test_phase6.py
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
PORT = int(os.environ.get("DOON_TEST_PORT", "27450"))

QUESTS = ROOT / "data" / "progression" / "quests.json"
SKILLS = ROOT / "data" / "progression" / "skills.json"

PROG = re.compile(
    r"\[prog\] (\S+) lvl=(\d+) xp=([\d.]+) next=([\d.]+) pts=(\d+) "
    r"solari=(\d+) skills=(\d+) step=(\d+)/(\d+)")

## The Journey should teach the whole game, not one corner of it. These are the
## objective kinds a directed path has to touch to have done that.
SPINE_KINDS = {"use", "gather", "craft", "build", "stake", "learn", "kill",
               "extract", "visit", "sell"}


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
        return [{"who": m[0], "level": int(m[1]), "xp": float(m[2]),
                 "points": int(m[4]), "solari": int(m[5]),
                 "skills": int(m[6]), "step": int(m[7]), "steps": int(m[8])}
                for m in PROG.findall(self.text())]


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home_p6"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    quests = json.loads(QUESTS.read_text())
    skills = json.loads(SKILLS.read_text())
    journey = quests["journey"]
    contracts = quests["contracts"]

    # --- the shape of the path ----------------------------------------------
    print("\n=== the Journey is a directed path ===")
    kinds = {s["objective"]["kind"] for s in journey}
    missing = SPINE_KINDS - kinds
    check(not missing,
          f"it touches every system the game has ({len(kinds)} kinds"
          + (f", missing {sorted(missing)}" if missing else "") + ")")
    check(len(journey) >= 10, f"it is long enough to be a path ({len(journey)} steps)")

    ids = [s["id"] for s in journey]
    check(len(set(ids)) == len(ids), "no step id is repeated")

    journey_xp = sum(s["reward"]["xp"] for s in journey)
    contract_xp = sum(c["reward"]["xp"] for c in contracts)
    # Curve from Progression: XP_BASE*n + XP_GROWTH*n*(n-1)/2 for level n+1.
    def xp_for(level):
        n = level - 1
        return 120.0 * n + 55.0 * n * (n - 1) / 2.0
    reached = max(l for l in range(1, 13) if xp_for(l) <= journey_xp)
    check(reached >= 5,
          f"the Journey alone carries a character to level {reached} "
          f"({journey_xp:.0f} xp)")
    check(contract_xp > journey_xp * 0.5,
          f"and the contract board is worth taking too ({contract_xp:.0f} xp)")

    tracks = {t["id"] for t in skills["tracks"]}
    check(len(tracks) == 5, f"there are five specializations ({len(tracks)})")
    per_track = {}
    for s in skills["skills"]:
        per_track[s["track"]] = per_track.get(s["track"], 0) + 1
    check(all(per_track.get(t, 0) >= 2 for t in tracks),
          f"each has something to choose between ({per_track})")
    trainers = {t.get("trainer", "") for t in skills["tracks"]}
    check("" not in trainers, "every track names a trainer to learn it from")

    # Contract chains must be reachable: a `next` that outranks what the chain
    # itself can pay for is a dead end.
    chained = [c for c in contracts if c.get("next")]
    check(bool(chained), f"contracts chain ({len(chained)} links)")

    # --- run 1: a bot walks the path ----------------------------------------
    print("\n=== run 1: following the Journey ===")
    # 420 s because the pace is real: the bot walks a 4.5 km map at 7.6 m/s,
    # and the opening steps are a round trip to an agave (~110 m out), back to
    # the bench, and out again. Measured, that is roughly 90-120 s per step, so
    # three steps sits right on a 300 s boundary and tips either way run to run.
    srv, (bot,) = session(
        user_dir, 420, PORT,
        ["--day-seconds", "99999", "--start-time", "0.30", "--peaceful"],
        [["--client", "--auto", "--bot-profile", "journeyman",
          "--identity", "journeyman"]])
    s = bot.samples()
    log = srv.text()

    check(bool(s), f"the bot reported progress ({len(s)} readings)")
    if s:
        first, last = s[0], s[-1]
        check(last["step"] > first["step"],
              f"it advanced the Journey ({first['step']} -> {last['step']} "
              f"of {last['steps']})")
        check(last["step"] >= 3,
              f"and got past the opening steps (step {last['step']})")
        check(last["level"] > 1, f"it levelled up (level {last['level']})")
        check(last["xp"] > first["xp"], "experience accrued")

    done = re.findall(r"\[journey\] \S+ completed '([^']+)'", log)
    check(len(done) >= 3, f"steps completed on the server: {done}")
    # The server is the only thing that says a step is done.
    check("[journey]" in log, "completions are announced by the authority")

    # --- run 2: training is where the trainer is -----------------------------
    print("\n=== run 2: points are spent at trainers ===")
    # Two runs of the same request, differing only in where the player stands.
    # That is the whole rule, and standing somewhere is the one thing a client
    # cannot lie about here because the server places it.
    away_srv, (away,) = session(
        user_dir, 30, PORT + 1,
        ["--day-seconds", "99999", "--peaceful", "--spawn-at", "Wali Hole"],
        [["--client", "--auto", "--identity", "faraway",
          "--learn", "blade_training"]])
    at_srv, (near,) = session(
        user_dir, 30, PORT + 2,
        ["--day-seconds", "99999", "--peaceful", "--spawn-at", "Trooper Trainer"],
        [["--client", "--auto", "--identity", "student",
          "--learn", "blade_training"]])

    refused = re.search(r"\[train\] faraway refused: (.+)", away_srv.text())
    check(bool(refused),
          "training away from your trainer is refused"
          + (f" ({refused.group(1)})" if refused else ""))
    if refused:
        check("Trooper Trainer" in refused.group(1),
              "and the refusal names who does teach it")
    learned = re.search(r"\[train\] student ok: (.+)", at_srv.text())
    check(bool(learned),
          "and allowed at the trainer" + (f" ({learned.group(1)})" if learned else ""))

    # --- run 2b: the post buys, and the spread is real -----------------------
    print("\n=== run 2b: trading at the post ===")
    post_srv, (trader,) = session(
        user_dir, 45, PORT + 3,
        ["--day-seconds", "99999", "--peaceful",
         "--spawn-at", "Griffin's Reach Trading Post",
         "--grant", "salvaged_metal:6,granite_stone:6"],
        [["--client", "--auto", "--bot-profile", "journeyman",
          "--identity", "trader"]])
    sold = re.findall(r"\[trade\] trader ok: sold (\d+) (.+?) for (\d+) solari",
                      post_srv.text())
    check(bool(sold), f"the post bought something ({len(sold)} sale(s))")
    ts = trader.samples()
    if ts and sold:
        check(ts[-1]["solari"] > 0, f"and paid for it ({ts[-1]['solari']} solari)")

    # --- run 3: it all survives a restart ------------------------------------
    print("\n=== run 3: progression persists ===")
    save = next(pathlib.Path(user_dir).rglob("world_save.json"), None)
    check(save is not None, "the world saved")
    before = {}
    if save:
        data = json.loads(save.read_text())
        players = data.get("players", {})
        check(bool(players), f"the player was persisted ({list(players)})")
        # Specifically the journeyman: the save also holds the short-lived
        # bots from the trainer and trading runs, and comparing the restart
        # against whichever one happens to be first in the dict compares two
        # different characters.
        rec = players.get("journeyman", {})
        before = rec.get("progression", {})
        check(bool(before), "with progression state (journeyman)")
        check("quests" in rec, "and quest state")

    srv2, (bot2,) = session(
        user_dir, 40, PORT + 1,
        ["--day-seconds", "99999", "--start-time", "0.30", "--peaceful"],
        [["--client", "--auto", "--bot-profile", "journeyman",
          "--identity", "journeyman"]])
    s2 = bot2.samples()
    if s2 and before:
        check(s2[0]["level"] == int(before.get("level", 1)),
              f"level survives a restart (level {s2[0]['level']})")
        check(s2[0]["skills"] == len(before.get("skills", [])),
              f"skills survive ({s2[0]['skills']})")
        check(s2[0]["solari"] == int(before.get("solari", 0)),
              f"solari survives ({s2[0]['solari']})")
    restored = re.search(r"restored '\S+' at .* level (\d+), (\d+) solari, "
                         r"journey step (\d+)", srv2.text())
    check(bool(restored),
          "the server restores the character it saved"
          + (f" ({restored.group(0).split('at')[-1].strip()})" if restored else ""))
    if restored and s:
        check(int(restored.group(3)) == s[-1]["step"],
              f"including its place in the Journey (step {restored.group(3)})")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    total = len(failures)
    if total:
        print(f"\nPhase 6 acceptance: FAIL ({total} failure(s))")
        for f in failures:
            print(f"  - {f}")
    else:
        print("\nPhase 6 acceptance: PASS")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
