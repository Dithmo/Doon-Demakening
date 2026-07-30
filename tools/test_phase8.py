#!/usr/bin/env python3
"""Phase 8 acceptance test: the client.

Phases 0-7 were all verified headlessly, by bots. That worked -- every rule is
server-owned and every rule is tested -- but it meant presentation drifted two
whole phases behind the simulation without ever failing a check. Vehicles were
replicated and drawn by nobody; progression, trading and guilds had no interface
at all; and the ground was still built as one mesh in one pass, so a windowed
client on the real map never finished loading.

So this suite tests the things a bot cannot notice:

  * a windowed client on the *real* region reaches a drawn frame, and quickly --
    the regression guard for the four-minute stall
  * the ground is built in tiles around the player, not all at once
  * every panel page renders from the replicated mirrors, naming the real
    Journey step, the real trading post, and all five specializations
  * pressing a row on a panel reaches the server and is validated there
  * no two actions share a key

Run: python3 tools/test_phase8.py
"""

import argparse
import json
import os
import pathlib
import re
import shutil
import tempfile
import subprocess
import sys
import time

GODOT = os.environ.get("GODOT", "/opt/godot/godot")
ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = int(os.environ.get("DOON_TEST_PORT", "27470"))

## A windowed client that has not drawn the world within this long is the stall
## this phase exists to prevent. The old whole-map builder blew past four
## minutes; the tiled one gets there in a couple of seconds.
RENDER_BUDGET_S = 60


class Proc:
    def __init__(self, args, env):
        self.lines = []
        # Output goes to a file, never a pipe. Nothing drains stdout while the
        # run is in flight, so a chatty session used to fill the 64 KB pipe
        # buffer and block the child mid-play -- which looks exactly like the
        # game being broken rather than the harness being wrong.
        self._out = tempfile.NamedTemporaryFile(
            mode="w+", suffix=".log", delete=False)
        self.p = subprocess.Popen(
            args, cwd=ROOT, env=env,
            stdout=self._out, stderr=subprocess.STDOUT,
        )

    def wait(self, timeout):
        try:
            self.p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.p.kill()
        self._collect()

    def _collect(self):
        # Read the log file the child wrote to. See the note on _out above.
        if self._out is None:
            return
        self._out.flush()
        self._out.close()
        with open(self._out.name, errors="replace") as fh:
            self.lines = [ln.rstrip() for ln in fh]
        os.unlink(self._out.name)
        self._out = None

    def text(self):
        return "\n".join(self.lines)

    def panel(self):
        return [m.group(1) for m in re.finditer(r"^\[panel\] (.*)$",
                                                self.text(), re.M)]


def launch(extra, user_dir, seconds, port, windowed=False):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    head = [GODOT]
    if windowed:
        # xvfb-run gives Godot a display to render into; there is no monitor
        # here, and a headless client builds no view at all.
        head = ["xvfb-run", "-a", "env", f"HOME={user_dir}", GODOT,
                "--resolution", "1280x800"]
    else:
        head = [GODOT, "--headless"]
    return Proc(head + ["--path", str(ROOT), "--",
                        "--port", str(port), "--run-seconds", str(seconds)] + extra, env)


def session(user_dir, seconds, port, extra, clients, windowed=False):
    server = launch(["--server"] + extra, user_dir, seconds, port)
    time.sleep(2.0)
    procs = [launch(c + extra, user_dir, seconds - 3, port, windowed)
             for c in clients]
    for p in procs + [server]:
        p.wait(seconds + 40)
    return server, procs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1
    have_xvfb = shutil.which("xvfb-run") is not None

    user_dir = ROOT / ".test_home_p8"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)
    shots = user_dir / "shots"
    shots.mkdir()

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    clock = ["--day-seconds", "99999", "--start-time", "0.35"]

    # --- run 1: the real map actually draws --------------------------------
    print("\n=== run 1: a windowed client on the real region ===")
    if not have_xvfb:
        print("       (skipped: no xvfb-run on this machine)")
    else:
        shot = shots / "real.png"
        started = time.time()
        srv, (win,) = session(
            user_dir, RENDER_BUDGET_S, PORT,
            clock + ["--peaceful", "--grant", "groundcar:1,fuel_cell:4"],
            [["--client", "--identity", "player", "--screenshot", str(shot)]],
            windowed=True)
        elapsed = time.time() - started
        text = win.text()

        check(shot.exists() and shot.stat().st_size > 5000,
              f"it draws the world and captures it "
              f"({shot.stat().st_size if shot.exists() else 0} bytes)")
        check(elapsed < RENDER_BUDGET_S + 40,
              f"within the budget ({elapsed:.0f} s)")
        check("hagga_basin_south" in text, "on the real region, not a test map")

        m = re.search(r"\[view\] terrain in (\d+)x(\d+) tiles of (\d+) m, "
                      r"drawn to (\d+) m", text)
        check(bool(m), "the ground is tiled"
              + (f" ({m.group(1)}x{m.group(2)} tiles of {m.group(3)} m)" if m else ""))
        if m:
            total = int(m.group(1)) * int(m.group(2))
            check(total > 400,
                  f"the real map is far more tiles than are ever drawn at once "
                  f"({total} total, radius {m.group(4)} m)")

        check("Parse Error" not in text and "SCRIPT ERROR" not in text,
              "and no script errors on the way")
        # A key bound twice fires both actions and says nothing about it.
        check("bound to both" not in text, "no two actions share a key")

    # --- run 2: every panel page renders real state ------------------------
    print("\n=== run 2: the panels ===")
    pages = ["JOURNEY", "SKILLS", "CONTRACTS", "MARKET", "GUILD", "HOLD"]
    bodies = {}
    for page in pages:
        # HOLD is about a vehicle, and a granted groundcar is an *item in the
        # bag* until something unloads it -- so that page gets a driver bot,
        # which deploys one, fuels it and climbs in. The rest only need to read.
        if page == "HOLD":
            client = ["--client", "--auto", "--bot-profile", "driver",
                      "--identity", "reader", "--panel", page]
            seconds = 50
        else:
            client = ["--client", "--identity", "reader", "--panel", page]
            seconds = 26
        srv, (cli,) = session(
            user_dir, seconds, PORT + 1,
            clock + ["--peaceful", "--grant", "groundcar:1,fuel_cell:4"],
            [client])
        bodies[page] = "\n".join(cli.panel())
        check(bool(bodies[page]), f"{page} renders ({len(cli.panel())} lines)")

    quests = json.loads((ROOT / "data" / "progression" / "quests.json").read_text())
    first_step = quests["journey"][0]["name"]
    check(first_step in bodies.get("JOURNEY", ""),
          f"the Journey page names the real first step ('{first_step}')")
    check("Step 1 of 12" in bodies.get("JOURNEY", ""),
          "and how far through the path you are")

    skills = json.loads((ROOT / "data" / "progression" / "skills.json").read_text())
    shown = sum(1 for t in skills["tracks"] if t["name"] in bodies.get("SKILLS", ""))
    check(shown == 5, f"the Skills page shows all five specializations ({shown})")
    check("Trooper Trainer" in bodies.get("SKILLS", ""),
          "and names who teaches each one")

    check("Griffin's Reach Trading Post" in bodies.get("MARKET", ""),
          "the Market page names the post you are standing at")
    check("solari" in bodies.get("MARKET", ""), "and prices what you are carrying")

    check("Landsraad" in bodies.get("GUILD", ""), "the Guild page covers the Landsraad")
    hold = bodies.get("HOLD", "")
    check("Groundcar" in hold, "the Hold page sees the vehicle")
    check("fuel" in hold and "altitude" in hold,
          "and reports its fuel and altitude while driving")

    # Every page has to survive being opened with nothing to show, which is the
    # state a new character is in for most of them.
    check(all("rows=" in b for b in bodies.values()),
          "every page reports how many rows it offers")

    # --- run 3: a row press reaches the server ----------------------------
    print("\n=== run 3: pressing a row ===")
    srv3, (shopper,) = session(
        user_dir, 26, PORT + 2,
        clock + ["--peaceful"],
        [["--client", "--identity", "shopper", "--panel", "MARKET", "--press", "1"]])
    check("pressed row 1: sent" in shopper.text(),
          "the interface sends what the row promised")
    sold = re.search(r"\[trade\] shopper ok: sold (\d+) (.+?) for (\d+) solari",
                     srv3.text())
    check(bool(sold),
          "and the server validates and books it"
          + (f" ({sold.group(0).split('ok: ')[1]})" if sold else ""))

    # Pressing a row that is not there must be refused, not crash.
    srv4, (fumble,) = session(
        user_dir, 24, PORT + 3,
        clock + ["--peaceful"],
        [["--client", "--identity", "fumble", "--panel", "JOURNEY", "--press", "9"]])
    check("no such row" in fumble.text(),
          "a row that does not exist is refused rather than obeyed")
    check("SCRIPT ERROR" not in fumble.text(), "and nothing errors")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    total = len(failures)
    if total:
        print(f"\nPhase 8 acceptance: FAIL ({total} failure(s))")
        for f in failures:
            print(f"  - {f}")
    else:
        print("\nPhase 8 acceptance: PASS")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
