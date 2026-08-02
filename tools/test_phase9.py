#!/usr/bin/env python3
"""Phase 9 acceptance test: the controls.

Phase 8 built an interface and tested it, and still shipped six actions that
were bound to keys, advertised in the HUD, and handled by nobody: build,
demolish, container, attack, extract and the debug toggle. Every one of them
had a working, replicated, server-validated implementation. The last inch --
`if pressed("attack"): world.try_attack()` -- was simply never written, and no
test could see it, because every harness in this project drives bots that call
the world's methods directly and never press anything.

So this suite tests the keyboard as its own subject:

  * no registered action is unhandled, and no key is bound twice -- the
    structural guard, and the only check here that catches the *next* one
  * each revived key reaches the server and is answered there, refusal included
  * the bag page equips, which is the only way a person can wear a stillsuit
  * a chest can be deployed, opened, and loaded from the bag -- moving
    resources, end to end
  * mouse-look does not disturb the movement contract the server validates

Every run is windowed under Xvfb: `--do` fires through the view's own dispatch
table, which is the point -- a headless client would prove nothing about keys.

Run: python3 tools/test_phase9.py
"""

import argparse
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
PORT = int(os.environ.get("DOON_TEST_PORT", "27480"))


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
        return "\n".join(m.group(1) for m in
                         re.finditer(r"^\[panel\] (.*)$", self.text(), re.M))


def launch(extra, user_dir, seconds, port, windowed=False):
    env = dict(os.environ)
    env["HOME"] = str(user_dir)
    if windowed:
        head = ["xvfb-run", "-a", "env", f"HOME={user_dir}", GODOT,
                "--resolution", "1280x800"]
    else:
        head = [GODOT, "--headless"]
    return Proc(head + ["--path", str(ROOT), "--",
                        "--port", str(port), "--run-seconds", str(seconds)] + extra, env)


def session(user_dir, seconds, port, server_extra, client, windowed=True):
    server = launch(["--server"] + server_extra, user_dir, seconds, port)
    time.sleep(2.0)
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
        print("FAIL: this suite is about keys, and keys need the view; "
              "no xvfb-run on this machine")
        return 1

    user_dir = ROOT / ".test_home_p9"
    if user_dir.exists():
        shutil.rmtree(user_dir)
    user_dir.mkdir(parents=True)

    failures = []

    def check(cond, msg):
        print(("  ok   " if cond else "  FAIL ") + msg)
        if not cond:
            failures.append(msg)

    clock = ["--day-seconds", "99999", "--start-time", "0.35", "--peaceful"]
    # Materials, not structures. A chest and a foundation are placed with the
    # Construction Tool and paid for out of the bag; neither is an item any
    # more, so granting one described a thing that does not exist.
    # The builder works down a fixed list and stops at the first thing it
    # cannot pay for, so the refined materials are here too -- otherwise it
    # never reaches the chest this run is about.
    kit = ["--grant", "stillsuit:1,construction_tool:1,granite_stone:80,"
           "salvaged_metal:60,plant_fiber:24,copper_ingot:24,fiber_weave:12"]

    # --- run 1: every key is answered ---------------------------------------
    # Nothing is in reach of any of these, on purpose: a refusal proves the key
    # reached the server just as well as a success, and it is the case the
    # player hits most.
    print("\n=== run 1: the revived keys reach the server ===")
    srv, cli = session(
        user_dir, 45, PORT, clock + kit,
        ["--client", "--identity", "tester", "--panel", "BAG",
         "--do", "trigger,extract,demolish,build,container"])
    s, c = srv.text(), cli.text()

    check("bound to both" not in c, "no two actions share a key")
    # The guard that makes this phase's bug impossible to repeat quietly.
    dead = re.findall(r"'(\w+)' is bound to a key but nothing handles it", c)
    check(not dead, "every registered action is handled"
          + (f" -- dead: {', '.join(dead)}" if dead else ""))

    # The trigger is the left mouse button now, and what it does depends on
    # what you are holding: empty-handed it swings.
    check("[combat] tester refused: nothing in reach" in s,
          "the trigger reaches the server as an attack")
    check("[blood] tester refused: nothing to draw from" in s,
          "[Z] draw water reaches the server")
    check("[demolish] tester refused: nothing to remove" in s,
          "[X] remove reaches the server")
    # These two the client settles itself, so they surface as notices instead.
    check("Construction Tool in hand" in c or "[build] tester" in s,
          "[V] build either builds or says why not")
    check("no container within reach" in c or "[container] tester" in s,
          "[T] container either opens one or says why not")
    check("SCRIPT ERROR" not in c and "Parse Error" not in c,
          "and nothing errors on the way")

    # --- run 2: the bag equips ----------------------------------------------
    print("\n=== run 2: wearing something ===")
    body = cli.panel()
    check("Stillsuit" in body and "wear" in body,
          "the bag page offers to wear the stillsuit")
    check("worn:" in body, "and says what you have on")

    # Run 1 carried the same kit, so its page tells us which row the stillsuit
    # is on. Read it rather than count it: only rows that do something are
    # numbered, so changing the kit renumbers the page.
    suit = re.search(r"\[(\d+)\]\s+Stillsuit", body)
    srv2, cli2 = session(
        user_dir, 40, PORT + 1, clock + kit,
        ["--client", "--identity", "dresser", "--panel", "BAG",
         "--press", suit.group(1) if suit else "4"])
    equipped = re.search(r"\[use\] dresser ok: equipped (.+)", srv2.text())
    check(bool(equipped),
          "pressing the row equips it server-side"
          + (f" ({equipped.group(1)})" if equipped else ""))

    # --- run 3: moving resources --------------------------------------------
    # A chest is deployed from the bag page, because the [B] key deploys
    # whatever is first and that is not necessarily the chest -- which is the
    # argument for the page existing.
    #
    # Land first. A chest has to stand somewhere, and unclaimed ground is
    # closed to everything but the Sub-Fief and the bench you craft it at, so
    # the fixture stakes a holding the way a player does rather than being
    # handed one. Same identity across both sessions, so the saved position
    # puts the hoarder back beside their own console.
    print("\n=== run 3: moving resources into a chest ===")
    store = ROOT / ".test_home_p9_chest"
    if store.exists():
        shutil.rmtree(store)
    store.mkdir(parents=True)

    srv3a, cli3a = session(
        store, 70, PORT + 2, clock + kit,
        ["--client", "--identity", "hoarder", "--auto", "--bot-profile", "builder"],
        windowed=False)
    a3 = srv3a.text()
    check("placed Sub-Fief Console" in a3,
          "the hoarder claims ground to put a chest on")
    check("placed Foundation" in a3, "and floors it, because kit stands on a floor")
    check("placed Storage Chest" in a3, "a chest goes down with the tool")


    # Same save, second visit: the chest is still there to be filled.
    srv4, cli4 = session(
        store, 40, PORT + 5, clock,
        ["--client", "--identity", "hoarder", "--panel", "CONTAINER",
         "--do", "container", "--press", "1"])
    page = cli4.panel()
    check("opened #" in srv4.text(), "[T] opens it")
    check("store " in page, "the container page offers to put things in")
    moved = re.search(r"\[container\] hoarder moved (.+)", srv4.text())
    check(bool(moved),
          "and a row press actually moves the goods"
          + (f" ({moved.group(1)})" if moved else ""))

    # --- run 4: looking around does not break movement ----------------------
    # The rotation itself is unit-tested; what matters here is that a windowed
    # client with the pointer captured still walks, syncs and draws.
    print("\n=== run 4: mouse-look leaves the movement contract alone ===")
    shot = user_dir / "look.png"
    srv5, cli5 = session(
        user_dir, 40, PORT + 6, clock,
        ["--client", "--identity", "looker", "--auto", "--bot-profile", "survive",
         "--screenshot", str(shot)])
    check(shot.exists() and shot.stat().st_size > 5000, "a windowed client still draws")
    check("rejected by server" not in cli5.text(), "and is not desynced")
    moves = re.findall(r"\[bot\] looker .* pos ([-\d.]+),([-\d.]+)", cli5.text())
    check(len(moves) >= 2 and moves[0] != moves[-1], "and still moves")

    if not args.keep:
        shutil.rmtree(user_dir, ignore_errors=True)
        shutil.rmtree(store, ignore_errors=True)

    total = len(failures)
    if total:
        print(f"\nPhase 9 acceptance: FAIL ({total} failure(s))")
        for f in failures:
            print(f"  - {f}")
    else:
        print("\nPhase 9 acceptance: PASS")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
