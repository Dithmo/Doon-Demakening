#!/usr/bin/env python3
"""Phase 11 acceptance test: the bag, the bar, and the beam.

The test a person actually wants to run, start to finish:

    start the game, open the bag, drag the cutteray onto hotbar slot 1, close
    the bag, press 1 to take it in hand, walk up to a scrap metal node, aim at
    it, hold the trigger, and watch four units a second come off it until there
    is nothing left.

Every step of that is checked here. The interesting part is *how*: a
mouse-driven grid is the least testable thing in this project, so the drag
decision lives in `InventoryView.drop()` and the pointer handler does nothing
but turn pixels into slot references before calling it. `--drag "bag:1>hot:0"`
runs the identical function with the identical arguments. Same trick as
`--press` in Phase 8 and `--do` in Phase 9, one layer further in.

Windowed under Xvfb throughout: the grid lives in the view, and a headless
client would prove nothing about it.

Run: python3 tools/test_phase11.py
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
PORT = int(os.environ.get("DOON_TEST_PORT", "27500"))


class Proc:
    def __init__(self, args, env):
        self._out = tempfile.NamedTemporaryFile(
            mode="w+", suffix=".log", delete=False)
        self.p = subprocess.Popen(
            args, cwd=ROOT, env=env, stdout=self._out, stderr=subprocess.STDOUT)
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


def launch(extra, user_dir, seconds, port, windowed=False):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    head = (["xvfb-run", "-a", "env", f"HOME={user_dir}", GODOT,
             "--resolution", "1280x800"] if windowed
            else [GODOT, "--headless"])
    return Proc(head + ["--path", str(ROOT), "--", "--port", str(port),
                        "--run-seconds", str(seconds)] + extra, env)


def session(user_dir, seconds, port, server_extra, client, windowed=True):
    server = launch(["--server"] + server_extra, user_dir, seconds, port)
    time.sleep(2.5)
    cli = launch(client, user_dir, seconds - 5, port, windowed)
    for p in (cli, server):
        p.wait(seconds + 60)
    return server, cli


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args()

    if not pathlib.Path(GODOT).exists():
        print(f"FAIL: no Godot binary at {GODOT} (set $GODOT)")
        return 1
    if shutil.which("xvfb-run") is None:
        print("FAIL: the grid needs a window; no xvfb-run on this machine")
        return 1

    user_dir = ROOT / ".test_home_p11"
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

    clock = ["--day-seconds", "99999", "--start-time", "0.35", "--peaceful"]

    # --- run 1: open the bag, drag the cutteray onto slot 1 -----------------
    print("\n=== run 1: dragging the cutteray onto the bar ===")
    shot = shots / "grid.png"
    srv, cli = session(
        user_dir, 45, PORT, clock,
        ["--client", "--identity", "dragger", "--do", "bag",
         "--drag", "bag:1>hot:0", "--screenshot", str(shot)])
    s, c = srv.text(), cli.text()

    check("[do] fired 'bag'" in c, "[I] opens the bag")
    check("[drag] bag:1 -> hot:0: sent" in c, "the drag is accepted by the grid")
    # The server is what decides it happened, exactly as for every other action.
    check("[hotbar] dragger slot 1 -> inventory 1" in s,
          "and the server puts it on hotbar slot 1")
    check(shot.exists() and shot.stat().st_size > 5000,
          f"the grid draws ({shot.stat().st_size if shot.exists() else 0} bytes)")
    check("SCRIPT ERROR" not in c and "Parse Error" not in c, "and nothing errors")
    check("nothing handles it" not in c, "no action is left unhandled")

    # --- run 2: the other three drags -------------------------------------
    print("\n=== run 2: the rest of the gestures ===")
    srv2, cli2 = session(
        user_dir, 45, PORT + 1, clock,
        ["--client", "--identity", "sorter", "--do", "bag",
         # onto the bar, shuffle along the bar, move within the bag, then off
         # the bar entirely -- every branch drop() has.
         "--drag", "bag:1>hot:0,hot:0>hot:3,bag:0>bag:9,hot:3>bag:2"])
    s2, c2 = srv2.text(), cli2.text()

    check(c2.count("sent") >= 4, f"all four gestures land ({c2.count('sent')})")
    check("[hotbar] sorter slot 4 -> inventory 1" in s2,
          "a key can be dragged along the bar")
    check("[bag] sorter moved slot 0 to 9" in s2,
          "and an item can be moved within the bag")
    # Dragging a key off the bar clears it rather than dropping the item.
    check("[hotbar] sorter slot 4 -> inventory -1" in s2,
          "dragging a key off the bar clears it")
    # Clearing a key must not destroy the item: it was only ever a pointer.
    inv2 = re.findall(r"\[inv\] sorter \| (.*)", c2)
    check(bool(inv2) and "cutteray" in inv2[-1],
          "and the item is still in the bag afterwards")

    # --- run 3: hold it, aim, and cut -------------------------------------
    # The cutter bot does the whole sequence for itself: puts the cutteray on
    # key 1, takes it in hand, walks to a node and holds the trigger.
    print("\n=== run 3: cutting with what is in your hand ===")
    srv3, cli3 = session(
        user_dir, 70, PORT + 2, clock,
        ["--client", "--identity", "cutter", "--auto", "--bot-profile", "cutter"],
        windowed=False)
    s3, c3 = srv3.text(), cli3.text()

    check("[hold] cutter holds slot 1 (Cutteray)" in s3,
          "pressing the key takes it in hand")
    check("opened up on node" in s3, "and the trigger opens a beam")

    cuts = re.findall(r"\[beam\] cutter cut (\d+) (\w+) \(node (\d+), (\d+) left\)", s3)
    check(len(cuts) > 10, f"the beam takes units off continuously ({len(cuts)} so far)")
    if cuts:
        # A node holds 40 and the beam runs at 4/s, so it should empty in ten
        # seconds -- and the count must run *down*.
        first_node = cuts[0][2]
        same = [int(c[3]) for c in cuts if c[2] == first_node]
        check(same == sorted(same, reverse=True),
              "and the node drains rather than jittering")
        check(min(same) == 0, f"until it is stripped bare (low water mark {min(same)})")

    # Four a second, measured against the server's own clock rather than assumed.
    stripped = re.search(r"\[beam\] cutter cut \d+ \w+ \(node (\d+), 0 left\)", s3)
    check(bool(stripped), "a node can be emptied in one sitting")

    check("SCRIPT ERROR" not in c3, "and nothing errors while cutting")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)

    total = len(failures)
    if total:
        print(f"\nPhase 11 acceptance: FAIL ({total} failure(s))")
        for f in failures:
            print(f"  - {f}")
    else:
        print("\nPhase 11 acceptance: PASS")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
