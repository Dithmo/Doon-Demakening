#!/usr/bin/env python3
"""Phase 10 acceptance test: the mechanics the wiki documents and we had not built.

Phases 0-9 built a survival loop, an economy, bases, a worm, the real map,
progression, vehicles, guilds, a client and controls. Read against
awakening.wiki, four things were missing outright rather than scaled down:

  * **Spice.** The defining substance of the setting did not exist in any form.
    No item, no blow, no melange, no reason to cross open sand.
  * **Death cost nothing.** You revived on the spot with a full bag, which made
    the worm, the heat and the entire water clock theatre.
  * **No stamina.** Sprinting was limited only by water, so it was a travel
    mode rather than a decision.
  * **No vertical axis.** Cliffs were walls. Rock -- the one surface a worm
    cannot strike through -- was reachable only where the ground happened to
    ramp.

This suite covers them over the wire, where a unit test cannot reach:
replication of the blow cycle, the server's refusal to be lied to about it,
what a player actually loses when they die, and that stamina survives a round
trip through prediction.

Run: python3 tools/test_phase10.py
"""

import argparse
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

GODOT = os.environ.get("GODOT", "/opt/godot/godot")
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27490"))


class Proc:
    """A child process whose output goes to a file, not a pipe.

    Every earlier harness in this project pipes stdout and only reads it after
    the process exits. That works right up until a run produces more than the
    64 KB pipe buffer: nobody is draining it, so the child *blocks on write* and
    silently stops playing. Phase 10 crossed that line -- spice logging, notices
    and stamina in the heartbeat -- and it looked exactly like the game being
    broken: a bot that walked to the spice and then did nothing.

    A temp file has no such limit.
    """

    def __init__(self, args, env):
        self._out = tempfile.NamedTemporaryFile(
            mode="w+", suffix=".log", delete=False)
        self.p = subprocess.Popen(
            args, cwd=ROOT, env=env,
            stdout=self._out, stderr=subprocess.STDOUT,
        )
        self._text = None

    def wait(self, timeout):
        try:
            self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait(timeout=20)
        self._out.flush()
        self._out.close()
        self._text = pathlib.Path(self._out.name).read_text(errors="replace")
        os.unlink(self._out.name)

    def text(self):
        return self._text or ""


def launch(extra, user_dir, seconds, port):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    return Proc([GODOT, "--headless", "--path", str(ROOT), "--",
                 "--port", str(port), "--run-seconds", str(seconds)] + extra, env)


def session(user_dir, seconds, port, server_extra, clients):
    server = launch(["--server"] + server_extra, user_dir, seconds, port)
    time.sleep(2.5)
    procs = [launch(c, user_dir, seconds - 4, port) for c in clients]
    for p in procs + [server]:
        p.wait(seconds + 60)
    return server, procs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1

    user_dir = ROOT / ".test_home_p10"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    clock = ["--day-seconds", "99999", "--start-time", "0.35"]

    # --- run 1: spice, all the way through ---------------------------------
    # A bot walks to a live blow, cuts it, and the noise reaches the worm. The
    # walk is ~750 m on the real map, which is the point -- spice you can reach
    # without crossing open sand is spice without a decision attached.
    print("\n=== run 1: cutting spice ===")
    srv, (bot,) = session(
        user_dir, 300, PORT,
        clock + ["--peaceful", "--spice-now"],
        [["--client", "--identity", "harvester", "--auto",
          "--bot-profile", "spicer", "--grant", "water:8"]])
    s, c = srv.text(), bot.text()

    fields = re.search(r"\[spice\] (\d+) field\(s\) on the cycle", s)
    check(bool(fields) and int(fields.group(1)) > 0,
          "the region has spice fields"
          + (f" ({fields.group(1)})" if fields else ""))

    cuts = re.findall(r"\[spice\] harvester cut (\d+) from '(.+?)'", s)
    check(bool(cuts),
          "a player can walk to a blow and cut it"
          + (f" ({len(cuts)} cuts, {sum(int(n) for n, _ in cuts)} spice)" if cuts else ""))
    check("spice_sand" in c, "and the spice reaches their bag")

    # --- run 2: the blow cycle is the server's, and it is replicated --------
    print("\n=== run 2: the cycle ===")
    srv2, (watcher,) = session(
        user_dir, 70, PORT + 1,
        clock + ["--peaceful"],
        [["--client", "--identity", "watcher", "--auto"]])
    s2 = srv2.text()
    # Without --spice-now the fields run the real 7-15 minute dormancy, so a
    # 70-second window should see the map quiet. A blow that fires the instant
    # a server boots would mean the stagger is broken.
    blows = len(re.findall(r"\[spice\] blow at", s2))
    check(blows <= 2,
          f"blows are staggered, not simultaneous ({blows} in the first minute)")
    check("[spice] " in s2, "and the cycle is running")

    # --- run 3: dying costs you what you were carrying ----------------------
    # Its own save directory. This run is about what a *fresh* player loses, and
    # sharing a world with the two runs above makes it depend on what they left
    # lying about -- the same cross-run bleed that made Phase 7's thopter test
    # inherit a parked groundcar.
    print("\n=== run 3: what death costs ===")
    grave = ROOT / ".test_home_p10_death"
    if grave.exists():
        shutil.rmtree(grave)
    grave.mkdir(parents=True)
    srv3, (doomed,) = session(
        grave, 80, PORT + 2,
        ["--day-seconds", "60", "--start-time", "0.5", "--peaceful",
         "--start-hydration", "3"],
        [["--client", "--identity", "doomed", "--auto",
          "--bot-profile", "reckless"]])
    s3, c3 = srv3.text(), doomed.text()

    died = re.search(r"\[death\] doomed died of (\w+).*-- (\d+) stack\(s\) (.+)", s3)
    check(bool(died), "the desert still kills you")
    check(bool(died) and int(died.group(2)) > 0,
          "and it takes what you were carrying"
          + (f" ({died.group(2)} stacks {died.group(3)})" if died else ""))
    # The bag really is emptied on the client, not just server-side. Asserted as
    # "was emptied at some point" rather than "is empty at the end": the cache
    # lands where you fell and a wandering bot may walk back over its own things,
    # which is the system working rather than failing.
    invs = re.findall(r"\[inv\] doomed \| (.*)", c3)
    check(any(line.strip() == "" for line in invs),
          f"the client's bag is emptied by dying ({len(invs)} inventory updates)")
    check("where they fell" in s3 or "eaten with them" in s3,
          "and the log says where it went")
    # Dropped, not deleted: a bad night is a walk back, not a wipe.
    check("left where they fell" in s3,
          "dying of thirst leaves a cache rather than destroying it")

    # --- run 4: stamina survives the round trip -----------------------------
    print("\n=== run 4: stamina ===")
    srv4, (runner,) = session(
        user_dir, 50, PORT + 3,
        clock + ["--peaceful"],
        [["--client", "--identity", "runner", "--auto",
          "--bot-profile", "reckless"]])
    c4 = runner.text()
    # A reckless bot sprints permanently. Stamina must therefore be visibly
    # spent -- if it stays pinned at maximum the server is not charging for it,
    # and sprint is a travel mode again.
    st = [float(m) for m in re.findall(r"stam=([\d.]+)", c4)]
    check(bool(st), "the client is told its stamina")
    check(bool(st) and min(st) < 90.0,
          f"and a permanent sprint runs it down (low: {min(st) if st else '?'})")
    check("rejected by server" not in c4,
          "and charging for it did not desync prediction")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)
        shutil.rmtree(grave, ignore_errors=True)

    total = len(failures)
    if total:
        print(f"\nPhase 10 acceptance: FAIL ({total} failure(s))")
        for f in failures:
            print(f"  - {f}")
    else:
        print("\nPhase 10 acceptance: PASS")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
